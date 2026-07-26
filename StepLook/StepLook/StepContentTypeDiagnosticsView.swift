import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Answers the one question that cannot be answered by looking at Finder: does
/// the type macOS resolved this file to actually reach the LookSTEP preview
/// extension? A mismatch produces no preview, no error and no log entry, so
/// without this panel the failure is invisible.
struct StepContentTypeDiagnosticsView: View {
    private struct Inspection {
        let url: URL
        let resolved: StepResolvedContentType
        let competingTypes: [String]
        let claim: StepContentTypeClaim
    }

    @State private var declaration = StepContentTypeInspector.previewExtensionDeclaration()
    @State private var inspection: Inspection?
    @State private var isDropTarget = false
    @State private var didCopyReport = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let inspection {
                    verdict(inspection)
                    resolvedTypeSection(inspection)
                    if !inspection.competingTypes.isEmpty {
                        competingSection(inspection)
                    }
                } else {
                    placeholder
                }
                extensionSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            inspect(url)
            return true
        } isTargeted: { isDropTarget = $0 }
        .navigationTitle("STEP Content Type")
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Content-type matching")
                .font(.title3.weight(.semibold))
            Text(
                """
                macOS has no system type for STEP. Each CAD vendor declares its own, and \
                a file resolves to exactly one of them. Quick Look invokes LookSTEP only \
                when that type is in the preview extension's QLSupportedContentTypes.
                """
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Choose File…") { chooseFile() }
                if let inspection {
                    Button(didCopyReport ? "Copied" : "Copy Report") { copyReport(inspection) }
                        .disabled(didCopyReport)
                }
                Spacer()
                Text("Any file works — drop one here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No file inspected yet")
                .font(.headline)
            Text("Choose or drop a file to see its resolved type and whether the extension claims it.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func verdict(_ inspection: Inspection) -> some View {
        let claim = inspection.claim
        let tint: Color = claim.isClaimed ? .green : .orange
        let symbol = claim.isClaimed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(claim.summary)
                    .font(.headline)
                Text(claim.reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(claim.summary). \(claim.reason)")
    }

    private func resolvedTypeSection(_ inspection: Inspection) -> some View {
        section("Resolved type") {
            field("File", inspection.url.lastPathComponent)
            field("Identifier", inspection.resolved.identifier, monospaced: true)
            if let description = inspection.resolved.localizedDescription {
                field("Description", description)
            }
            field(
                "Dynamic",
                inspection.resolved.isDynamic
                    ? "Yes — macOS synthesised this type; nothing declares it"
                    : "No"
            )
            field(
                "Declared",
                inspection.resolved.isDeclared
                    ? "Yes — an installed bundle declares this type"
                    : "No"
            )
            field(
                "Conforms to",
                inspection.resolved.conformanceChain.isEmpty
                    ? "(nothing)"
                    : inspection.resolved.conformanceChain.joined(separator: "  →  "),
                monospaced: true
            )
            if let matched = inspection.claim.matchedIdentifier {
                field("Matched by", matched, monospaced: true)
            }
        }
    }

    private func competingSection(_ inspection: Inspection) -> some View {
        section("Other types claiming .\(inspection.url.pathExtension)") {
            ForEach(inspection.competingTypes, id: \.self) { identifier in
                HStack(spacing: 6) {
                    Image(
                        systemName: identifier.caseInsensitiveCompare(inspection.resolved.identifier)
                            == .orderedSame ? "largecircle.fill.circle" : "circle"
                    )
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                    Text(identifier)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }
            Text(
                """
                Only the filled entry is what this file resolves to. The others can win \
                on a Mac with a different set of CAD applications installed.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var extensionSection: some View {
        section("Preview extension") {
            field("Bundle identifier", declaration.bundleIdentifier ?? "(not found)", monospaced: true)
            if let url = declaration.bundleURL {
                field("Path", url.path, monospaced: true)
            }
            if let failure = declaration.failure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("QLSupportedContentTypes")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            if declaration.supportedContentTypes.isEmpty {
                Text("(none)").font(.callout.monospaced()).foregroundStyle(.secondary)
            } else {
                ForEach(declaration.supportedContentTypes, id: \.self) { identifier in
                    Text(identifier)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func section(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func field(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 128, alignment: .leading)
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }

    // MARK: - Actions

    private func chooseFile() {
        let panel = NSOpenPanel()
        // Deliberately unfiltered: the interesting cases are files LookSTEP is
        // failing to claim.
        panel.allowedContentTypes = []
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Inspect"
        panel.message = "Choose any file to see the content type macOS resolves it to."
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            inspect(url)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func inspect(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        declaration = StepContentTypeInspector.previewExtensionDeclaration()
        let resolved = StepContentTypeInspector.resolvedContentType(of: url)
        inspection = Inspection(
            url: url,
            resolved: resolved,
            competingTypes: StepContentTypeInspector.typesClaimingExtension(of: url),
            claim: StepContentTypeMatch.evaluate(
                resolved: resolved,
                declaredContentTypes: declaration.supportedContentTypes
            )
        )
        didCopyReport = false
    }

    private func copyReport(_ inspection: Inspection) {
        let report = StepContentTypeClaim.report(
            fileName: inspection.url.lastPathComponent,
            resolved: inspection.resolved,
            declaration: declaration,
            competingTypes: inspection.competingTypes,
            claim: inspection.claim
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        didCopyReport = true
    }
}
