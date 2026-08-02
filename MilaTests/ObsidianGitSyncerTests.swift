import XCTest
@testable import Mila

/// Records every git invocation and returns programmable results, so we can
/// assert the command sequence without a real repo. An actor because
/// `ObsidianGitSyncer` calls it from actor-isolated context and reads must be
/// awaited afterwards.
private actor FakeGitRunner: GitCommandRunning {
    private(set) var calls: [[String]] = []
    private let handler: @Sendable ([String]) -> GitCommandResult

    init(handler: @escaping @Sendable ([String]) -> GitCommandResult) {
        self.handler = handler
    }

    func run(_ arguments: [String], in directory: URL) async -> GitCommandResult {
        calls.append(arguments)
        return handler(arguments)
    }
}

private func ok(_ stdout: String = "") -> GitCommandResult {
    GitCommandResult(exitCode: 0, stdout: stdout, stderr: "", timedOut: false)
}

private func fail(_ stderr: String) -> GitCommandResult {
    GitCommandResult(exitCode: 1, stdout: "", stderr: stderr, timedOut: false)
}

final class ObsidianGitSyncerTests: XCTestCase {

    private let vault = URL(fileURLWithPath: "/repo/vault")
    private let file = URL(fileURLWithPath: "/repo/vault/note.md")

    func test_happy_path_runs_add_commit_rebase_push_in_order() async {
        let fake = FakeGitRunner { args in
            args.first == "rev-parse" ? ok("/repo") : ok()
        }
        let syncer = ObsidianGitSyncer(runner: fake)
        let error = await syncer.sync(vault: vault, changedPaths: [file],
                                      branch: "main", commitMessage: "Add transcript: T")
        XCTAssertNil(error)
        let calls = await fake.calls
        XCTAssertEqual(calls, [
            ["rev-parse", "--show-toplevel"],
            ["add", "--all", "--", file.path],
            ["commit", "-m", "Add transcript: T"],
            ["pull", "--rebase", "origin", "refs/heads/main"],
            ["push", "origin", "HEAD:refs/heads/main"],
        ])
    }

    func test_not_a_repo_returns_error_and_stops() async {
        let fake = FakeGitRunner { _ in fail("not a git repository") }
        let syncer = ObsidianGitSyncer(runner: fake)
        let error = await syncer.sync(vault: vault, changedPaths: [file],
                                      branch: "main", commitMessage: "m")
        XCTAssertNotNil(error)
        let calls = await fake.calls
        XCTAssertEqual(calls, [["rev-parse", "--show-toplevel"]])
    }

    func test_nothing_to_commit_still_pulls_and_pushes() async {
        let fake = FakeGitRunner { args in
            switch args.first {
            case "rev-parse": return ok("/repo")
            case "commit": return fail("nothing to commit, working tree clean")
            default: return ok()
            }
        }
        let syncer = ObsidianGitSyncer(runner: fake)
        let error = await syncer.sync(vault: vault, changedPaths: [file],
                                      branch: "main", commitMessage: "m")
        XCTAssertNil(error, "an unchanged note is not a failure")
        let calls = await fake.calls
        XCTAssertTrue(calls.contains(["pull", "--rebase", "origin", "refs/heads/main"]))
        XCTAssertTrue(calls.contains(["push", "origin", "HEAD:refs/heads/main"]))
    }

    func test_rebase_conflict_aborts_and_does_not_push() async {
        let fake = FakeGitRunner { args in
            switch args.first {
            case "rev-parse": return ok("/repo")
            case "pull": return fail("CONFLICT (content): Merge conflict")
            default: return ok()
            }
        }
        let syncer = ObsidianGitSyncer(runner: fake)
        let error = await syncer.sync(vault: vault, changedPaths: [file],
                                      branch: "main", commitMessage: "m")
        XCTAssertNotNil(error)
        let calls = await fake.calls
        XCTAssertTrue(calls.contains(["rebase", "--abort"]),
                      "a rebase conflict must be aborted so the vault isn't left mid-rebase")
        XCTAssertFalse(calls.contains(where: { $0.first == "push" }),
                       "push must not run after a failed rebase")
    }

    func test_push_failure_is_surfaced() async {
        let fake = FakeGitRunner { args in
            switch args.first {
            case "rev-parse": return ok("/repo")
            case "push": return fail("Permission denied (publickey)")
            default: return ok()
            }
        }
        let syncer = ObsidianGitSyncer(runner: fake)
        let error = await syncer.sync(vault: vault, changedPaths: [file],
                                      branch: "main", commitMessage: "m")
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.contains("push") == true)
    }

    func test_branch_is_honored() async {
        let fake = FakeGitRunner { args in args.first == "rev-parse" ? ok("/repo") : ok() }
        let syncer = ObsidianGitSyncer(runner: fake)
        _ = await syncer.sync(vault: vault, changedPaths: [file],
                              branch: "notes", commitMessage: "m")
        let calls = await fake.calls
        XCTAssertTrue(calls.contains(["pull", "--rebase", "origin", "refs/heads/notes"]))
        XCTAssertTrue(calls.contains(["push", "origin", "HEAD:refs/heads/notes"]))
    }

    // MARK: - Branch validation

    /// `obsidian.git.branch` is free text from Settings and lands in an
    /// argument position where git reads a leading `-` as an option. A branch
    /// named `--upload-pack=…` would turn the sync into an arbitrary-command
    /// execution against the user's vault. Nothing may run at all.
    func test_a_branch_that_looks_like_an_option_runs_no_git_at_all() async {
        for hostile in ["--upload-pack=/bin/sh", "-o", "--exec=evil", "-"] {
            let fake = FakeGitRunner { args in args.first == "rev-parse" ? ok("/repo") : ok() }
            let syncer = ObsidianGitSyncer(runner: fake)
            let error = await syncer.sync(vault: vault, changedPaths: [file],
                                          branch: hostile, commitMessage: "m")
            XCTAssertNotNil(error, "\(hostile.debugDescription) must be rejected")
            let calls = await fake.calls
            XCTAssertTrue(calls.isEmpty,
                          "\(hostile.debugDescription) reached git as \(calls)")
        }
    }

    func test_invalid_branch_names_are_rejected_before_any_command() async {
        for hostile in ["", " ", "a b", "a~b", "a^b", "a:b", "a..b", "a?b", "a*b",
                        "a[b", "a\\b", "feature.lock", "/leading", "trailing/",
                        ".dot", "dot.", "a@{0}", "a\nb", "a\tb"] {
            let fake = FakeGitRunner { args in args.first == "rev-parse" ? ok("/repo") : ok() }
            let syncer = ObsidianGitSyncer(runner: fake)
            let error = await syncer.sync(vault: vault, changedPaths: [file],
                                          branch: hostile, commitMessage: "m")
            XCTAssertNotNil(error, "\(hostile.debugDescription) must be rejected")
            let calls = await fake.calls
            XCTAssertTrue(calls.isEmpty, "\(hostile.debugDescription) reached git as \(calls)")
        }
    }

    /// The names people actually use must keep working.
    func test_ordinary_branch_names_are_accepted() {
        for good in ["main", "master", "notes", "feature/obsidian", "v1.9.2",
                     "user/kobi-vault", "release-2026", "notes_2"] {
            XCTAssertTrue(ObsidianGitSyncer.isValidBranch(good), good)
        }
    }
}
