import Cocoa
import OSLog
import Quartz
import SwiftUI

@MainActor
final class PreviewViewController: NSViewController, QLPreviewingController {
    private nonisolated static let lifecycleLog = Logger(
        subsystem: "com.local.stepviewer.StepLook",
        category: "PreviewLifecycle"
    )

    private var hostingController: NSHostingController<PreviewContent>?
    private var importTask: Task<Void, Never>?
    private let importClient = StepImportClient()
    private var requestGeneration = UUID()
    private let caliper = StepCaliperHandoff.configured()
    private var currentURL: URL?

    /// The handoff to offer beside a failure, or `nil` when Caliper is absent.
    private var caliperAction: StepCaliperAction? {
        guard let caliper, caliper.isInstalled, let currentURL else { return nil }
        return StepCaliperAction(handoff: caliper, sourceURL: currentURL)
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        show(.loading)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        cancelCurrentRequest(deactivate: false)
        let generation = UUID()
        requestGeneration = generation
        show(.loading)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.load(url, generation: generation)
            if self.requestGeneration == generation {
                self.importTask = nil
            }
        }
        importTask = task
        await task.value
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        cancelCurrentRequest(deactivate: true)
    }

    deinit {
        importTask?.cancel()
        importClient.cancel()
    }

    private func load(_ url: URL, generation: UUID) async {
        currentURL = url
        let requestStart = ProcessInfo.processInfo.systemUptime
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let budgetResolution = await StepPreviewImportBudget.resolve(for: url)
            let budget = budgetResolution.budget
            let cache = StepPreviewCache(profileIdentifier: budget.cacheProfileIdentifier)
            let cacheLocation = try await cache.locationEvidence()
            Self.lifecycleLog.info(
                "cache_location scope=\(cacheLocation.scope.rawValue, privacy: .public) identifier=\(cacheLocation.identifierFingerprint, privacy: .public) preflight_worker_thread=\(budgetResolution.workerThread && cacheLocation.workerThread)"
            )
            let cacheStart = ProcessInfo.processInfo.systemUptime
            let loaded = try await cache.loadOrImport(for: url) {
                let preflight = try await budget.preflightColdImport(for: url)
                if let preflight {
                    Self.lifecycleLog.info(
                        "cold_import_preflight advanced_faces=\(preflight.scan.advancedFaceCount) b_spline_surfaces=\(preflight.scan.bSplineSurfaceCount) scan_seconds=\(preflight.scan.scanSeconds, format: .fixed(precision: 3)) predicted_seconds=\(preflight.predictedSeconds, format: .fixed(precision: 3)) budget_seconds=\(preflight.budgetSeconds, format: .fixed(precision: 3)) starting_simplification=\(preflight.startingSimplificationLevel)"
                    )
                }
                let lookupSeconds = ProcessInfo.processInfo.systemUptime - cacheStart
                Self.lifecycleLog.info(
                    "cache_miss lookup_seconds=\(lookupSeconds, format: .fixed(precision: 3))"
                )
                let importStart = ProcessInfo.processInfo.systemUptime
                let result = try await importClient.importFile(
                    at: url,
                    maxSeconds: budget.seconds,
                    maxTriangles: budget.maximumTriangles,
                    relativeDeflection: budget.relativeDeflection,
                    minimumDeflection: budget.minimumDeflection,
                    maximumDeflection: budget.maximumDeflection,
                    startingSimplificationLevel:
                        preflight?.startingSimplificationLevel ?? 0
                )
                let importSeconds = ProcessInfo.processInfo.systemUptime - importStart
                Self.lifecycleLog.info(
                    "import_complete seconds=\(importSeconds, format: .fixed(precision: 3)) metrics=\(String(describing: result.metrics), privacy: .public)"
                )
                return result.archive
            }
            try Task.checkCancellation()
            guard requestGeneration == generation else { throw CancellationError() }
            let totalSeconds = ProcessInfo.processInfo.systemUptime - requestStart
            Self.lifecycleLog.info(
                "preview_ready source=\(loaded.source.rawValue, privacy: .public) cache_seconds=\(ProcessInfo.processInfo.systemUptime - cacheStart, format: .fixed(precision: 3)) request_seconds=\(totalSeconds, format: .fixed(precision: 3)) triangles=\(loaded.model.triangleCount) definitions=\(loaded.model.definitions.count) occurrences=\(loaded.model.occurrences.count) missing_faces=\(loaded.model.missingFaceCount)"
            )
            show(.model(
                loaded.model,
                loadIdentifier: generation,
                requestStartUptime: requestStart,
                loadSource: loaded.source.rawValue,
                caliper: caliperAction
            ), generation: generation)
        } catch is CancellationError {
            let totalSeconds = ProcessInfo.processInfo.systemUptime - requestStart
            Self.lifecycleLog.info("preview_cancelled request_seconds=\(totalSeconds, format: .fixed(precision: 3))")
            return
        } catch {
            let totalSeconds = ProcessInfo.processInfo.systemUptime - requestStart
            guard requestGeneration == generation, !Task.isCancelled else {
                Self.lifecycleLog.info(
                    "preview_cancelled request_seconds=\(totalSeconds, format: .fixed(precision: 3))"
                )
                return
            }
            let nsError = error as NSError
            Self.lifecycleLog.error(
                "preview_failed category=\(StepTelemetryFailureCategory.label(for: error), privacy: .public) request_seconds=\(totalSeconds, format: .fixed(precision: 3)) domain=\(nsError.domain, privacy: .public) code=\(nsError.code)"
            )
            let action = caliperAction
            let advice = StepPreviewErrorMessage.advice(
                for: error,
                caliperInstalled: action != nil
            )
            show(.failure(advice.message, advice.offersCaliper ? action : nil))
        }
    }

    private func cancelCurrentRequest(deactivate: Bool) {
        requestGeneration = UUID()
        importTask?.cancel()
        importTask = nil
        importClient.cancel()
        if deactivate, isViewLoaded {
            show(.inactive)
        }
    }

    private func show(_ state: PreviewContent.State, generation: UUID? = nil) {
        let content = PreviewContent(state: state) { [weak self] message in
            guard let self else { return }
            if let generation, self.requestGeneration != generation { return }
            // A render failure is a LookSTEP-side problem, so Caliper is a
            // genuine alternative here whenever it is installed.
            self.show(.failure(message, self.caliperAction))
        }
        if let hostingController {
            hostingController.rootView = content
            return
        }
        let host = NSHostingController(rootView: content)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hostingController = host
    }

    private static func friendlyMessage(for error: Error) -> String {
        StepPreviewErrorMessage.userMessage(for: error)
    }
}

/// The Caliper handoff for the currently previewed file, if one is offered.
private struct StepCaliperAction {
    let handoff: StepCaliperHandoff
    let sourceURL: URL
}

private struct PreviewContent: View {
    enum State {
        case inactive
        case loading
        case model(
            StepMeshData,
            loadIdentifier: UUID,
            requestStartUptime: TimeInterval,
            loadSource: String,
            caliper: StepCaliperAction?
        )
        case failure(String, StepCaliperAction?)
    }

    let state: State
    let onRenderFailure: (String) -> Void
    @AppStorage(
        StepPreviewBackgroundPreference.alwaysWhiteKey,
        store: StepPreviewBackgroundPreference.sharedDefaults
    )
    private var alwaysUseWhitePreviewBackground =
        StepPreviewBackgroundPreference.defaultAlwaysWhite
    @SwiftUI.State private var fitRequest = 0

    private struct ModelPresentation {
        let model: StepMeshData
        let loadIdentifier: UUID
        let requestStartUptime: TimeInterval
        let loadSource: String
        let caliper: StepCaliperAction?
    }

    private var modelPresentation: ModelPresentation? {
        guard case .model(
            let model,
            let loadIdentifier,
            let requestStartUptime,
            let loadSource,
            let caliper
        ) = state else { return nil }
        return ModelPresentation(
            model: model,
            loadIdentifier: loadIdentifier,
            requestStartUptime: requestStartUptime,
            loadSource: loadSource,
            caliper: caliper
        )
    }

    var body: some View {
        let presentation = modelPresentation
        ZStack {
            previewBackgroundColor
            StepInteractiveView(
                model: presentation?.model,
                loadIdentifier: presentation?.loadIdentifier,
                fitRequest: fitRequest,
                requestStartUptime: presentation?.requestStartUptime,
                loadSource: presentation?.loadSource,
                alwaysWhiteBackground: alwaysUseWhitePreviewBackground,
                onFailure: { message in
                    onRenderFailure(message)
                }
            )
            switch state {
            case .inactive:
                previewBackgroundColor
            case .loading:
                previewBackgroundColor
                    .overlay {
                        VStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.large)
                                .accessibilityHidden(true)
                            Text("Preparing preview…")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .stepAccessibilityStatus(.loading(
                            phase: "Preparing preview…"
                        ))
                    }
            case .model:
                if let presentation {
                    modelChrome(presentation)
                }
            case .failure(let message, let caliper):
                previewBackgroundColor
                    .overlay {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 30, weight: .light))
                                .foregroundStyle(.orange)
                                .accessibilityHidden(true)
                            Text("Can’t preview this STEP file")
                                .font(.system(size: 16, weight: .semibold))
                            Text(message)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 380)
                            if let caliper {
                                Button("Open in Caliper") { openInCaliper(caliper) }
                                    .controlSize(.regular)
                                    .accessibilityHint(
                                        "Opens this file in Caliper for exact geometry"
                                    )
                            }
                        }
                        .stepAccessibilityStatus(.failure(
                            title: "Can’t preview this STEP file",
                            message: message
                        ))
                        .padding(30)
                    }
            }
        }
        .preferredColorScheme(alwaysUseWhitePreviewBackground ? .light : nil)
    }

    private var previewBackgroundColor: Color {
        alwaysUseWhitePreviewBackground
            ? .white
            : Color(nsColor: .windowBackgroundColor)
    }

    private func modelChrome(_ presentation: ModelPresentation) -> some View {
        ZStack {
            VStack {
                HStack {
                    Spacer()
                    Button {
                        fitRequest &+= 1
                    } label: {
                        Image(systemName: "viewfinder")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(.regularMaterial, in: Circle())
                            .overlay {
                                Circle().stroke(.black.opacity(0.08), lineWidth: 0.5)
                            }
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Fit model to window")
                    .accessibilityHint("Centers the entire model in the preview")
                    .help("Fit model to window")
                    .padding(6)
                }
                Spacer()
            }
            VStack {
                Spacer()
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        if let notice = presentation.model.simplifiedPreviewNotice(
                            caliperInstalled: presentation.caliper != nil
                        ) {
                            previewBadge(
                                symbol: "square.on.square.dashed",
                                tint: .secondary,
                                summary: notice.summary,
                                detail: notice.detail,
                                accessibilityLabel: notice.accessibilityLabel
                            )
                            .onTapGesture {
                                if notice.offersCaliper,
                                   let caliper = presentation.caliper {
                                    openInCaliper(caliper)
                                }
                            }
                        }
                        if let notice = presentation.model.incompleteGeometryNotice {
                            previewBadge(
                                symbol: "exclamationmark.circle.fill",
                                tint: .orange,
                                summary: notice.summary,
                                detail: notice.detail,
                                accessibilityLabel: notice.accessibilityLabel
                            )
                        }
                    }
                    Spacer()
                }
                .padding(12)
            }
        }
    }

    private func openInCaliper(_ action: StepCaliperAction) {
        Task { @MainActor in
            // A failed handoff leaves the existing message in place: the user
            // is already looking at an explanation, and replacing it with a
            // launch error would lose why the preview failed in the first place.
            try? await action.handoff.open(action.sourceURL)
        }
    }

    private func previewBadge(
        symbol: String,
        tint: Color,
        summary: String,
        detail: String,
        accessibilityLabel: String
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(summary)
                .foregroundStyle(.primary)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().stroke(tint.opacity(0.35), lineWidth: 0.5) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .help(detail)
    }
}
