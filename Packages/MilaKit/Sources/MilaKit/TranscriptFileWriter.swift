import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Writes a rendered transcript straight to disk for `save_transcript`, so
/// the bytes never pass through the MCP client.
///
/// ## Why this exists
///
/// Copying a transcript to a file *through* the model means the model
/// re-generates every character as output tokens. For Hebrew that is close
/// to one token per character: a 40 KB transcript of a 20-minute meeting is
/// 12–15k output tokens, about three minutes of pure generation, where the
/// helper can write the same file in milliseconds. So when the caller only
/// wants the file, the helper writes it and the reply carries the path and
/// size — not the text.
///
/// ## Two phases
///
/// `plan(for:)` checks everything that depends only on the path — absolute,
/// the folder exists, not inside Mila's data — and runs BEFORE the store is
/// loaded, so a bad path is reported on its own rather than behind an
/// unknown `id` or a recordings.json read. `destination(for:defaultFileName:)`
/// then settles the file name (which may come from the recording) and checks
/// the leaf itself.
///
/// ## What it refuses
///
/// - **Relative paths.** The helper's working directory is whatever the MCP
///   client launched it with, which the caller cannot see; a relative path
///   would land somewhere it did not mean. `~` is expanded.
/// - **A missing folder.** Creating directories on a guess is how a typo
///   becomes a stray folder tree. A path ending in `/` names a folder, so
///   `~/Exports/` that does not exist is this error — not a file called
///   `Exports`.
/// - **An existing file, unless `overwrite`.** A transcript export should
///   not silently replace whatever was there. The no-overwrite write ends
///   in `renamex_np(…, RENAME_EXCL)` (or `link(2)`, or `O_EXCL`, on volumes
///   that lack it), which the kernel refuses atomically when the name
///   exists, so a file created between the check and the write is not
///   replaced either.
/// - **A destination that is a symbolic link** (or a folder, or anything
///   but a regular file). Writing "to" `~/Desktop/notes.txt` must not mean
///   writing through it to wherever it points. The replace itself is a
///   `rename(2)` onto the name, which swaps the directory entry and never
///   follows a link, so a symlink planted after the check is replaced, not
///   written through.
/// - **Anything inside Mila's app-support root** — consent and pointer
///   files, the live sidecar, the default store. Containment is decided by
///   FILESYSTEM IDENTITY (device + inode of every real ancestor of the
///   folder), not by comparing path strings: APFS is case- and
///   normalization-insensitive by default, so `…/application support/mila`
///   is the same folder as `…/Application Support/Mila` while sharing no
///   string prefix with it, and a symlinked folder spells a protected one
///   under a different name altogether.
/// - **Mila's own files in a relocated recordings folder.** That folder can
///   be somewhere ordinary — `~/Documents` — so it is not off limits as a
///   whole: a NEW export may be created there. What is refused is replacing
///   any file already in it (Mila's audio and sidecars live there, mixed
///   with whatever else the user keeps), Mila's reserved names
///   (`recordings.json`, `folders.json`, …), audio names (the orphan sweep
///   would import a `.wav` as a recording) and a name that shares its stem
///   with a recording's audio (that is the recording's own `.txt`/`.srt`
///   sidecar, possibly not written yet).
///
/// Like the access gate this is not a privilege boundary: `mila-mcp` runs as
/// the user and can write wherever they can. These checks stop mistakes —
/// an assistant's wrong guess at a path should not be able to corrupt the
/// library.
struct TranscriptFileWriter: Sendable {

    enum WriteError: Error, CustomStringConvertible {
        case notAbsolute(String)
        case parentMissing(String)
        case exists(String)
        case insideMilaData(String)
        case notARegularFile(String, String)
        case reservedByMila(String, String)
        case invalidName(String)
        case failed(String, String)

        var description: String {
            switch self {
            case .notAbsolute(let path):
                return "path must be absolute (or start with ~), got \"\(path)\""
            case .parentMissing(let dir):
                return "The folder to save into does not exist: \(dir)"
            case .exists(let path):
                return "\(path) already exists; pass overwrite: true to replace it, or choose another path"
            case .insideMilaData(let path):
                return "Cannot save inside Mila's own data directory (\(path)); choose a path outside it"
            case .notARegularFile(let path, let what):
                return "\(path) is \(what); save_transcript only writes regular files — choose another path"
            case .reservedByMila(let path, let why):
                return "Cannot save to \(path): \(why). Choose another name, or a folder outside Mila's recordings folder"
            case .invalidName(let name):
                return "\"\(name)\" is not a usable file name"
            case .failed(let path, let reason):
                return "Could not write \(path): \(reason)"
            }
        }
    }

    /// Mila's data as the writer needs to see it.
    struct ProtectedLocations: Sendable {
        /// Nothing may be written anywhere beneath these.
        var roots: [URL]
        /// Folders that hold Mila's files among other things (a relocated
        /// recordings folder): new exports may be created directly inside,
        /// but nothing there may be replaced and Mila's names are reserved.
        var managedFolders: [URL]
    }

    /// What `plan(for:)` settled before the store was touched.
    struct Plan: Sendable {
        /// The existing folder to write into, symlinks resolved.
        let directory: URL
        /// The caller's file name; nil when the path named a folder and the
        /// recording's default name is to be used.
        let fileName: String?
        /// The folder is one of `ProtectedLocations.managedFolders`.
        let inManagedFolder: Bool
    }

    let protected: ProtectedLocations

    // MARK: - Phase 1: the path alone

    func plan(for rawPath: String) throws -> Plan {
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw WriteError.notAbsolute(rawPath) }

        let directoryPath: String
        let fileName: String?
        if Self.namesAFolder(rawPath) || POSIXFiles.kind(of: expanded, followingLinks: true) == .directory {
            // `~/Exports/`, `~/Exports/.`, or an existing folder (or a link
            // to one): the recording's default name goes inside it. A folder
            // spelled with a trailing slash that does not exist falls through
            // to the "does not exist" error below rather than becoming a
            // file named after it.
            directoryPath = expanded
            fileName = nil
        } else {
            let url = URL(fileURLWithPath: expanded)
            directoryPath = url.deletingLastPathComponent().path
            fileName = url.lastPathComponent
        }

        guard let real = POSIXFiles.realPath(directoryPath),
              POSIXFiles.kind(of: real, followingLinks: false) == .directory else {
            throw WriteError.parentMissing(directoryPath)
        }

        // Identity, not spelling: every real ancestor of the folder, itself
        // included, against every protected root.
        let rootIDs = Set(protected.roots.compactMap { POSIXFiles.identity(of: $0.path) })
        var ancestor = real
        while true {
            if let id = POSIXFiles.identity(of: ancestor), rootIDs.contains(id) {
                throw WriteError.insideMilaData(real)
            }
            let parent = (ancestor as NSString).deletingLastPathComponent
            if parent == ancestor || parent.isEmpty { break }
            ancestor = parent
        }
        let managedIDs = Set(protected.managedFolders.compactMap { POSIXFiles.identity(of: $0.path) })
        let inManaged = POSIXFiles.identity(of: real).map { managedIDs.contains($0) } ?? false

        return Plan(directory: URL(fileURLWithPath: real, isDirectory: true),
                    fileName: fileName, inManagedFolder: inManaged)
    }

    /// A path that can only mean a folder, whatever is on disk: a trailing
    /// separator, a final `.`/`..`, or a bare `~`.
    private static func namesAFolder(_ rawPath: String) -> Bool {
        rawPath == "~" || rawPath.hasSuffix("/") || rawPath.hasSuffix("/.")
            || rawPath.hasSuffix("/..")
    }

    // MARK: - Phase 2: the file itself

    /// The file to write, once the name is known.
    func destination(for plan: Plan, defaultFileName: String) throws -> URL {
        let name = plan.fileName ?? defaultFileName
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw WriteError.invalidName(name)
        }
        let url = plan.directory.appendingPathComponent(name, isDirectory: false)
        let kind = POSIXFiles.kind(of: url.path, followingLinks: false)
        switch kind {
        case .missing, .regular: break
        case .symlink: throw WriteError.notARegularFile(url.path, "a symbolic link")
        case .directory: throw WriteError.notARegularFile(url.path, "a folder")
        case .other: throw WriteError.notARegularFile(url.path, "not a regular file")
        }
        if plan.inManagedFolder {
            try checkManagedFolderName(name, exists: kind != .missing,
                                       in: plan.directory, path: url.path)
        }
        return url
    }

    /// Names Mila writes beside its recordings. Compared case- and
    /// normalization-folded, as APFS compares them.
    static let reservedNames: Set<String> = [
        "recordings.json", "folders.json", "voicememo-tombstones.json",
        "speaker-names.json", "speaker-profiles.json",
        StoreLocationPointer.fileName, MCPAccessGate.fileName,
    ]
    /// Audio Mila owns (`recoverOrphanRecordings` imports any unreferenced
    /// `.wav`), and the staging suffix the share importer renames from.
    static let reservedExtensions: Set<String> = ["wav", "m4a", "partial"]
    private static let audioExtensions: Set<String> = ["wav", "m4a"]

    private func checkManagedFolderName(_ name: String, exists: Bool,
                                        in directory: URL, path: String) throws {
        if exists {
            throw WriteError.reservedByMila(
                path, "it is in Mila's recordings folder, where existing files are never replaced")
        }
        let folded = Self.fold(name)
        if Self.reservedNames.contains(folded) {
            throw WriteError.reservedByMila(path, "Mila uses that name for its own data")
        }
        if Self.reservedExtensions.contains((folded as NSString).pathExtension) {
            throw WriteError.reservedByMila(path, "Mila treats files with that extension in its recordings folder as its own")
        }
        let stem = Self.recordingStem(folded)
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let ownedByARecording = siblings.contains { sibling in
            let foldedSibling = Self.fold(sibling)
            return Self.audioExtensions.contains((foldedSibling as NSString).pathExtension)
                && Self.recordingStem(foldedSibling) == stem
        }
        if ownedByARecording {
            throw WriteError.reservedByMila(path, "that name belongs to one of Mila's recordings")
        }
    }

    private static func fold(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// `x.wav`, `x.txt`, `x.srt` and `x.summary.txt` all belong to `x`.
    private static func recordingStem(_ folded: String) -> String {
        if folded.hasSuffix(".summary.txt") { return String(folded.dropLast(".summary.txt".count)) }
        return (folded as NSString).deletingPathExtension
    }

    // MARK: - Writing

    /// Writes `text` as UTF-8 to `url` and returns the byte count.
    ///
    /// Both paths stage the bytes in a temp file in the same folder (so the
    /// final step is a rename on one volume) and never open the destination
    /// name for writing, so neither can write through a symlink there.
    func write(_ text: String, to url: URL, overwrite: Bool) throws -> Int {
        let data = Data(text.utf8)
        let fm = FileManager.default
        if !overwrite, POSIXFiles.kind(of: url.path, followingLinks: false) != .missing {
            // Only the friendly early error; the exclusive publish below is
            // what actually guarantees nothing is replaced.
            throw WriteError.exists(url.path)
        }
        let temp = url.deletingLastPathComponent()
            // Not derived from the target's name, which may already be
            // near the 255-byte limit — any affix would push it over.
            .appendingPathComponent(".mila-save-\(UUID().uuidString).partial")
        do {
            try data.write(to: temp, options: .withoutOverwriting)
        } catch {
            try? fm.removeItem(at: temp)
            throw WriteError.failed(url.path, error.localizedDescription)
        }
        defer { _ = unlink(temp.path) }   // no-op once renamed away

        if overwrite {
            // rename(2) replaces the directory entry atomically; a symlink
            // at the destination is replaced, not followed.
            guard rename(temp.path, url.path) == 0 else {
                throw WriteError.failed(url.path, POSIXFiles.errorString(errno))
            }
            return data.count
        }
        try Self.publishExclusively(temp: temp.path, data: data, to: url.path)
        return data.count
    }

    /// Moves `temp` to `path` only if nothing is there, in the strongest way
    /// the volume supports:
    ///
    /// 1. `renamex_np(RENAME_EXCL)` — atomic, all-or-nothing (APFS, HFS+).
    /// 2. `link(2)` + unlink — also atomic, and fails with `EEXIST`. Some
    ///    volumes (SMB shares, older network filesystems) take this but not
    ///    the exclusive rename.
    /// 3. `open(O_CREAT | O_EXCL)` and write — exFAT/FAT have neither of the
    ///    above. The name is claimed atomically; only the content appears
    ///    progressively, and a failed write removes the file it created.
    ///
    /// Without the fallbacks the default (`overwrite: false`) save failed on
    /// every exFAT/FAT drive with "Operation not supported".
    private static func publishExclusively(temp: String, data: Data, to path: String) throws {
        if renamex_np(temp, path, UInt32(RENAME_EXCL)) == 0 { return }
        let renameError = errno
        if renameError == EEXIST { throw WriteError.exists(path) }
        guard [ENOTSUP, EOPNOTSUPP, EINVAL, ENOSYS].contains(renameError) else {
            throw WriteError.failed(path, POSIXFiles.errorString(renameError))
        }

        if link(temp, path) == 0 { return }   // the deferred unlink drops temp
        let linkError = errno
        if linkError == EEXIST { throw WriteError.exists(path) }

        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
        guard fd >= 0 else {
            let openError = errno
            if openError == EEXIST { throw WriteError.exists(path) }
            throw WriteError.failed(path, POSIXFiles.errorString(openError))
        }
        let writeError = POSIXFiles.writeAll(data, to: fd)
        let closeError = close(fd) == 0 ? 0 : errno
        if let failure = writeError ?? (closeError == 0 ? nil : closeError) {
            _ = unlink(path)   // ours: O_EXCL created it
            throw WriteError.failed(path, POSIXFiles.errorString(failure))
        }
    }

    // MARK: - Default name

    /// `"<yyyy-MM-dd> <title>.<ext>"`, with the characters a macOS path
    /// component cannot hold (or that hide or spoof a name) replaced.
    ///
    /// Format controls (Unicode `Cf`) are deliberately NOT all stripped:
    /// U+200D ZERO WIDTH JOINER holds composed emoji together (👨‍👩‍👧),
    /// U+200C ZWNJ is orthographic in Persian and Hindi, and U+200E/U+200F
    /// (LRM/RLM) keep a mixed Hebrew/English title in reading order. Only the
    /// bidi embedding/override/isolate controls are replaced — those can
    /// make a name display as something it is not (`txt.exe` reading as
    /// `exe.txt`).
    ///
    /// TODO: the app's `ObsidianPathSanitizer` does the same job with a
    /// slightly different character set; one shared MilaKit implementation
    /// is a follow-up.
    static func defaultFileName(title: String, createdAt: Date, fileExtension: String) -> String {
        let day = createdAt.formatted(Date.ISO8601FormatStyle(timeZone: .current)
            .year().month().day())
        var cleaned = String(String.UnicodeScalarView(title.unicodeScalars.map {
            isDisallowedInName($0) ? "-" : $0
        })).trimmingCharacters(in: .whitespaces)
        // APFS caps a name at 255 UTF-8 BYTES, not characters — Hebrew is 2
        // bytes a letter, emoji 4 — so budget in bytes, cutting only between
        // characters. 200 leaves room for the date and the extension.
        var budget = 200
        cleaned = String(cleaned.prefix { character in
            budget -= character.utf8.count
            return budget >= 0
        }).trimmingCharacters(in: .whitespaces)
        let stem = cleaned.isEmpty ? day : "\(day) \(cleaned)"
        return "\(stem).\(fileExtension)"
    }

    private static func isDisallowedInName(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2F, 0x3A, 0x5C:          // / : \
            return true
        case 0x202A...0x202E,           // LRE RLE PDF LRO RLO
             0x2066...0x2069:           // LRI RLI FSI PDI
            return true
        default:
            break
        }
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator:   // Cc, Zl, Zp
            return true
        default:
            return false
        }
    }
}

/// The handful of POSIX calls the writer needs, kept out of the writer's own
/// namespace (its `write(_:to:overwrite:)` would shadow `write(2)`).
enum POSIXFiles {
    enum Kind: Equatable { case missing, regular, directory, symlink, other }

    struct Identity: Hashable {
        let device: Int64
        let inode: UInt64
    }

    static func kind(of path: String, followingLinks: Bool) -> Kind {
        var info = stat()
        let rc: Int32
        if followingLinks {
            rc = stat(path, &info)
        } else {
            rc = lstat(path, &info)
        }
        guard rc == 0 else { return .missing }
        switch Int(info.st_mode) & 0o170000 {
        case 0o100000: return .regular
        case 0o040000: return .directory
        case 0o120000: return .symlink
        default: return .other
        }
    }

    /// Device + inode of what `path` resolves to, following links; nil when
    /// it does not exist.
    static func identity(of path: String) -> Identity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Identity(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
    }

    /// `realpath(3)`: every symlink, `.` and `..` resolved; nil when any
    /// component is missing.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Writes all of `data`, retrying short writes and `EINTR`. Returns the
    /// failing `errno`, or nil.
    static func writeAll(_ data: Data, to fd: Int32) -> Int32? {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Int32? in
            guard let base = buffer.baseAddress else { return nil }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                offset += written
            }
            return nil
        }
    }

    static func errorString(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
