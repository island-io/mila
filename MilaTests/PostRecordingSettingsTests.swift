import XCTest
@testable import Mila

@MainActor
final class PostRecordingSettingsTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let suite = "PostRecordingSettingsTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func test_batchOnly_defaults_to_off() {
        let s = PostRecordingSettings(defaults: freshDefaults())
        XCTAssertFalse(s.batchOnly, "Batch-only should default OFF so users get live transcription")
    }

    func test_batchOnly_persists_across_reinit() throws {
        let defaults = freshDefaults()
        do {
            let s = PostRecordingSettings(defaults: defaults)
            s.batchOnly = true
        }
        let reloaded = PostRecordingSettings(defaults: defaults)
        XCTAssertTrue(reloaded.batchOnly, "Batch-only should survive a relaunch")
    }

    func test_batchOnly_toggle_off_persists() throws {
        let defaults = freshDefaults()
        do {
            let s = PostRecordingSettings(defaults: defaults)
            s.batchOnly = true
            s.batchOnly = false
        }
        let reloaded = PostRecordingSettings(defaults: defaults)
        XCTAssertFalse(reloaded.batchOnly, "Turning batch-only off should persist")
    }
}
