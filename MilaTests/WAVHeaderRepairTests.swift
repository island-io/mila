import XCTest
import AVFoundation
@testable import Mila

/// Unit tests for `WAVHeaderRepair` — the crash-recovery fix that rewrites the
/// `RIFF`/`data` size fields of a WAV whose header was never finalized because
/// the app was killed mid-recording (AVAudioFile only backfills the sizes on
/// close()). The audio frames are physically present; only the header lies.
final class WAVHeaderRepairTests: XCTestCase {

    // MARK: - byte helpers

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
    }
    private func le16(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]
    }
    private func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// A `fmt ` chunk (24 bytes) for float32 (or PCM) audio.
    private func fmtChunk(channels: UInt16, sampleRate: UInt32, bits: UInt16, format: UInt16 = 3) -> [UInt8] {
        let blockAlign = channels * (bits / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        return ascii("fmt ") + le32(16)
            + le16(format) + le16(channels) + le32(sampleRate)
            + le32(byteRate) + le16(blockAlign) + le16(bits)
    }

    /// Build a WAV with a canonical `fmt`+`data` layout.
    /// - `declaredData` lets us simulate an unfinalized header (pass 0).
    /// - Returns the full bytes + the offset of the `data` chunk.
    private func canonicalWAV(dataByteCount: Int,
                              declaredRiffSize: UInt32,
                              declaredDataSize: UInt32,
                              channels: UInt16 = 1,
                              sampleRate: UInt32 = 16000,
                              bits: UInt16 = 32) -> (bytes: [UInt8], dataChunkOffset: Int) {
        var out = ascii("RIFF") + le32(declaredRiffSize) + ascii("WAVE")
        out += fmtChunk(channels: channels, sampleRate: sampleRate, bits: bits)
        let dataChunkOffset = out.count
        out += ascii("data") + le32(declaredDataSize)
        out += [UInt8](repeating: 0xAB, count: dataByteCount)
        return (out, dataChunkOffset)
    }

    /// Build a WAV that mimics AVAudioFile's real layout: JUNK + fmt + FLLR
    /// padding before the `data` chunk (exactly the shape observed on disk).
    private func extendedWAV(dataByteCount: Int,
                             fllrPadding: Int,
                             declaredRiffSize: UInt32,
                             declaredDataSize: UInt32) -> (bytes: [UInt8], dataChunkOffset: Int) {
        var out = ascii("RIFF") + le32(declaredRiffSize) + ascii("WAVE")
        out += ascii("JUNK") + le32(28) + [UInt8](repeating: 0, count: 28)
        out += fmtChunk(channels: 1, sampleRate: 16000, bits: 32)
        out += ascii("FLLR") + le32(UInt32(fllrPadding)) + [UInt8](repeating: 0, count: fllrPadding)
        let dataChunkOffset = out.count
        out += ascii("data") + le32(declaredDataSize)
        out += [UInt8](repeating: 0xCD, count: dataByteCount)
        return (out, dataChunkOffset)
    }

    private func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }

    private func writeTemp(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavrepair-\(UUID().uuidString).wav")
        try Data(bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - plan()

    func test_unfinalized_canonical_yields_plan() {
        let (bytes, dataOff) = canonicalWAV(dataByteCount: 4000,
                                            declaredRiffSize: 36,   // header-only (crash)
                                            declaredDataSize: 0)    // never finalized
        let plan = WAVHeaderRepair.plan(header: bytes, fileSize: bytes.count)
        XCTAssertEqual(plan?.riffSizeOffset, 4)
        XCTAssertEqual(plan?.newRiffSize, UInt32(bytes.count - 8))
        XCTAssertEqual(plan?.dataSizeOffset, dataOff + 4)
        XCTAssertEqual(plan?.newDataSize, 4000)
    }

    func test_extended_header_locates_data_chunk() {
        // FLLR padding pushes `data` well past the canonical offset 44.
        let (bytes, dataOff) = extendedWAV(dataByteCount: 8000,
                                           fllrPadding: 4008,
                                           declaredRiffSize: 4088,
                                           declaredDataSize: 0)
        let plan = WAVHeaderRepair.plan(header: bytes, fileSize: bytes.count)
        XCTAssertEqual(plan?.dataSizeOffset, dataOff + 4)
        XCTAssertEqual(plan?.newDataSize, 8000)
        XCTAssertEqual(plan?.newRiffSize, UInt32(bytes.count - 8))
    }

    func test_finalized_header_yields_no_plan() {
        let dataCount = 4000
        let (bytes, _) = canonicalWAV(dataByteCount: dataCount,
                                      declaredRiffSize: UInt32(36 + dataCount),
                                      declaredDataSize: UInt32(dataCount))
        XCTAssertNil(WAVHeaderRepair.plan(header: bytes, fileSize: bytes.count),
                     "A correctly-finalized header must not be rewritten.")
    }

    func test_non_wav_yields_no_plan() {
        let junk = [UInt8]("not a wave file at all, just some bytes here".utf8)
        XCTAssertNil(WAVHeaderRepair.plan(header: junk, fileSize: junk.count))
    }

    func test_too_small_yields_no_plan() {
        let tiny = ascii("RIFF") + [0, 0, 0, 0] + ascii("WAVE")
        XCTAssertNil(WAVHeaderRepair.plan(header: tiny, fileSize: tiny.count))
    }

    func test_trailing_chunk_after_data_is_left_alone() {
        // A healthy WAV whose `data` chunk isn't last: a LIST/INFO trailer
        // (Audacity, Pro Tools, anything that appends metadata) makes the
        // physical remainder exceed the declared `data` size. Extending `data`
        // over it would splice metadata bytes into the audio stream. These
        // files reach us for real — the recordings directory is user-chosen
        // and RecordingStore adopts every unreferenced .wav it finds there.
        let dataCount = 4000
        var (bytes, _) = canonicalWAV(dataByteCount: dataCount,
                                      declaredRiffSize: 0,   // patched below
                                      declaredDataSize: UInt32(dataCount))
        let listPayload = ascii("INFOINAM") + le32(8) + ascii("My Song\0")
        bytes += ascii("LIST") + le32(UInt32(listPayload.count)) + listPayload
        // A healthy file declares the correct RIFF size for the whole thing.
        bytes.replaceSubrange(4..<8, with: le32(UInt32(bytes.count - 8)))

        XCTAssertNil(WAVHeaderRepair.plan(header: bytes, fileSize: bytes.count),
                     "A `data` chunk followed by a metadata chunk must not be extended over it.")
    }

    func test_overclaiming_data_size_is_left_alone() {
        // Truncated write: the header claims more audio than is on disk. We
        // can't invent the missing frames, and shrinking the field would take
        // away a reader's chance to salvage what is there — so: no plan.
        let (bytes, _) = canonicalWAV(dataByteCount: 4000,
                                      declaredRiffSize: UInt32(36 + 10_000),
                                      declaredDataSize: 10_000)
        XCTAssertNil(WAVHeaderRepair.plan(header: bytes, fileSize: bytes.count),
                     "An over-claiming `data` size is a different problem; don't rewrite it.")
    }

    func test_nonzero_stale_data_size_is_left_alone() {
        // Only the placeholder `0` is treated as "unfinalized". AVAudioFile
        // never publishes an intermediate size, so a non-zero-but-short size
        // came from some other writer and is not ours to reinterpret.
        let (bytes, _) = canonicalWAV(dataByteCount: 4000,
                                      declaredRiffSize: 36 + 1000,
                                      declaredDataSize: 1000)
        XCTAssertNil(WAVHeaderRepair.plan(header: bytes, fileSize: bytes.count))
    }

    func test_repairIfNeeded_leaves_a_healthy_file_byte_identical() throws {
        let dataCount = 4000
        let (bytes, _) = canonicalWAV(dataByteCount: dataCount,
                                      declaredRiffSize: UInt32(36 + dataCount),
                                      declaredDataSize: UInt32(dataCount))
        let url = try writeTemp(bytes)
        XCTAssertFalse(WAVHeaderRepair.repairIfNeeded(at: url))
        XCTAssertEqual([UInt8](try Data(contentsOf: url)), bytes,
                       "A finalized WAV must come back byte-for-byte unchanged.")
    }

    func test_repair_matches_a_real_AVAudioFile_close() throws {
        // Ground truth: write a WAV with AVAudioFile, snapshot the bytes while
        // it is still open (exactly what a crash leaves behind), then close it
        // and compare. The repair must reproduce close()'s header verbatim.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavrepair-live-\(UUID().uuidString).wav")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings,
                                                 commonFormat: .pcmFormatFloat32,
                                                 interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file!.processingFormat,
                                                    frameCapacity: 16_000))
        buffer.frameLength = 16_000
        for i in 0..<16_000 { buffer.floatChannelData![0][i] = Float(i % 100) / 100.0 }
        for _ in 0..<4 { try file!.write(from: buffer) }

        let unclosed = [UInt8](try Data(contentsOf: url))   // the "crashed" file
        file = nil                                          // close() finalizes the header
        let finalized = [UInt8](try Data(contentsOf: url))

        XCTAssertEqual(unclosed.count, finalized.count, "close() must not change the file length.")
        XCTAssertNotEqual(unclosed, finalized, "close() is expected to backfill the size fields.")

        // Put the unfinalized bytes back and let the repair redo close()'s work.
        try Data(unclosed).write(to: url)
        XCTAssertTrue(WAVHeaderRepair.repairIfNeeded(at: url))
        XCTAssertEqual([UInt8](try Data(contentsOf: url)), finalized,
                       "Repaired header must be byte-identical to what close() writes.")
    }

    func test_frame_flooring_drops_torn_final_frame() {
        // blockAlign = 4 (float32 mono). A crash left 2 extra bytes = a torn
        // frame; the repaired size must floor to a whole-frame multiple.
        let (bytes, _) = canonicalWAV(dataByteCount: 4002,
                                      declaredRiffSize: 36,
                                      declaredDataSize: 0)
        let plan = WAVHeaderRepair.plan(header: bytes, fileSize: bytes.count)
        XCTAssertEqual(plan?.newDataSize, 4000, "Should floor 4002 down to the nearest 4-byte frame boundary.")
    }

    // MARK: - repairIfNeeded()

    func test_repairIfNeeded_rewrites_and_is_idempotent() throws {
        let (bytes, dataOff) = canonicalWAV(dataByteCount: 4000,
                                            declaredRiffSize: 36,
                                            declaredDataSize: 0)
        let url = try writeTemp(bytes)

        XCTAssertTrue(WAVHeaderRepair.repairIfNeeded(at: url), "First call should write a fix.")

        let fixed = [UInt8](try Data(contentsOf: url))
        XCTAssertEqual(u32(fixed, 4), UInt32(bytes.count - 8), "RIFF size rewritten.")
        XCTAssertEqual(u32(fixed, dataOff + 4), 4000, "data size rewritten.")

        XCTAssertFalse(WAVHeaderRepair.repairIfNeeded(at: url),
                       "Second call is a no-op once the header is finalized.")
    }

    func test_repaired_file_is_readable_by_AVAudioFile() throws {
        // 250 float32 frames @ 16 kHz mono => 1000 data bytes, header says 0.
        let frames = 250
        let (bytes, _) = canonicalWAV(dataByteCount: frames * 4,
                                      declaredRiffSize: 36,
                                      declaredDataSize: 0)
        let url = try writeTemp(bytes)

        // Before repair AVAudioFile sees an empty (or unreadable) file.
        let before = try? AVAudioFile(forReading: url)
        XCTAssertTrue(before == nil || before!.length == 0,
                      "Unfinalized header should read as zero frames.")

        XCTAssertTrue(WAVHeaderRepair.repairIfNeeded(at: url))

        let after = try AVAudioFile(forReading: url)
        XCTAssertEqual(after.length, AVAudioFramePosition(frames),
                       "After repair the full audio is readable.")
    }

    func test_missing_file_is_noop() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).wav")
        XCTAssertFalse(WAVHeaderRepair.repairIfNeeded(at: url))
    }
}
