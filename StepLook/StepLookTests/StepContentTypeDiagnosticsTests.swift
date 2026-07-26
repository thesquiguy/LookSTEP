import Foundation
import Testing
import UniformTypeIdentifiers
@testable import LookSTEP

/// The claimed/not-claimed decision is the whole of UX_FEATURE_PLAN item 2.1:
/// when it says "not claimed", Quick Look produces no preview, no error and no
/// log entry. These exercise it against vendor types no machine here has
/// installed, which is the population the plan is actually about.
struct StepContentTypeDiagnosticsTests {
    private static let shippingDeclarations = [
        "com.local.stepviewer.step",
        "com.shapr3d.step",
        "com.shapr3d.stp",
        "com.autodesk.fusion360.step",
    ]

    private func stepType(
        _ identifier: String,
        isDynamic: Bool = false,
        isDeclared: Bool = true,
        conformsTo: [String] = ["public.3d-content", "public.data", "public.content", "public.item"]
    ) -> StepResolvedContentType {
        StepResolvedContentType(
            identifier: identifier,
            localizedDescription: "STEP 3D Model",
            conformanceChain: conformsTo,
            isDynamic: isDynamic,
            isDeclared: isDeclared
        )
    }

    // MARK: - Claimed

    @Test func exactIdentifierIsClaimedDirectly() {
        let claim = StepContentTypeMatch.evaluate(
            resolved: stepType("com.shapr3d.step"),
            declaredContentTypes: Self.shippingDeclarations
        )

        #expect(claim.isClaimed)
        #expect(claim.outcome == .claimedDirectly(matched: "com.shapr3d.step"))
        #expect(claim.matchedIdentifier == "com.shapr3d.step")
    }

    /// Shapr3D's bundle declares `com.shapr3d.STEP`; Launch Services reports
    /// `com.shapr3d.step` for the same type. Both must match.
    @Test func identifierComparisonIsCaseInsensitive() {
        let claim = StepContentTypeMatch.evaluate(
            resolved: stepType("com.shapr3d.STEP"),
            declaredContentTypes: Self.shippingDeclarations
        )

        #expect(claim.isClaimed)
        #expect(claim.matchedIdentifier == "com.shapr3d.step")
    }

    @Test func surroundingWhitespaceInADeclarationStillMatches() {
        let claim = StepContentTypeMatch.evaluate(
            resolved: stepType("com.shapr3d.stp"),
            declaredContentTypes: ["  com.shapr3d.stp\n"]
        )

        #expect(claim.isClaimed)
    }

    /// Quick Look matches conforming types, so a vendor type that conforms to a
    /// declared one is claimed even though it is not listed verbatim.
    @Test func conformanceToADeclaredTypeIsClaimed() {
        let claim = StepContentTypeMatch.evaluate(
            resolved: stepType(
                "com.example.cad.step.v2",
                conformsTo: ["com.shapr3d.step", "public.data", "public.item"]
            ),
            declaredContentTypes: Self.shippingDeclarations
        )

        #expect(claim.isClaimed)
        #expect(claim.outcome == .claimedByConformance(matched: "com.shapr3d.step"))
        #expect(claim.reason.contains("conforms to"))
    }

    @Test func directMatchWinsOverConformanceMatch() {
        let claim = StepContentTypeMatch.evaluate(
            resolved: stepType(
                "com.shapr3d.stp",
                conformsTo: ["com.shapr3d.step", "public.data"]
            ),
            declaredContentTypes: Self.shippingDeclarations
        )

        #expect(claim.outcome == .claimedDirectly(matched: "com.shapr3d.stp"))
    }

    // MARK: - Not claimed

    /// The exact population UX_FEATURE_PLAN item 2.1 exists for: a vendor type
    /// that resolves fine but is absent from QLSupportedContentTypes.
    @Test func unlistedVendorTypeIsNotClaimedAndNamesTheFix() {
        let claim = StepContentTypeMatch.evaluate(
            resolved: stepType("com.mcneel.rhinoceros.step"),
            declaredContentTypes: Self.shippingDeclarations
        )

        #expect(!claim.isClaimed)
        #expect(claim.outcome == .notClaimed)
        #expect(claim.matchedIdentifier == nil)
        #expect(claim.reason.contains("com.mcneel.rhinoceros.step"))
        #expect(claim.reason.contains("StepLookPreview/Info.plist"))
    }

    /// Conformance runs one way only. A declared type conforming to the file's
    /// type must not be mistaken for a match.
    @Test func reverseConformanceIsNotAMatch() {
        let claim = StepContentTypeMatch.evaluate(
            resolved: stepType("public.data", conformsTo: ["public.item"]),
            declaredContentTypes: Self.shippingDeclarations
        )

        #expect(!claim.isClaimed)
    }

    @Test func dynamicTypeReportsThatNothingDeclaresTheExtension() {
        let claim = StepContentTypeMatch.evaluate(
            resolved: stepType(
                "dyn.ah62d4rv4ge81a5pu",
                isDynamic: true,
                isDeclared: false,
                conformsTo: ["public.data", "public.item"]
            ),
            declaredContentTypes: Self.shippingDeclarations
        )

        #expect(!claim.isClaimed)
        #expect(claim.outcome == .notClaimed)
        #expect(claim.reason.contains("dynamic"))
        #expect(claim.reason.contains("lsregister"))
    }

    @Test func undeclaredNonDynamicTypeSaysSo() {
        let claim = StepContentTypeMatch.evaluate(
            resolved: stepType("com.example.unknown", isDeclared: false),
            declaredContentTypes: Self.shippingDeclarations
        )

        #expect(!claim.isClaimed)
        #expect(claim.reason.contains("not declared by any bundle"))
    }

    @Test func emptyDeclarationIsUndeterminableRatherThanNotClaimed() {
        let claim = StepContentTypeMatch.evaluate(
            resolved: stepType("com.shapr3d.step"),
            declaredContentTypes: []
        )

        #expect(!claim.isClaimed)
        #expect(claim.outcome == .undeterminable)
        #expect(claim.summary == "No declared content types")
    }

    // MARK: - Report

    @Test func reportCarriesTheFactsNeededToFileTheBug() {
        let resolved = stepType("com.mcneel.rhinoceros.step")
        let declaration = StepPreviewExtensionDeclaration(
            bundleIdentifier: "com.local.stepviewer.StepLook.StepLookPreview",
            bundleURL: URL(fileURLWithPath: "/Applications/LookSTEP.app/Contents/PlugIns/StepLookPreview.appex"),
            supportedContentTypes: Self.shippingDeclarations
        )
        let claim = StepContentTypeMatch.evaluate(
            resolved: resolved,
            declaredContentTypes: declaration.supportedContentTypes
        )

        let report = StepContentTypeClaim.report(
            fileName: "bracket.step",
            resolved: resolved,
            declaration: declaration,
            competingTypes: ["com.mcneel.rhinoceros.step", "com.shapr3d.step"],
            claim: claim
        )

        #expect(report.contains("bracket.step"))
        #expect(report.contains("Resolved type: com.mcneel.rhinoceros.step"))
        #expect(report.contains("Dynamic: no"))
        #expect(report.contains("StepLookPreview.appex"))
        #expect(report.contains("com.shapr3d.step"))
        #expect(report.contains("Verdict: Not claimed"))
    }

    // MARK: - Real declarations shipped by this build

    /// Guards the silent-failure mode itself: the type LookSTEP exports must be
    /// one the preview extension actually claims. Reads the built extension
    /// rather than a hardcoded list, so a build-setting rename cannot separate
    /// the two without failing here.
    @Test func embeddedPreviewExtensionClaimsTheTypeThisBuildExports() throws {
        let declaration = StepContentTypeInspector.previewExtensionDeclaration()
        try #require(declaration.failure == nil, "\(declaration.failure ?? "")")
        #expect(!declaration.supportedContentTypes.isEmpty)

        let exported = try #require(
            Bundle.main.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]]
        )
        let exportedIdentifiers = exported.compactMap { $0["UTTypeIdentifier"] as? String }
        #expect(!exportedIdentifiers.isEmpty)

        for identifier in exportedIdentifiers {
            let claim = StepContentTypeMatch.evaluate(
                resolved: StepResolvedContentType(identifier: identifier),
                declaredContentTypes: declaration.supportedContentTypes
            )
            #expect(claim.isClaimed, "Preview extension does not claim exported type \(identifier)")
        }
    }

    /// Every identifier the app declares — exported or imported — must also be
    /// in QLSupportedContentTypes. Declaring a vendor type the preview
    /// extension does not claim is exactly the bug item 2.1 fixes.
    @Test func everyDeclaredTypeIsAlsoClaimedByThePreviewExtension() throws {
        let declaration = StepContentTypeInspector.previewExtensionDeclaration()
        try #require(declaration.failure == nil, "\(declaration.failure ?? "")")
        let claimed = Set(declaration.supportedContentTypes.map { $0.lowercased() })

        let imported = (Bundle.main.object(forInfoDictionaryKey: "UTImportedTypeDeclarations")
            as? [[String: Any]]) ?? []
        let exported = (Bundle.main.object(forInfoDictionaryKey: "UTExportedTypeDeclarations")
            as? [[String: Any]]) ?? []
        let declared = (imported + exported).compactMap { $0["UTTypeIdentifier"] as? String }

        #expect(declared.count >= 3)
        for identifier in declared {
            #expect(
                claimed.contains(identifier.lowercased()),
                "\(identifier) is declared by the app but absent from QLSupportedContentTypes"
            )
        }
    }

    /// Both declarations must add `public.3d-content`, which is what puts STEP
    /// alongside USD and STL for anything that filters on 3D content.
    @Test func exportedTypeConformsToThreeDContent() throws {
        let exported = try #require(
            Bundle.main.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]]
        )
        for declaration in exported {
            let conformsTo = (declaration["UTTypeConformsTo"] as? [String]) ?? []
            #expect(conformsTo.contains("public.3d-content"))
            #expect(conformsTo.contains("public.data"))
        }
    }

    /// Only the exported type may claim the .step/.stp extensions. An imported
    /// vendor type that also claimed them could beat it when the owning
    /// application is absent, putting a foreign vendor name in Finder's Kind
    /// column for a file nothing else claims.
    @Test func importedVendorTypesDoNotClaimFileExtensions() throws {
        let imported = try #require(
            Bundle.main.object(forInfoDictionaryKey: "UTImportedTypeDeclarations") as? [[String: Any]]
        )
        #expect(!imported.isEmpty)
        for declaration in imported {
            let identifier = (declaration["UTTypeIdentifier"] as? String) ?? "(unknown)"
            #expect(
                declaration["UTTypeTagSpecification"] == nil,
                "Imported type \(identifier) must not claim a filename extension"
            )
        }
    }

    // MARK: - Launch Services access

    @Test func inspectorResolvesAKnownSystemTypeAndItsConformanceChain() {
        let resolved = StepContentTypeInspector.describe(.usdz)

        #expect(resolved.identifier == UTType.usdz.identifier)
        #expect(!resolved.isDynamic)
        #expect(resolved.isDeclared)
        #expect(resolved.conformanceChain.contains("public.3d-content"))
        // Most specific first: public.item has no supertypes and must be last.
        #expect(resolved.conformanceChain.last == "public.item")
    }

    @Test func inspectorReportsAnUnresolvableURLRatherThanCrashing() {
        let resolved = StepContentTypeInspector.resolvedContentType(
            of: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        )

        #expect(!resolved.isDeclared)
        #expect(resolved.identifier == "(unresolved)")
    }

    @Test func typesClaimingExtensionIsEmptyForAnExtensionlessURL() {
        #expect(
            StepContentTypeInspector.typesClaimingExtension(
                of: URL(fileURLWithPath: "/tmp/no-extension")
            ).isEmpty
        )
    }

    @Test func missingExtensionPointYieldsAFailureNotACrash() {
        let declaration = StepContentTypeInspector.previewExtensionDeclaration(
            extensionPointIdentifier: "com.example.not-an-extension-point"
        )

        #expect(declaration.supportedContentTypes.isEmpty)
        #expect(declaration.failure != nil)
    }
}
