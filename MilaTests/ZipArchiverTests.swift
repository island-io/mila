import XCTest
@testable import Mila

final class ZipArchiverTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = TestSupport.makeTempRoot(label: "ZipArchiverTests")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    func test_zip_then_unzip_round_trips_the_directory_contents_at_the_archive_root() async throws {
        let payload = root.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: payload.appendingPathComponent("a.txt"))
        try Data(repeating: 7, count: 100_000).write(to: payload.appendingPathComponent("b.bin"))

        let archive = root.appendingPathComponent("out.zip")
        try await ZipArchiver.zipContents(of: payload, to: archive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))

        let out = root.appendingPathComponent("out", isDirectory: true)
        try await ZipArchiver.unzip(archive, into: out)
        let entries = Set(try FileManager.default.contentsOfDirectory(atPath: out.path))
        XCTAssertEqual(entries, ["a.txt", "b.bin"],
                       "entries must sit at the archive root — no parent folder, no __MACOSX")
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("a.txt")), Data("hello".utf8))
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("b.bin")).count, 100_000)
    }

    func test_unzipping_something_that_is_not_a_zip_throws_a_failure_with_the_exit_code() async throws {
        let notZip = root.appendingPathComponent("garbage.milashare")
        try Data((0..<2048).map { _ in UInt8.random(in: 0...255) }).write(to: notZip)

        do {
            try await ZipArchiver.unzip(notZip, into: root.appendingPathComponent("x"))
            XCTFail("expected a failure")
        } catch let failure as ZipArchiver.Failure {
            guard case .nonZeroExit(let code) = failure.kind else { return XCTFail("\(failure)") }
            XCTAssertNotEqual(code, 0)
            // The log line carries the code and a byte count, never ditto's
            // message (which quotes the paths it was given).
            XCTAssertFalse(failure.logDescription.contains("garbage.milashare"))
            XCTAssertTrue(failure.logDescription.contains("exit \(code)"))
        }
    }

    // MARK: - Listing

    func test_listEntries_reports_names_declared_sizes_and_types_without_extracting() async throws {
        let payload = root.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload.appendingPathComponent("sub", isDirectory: true),
                                                withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: payload.appendingPathComponent("a.txt"))
        try Data(repeating: 7, count: 100_000).write(to: payload.appendingPathComponent("sub/b.bin"))
        try FileManager.default.createSymbolicLink(at: payload.appendingPathComponent("link"),
                                                   withDestinationURL: payload.appendingPathComponent("a.txt"))
        let archive = root.appendingPathComponent("listed.zip")
        try await ZipArchiver.zipContents(of: payload, to: archive)

        let entries = try ZipArchiver.listEntries(of: archive)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        XCTAssertEqual(Set(byName.keys), ["a.txt", "sub/", "sub/b.bin", "link"],
                       "ditto writes an entry for the directory too; the importer must see it")
        XCTAssertEqual(byName["a.txt"]?.uncompressedSize, 5)
        XCTAssertEqual(byName["a.txt"]?.isDirectory, false)
        XCTAssertEqual(byName["a.txt"]?.isSymlink, false)
        XCTAssertEqual(byName["sub/b.bin"]?.uncompressedSize, 100_000,
                       "the DECLARED size, read while the entry is still deflated")
        XCTAssertEqual(byName["sub/"]?.isDirectory, true)
        XCTAssertEqual(byName["link"]?.isSymlink, true)
        // Nothing was inflated anywhere: the archive is the only new file.
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)),
                       ["payload", "listed.zip"])
    }

    /// `zip -fz` forces the ZIP64 layout onto a tiny archive: a saturated
    /// size in each central-directory header with the real value in the
    /// 0x0001 extra field, and a saturated directory offset in the EOCD that
    /// has to be followed through the ZIP64 locator. `ditto` writes the same
    /// layout past 4 GB, which no test wants to build.
    func test_listEntries_resolves_zip64_fields() throws {
        let payload = root.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 12_345).write(to: payload.appendingPathComponent("big.bin"))
        let archive = root.appendingPathComponent("zip64.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = payload
        zip.arguments = ["-q", "-fz", archive.path, "big.bin"]
        zip.standardOutput = FileHandle.nullDevice
        zip.standardError = FileHandle.nullDevice
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)

        XCTAssertEqual(try ZipArchiver.listEntries(of: archive),
                       [ZipArchiver.Entry(name: "big.bin", uncompressedSize: 12_345,
                                          isDirectory: false, isSymlink: false)])
    }

    func test_listEntries_refuses_what_is_not_a_zip_instead_of_trapping() async throws {
        let garbage = root.appendingPathComponent("garbage.bin")
        try Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: garbage)
        XCTAssertThrowsError(try ZipArchiver.listEntries(of: garbage)) {
            XCTAssertTrue($0 is ZipArchiver.MalformedArchive, "\($0)")
        }

        let empty = root.appendingPathComponent("empty.zip")
        try Data().write(to: empty)
        XCTAssertThrowsError(try ZipArchiver.listEntries(of: empty)) {
            XCTAssertTrue($0 is ZipArchiver.MalformedArchive, "\($0)")
        }

        // A real archive cut off halfway has lost its central directory.
        let payload = root.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 10_000).write(to: payload.appendingPathComponent("a.bin"))
        let archive = root.appendingPathComponent("whole.zip")
        try await ZipArchiver.zipContents(of: payload, to: archive)
        let bytes = try Data(contentsOf: archive)
        let truncated = root.appendingPathComponent("truncated.zip")
        try bytes.prefix(bytes.count / 2).write(to: truncated)
        XCTAssertThrowsError(try ZipArchiver.listEntries(of: truncated)) {
            XCTAssertTrue($0 is ZipArchiver.MalformedArchive, "\($0)")
        }
    }
}
