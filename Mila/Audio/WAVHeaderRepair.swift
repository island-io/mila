import Foundation
import OSLog

private let wavRepairLog = Logger(subsystem: "io.island.whisper.IslandWhisper",
                                  category: "WAVHeaderRepair")

/// Repairs WAV files whose header size fields were never finalized because the
/// app was killed mid-recording.
///
/// `AVAudioFile` streams the PCM frames to disk as they arrive, but only
/// backfills the `RIFF` chunk size and the `data` chunk size when the file is
/// `close()`d — which only happens on a clean Stop. A crash / force-quit skips
/// `close()`, so the header is frozen at its initial placeholder (`data`
/// size = 0). Every decoder — including Mila's own transcription reader —
/// then honors that header and treats the file as empty, even though the audio
/// is physically present. Rewriting the two size fields from the actual file
/// length makes the recording readable again.
///
/// The decision (`plan`) is a pure function over the header bytes + file size
/// so it can be unit-tested without touching the filesystem; `repairIfNeeded`
/// applies it in place.
enum WAVHeaderRepair {

    /// A concrete repair to apply: which little-endian `UInt32` fields to
    /// overwrite and with what values.
    struct Plan: Equatable {
        /// Offset of the `RIFF` chunk size field — always 4 for a real WAV.
        let riffSizeOffset: Int
        let newRiffSize: UInt32
        /// Offset of the `data` chunk's size field (chunk offset + 4).
        let dataSizeOffset: Int
        let newDataSize: UInt32
    }

    /// Decide whether `header` describes an unfinalized WAV that needs its
    /// `RIFF`/`data` size fields rewritten. Returns `nil` for anything that
    /// isn't the crash signature — an already-finalized header, a `data` size
    /// that is merely wrong rather than zero, a file we don't recognize as a
    /// WAV, or one too small to hold a header. Callers treat "no plan" as
    /// "leave the file untouched", so the default is always to do nothing.
    ///
    /// - Parameters:
    ///   - header: the first bytes of the file (the RIFF header + chunk table
    ///     live in the first few KB; pass a generous prefix, e.g. 64 KB).
    ///   - fileSize: the physical file size in bytes.
    static func plan(header: [UInt8], fileSize: Int) -> Plan? {
        // Minimum: RIFF(8) + WAVE(4) + fmt(24) + data header(8) = 44.
        guard fileSize > 44, header.count >= 12 else { return nil }
        guard header[0] == 0x52, header[1] == 0x49, header[2] == 0x46, header[3] == 0x46, // "RIFF"
              header[8] == 0x57, header[9] == 0x41, header[10] == 0x56, header[11] == 0x45 // "WAVE"
        else { return nil }

        func u32(_ offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= header.count else { return nil }
            return UInt32(header[offset])
                | (UInt32(header[offset + 1]) << 8)
                | (UInt32(header[offset + 2]) << 16)
                | (UInt32(header[offset + 3]) << 24)
        }
        func tag(_ offset: Int, _ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Bool {
            offset + 4 <= header.count
                && header[offset] == a && header[offset + 1] == b
                && header[offset + 2] == c && header[offset + 3] == d
        }

        // Walk the chunk table to find `data` (and `fmt ` for block alignment).
        var offset = 12
        var blockAlign = 0
        var dataChunkOffset: Int?
        while offset + 8 <= header.count {
            guard let size = u32(offset + 4) else { break }
            if tag(offset, 0x64, 0x61, 0x74, 0x61) {          // "data"
                dataChunkOffset = offset
                break
            }
            if tag(offset, 0x66, 0x6d, 0x74, 0x20),           // "fmt "
               offset + 8 + 14 <= header.count {
                // fmt content: audioFormat(2) numChannels(2) sampleRate(4)
                // byteRate(4) blockAlign(2)@12 bitsPerSample(2)@14.
                blockAlign = Int(header[offset + 8 + 12])
                    | (Int(header[offset + 8 + 13]) << 8)
            }
            // Chunks are word-aligned: an odd size carries a trailing pad byte.
            offset += 8 + Int(size) + (Int(size) & 1)
        }

        guard let dataChunkOffset else { return nil }
        let dataStart = dataChunkOffset + 8
        guard dataStart <= fileSize else { return nil }

        var available = fileSize - dataStart
        // Floor to a whole frame so a torn final frame (crash mid-write) doesn't
        // leave a fractional sample the reader could choke on.
        if blockAlign > 1 { available -= available % blockAlign }
        guard available > 0 else { return nil }

        // Only repair the exact crash signature: a `data` size still sitting at
        // the placeholder `0`. `AVAudioFile` writes the header once on open
        // (JUNK + fmt + FLLR + `data` size 0) and backfills the two size fields
        // only in `close()` — it never publishes an intermediate size, however
        // many megabytes have streamed out. So `0` is the whole failure mode.
        //
        // The looser rule "declared is smaller than what's on disk" would also
        // fire on a perfectly healthy WAV whose `data` chunk simply isn't last:
        // a trailing `LIST`/`INFO`, `cue `, or `id3 ` chunk makes the physical
        // remainder exceed the declared size, and extending `data` over it
        // would splice metadata into the audio stream. That matters because the
        // recordings directory is user-chosen (Settings → Storage) and
        // `RecordingStore.recoverOrphanRecordings` adopts *every* unreferenced
        // `.wav` it finds there — foreign files written by other tools really
        // do reach this code, and this is the user's only copy.
        //
        // A size that over-claims (a truncated write) is likewise left alone:
        // we can't invent the missing audio, and shrinking the field would
        // discard a reader's chance to salvage what is there.
        //
        // Keying off `0` alone also makes the call idempotent and convergent
        // after a partial write — see `repairIfNeeded`.
        guard u32(dataChunkOffset + 4) == 0 else { return nil }

        // WAV size fields are UInt32; a >4 GiB file can't be described by the
        // format anyway, so bail rather than truncate.
        guard available <= Int(UInt32.max), (fileSize - 8) <= Int(UInt32.max) else { return nil }

        return Plan(riffSizeOffset: 4,
                    newRiffSize: UInt32(fileSize - 8),
                    dataSizeOffset: dataChunkOffset + 4,
                    newDataSize: UInt32(available))
    }

    /// Repair the WAV at `url` in place if its header is unfinalized. Returns
    /// `true` iff both size fields were written and flushed. Safe to call on any
    /// file: non-WAVs, already-finalized WAVs, and unreadable paths are no-ops.
    ///
    /// A `false` return means "don't rely on this file being fixed", not
    /// "nothing was touched" — if the RIFF write lands and the `data` write
    /// fails, the file has been partially updated. That's safe to retry:
    /// `plan` keys the decision off the `data` field alone, so a later call
    /// re-derives the same plan and converges.
    @discardableResult
    static func repairIfNeeded(at url: URL) -> Bool {
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard fileSize > 44 else { return false }
        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }

        // The RIFF header + chunk table sit in the first few KB; 64 KB is
        // comfortably beyond any realistic fmt/JUNK/FLLR padding.
        guard let prefix = try? handle.read(upToCount: 64 * 1024),
              let plan = plan(header: [UInt8](prefix), fileSize: fileSize)
        else { return false }

        func write(_ value: UInt32, at offset: Int) -> Bool {
            var le = value.littleEndian
            let bytes = Data(bytes: &le, count: 4)
            do {
                try handle.seek(toOffset: UInt64(offset))
                try handle.write(contentsOf: bytes)
                return true
            } catch {
                wavRepairLog.error("WAV header write failed at \(offset): \(error.localizedDescription, privacy: .public)")
                return false
            }
        }

        let okRiff = write(plan.newRiffSize, at: plan.riffSizeOffset)
        let okData = write(plan.newDataSize, at: plan.dataSizeOffset)
        guard okRiff && okData else { return false }
        // Force the header out to durable storage. This path only runs because
        // a crash already cost us the clean close(); leaving the fix sitting in
        // the page cache would let a second crash lose it again.
        do {
            try handle.synchronize()
        } catch {
            wavRepairLog.error("WAV header fsync failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        wavRepairLog.log("repaired unfinalized WAV header for \(url.lastPathComponent, privacy: .public) (data size -> \(plan.newDataSize))")
        return true
    }
}
