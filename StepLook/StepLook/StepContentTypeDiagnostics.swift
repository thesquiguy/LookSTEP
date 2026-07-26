import Foundation
import UniformTypeIdentifiers

// MARK: - Values

/// The single content type Launch Services resolved a file to, flattened into a
/// value so the claim decision below can be tested without touching the disk or
/// the type database.
///
/// macOS declares no system type for STEP. Every CAD vendor exports its own and
/// a given `.step` file resolves to exactly one of them, so the identifier here
/// is the whole ballgame for Quick Look matching.
nonisolated struct StepResolvedContentType: Sendable, Equatable {
    /// The resolved identifier, e.g. `com.shapr3d.step` or `dyn.ah62d4rv4ge81a5pu`.
    let identifier: String
    /// Launch Services' human-readable name for the type, when it has one.
    let localizedDescription: String?
    /// Transitive supertypes, most specific first, excluding `identifier`.
    let conformanceChain: [String]
    /// True when macOS synthesised the type because nothing declared it.
    let isDynamic: Bool
    /// True when some installed bundle declares the type.
    let isDeclared: Bool

    init(
        identifier: String,
        localizedDescription: String? = nil,
        conformanceChain: [String] = [],
        isDynamic: Bool = false,
        isDeclared: Bool = true
    ) {
        self.identifier = identifier
        self.localizedDescription = localizedDescription
        self.conformanceChain = conformanceChain
        self.isDynamic = isDynamic
        self.isDeclared = isDeclared
    }
}

/// What a Quick Look extension actually declares, read from the bundle on disk
/// rather than assumed, so the panel reports the copy that is really installed.
nonisolated struct StepPreviewExtensionDeclaration: Sendable, Equatable {
    let bundleIdentifier: String?
    let bundleURL: URL?
    /// The verbatim `QLSupportedContentTypes` array.
    let supportedContentTypes: [String]
    /// Why the declaration could not be read, when it could not be.
    let failure: String?

    init(
        bundleIdentifier: String? = nil,
        bundleURL: URL? = nil,
        supportedContentTypes: [String] = [],
        failure: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = bundleURL
        self.supportedContentTypes = supportedContentTypes
        self.failure = failure
    }
}

/// The verdict: will Quick Look hand this file to the LookSTEP extension?
nonisolated struct StepContentTypeClaim: Sendable, Equatable {
    nonisolated enum Outcome: Sendable, Equatable {
        /// `QLSupportedContentTypes` lists the resolved identifier verbatim.
        case claimedDirectly(matched: String)
        /// The resolved type conforms to something the extension lists.
        case claimedByConformance(matched: String)
        /// The extension declares nothing that matches.
        case notClaimed
        /// The extension's declaration could not be read at all.
        case undeterminable
    }

    let outcome: Outcome
    /// One line, safe to use as a headline.
    let summary: String
    /// Why, in enough detail to act on.
    let reason: String

    var isClaimed: Bool {
        switch outcome {
        case .claimedDirectly, .claimedByConformance: true
        case .notClaimed, .undeterminable: false
        }
    }

    /// The identifier in `QLSupportedContentTypes` responsible for a match.
    var matchedIdentifier: String? {
        switch outcome {
        case let .claimedDirectly(matched), let .claimedByConformance(matched): matched
        case .notClaimed, .undeterminable: nil
        }
    }
}

// MARK: - Decision

/// The claimed/not-claimed decision, isolated from SwiftUI and from Launch
/// Services so it can be exercised against types no machine here has installed.
nonisolated enum StepContentTypeMatch {
    /// Quick Look invokes an extension when the file's resolved type is listed
    /// in `QLSupportedContentTypes`, or conforms to something listed. Anything
    /// else is a silent no-op: no preview, no error, no log entry.
    static func evaluate(
        resolved: StepResolvedContentType,
        declaredContentTypes: [String]
    ) -> StepContentTypeClaim {
        guard !declaredContentTypes.isEmpty else {
            return StepContentTypeClaim(
                outcome: .undeterminable,
                summary: "No declared content types",
                reason: """
                    The preview extension declares an empty QLSupportedContentTypes \
                    list, so Quick Look will never invoke it for any file.
                    """
            )
        }

        let normalizedDeclarations = declaredContentTypes.map(normalize)

        if let index = normalizedDeclarations.firstIndex(of: normalize(resolved.identifier)) {
            let matched = declaredContentTypes[index]
            return StepContentTypeClaim(
                outcome: .claimedDirectly(matched: matched),
                summary: "Claimed — Quick Look will use LookSTEP",
                reason: """
                    QLSupportedContentTypes lists \(matched) verbatim, and this file \
                    resolves to exactly that type.
                    """
            )
        }

        let normalizedChain = resolved.conformanceChain.map(normalize)
        for (index, declaration) in normalizedDeclarations.enumerated()
        where normalizedChain.contains(declaration) {
            let matched = declaredContentTypes[index]
            return StepContentTypeClaim(
                outcome: .claimedByConformance(matched: matched),
                summary: "Claimed by conformance — Quick Look will use LookSTEP",
                reason: """
                    This file resolves to \(resolved.identifier), which conforms to \
                    \(matched). QLSupportedContentTypes lists \(matched), and Quick Look \
                    matches conforming types.
                    """
            )
        }

        return StepContentTypeClaim(
            outcome: .notClaimed,
            summary: "Not claimed — Quick Look will skip LookSTEP",
            reason: unclaimedReason(for: resolved)
        )
    }

    private static func unclaimedReason(for resolved: StepResolvedContentType) -> String {
        if resolved.isDynamic {
            return """
                macOS synthesised the dynamic type \(resolved.identifier) because no \
                installed application declares this file's extension — not even LookSTEP. \
                Quick Look has no declared type to match, so it skips the preview \
                extension silently. Reinstall LookSTEP, or re-register it with \
                lsregister, so its exported STEP type reaches Launch Services.
                """
        }
        if !resolved.isDeclared {
            return """
                \(resolved.identifier) is not declared by any bundle on this Mac and is \
                not listed in QLSupportedContentTypes. Quick Look skips the preview \
                extension for this file with no error and no log entry.
                """
        }
        return """
            \(resolved.identifier) is declared by another application on this Mac and is \
            absent from QLSupportedContentTypes. This is the silent failure mode: Quick \
            Look skips the LookSTEP preview extension with no error and no log entry. \
            Add \(resolved.identifier) to StepLookPreview/Info.plist (and the matching \
            declarations in StepLook/Info.plist) to fix it.
            """
    }

    /// UTI comparison is case-insensitive: Shapr3D declares `com.shapr3d.STEP`
    /// and Launch Services reports `com.shapr3d.step` for the same type.
    private static func normalize(_ identifier: String) -> String {
        identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - Report

nonisolated extension StepContentTypeClaim {
    /// A plain-text report, so a user hitting the silent failure can paste the
    /// one fact that resolves it: the identifier their CAD vendor actually uses.
    static func report(
        fileName: String,
        resolved: StepResolvedContentType,
        declaration: StepPreviewExtensionDeclaration,
        competingTypes: [String],
        claim: StepContentTypeClaim
    ) -> String {
        var lines: [String] = []
        lines.append("LookSTEP content-type diagnostic")
        lines.append("File: \(fileName)")
        lines.append("Resolved type: \(resolved.identifier)")
        if let description = resolved.localizedDescription {
            lines.append("Type description: \(description)")
        }
        lines.append("Dynamic: \(resolved.isDynamic ? "yes" : "no")")
        lines.append("Declared by an installed bundle: \(resolved.isDeclared ? "yes" : "no")")
        lines.append(
            "Conforms to: "
                + (resolved.conformanceChain.isEmpty
                    ? "(nothing)" : resolved.conformanceChain.joined(separator: " → "))
        )
        if !competingTypes.isEmpty {
            lines.append("Other types claiming this extension: \(competingTypes.joined(separator: ", "))")
        }
        lines.append("Preview extension: \(declaration.bundleIdentifier ?? "(not found)")")
        if let url = declaration.bundleURL {
            lines.append("Preview extension path: \(url.path)")
        }
        if let failure = declaration.failure {
            lines.append("Preview extension problem: \(failure)")
        }
        lines.append(
            "QLSupportedContentTypes: "
                + (declaration.supportedContentTypes.isEmpty
                    ? "(none)" : declaration.supportedContentTypes.joined(separator: ", "))
        )
        lines.append("Verdict: \(claim.summary)")
        lines.append("Reason: \(claim.reason)")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Launch Services access

/// The impure half: everything that has to ask Launch Services or the file
/// system. Kept separate so `StepContentTypeMatch` stays testable.
nonisolated enum StepContentTypeInspector {
    /// Resolve a URL exactly the way Quick Look does — one type, not a set.
    static func resolvedContentType(of url: URL) -> StepResolvedContentType {
        let resolved = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        guard let resolved else {
            return StepResolvedContentType(
                identifier: "(unresolved)",
                localizedDescription: nil,
                conformanceChain: [],
                isDynamic: false,
                isDeclared: false
            )
        }
        return describe(resolved)
    }

    static func describe(_ type: UTType) -> StepResolvedContentType {
        StepResolvedContentType(
            identifier: type.identifier,
            localizedDescription: type.localizedDescription,
            conformanceChain: orderedSupertypes(of: type),
            isDynamic: type.isDynamic,
            isDeclared: type.isDeclared
        )
    }

    /// Every type that claims the file's extension. When more than one appears,
    /// the extra entries are precisely the ones that can steal the resolution
    /// on another user's Mac.
    static func typesClaimingExtension(of url: URL) -> [String] {
        let ext = url.pathExtension
        guard !ext.isEmpty else { return [] }
        return UTType.types(tag: ext, tagClass: .filenameExtension, conformingTo: nil)
            .map(\.identifier)
            .sorted()
    }

    /// Read `QLSupportedContentTypes` from the Quick Look preview extension
    /// embedded in `bundle`, rather than assuming what it contains.
    static func previewExtensionDeclaration(
        in bundle: Bundle = .main,
        extensionPointIdentifier: String = "com.apple.quicklook.preview"
    ) -> StepPreviewExtensionDeclaration {
        guard let plugInsURL = bundle.builtInPlugInsURL else {
            return StepPreviewExtensionDeclaration(
                failure: "This build has no PlugIns directory, so no preview extension is embedded."
            )
        }
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: plugInsURL,
            includingPropertiesForKeys: nil
        )) ?? []
        let appExtensions = candidates.filter { $0.pathExtension == "appex" }
        guard !appExtensions.isEmpty else {
            return StepPreviewExtensionDeclaration(
                bundleURL: plugInsURL,
                failure: "No app extension is embedded in \(plugInsURL.path)."
            )
        }

        for candidate in appExtensions.sorted(by: { $0.path < $1.path }) {
            guard let info = infoDictionary(atBundle: candidate) else { continue }
            guard let nsExtension = info["NSExtension"] as? [String: Any],
                  nsExtension["NSExtensionPointIdentifier"] as? String == extensionPointIdentifier
            else { continue }

            let attributes = nsExtension["NSExtensionAttributes"] as? [String: Any]
            let declared = attributes?["QLSupportedContentTypes"] as? [String]
            return StepPreviewExtensionDeclaration(
                bundleIdentifier: info["CFBundleIdentifier"] as? String,
                bundleURL: candidate,
                supportedContentTypes: declared ?? [],
                failure: declared == nil
                    ? "The extension declares no QLSupportedContentTypes array."
                    : nil
            )
        }

        return StepPreviewExtensionDeclaration(
            bundleURL: plugInsURL,
            failure: """
                None of the embedded app extensions declare the \
                \(extensionPointIdentifier) extension point.
                """
        )
    }

    private static func infoDictionary(atBundle url: URL) -> [String: Any]? {
        let plistURL = url.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any]
        else { return nil }
        return plist
    }

    /// Supertypes ordered most specific first. A type with more supertypes of
    /// its own sits lower in the tree, which gives a stable, readable chain.
    private static func orderedSupertypes(of type: UTType) -> [String] {
        type.supertypes
            .sorted {
                if $0.supertypes.count != $1.supertypes.count {
                    return $0.supertypes.count > $1.supertypes.count
                }
                return $0.identifier < $1.identifier
            }
            .map(\.identifier)
    }
}
