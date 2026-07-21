import Cocoa
import OSLog
import Quartz
import SwiftUI

@MainActor
final class PreviewViewController: NSViewController, QLPreviewingController {
    private static let lifecycleLog = Logger(
        subsystem: "com.local.stepviewer.StepLook",
        category: "PreviewLifecycle"
    )

    private var hostingController: NSHostingController<PreviewContent>?
    private var importTask: Task<Void, Never>?
    private let importClient = StepImportClient()

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        show(.loading)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        show(.loading)
        importTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.load(url)
        }
        importTask = task
        await task.value
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        importTask?.cancel()
        importClient.cancel()
    }

    deinit {
        importTask?.cancel()
        importClient.cancel()
    }

    private func load(_ url: URL) async {
        let requestStart = ProcessInfo.processInfo.systemUptime
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let budget = PreviewImportBudget(for: url)
            let cache = StepPreviewCache(profileIdentifier: budget.cacheProfileIdentifier)
            let cacheStart = ProcessInfo.processInfo.systemUptime
            if let cached = try await Task.detached(priority: .userInitiated, operation: {
                try cache.load(for: url)
            }).value {
                try Task.checkCancellation()
                let cacheSeconds = ProcessInfo.processInfo.systemUptime - cacheStart
                Self.lifecycleLog.info(
                    "cache_hit seconds=\(cacheSeconds, format: .fixed(precision: 3)) triangles=\(cached.triangleCount) definitions=\(cached.definitions.count) occurrences=\(cached.occurrences.count) missing_faces=\(cached.missingFaceCount)"
                )
                show(.model(cached))
                return
            }
            let lookupSeconds = ProcessInfo.processInfo.systemUptime - cacheStart
            Self.lifecycleLog.info("cache_miss lookup_seconds=\(lookupSeconds, format: .fixed(precision: 3))")
            let importStart = ProcessInfo.processInfo.systemUptime
            let result = try await importClient.importFile(
                at: url,
                maxSeconds: budget.seconds,
                maxTriangles: 750_000,
                relativeDeflection: budget.relativeDeflection,
                minimumDeflection: budget.minimumDeflection,
                maximumDeflection: budget.maximumDeflection
            )
            try Task.checkCancellation()
            let importSeconds = ProcessInfo.processInfo.systemUptime - importStart
            Self.lifecycleLog.info(
                "import_complete seconds=\(importSeconds, format: .fixed(precision: 3)) metrics=\(String(describing: result.metrics), privacy: .public)"
            )
            let storeStart = ProcessInfo.processInfo.systemUptime
            let model = try await Task.detached(priority: .userInitiated) {
                try cache.store(result.archive, for: url)
            }.value
            try Task.checkCancellation()
            let storeSeconds = ProcessInfo.processInfo.systemUptime - storeStart
            let totalSeconds = ProcessInfo.processInfo.systemUptime - requestStart
            Self.lifecycleLog.info(
                "preview_ready store_seconds=\(storeSeconds, format: .fixed(precision: 3)) request_seconds=\(totalSeconds, format: .fixed(precision: 3)) triangles=\(model.triangleCount) definitions=\(model.definitions.count) occurrences=\(model.occurrences.count) missing_faces=\(model.missingFaceCount)"
            )
            show(.model(model))
        } catch is CancellationError {
            let totalSeconds = ProcessInfo.processInfo.systemUptime - requestStart
            Self.lifecycleLog.info("preview_cancelled request_seconds=\(totalSeconds, format: .fixed(precision: 3))")
            return
        } catch {
            let totalSeconds = ProcessInfo.processInfo.systemUptime - requestStart
            Self.lifecycleLog.error(
                "preview_failed request_seconds=\(totalSeconds, format: .fixed(precision: 3)) error=\(error.localizedDescription, privacy: .public)"
            )
            show(.failure(Self.friendlyMessage(for: error)))
        }
    }

    private func show(_ state: PreviewContent.State) {
        let content = PreviewContent(state: state) { [weak self] message in
            self?.show(.failure(message))
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

private struct PreviewImportBudget {
    let seconds: Double
    let relativeDeflection: Double
    let minimumDeflection: Double
    let maximumDeflection: Double

    var cacheProfileIdentifier: String {
        "preview-v2-750000-\(relativeDeflection)-\(minimumDeflection)-\(maximumDeflection)"
    }

    init(for url: URL) {
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let scale: Double
        switch fileSize {
        case ...1_000_000:
            scale = 1
            seconds = 10
        case ...10_000_000:
            scale = 1.5
            seconds = 12
        case ...50_000_000:
            scale = 4
            seconds = 15
        default:
            scale = 8
            seconds = 15
        }
        relativeDeflection = 0.0008 * scale
        minimumDeflection = 0.02 * scale
        maximumDeflection = 0.2 * scale
    }
}

private struct PreviewContent: View {
    enum State {
        case loading
        case model(StepMeshData)
        case failure(String)
    }

    let state: State
    let onRenderFailure: (String) -> Void
    @SwiftUI.State private var fitRequest = 0

    var body: some View {
        ZStack {
            Color.white
            switch state {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Preparing preview…").font(.system(size: 14, weight: .medium))
                }
            case .model(let model):
                StepInteractiveView(model: model, fitRequest: fitRequest) { message in
                    onRenderFailure(message)
                }
                    .overlay(alignment: .topTrailing) {
                        Button {
                            fitRequest &+= 1
                        } label: {
                            Image(systemName: "viewfinder")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 30, height: 30)
                                .background(.regularMaterial, in: Circle())
                                .overlay { Circle().stroke(.black.opacity(0.08), lineWidth: 0.5) }
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Fit model to window")
                        .accessibilityHint("Centers the entire model in the preview")
                        .help("Fit model to window")
                        .padding(6)
                    }
            case .failure(let message):
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
                }
                .padding(30)
            }
        }
        .environment(\.colorScheme, .light)
    }
}
