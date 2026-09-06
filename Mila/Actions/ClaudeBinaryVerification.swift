import Foundation
import CryptoKit
import Security
import os

private let verifyLog = os.Logger(subsystem: "io.island.whisper.IslandWhisper",
                                  category: "ClaudeInstall")

/// What a code signature says about who produced a binary. Deliberately tiny —
/// two strings — so the accept/refuse decision below is a pure function over
/// values a test can construct, rather than something that can only be
/// exercised by having a real signed Mach-O on disk.
struct ClaudeSignatureIdentity: Equatable {
    /// `TeamIdentifier=` — the Apple Developer Team ID.
    let teamIdentifier: String?
    /// `Identifier=` — the signing identifier baked into the binary.
    let signingIdentifier: String?
    /// Whether the signature itself checked out: intact, chained to the Apple
    /// root, and matching the bytes on disk. False means the identity strings
    /// above are unverified claims and must not be trusted for anything.
    let isValid: Bool
}

/// Everything that can stop Mila from installing or running a downloaded CLI.
///
/// Each case says what failed **and** what a user can do about it, because the
/// only place these surface is a Settings row with no log next to it. The two
/// verification failures deliberately do not offer a way to continue: a
/// "download it anyway" button is a button for defeating the check.
enum ClaudeInstallError: LocalizedError, Equatable {
    case unsupportedPlatform(String)
    case versionLookupFailed(String)
    case manifestMissingPlatform(String)
    case untrustedURL(String)
    case httpError(status: Int)
    case checksumMismatch(expected: String, actual: String)
    case sizeMismatch(expected: Int64, actual: Int64)
    case signatureInvalid(String)
    case wrongPublisher(team: String?, identifier: String?)
    case installFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform(let machine):
            return "Mila doesn't have a Claude build for this Mac's architecture (\(machine))."
        case .versionLookupFailed(let detail):
            return "Couldn't find out which Claude version to download. \(detail)"
        case .manifestMissingPlatform(let platform):
            return "Anthropic's release manifest has no \(platform) build listed."
        case .untrustedURL(let url):
            return "Refusing to download from an unexpected location (\(url)). Mila only downloads Claude from \(ClaudeManagedInstall.downloadHost)."
        case .httpError(let status):
            return "The download server returned HTTP \(status)."
        case .checksumMismatch(let expected, let actual):
            // Both digests in full: they are public values, and "which one
            // differs" is the only way to tell a truncated download from a
            // substituted file.
            return "The downloaded file doesn't match Anthropic's published checksum, so Mila deleted it. Expected \(expected), got \(actual)."
        case .sizeMismatch(let expected, let actual):
            return "The download stopped early (\(actual) of \(expected) bytes). Check your connection and try again."
        case .signatureInvalid(let detail):
            return "The downloaded Claude binary isn't correctly signed, so Mila won't run it. \(detail)"
        case .wrongPublisher(let team, let identifier):
            let who = [identifier, team].compactMap { $0 }.joined(separator: ", ")
            return "The downloaded binary is signed by someone other than Anthropic\(who.isEmpty ? "" : " (\(who))"), so Mila won't run it."
        case .installFailed(let detail):
            return "Couldn't finish installing Claude. \(detail)"
        case .cancelled:
            return "Setup was cancelled."
        }
    }

    /// The log-safe twin, following the same split `LLMRunnerError.logDescription`
    /// makes: shape yes, payload no. Nothing here carries a credential or user
    /// content — these are checksums, HTTP statuses and publisher names — so the
    /// messages pass through, except that the failure *kind* leads so a log line
    /// is greppable without reading the sentence.
    var logDescription: String {
        switch self {
        case .unsupportedPlatform(let m):     return "unsupported-platform machine=\(m)"
        case .versionLookupFailed:            return "version-lookup-failed"
        case .manifestMissingPlatform(let p): return "manifest-missing-platform platform=\(p)"
        case .untrustedURL:                   return "untrusted-url"
        case .httpError(let s):               return "http-error status=\(s)"
        case .checksumMismatch:               return "checksum-mismatch"
        case .sizeMismatch(let e, let a):     return "size-mismatch expected=\(e) actual=\(a)"
        case .signatureInvalid:               return "signature-invalid"
        case .wrongPublisher(let t, _):       return "wrong-publisher team=\(t ?? "(none)")"
        case .installFailed:                  return "install-failed"
        case .cancelled:                      return "cancelled"
        }
    }
}

/// Reads a binary's code signature. A protocol so the *refusal* paths can be
/// tested — a unit test cannot produce a genuinely Anthropic-signed Mach-O, and
/// a check that is only ever exercised by the happy path is a check nobody has
/// seen fail.
protocol ClaudeSignatureVerifying {
    /// Validate the signature at `url` and report who signed it.
    /// Throws only when the signature could not be *examined* at all
    /// (unreadable file); an invalid or absent signature comes back as an
    /// identity with `isValid == false`.
    func identity(ofBinaryAt url: URL) throws -> ClaudeSignatureIdentity
}

/// Verification that does not need a network, a Keychain, or a real binary —
/// so every rule here is pinned by a test.
enum ClaudeBinaryVerification {

    /// The code-signing requirement the downloaded binary must satisfy.
    ///
    /// This is the authoritative check, and it is a single expression on
    /// purpose. `anchor apple generic` pins the chain to Apple's roots, so a
    /// self-signed binary that simply *claims* Anthropic's team ID fails;
    /// `certificate leaf[subject.OU]` is where a Developer ID certificate
    /// carries the team; and the identifier pins which Anthropic product this
    /// is. Comparing the strings we read back afterwards would not be
    /// equivalent — unanchored, those strings are attacker-chosen.
    static var designatedRequirement: String {
        """
        anchor apple generic and identifier "\(ClaudeManagedInstall.claudeSigningIdentifier)" \
        and certificate leaf[subject.OU] = "\(ClaudeManagedInstall.anthropicTeamIdentifier)"
        """
    }

    /// Whether an examined identity is one Mila will execute.
    ///
    /// Pure, and separate from the requirement check above so the refusal
    /// reasons are distinguishable: "this file's signature is broken" and "this
    /// file is signed by somebody else" send a user to different places, and
    /// collapsing both into "verification failed" is the error message that
    /// helps nobody.
    static func accept(_ identity: ClaudeSignatureIdentity,
                       expectedTeam: String = ClaudeManagedInstall.anthropicTeamIdentifier,
                       expectedIdentifier: String = ClaudeManagedInstall.claudeSigningIdentifier)
    -> ClaudeInstallError? {
        guard identity.isValid else {
            return .signatureInvalid("The signature is missing or doesn't match the file's contents.")
        }
        guard identity.teamIdentifier == expectedTeam,
              identity.signingIdentifier == expectedIdentifier else {
            return .wrongPublisher(team: identity.teamIdentifier,
                                   identifier: identity.signingIdentifier)
        }
        return nil
    }

    /// Constant-time-ish comparison of two hex digests, case-insensitively.
    ///
    /// Not a secret comparison — a published checksum is public — but written
    /// as a full-width compare anyway so a future reader doesn't "optimise" it
    /// into an early-exit loop over something that later *is* secret. The
    /// lowercasing is the part that actually matters: manifests publish
    /// lowercase, `shasum` prints lowercase, and a future uppercase producer
    /// must not read as a mismatch.
    static func digestsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.lowercased().utf8)
        let b = Array(rhs.lowercased().utf8)
        guard a.count == b.count, !a.isEmpty else { return false }
        var difference: UInt8 = 0
        for i in 0..<a.count { difference |= a[i] ^ b[i] }
        return difference == 0
    }

    /// SHA-256 of a file, hashed in chunks.
    ///
    /// Chunked rather than `Data(contentsOf:)` because the CLI is ~200 MB and
    /// this runs while the user is looking at a progress bar: reading it all
    /// into memory to hash it doubles the footprint of the install for no
    /// benefit. 1 MiB chunks are large enough that the syscall overhead
    /// disappears and small enough to stay invisible in memory graphs.
    static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of an in-memory blob. Used by tests and by the small
    /// version/manifest responses; the binary always goes through the streaming
    /// form above.
    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The real signature check, via the Security framework rather than a
/// `codesign` subprocess.
///
/// Two reasons it is not a subprocess. It is the same evaluation `codesign`
/// performs (both are thin wrappers over these APIs), so nothing is lost; and
/// the alternative would mean spawning a child process, with the pipe-drain,
/// dedicated-thread and bounded-wait machinery `.claude/rules/python-subprocess.md`
/// requires — an entire failure surface, added to the one code path whose whole
/// job is to decide whether something is safe to execute.
struct SecurityFrameworkSignatureVerifier: ClaudeSignatureVerifying {

    func identity(ofBinaryAt url: URL) throws -> ClaudeSignatureIdentity {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            throw ClaudeInstallError.signatureInvalid(Self.message(for: createStatus))
        }

        // The authoritative check: validity AND publisher in one evaluation,
        // anchored to Apple's roots. See `designatedRequirement`.
        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(
            ClaudeBinaryVerification.designatedRequirement as CFString, [], &requirement)
        guard requirementStatus == errSecSuccess, let requirement else {
            throw ClaudeInstallError.signatureInvalid(Self.message(for: requirementStatus))
        }
        let validity = SecStaticCodeCheckValidity(
            code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement)

        // Read the identity back regardless of the verdict — a *failed* check is
        // exactly when "signed by whom, then?" is the useful thing to say.
        var infoRef: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef)
        let info = infoRef as? [String: Any]
        let team = info?[kSecCodeInfoTeamIdentifier as String] as? String
        let identifier = info?[kSecCodeInfoIdentifier as String] as? String

        if validity != errSecSuccess {
            verifyLog.error("""
                claude install signature check failed \
                status=\(validity, privacy: .public) \
                team=\(team ?? "(none)", privacy: .public)
                """)
        }
        return ClaudeSignatureIdentity(teamIdentifier: team,
                                       signingIdentifier: identifier,
                                       isValid: validity == errSecSuccess)
    }

    /// Turn an OSStatus into something a Settings row can show. Falls back to
    /// the numeric status, which is still greppable in Apple's headers, rather
    /// than to a generic sentence that erases the only clue.
    private static func message(for status: OSStatus) -> String {
        if let text = SecCopyErrorMessageString(status, nil) as String? {
            return "\(text) (\(status))"
        }
        return "Security framework status \(status)."
    }
}
