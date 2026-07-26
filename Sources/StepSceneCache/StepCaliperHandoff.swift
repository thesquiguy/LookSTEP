import Foundation
#if canImport(AppKit)
import AppKit
#endif

nonisolated enum StepCaliperHandoffError: LocalizedError {
    case notInstalled
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "Caliper isn’t installed."
        case .launchFailed(let reason):
            "Caliper couldn’t open this file. \(reason)"
        }
    }
}

/// Hands a STEP source off to Caliper, the exact-geometry viewer.
///
/// LookSTEP's refusal and degradation messages are only allowed to name Caliper
/// when Caliper is actually on the machine — an instruction to use software the
/// user does not have is worse than no advice at all. Every message that names
/// it therefore goes through `StepPreviewAdvice`, which asks this type first.
///
/// The bundle identifier comes from `Info.plist`, populated from the
/// `STEPLOOK_CALIPER_BUNDLE_IDENTIFIER` build setting, so no identifier is
/// baked into source. An unsubstituted or malformed value resolves to `nil`
/// and the whole feature degrades to absent rather than to a broken action.
///
/// That build setting is deliberately empty while Caliper is unreleased, which
/// keeps every Caliper affordance out of the shipping product without deleting
/// the feature. Restoring the handoff when Caliper ships means setting the
/// identifier again; no code here changes.
nonisolated struct StepCaliperHandoff: Sendable {
    static let infoDictionaryKey = "StepLookCaliperBundleIdentifier"

    let bundleIdentifier: String

    init?(bundleIdentifier: String) {
        guard Self.isValidBundleIdentifier(bundleIdentifier) else { return nil }
        self.bundleIdentifier = bundleIdentifier
    }

    /// Rejects empty values, unsubstituted build settings, and anything whose
    /// characters could not appear in a bundle identifier.
    static func isValidBundleIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, !value.contains("$("), value.count <= 255 else {
            return false
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return false
        }
        // A bundle identifier is reverse-DNS: at least two non-empty segments.
        let segments = value.split(separator: ".", omittingEmptySubsequences: false)
        return segments.count >= 2 && segments.allSatisfy { !$0.isEmpty }
    }

    static func configured(
        bundle: Bundle = .main
    ) -> Self? {
        guard let value = bundle.object(
            forInfoDictionaryKey: infoDictionaryKey
        ) as? String else {
            return nil
        }
        return Self(bundleIdentifier: value)
    }

    /// Where Caliper is installed, or `nil` if LaunchServices doesn't know it.
    var applicationURL: URL? {
        #if canImport(AppKit)
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        #else
        nil
        #endif
    }

    var isInstalled: Bool { applicationURL != nil }

    /// Opens `url` in Caliper, activating it.
    ///
    /// Handing the document to LaunchServices is what extends read access to
    /// Caliper — LookSTEP's own security-scoped access does not transfer, so
    /// the caller must not tear its scope down before this returns.
    @MainActor
    func open(_ url: URL) async throws {
        #if canImport(AppKit)
        guard let applicationURL else { throw StepCaliperHandoffError.notInstalled }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.open(
                [url],
                withApplicationAt: applicationURL,
                configuration: configuration
            )
        } catch {
            throw StepCaliperHandoffError.launchFailed(
                (error as NSError).localizedDescription
            )
        }
        #else
        throw StepCaliperHandoffError.notInstalled
        #endif
    }
}

/// A user-facing failure message plus whether it may offer a Caliper action.
///
/// Splitting the sentence from the advice is what lets one message serve both
/// populations: the base sentence always states what happened, and the Caliper
/// clause is appended only when the action behind it will actually work.
nonisolated struct StepPreviewAdvice: Sendable, Equatable {
    let message: String
    let offersCaliper: Bool

    /// Builds advice from a base sentence and the fallback that applies when
    /// Caliper is unavailable. Exactly one trailing clause is used.
    static func make(
        base: String,
        caliperClause: String,
        fallbackClause: String?,
        caliperInstalled: Bool
    ) -> Self {
        if caliperInstalled {
            return Self(message: "\(base) \(caliperClause)", offersCaliper: true)
        }
        guard let fallbackClause else {
            return Self(message: base, offersCaliper: false)
        }
        return Self(message: "\(base) \(fallbackClause)", offersCaliper: false)
    }
}
