import XCTest
@testable import Mila

final class AppSupportLocationTests: XCTestCase {

    /// A FileManager whose directory creation always fails, like a read-only
    /// home. The old `try!` crashed here.
    private final class FailingFileManager: FileManager {
        override func url(for directory: FileManager.SearchPathDirectory,
                          in domain: FileManager.SearchPathDomainMask,
                          appropriateFor url: URL?,
                          create shouldCreate: Bool) throws -> URL {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private final class NoDirectoryFileManager: FileManager {
        override func url(for directory: FileManager.SearchPathDirectory,
                          in domain: FileManager.SearchPathDomainMask,
                          appropriateFor url: URL?,
                          create shouldCreate: Bool) throws -> URL {
            throw CocoaError(.fileWriteNoPermission)
        }
        override func urls(for directory: FileManager.SearchPathDirectory,
                           in domainMask: FileManager.SearchPathDomainMask) -> [URL] { [] }
    }

    func test_normal_lookup_returns_application_support() {
        let url = AppSupportLocation.directory()
        XCTAssertTrue(url.path.contains("Application Support"))
    }

    func test_failed_creation_falls_back_to_the_search_path_url() {
        let url = AppSupportLocation.directory(fileManager: FailingFileManager())
        XCTAssertTrue(url.path.contains("Application Support"))
    }

    func test_no_directory_at_all_falls_back_to_temp_instead_of_crashing() {
        let fm = NoDirectoryFileManager()
        XCTAssertEqual(AppSupportLocation.directory(fileManager: fm), fm.temporaryDirectory)
    }
}
