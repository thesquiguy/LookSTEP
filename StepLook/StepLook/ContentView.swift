import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

enum StepViewerCommand {
    static let open = Notification.Name("LookSTEP.command.open")
    static let openURL = Notification.Name("LookSTEP.command.openURL")
    static let fit = Notification.Name("LookSTEP.command.fit")
}

struct ContentView: View {
    private struct PendingPublication {
        let model: StepMeshData
        let url: URL
        let generation: UUID
        let requestStart: TimeInterval
        let source: String
    }

    private nonisolated static let lifecycleLog = Logger(
        subsystem: "com.local.stepviewer.StepLook",
        category: "HostLifecycle"
    )

    @AppStorage(
        StepPreviewBackgroundPreference.alwaysWhiteKey,
        store: StepPreviewBackgroundPreference.sharedDefaults
    )
    private var alwaysUseWhitePreviewBackground =
        StepPreviewBackgroundPreference.defaultAlwaysWhite
    @AppStorage("LookSTEP.restorationBookmark") private var restorationBookmark = Data()
    @State private var openPanelController = StepOpenPanelController()
    @State private var isDropTarget = false
    @State private var displayedURL: URL?
    @State private var openingURL: URL?
    @State private var lastFailedURL: URL?
    @State private var model: StepMeshData?
    @State private var displayedModel: StepMeshData?
    @State private var pendingPublication: PendingPublication?
    @State private var presentationTransaction = StepPresentationTransaction()
    @State private var modelLoadIdentifier = UUID()
    @State private var rendererRequestStartUptime: TimeInterval?
    @State private var rendererLoadSource: String?
    @State private var errorMessage: String?
    @State private var errorOffersCaliper = false
    private let caliper = StepCaliperHandoff.configured()
    @State private var loadingMessage = "Opening model…"
    @State private var isLoading = false
    @State private var viewportResetID = 0
    @State private var loadGeneration = UUID()
    @State private var importTask: Task<Void, Never>?
    @State private var importClient = StepImportClient()
    @State private var didAttemptRestoration = false

    var body: some View {
        VStack(spacing: 0) {
            viewport
            if let displayedModel {
                statusBar(for: displayedModel)
            }
        }
        .background(previewBackgroundColor)
        .preferredColorScheme(alwaysUseWhitePreviewBackground ? .light : nil)
        .navigationTitle(displayedURL?.lastPathComponent ?? "LookSTEP")
        .toolbarRole(.editor)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if displayedModel != nil {
                    Button {
                        viewportResetID &+= 1
                    } label: {
                        Label("Fit", systemImage: "viewfinder")
                    }
                    .help("Fit the entire model in the window (Command-0)")
                    .accessibilityHint("Centers the entire model in the viewport")
                }

                if isOpenCancellable {
                    Button(role: .cancel) {
                        cancelImport()
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                    }
                    .help("Cancel opening \(openingURL?.lastPathComponent ?? "this model")")
                }

                Button {
                    chooseFile()
                } label: {
                    Label("Open…", systemImage: "folder")
                }
                .help("Open a STEP model (Command-O)")
            }
        }
        .background(StepWindowConfigurator(representedURL: displayedURL))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: Self.isSTEPFile) else { return false }
            open(url)
            return true
        } isTargeted: { isTargeted in
            isDropTarget = isTargeted
        }
        .onOpenURL { url in
            guard Self.isSTEPFile(url) else { return }
            open(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: StepViewerCommand.open)) { _ in
            chooseFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: StepViewerCommand.openURL)) { note in
            guard let url = note.object as? URL, Self.isSTEPFile(url) else { return }
            open(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: StepViewerCommand.fit)) { _ in
            guard displayedModel != nil else { return }
            viewportResetID &+= 1
        }
        .onAppear(perform: restoreDocumentIfNeeded)
        .onDisappear {
            importTask?.cancel()
            importClient.cancel()
        }
    }

    private var viewport: some View {
        ZStack {
            previewBackgroundColor

            if let model {
                interactiveViewport(for: model)
                .transition(.opacity)
            } else if isLoading {
                loadingView
            } else if let errorMessage {
                errorView(errorMessage)
            } else {
                emptyView
            }

            if isOpenCancellable, model != nil {
                loadingOverlay
                    .frame(maxHeight: .infinity, alignment: .top)
            }

            if let errorMessage, model != nil, !isLoading {
                replacementErrorBanner(errorMessage)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }

            if isDropTarget {
                dropOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(.easeOut(duration: 0.18), value: isDropTarget)
        .accessibilityAction(named: "Open STEP model") {
            chooseFile()
        }
    }

    private var isOpenCancellable: Bool {
        isLoading || presentationTransaction.isActive
    }

    private var previewBackgroundColor: Color {
        alwaysUseWhitePreviewBackground
            ? .white
            : Color(nsColor: .windowBackgroundColor)
    }

    private func interactiveViewport(for model: StepMeshData) -> some View {
        let presentationGeneration = presentationTransaction.generation
        return StepInteractiveView(
            model: model,
            loadIdentifier: modelLoadIdentifier,
            fitRequest: viewportResetID,
            requestStartUptime: rendererRequestStartUptime,
            loadSource: rendererLoadSource,
            alwaysWhiteBackground: alwaysUseWhitePreviewBackground,
            onReady: {
                guard let presentationGeneration else { return }
                completeRendererPublication(generation: presentationGeneration)
            },
            onFailure: { message in
                guard let presentationGeneration else { return }
                failRendererPublication(message, generation: presentationGeneration)
            }
        )
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .accessibilityHidden(true)

            VStack(spacing: 5) {
                Text("Preview a STEP model")
                    .font(.title3.weight(.semibold))
                Text("Drop a .step or .stp file here, or choose one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .stepAccessibilityStatus(.empty(
                detail: "Drop a .step or .stp file here, or choose one."
            ))

            Button("Open STEP File…") {
                chooseFile()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(32)
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .accessibilityHidden(true)
                Text(loadingMessage)
                    .font(.headline)
                if let openingURL {
                    Text(openingURL.lastPathComponent)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .stepAccessibilityStatus(.loading(
                phase: loadingMessage,
                fileName: openingURL?.lastPathComponent
            ))
            Button("Cancel") {
                cancelImport()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(32)
    }

    private var loadingOverlay: some View {
        HStack(spacing: 9) {
            HStack(spacing: 9) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text(loadingMessage)
                if let openingURL {
                    Text(openingURL.lastPathComponent)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .stepAccessibilityStatus(.loading(
                phase: loadingMessage,
                fileName: openingURL?.lastPathComponent
            ))
            Spacer(minLength: 12)
            if isOpenCancellable {
                Button("Cancel") { cancelImport() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(spacing: 5) {
                Text("Can’t open this STEP file")
                    .font(.title3.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            .stepAccessibilityStatus(.failure(
                title: "Can’t open this STEP file",
                message: message
            ))
            HStack(spacing: 8) {
                let failedURL = lastFailedURL ?? openingURL ?? displayedURL
                if let failedURL {
                    Button("Try Again") { open(failedURL) }
                }
                if errorOffersCaliper, let failedURL {
                    Button("Open in Caliper") { openInCaliper(failedURL) }
                        .buttonStyle(.bordered)
                        .accessibilityHint(
                            "Opens this file in Caliper for exact geometry"
                        )
                }
                Button("Choose Another File…") { chooseFile() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(32)
    }

    private func replacementErrorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("The new model couldn’t be opened")
                    .fontWeight(.semibold)
                Text(message)
                    .foregroundStyle(.secondary)
            }
            .stepAccessibilityStatus(.failure(
                title: "The new model couldn’t be opened",
                message: message
            ))
            Spacer(minLength: 12)
            Button("Dismiss") { errorMessage = nil }
        }
        .font(.callout)
        .padding(12)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private var dropOverlay: some View {
        ZStack {
            Color.accentColor.opacity(0.08)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
                .padding(14)
            Label("Drop to open", systemImage: "square.and.arrow.down")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func statusBar(for model: StepMeshData) -> some View {
        HStack(spacing: 0) {
            statusItem("Triangles", value: model.triangleCount.formatted())
            statusDivider
            statusItem("Faces", value: model.faceCount.formatted())
            statusDivider
            statusItem("Parts", value: model.definitions.count.formatted())
            statusDivider
            statusItem("Instances", value: model.occurrences.count.formatted())
            statusDivider
            statusItem("Units", value: unitDescription(for: model))
            statusDivider
            statusItem("Opened", value: duration(model.parseSeconds + model.meshSeconds))

            if let notice = model.simplifiedPreviewNotice(
                caliperInstalled: isCaliperInstalled
            ) {
                Spacer(minLength: 12)
                HStack(spacing: 4) {
                    Image(systemName: "square.on.square.dashed")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(notice.summary)
                        .foregroundStyle(.primary)
                }
                    .font(.caption.weight(.medium))
                    .accessibilityLabel(notice.accessibilityLabel)
                    .help(notice.detail)
            }

            if let notice = model.incompleteGeometryNotice {
                Spacer(minLength: 12)
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(notice.summary)
                        .foregroundStyle(.primary)
                }
                    .font(.caption.weight(.medium))
                    .accessibilityLabel(notice.accessibilityLabel)
                    .help(notice.detail)
            }

            Spacer(minLength: 12)
            Text("Drag: rotate  •  Shift-drag: pan  •  Scroll: zoom")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Viewport controls: drag to rotate, Shift-drag to pan, and scroll to zoom")
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { Divider().opacity(0.55) }
    }

    private func statusItem(_ label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .font(.caption2.weight(.medium))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }

    private var statusDivider: some View {
        Divider().frame(height: 12).padding(.horizontal, 10)
    }

    private func chooseFile() {
        openPanelController.present { url in
            open(url)
        }
    }

    private func open(_ url: URL) {
        importTask?.cancel()
        importClient.cancel()

        // Rendering is part of the open transaction. If another open starts,
        // abandon the candidate and keep the last presented document active.
        if presentationTransaction.cancel() == .restoreDisplayedDocument {
            pendingPublication = nil
            model = displayedModel
            modelLoadIdentifier = UUID()
            rendererRequestStartUptime = nil
            rendererLoadSource = nil
        }

        let generation = UUID()
        loadGeneration = generation
        openingURL = url
        lastFailedURL = nil
        errorMessage = nil
        isLoading = true
        loadingMessage = "Opening model…"
        let requestStart = ProcessInfo.processInfo.systemUptime

        importTask = Task {
            await loadModel(at: url, generation: generation, requestStart: requestStart)
        }
    }

    private func loadModel(at url: URL, generation: UUID, requestStart: TimeInterval) async {
        let hasScopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let budgetResolution = await StepPreviewImportBudget.resolve(for: url)
            let budget = budgetResolution.budget
            loadingMessage = "Preparing model…"
            let cache = StepPreviewCache(
                profileIdentifier: budget.cacheProfileIdentifier
            )
            let cacheLocation = try await cache.locationEvidence()
            Self.lifecycleLog.info(
                "cache_location scope=\(cacheLocation.scope.rawValue, privacy: .public) identifier=\(cacheLocation.identifierFingerprint, privacy: .public) preflight_worker_thread=\(budgetResolution.workerThread && cacheLocation.workerThread)"
            )
            let loaded = try await cache.loadOrImport(for: url) {
                let preflight = try await budget.preflightColdImport(for: url)
                if let preflight {
                    Self.lifecycleLog.info(
                        "cold_import_preflight advanced_faces=\(preflight.scan.advancedFaceCount) b_spline_surfaces=\(preflight.scan.bSplineSurfaceCount) scan_seconds=\(preflight.scan.scanSeconds, format: .fixed(precision: 3)) predicted_seconds=\(preflight.predictedSeconds, format: .fixed(precision: 3)) budget_seconds=\(preflight.budgetSeconds, format: .fixed(precision: 3)) starting_simplification=\(preflight.startingSimplificationLevel)"
                    )
                }
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
                return result.archive
            }
            try Task.checkCancellation()
            guard loadGeneration == generation else { throw CancellationError() }

            loadingMessage = "Rendering model…"
            publish(
                loaded.model,
                from: url,
                generation: generation,
                requestStart: requestStart,
                source: loaded.source.rawValue
            )
        } catch is CancellationError {
            finishCancellation(generation: generation)
        } catch {
            if Task.isCancelled {
                finishCancellation(generation: generation)
            } else if loadGeneration == generation {
                openingURL = nil
                lastFailedURL = url
                isLoading = false
                applyFailure(error)
                let nsError = error as NSError
                Self.lifecycleLog.error(
                    "open_failed category=\(StepTelemetryFailureCategory.label(for: error), privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code) preserved_document=\(displayedModel != nil)"
                )
            }
        }
    }

    private func publish(
        _ openedModel: StepMeshData,
        from url: URL,
        generation: UUID,
        requestStart: TimeInterval,
        source: String
    ) {
        guard loadGeneration == generation else { return }
        pendingPublication = PendingPublication(
            model: openedModel,
            url: url,
            generation: generation,
            requestStart: requestStart,
            source: source
        )
        model = openedModel
        modelLoadIdentifier = UUID()
        presentationTransaction.begin(generation: generation)
        rendererRequestStartUptime = requestStart
        rendererLoadSource = source
        openingURL = nil
        lastFailedURL = nil
        errorMessage = nil
        isLoading = false
        loadingMessage = "Rendering model…"
    }

    private func completeRendererPublication(generation: UUID) {
        guard let publication = pendingPublication,
              publication.generation == generation,
              presentationTransaction.complete(generation: generation) else { return }
        pendingPublication = nil
        displayedModel = publication.model
        displayedURL = publication.url
        rendererRequestStartUptime = nil
        rendererLoadSource = nil
        loadingMessage = "Opening model…"
        NSDocumentController.shared.noteNewRecentDocumentURL(publication.url)
        if let bookmark = try? publication.url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            restorationBookmark = bookmark
        }
        let totalSeconds = ProcessInfo.processInfo.systemUptime - publication.requestStart
        Self.lifecycleLog.info(
            "model_presented source=\(publication.source, privacy: .public) seconds=\(totalSeconds, format: .fixed(precision: 3)) triangles=\(publication.model.triangleCount) definitions=\(publication.model.definitions.count) occurrences=\(publication.model.occurrences.count) hierarchy_nodes=\(publication.model.hierarchy.count) missing_faces=\(publication.model.missingFaceCount)"
        )
    }

    private func failRendererPublication(_ message: String, generation: UUID) {
        guard let publication = pendingPublication,
              publication.generation == generation,
              presentationTransaction.complete(generation: generation) else { return }
        let failedURL = publication.url
        pendingPublication = nil
        rendererRequestStartUptime = nil
        rendererLoadSource = nil
        lastFailedURL = failedURL
        errorMessage = message
        model = displayedModel
        loadingMessage = "Opening model…"
        Self.lifecycleLog.error(
            "open_failed category=presentation preserved_document=\(displayedModel != nil)"
        )
    }

    private func cancelImport() {
        let wasPresenting = presentationTransaction.isActive
        Self.lifecycleLog.info(
            "open_cancelled phase=\(wasPresenting ? "presentation" : "import", privacy: .public) preserved_document=\(displayedModel != nil)"
        )
        loadGeneration = UUID()
        importTask?.cancel()
        importTask = nil
        importClient.cancel()
        if presentationTransaction.cancel() == .restoreDisplayedDocument {
            pendingPublication = nil
            model = displayedModel
            modelLoadIdentifier = UUID()
            rendererRequestStartUptime = nil
            rendererLoadSource = nil
        }
        finishCancellation()
    }

    private func finishCancellation(generation: UUID? = nil) {
        if let generation, generation != loadGeneration { return }
        isLoading = false
        openingURL = nil
        errorMessage = nil
        loadingMessage = "Opening model…"
    }

    private func restoreDocumentIfNeeded() {
        guard !didAttemptRestoration else { return }
        didAttemptRestoration = true
        // The XCTest host launches the real app. Restoring a bookmarked model
        // there would start an unrelated import and race the XPC contract tests
        // for the service's single request slot.
        guard ProcessInfo.processInfo.environment[
            "XCTestConfigurationFilePath"
        ] == nil else {
            return
        }
        guard !restorationBookmark.isEmpty else { return }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: restorationBookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), Self.isSTEPFile(url) else {
            self.restorationBookmark = Data()
            return
        }
        if isStale {
            if let bookmark = try? url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                self.restorationBookmark = bookmark
            }
        }
        open(url)
    }

    private var isCaliperInstalled: Bool {
        caliper?.isInstalled ?? false
    }

    /// The message to show, recording alongside it whether an Open in Caliper
    /// button belongs beneath it.
    private func applyFailure(_ error: Error) {
        let nsError = error as NSError
        if nsError.code == NSUserCancelledError {
            errorMessage = "Opening was canceled."
            errorOffersCaliper = false
            return
        }
        let advice = StepPreviewErrorMessage.advice(
            for: error,
            caliperInstalled: isCaliperInstalled
        )
        errorMessage = advice.message
        errorOffersCaliper = advice.offersCaliper
    }

    private func openInCaliper(_ url: URL) {
        guard let caliper else { return }
        Task { @MainActor in
            do {
                try await caliper.open(url)
            } catch {
                // Keep the original explanation on screen; only append why the
                // handoff itself did not happen.
                errorOffersCaliper = false
                errorMessage = [
                    errorMessage,
                    (error as? StepCaliperHandoffError)?.errorDescription,
                ].compactMap(\.self).joined(separator: " ")
            }
        }
    }

    private func duration(_ seconds: Double) -> String {
        if seconds < 1 { return "\(Int((seconds * 1_000).rounded())) ms" }
        return "\(seconds.formatted(.number.precision(.fractionLength(1)))) s"
    }

    private func unitDescription(for model: StepMeshData) -> String {
        let scale = model.unitScaleToMeters
        let label: String
        if abs(scale - 0.001) < 1e-12 { label = "mm" }
        else if abs(scale - 0.0254) < 1e-12 { label = "in" }
        else if abs(scale - 1) < 1e-12 { label = "m" }
        else if abs(scale - 0.01) < 1e-12 { label = "cm" }
        else { label = "\(scale.formatted(.number.precision(.significantDigits(3)))) m/unit" }
        return model.hasExplicitLengthUnit ? label : "\(label)*"
    }

    nonisolated private static func isSTEPFile(_ url: URL) -> Bool {
        ["step", "stp"].contains(url.pathExtension.lowercased())
    }
}

private struct StepWindowConfigurator: NSViewRepresentable {
    let representedURL: URL?

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.representedURL = representedURL
            window.title = representedURL?.lastPathComponent ?? "LookSTEP"
            window.isRestorable = true
            window.setFrameAutosaveName("LookSTEP.MainWindow")
        }
    }
}

@MainActor
private final class StepOpenPanelController: NSObject {
    private var isPresenting = false

    func present(onSelection: @escaping (URL) -> Void) {
        guard !isPresenting else { return }
        isPresenting = true

        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.prompt = "Open"
        panel.message = "Choose a STEP (.step or .stp) model."

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.isPresenting = false
            guard response == .OK, let url = panel.url else { return }
            guard Self.isSTEPFile(url) else {
                self?.presentWrongTypeAlert()
                return
            }
            onSelection(url)
        }

        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func presentWrongTypeAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Choose a STEP model"
        alert.informativeText = "LookSTEP opens files whose names end in .step or .stp."
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private static func isSTEPFile(_ url: URL) -> Bool {
        ["step", "stp"].contains(url.pathExtension.lowercased())
    }
}
