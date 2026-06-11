import Foundation
import Darwin
import IOKit

/// One-shot snapshot of the Mac's hardware identity, used to gate
/// CPU-bound features (currently: Live AI live-transcript pane) on
/// machines where they would feel sluggish.
///
/// The lone consumer of this in production is `LiveAISettings.isLiveAIAvailable`,
/// but the struct also exposes RAM + performance-core counts so we
/// can later tighten the cutoff (e.g. "16 GB minimum" or "8+ P-cores")
/// without touching call sites.
///
/// **Why a struct, not an actor:** the sysctl values never change at
/// runtime, so the read is a one-shot at app launch — caching it as
/// `.live` (a let-bound static singleton) is simpler than an actor and
/// has no concurrency footprint. Tests construct their own
/// `SystemCapabilities` with literal field values to exercise the
/// `isLiveAIRecommended` predicate without depending on the host.
struct SystemCapabilities: Sendable, Equatable {
    /// Raw `hw.model` string. Examples: `Mac14,15`, `Mac15,12` (MacBook
    /// Air); `Mac15,3`, `Mac16,7` (MacBook Pro). Apple does not group
    /// Air vs Pro under a stable prefix — both are `MacXX,NN` — so we
    /// detect Air using the marketing name from IOKit (see
    /// `marketingName`) rather than parsing this string.
    let modelIdentifier: String

    /// Marketing name read from `IOPlatformExpertDevice` (e.g.
    /// "MacBook Air", "MacBook Pro", "Mac mini"). May be empty on
    /// systems where the IOKit query fails — in that case
    /// `isMacBookAir` falls back to `false` (don't gate Live AI on a
    /// machine we can't identify).
    let marketingName: String

    /// True iff the marketing name contains "MacBookAir" (matches
    /// "MacBook Air" with or without the space, depending on how
    /// IOKit reports it — different macOS versions strip the space).
    let isMacBookAir: Bool

    /// Physical RAM in gigabytes, rounded to the nearest integer.
    /// Reported via `hw.memsize`.
    let physicalRamGB: Int

    /// Number of performance ("P") cores. On Apple silicon this is
    /// `hw.perflevel0.physicalcpu`; on Intel Macs that sysctl is
    /// missing and we fall back to `hw.physicalcpu`. Used as a
    /// future-proofing field — the current `isLiveAIRecommended`
    /// only checks the Air flag, but a stricter cutoff would
    /// likely want a P-core minimum.
    let performanceCoreCount: Int

    /// The single decision the rest of the app cares about: should
    /// the Live AI live-transcript pane (and its toggle in Settings)
    /// be available on this machine? `false` on MBA, `true` everywhere
    /// else. This deliberately does NOT check the user's
    /// `LiveAISettings.enabled` flag — that's a separate concern; we
    /// gate the UI availability, the user's preference is preserved.
    var isLiveAIRecommended: Bool { !isMacBookAir }

    /// The live snapshot, read once on first access. Read-only;
    /// hardware doesn't change at runtime.
    static let live: SystemCapabilities = .readFromHardware()

    /// Read the real sysctl + IOKit values. Direct callers should
    /// almost always use `.live` instead; this is exposed so unit
    /// tests can re-trigger a read if they want to assert that
    /// detection completes without crashing.
    static func readFromHardware() -> SystemCapabilities {
        let model = Self.sysctlString("hw.model") ?? ""
        let marketing = Self.iokitMarketingName() ?? ""
        // Apple has historically reported the marketing name as
        // "MacBookAir" (no space) via IOPlatformExpertDevice. Newer
        // macOS releases sometimes insert a space — match both.
        let isAir: Bool = {
            let normalized = marketing.replacingOccurrences(of: " ", with: "")
            return normalized.localizedCaseInsensitiveContains("MacBookAir")
        }()
        let mem = Self.sysctlUInt64("hw.memsize") ?? 0
        let ramGB = Int((Double(mem) / 1_073_741_824.0).rounded())
        // `hw.perflevel0.physicalcpu` is the P-core count on Apple
        // silicon. On Intel Macs the sysctl is missing — fall back
        // to `hw.physicalcpu` so the field is always populated.
        let pCores = Self.sysctlInt32("hw.perflevel0.physicalcpu")
            ?? Self.sysctlInt32("hw.physicalcpu")
            ?? 0
        return SystemCapabilities(
            modelIdentifier: model,
            marketingName: marketing,
            isMacBookAir: isAir,
            physicalRamGB: ramGB,
            performanceCoreCount: Int(pCores)
        )
    }

    // MARK: - sysctl helpers

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    /// Read the marketing-friendly model name (e.g. "MacBook Air")
    /// from `IOPlatformExpertDevice`'s `product-name` property. This
    /// is what gives us a clean Air-vs-Pro signal — the raw
    /// `hw.model` (`Mac15,12` etc.) doesn't follow a pattern we can
    /// match on.
    ///
    /// Returns nil on IOKit failure; callers should treat that as
    /// "unknown hardware, don't gate features off".
    private static func iokitMarketingName() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        // Try the modern `product-name` key first (Apple silicon),
        // then fall back to `model` for older Macs.
        for key in ["product-name", "model"] {
            if let value = IORegistryEntryCreateCFProperty(
                service, key as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() {
                if let data = value as? Data,
                   let string = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\0")),
                   !string.isEmpty {
                    return string
                }
                if let string = value as? String, !string.isEmpty {
                    return string
                }
            }
        }
        return nil
    }
}
