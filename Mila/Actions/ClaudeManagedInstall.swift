import Foundation

/// Where Mila's own copy of the `claude` CLI lives, how its download URLs are
/// derived, and the one rule that decides when the managed OAuth token is
/// handed to a child process.
///
/// Everything here is **pure** except `binaryURL` / `stagingDirectory`, which
/// only compose paths. That is deliberate: the interesting decisions — which
/// platform build to fetch, whether a URL is one we are willing to download
/// from, whether this particular executable gets the token — are the ones a
/// test needs to pin, and none of them should require a network or a Keychain.
///
/// ## Why Mila installs its own copy at all (issue #271)
///
/// The alternative is what shipped before: tell the user to run
/// `curl … | bash` in a terminal and then hope `LLMRunner.searchDirectories()`
/// finds the result. That search exists (#196) and is good, but it is a
/// mitigation for a setup step nobody owned. A managed install turns three
/// terminal steps into one button, and — because Mila knows exactly which file
/// it installed — makes the token-injection rule below expressible at all.
enum ClaudeManagedInstall {

    // MARK: - Publisher identity

    /// Apple Developer Team ID on Anthropic's Developer ID signing certificate.
    ///
    /// Read off the official binary with
    /// `codesign -dv --verbose=4 $(which claude)`, which reports:
    ///
    ///     Authority=Developer ID Application: Anthropic PBC (Q6L2SF6YDW)
    ///     TeamIdentifier=Q6L2SF6YDW
    ///
    /// This is the check that makes the download meaningful. TLS says the bytes
    /// came from a host we trust; the signature says Anthropic produced them and
    /// nobody has touched them since — which still holds if the CDN itself is
    /// compromised, and which a checksum published by that same CDN cannot say.
    ///
    /// Hardcoded rather than configurable on purpose: a "which team do you
    /// trust?" setting is a setting for talking a user out of the check.
    static let anthropicTeamIdentifier = "Q6L2SF6YDW"

    /// Signing identifier embedded in the official binary (`Identifier=` in the
    /// same `codesign -dv` output). Checked alongside the team ID so a
    /// *different* Anthropic-signed binary — a future unrelated tool from the
    /// same team — can't be installed here and run as if it were the CLI.
    static let claudeSigningIdentifier = "com.anthropic.claude-code"

    // MARK: - Release endpoints

    /// The ONLY host Mila will download the CLI from.
    ///
    /// Taken from `https://claude.ai/install.sh`, Anthropic's own installer,
    /// which resolves everything under `$DOWNLOAD_BASE_URL`:
    ///
    ///     DOWNLOAD_BASE_URL="https://downloads.claude.ai/claude-code-releases"
    ///
    /// Mila replicates that resolution over HTTPS rather than piping the script
    /// to a shell — we want the version/manifest/binary steps to be code we can
    /// test and refuse from, not an opaque program that also runs
    /// `claude install` and edits the user's shell profile.
    ///
    /// `isTrusted(_:)` enforces the host, so a redirect or a manifest that tried
    /// to send us somewhere else is refused rather than followed.
    static let downloadHost = "downloads.claude.ai"

    /// Base for every release artifact. Kept as a string constant so the three
    /// URL builders below cannot drift apart.
    static let downloadBase = "https://\(downloadHost)/claude-code-releases"

    /// `GET` this for the current version string (e.g. `2.1.263`). Plain text,
    /// no JSON — matching `install.sh`'s `download_file "$DOWNLOAD_BASE_URL/latest"`.
    static var latestVersionURL: URL { URL(string: "\(downloadBase)/latest")! }

    /// Per-version manifest carrying a SHA-256 and a byte size for every
    /// platform build. See `ReleaseManifest`.
    static func manifestURL(version: String) -> URL? {
        guard isPlausibleVersion(version) else { return nil }
        return URL(string: "\(downloadBase)/\(version)/manifest.json")
    }

    /// The platform binary itself.
    static func binaryDownloadURL(version: String, platform: String) -> URL? {
        guard isPlausibleVersion(version), isPlausiblePlatform(platform) else { return nil }
        return URL(string: "\(downloadBase)/\(version)/\(platform)/claude")
    }

    /// Whether a URL is one we are willing to fetch: HTTPS, and on the release
    /// host exactly (not a subdomain of it, not a userinfo trick).
    ///
    /// Applied to every request AND to the final URL after redirects, so a
    /// 302 off the CDN cannot quietly become the thing we execute.
    static func isTrusted(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        guard url.user == nil, url.password == nil else { return false }
        return url.host?.lowercased() == downloadHost
    }

    /// Guards the version string before it is interpolated into a URL. The
    /// version comes off the network, and `2.1.263/../../evil` would otherwise
    /// build a path that escapes the release prefix.
    ///
    /// Deliberately narrow — digits, dots, and a `-suffix` for pre-releases —
    /// which is the same shape `install.sh` accepts
    /// (`^[0-9]+\.[0-9]+\.[0-9]+(-[^[:space:]]+)?$`).
    ///
    /// Written with the `#/…/#` extended delimiters rather than a bare `/…/`
    /// literal: this target builds in Swift 5.10 language mode, where the bare
    /// form needs the `BareSlashRegexLiterals` upcoming-feature flag that
    /// `project.yml` does not set. The extended form needs no flag.
    static func isPlausibleVersion(_ version: String) -> Bool {
        guard !version.isEmpty, version.count <= 64 else { return false }
        return version.wholeMatch(of: #/[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?/#) != nil
    }

    /// Same guard for the platform segment. Only the two macOS builds are
    /// accepted: Mila is a macOS app, so a manifest key naming a Linux or
    /// Windows build is either a bug or a redirect attempt.
    static func isPlausiblePlatform(_ platform: String) -> Bool {
        platform == "darwin-arm64" || platform == "darwin-x64"
    }

    // MARK: - Platform selection

    /// Which manifest key describes the build for this Mac.
    ///
    /// `install.sh` derives it from `uname -m`, plus one correction: when the
    /// shell is itself running as x86_64 under Rosetta on an Apple Silicon Mac
    /// it fetches the **arm64** build anyway, because the native binary is the
    /// right one for the machine. A Swift process has the same problem — a
    /// Mila built for x86_64 running translated would otherwise install a
    /// translated CLI — and the same answer: `sysctl.proc_translated`.
    ///
    /// `isTranslated` is a parameter so the Rosetta branch is testable on a
    /// machine that isn't running under Rosetta.
    static func platformKey(machine: String = currentMachine(),
                            isTranslated: Bool = isRunningTranslated()) -> String? {
        switch machine {
        case "arm64", "aarch64":
            return "darwin-arm64"
        case "x86_64", "amd64":
            // Translated x86_64 on an arm64 Mac: take the native build.
            return isTranslated ? "darwin-arm64" : "darwin-x64"
        default:
            return nil
        }
    }

    /// `uname -m`, without shelling out.
    static func currentMachine() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return "" }
        let capacity = MemoryLayout.size(ofValue: info.machine)
        return withUnsafePointer(to: &info.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }

    /// True when this process is an x86_64 binary running under Rosetta 2.
    /// `sysctl.proc_translated` is absent on Intel Macs and on native arm64
    /// processes, which both read as "not translated".
    static func isRunningTranslated() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0) == 0 else {
            return false
        }
        return value == 1
    }

    // MARK: - On-disk layout

    /// `~/Library/Application Support`, with the same temp-directory fallback
    /// `LLMRunner.sandboxDirectory()` uses. Mila is not app-sandboxed, so this
    /// is the real user-domain path.
    static func applicationSupportRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    /// Directory holding Mila-managed executables. Sibling of the
    /// `llm-sandbox` directory `LLMRunner` already owns, under the same
    /// `Mila` root, so everything Mila puts on this machine outside the
    /// recordings folder stays in one place a user can delete.
    static func binDirectory(appSupportRoot: URL = applicationSupportRoot()) -> URL {
        appSupportRoot
            .appendingPathComponent("Mila", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
    }

    /// The managed CLI itself. This exact path is what
    /// `environmentAdditions(executable:managedBinary:token:)` compares
    /// against, and what `LLMRunner.resolveExecutable` prefers.
    static func binaryURL(appSupportRoot: URL = applicationSupportRoot()) -> URL {
        binDirectory(appSupportRoot: appSupportRoot)
            .appendingPathComponent("claude", isDirectory: false)
    }

    /// Where a download is assembled before it is verified. Separate from
    /// `binDirectory` so an interrupted or failed download can never be found
    /// by `resolveExecutable` — an unverified binary must not be reachable by
    /// anything that would run it.
    static func stagingDirectory(appSupportRoot: URL = applicationSupportRoot()) -> URL {
        binDirectory(appSupportRoot: appSupportRoot)
            .appendingPathComponent("staging", isDirectory: true)
    }

    /// True when a managed binary is present and executable.
    static func isInstalled(fileManager: FileManager = .default,
                            appSupportRoot: URL = applicationSupportRoot()) -> Bool {
        fileManager.isExecutableFile(atPath: binaryURL(appSupportRoot: appSupportRoot).path)
    }

    // MARK: - Token injection

    /// Name of the environment variable the CLI reads a long-lived OAuth token
    /// from. Confirmed present in the shipped binary (`strings` on the official
    /// 2.1.260 build) and it is what `claude setup-token` mints a token *for*.
    static let oauthTokenEnvironmentKey = "CLAUDE_CODE_OAUTH_TOKEN"

    /// The one rule that decides whether Mila's stored token travels to a child
    /// process: **only when the executable being run is Mila's own managed
    /// binary.**
    ///
    /// Both halves of that matter, and they fail in opposite directions:
    ///
    ///   * Injecting too *narrowly* breaks the feature — the whole point of the
    ///     managed install is that the token Mila minted is the credential the
    ///     binary Mila installed uses.
    ///   * Injecting too *broadly* breaks other people's setups, silently and
    ///     confusingly. A user with their own `claude` on `PATH` is already
    ///     logged in, quite possibly to a different account or through a
    ///     corporate SSO. Handing that binary a `CLAUDE_CODE_OAUTH_TOKEN`
    ///     overrides the login they chose, with no UI anywhere saying so.
    ///     A system CLI is left exactly as it was.
    ///
    /// Nothing is ever *removed* from the environment, including an inherited
    /// `CLAUDE_CODE_OAUTH_TOKEN` the user set themselves: that is their
    /// deliberate configuration for their own binary, and unsetting it would be
    /// the same overreach in the other direction.
    ///
    /// Paths are compared after `standardizedFileURL` resolution so
    /// `…/bin/claude` and `…/bin/./claude` are the same file. A user who points
    /// the "Executable" override *at* the managed binary therefore still gets
    /// the token, which is the right answer — it is the same file.
    ///
    /// `token` is passed in rather than read here so this stays pure: the
    /// Keychain read happens at the call site, and only when it can matter.
    static func environmentAdditions(executable: URL,
                                     managedBinary: URL,
                                     token: String?) -> [String: String] {
        guard executable.standardizedFileURL.path == managedBinary.standardizedFileURL.path else {
            return [:]
        }
        guard let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [:]
        }
        return [oauthTokenEnvironmentKey: token]
    }

    // MARK: - Release manifest

    /// The subset of `manifest.json` Mila reads.
    ///
    /// The real document carries a `platforms` map keyed by the platform string
    /// (`darwin-arm64`, `linux-x64-musl`, …), each entry holding a `checksum`
    /// (SHA-256, lowercase hex) and a `size`. Everything else in the document —
    /// `commit`, `buildDate`, signature-enforcement flags — is ignored, and
    /// ignoring it is what keeps this decoding robust across manifest changes.
    struct ReleaseManifest: Decodable, Equatable {
        struct Platform: Decodable, Equatable {
            let checksum: String
            let size: Int64?
        }
        let version: String?
        let platforms: [String: Platform]

        /// The checksum for `platform`, validated to be a well-formed SHA-256.
        ///
        /// A malformed value is treated as *absent* rather than passed through:
        /// a truncated or non-hex "checksum" that we then compared against
        /// would fail every time, which reads to a user as "the download is
        /// corrupt" when the truth is "the manifest is". `install.sh` applies
        /// the same `^[a-f0-9]{64}$` guard for the same reason.
        func checksum(for platform: String) -> String? {
            guard let raw = platforms[platform]?.checksum else { return nil }
            let value = raw.lowercased()
            guard value.count == 64,
                  value.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
            return value
        }

        func expectedSize(for platform: String) -> Int64? {
            guard let size = platforms[platform]?.size, size > 0 else { return nil }
            return size
        }
    }
}
