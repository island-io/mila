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
}
