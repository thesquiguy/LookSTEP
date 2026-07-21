import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var isChoosingFile = false
    @State private var isDropTarget = false
    @State private var selectedURL: URL?
    @State private var model: StepMeshData?
    @State private var errorMessage: String?
    @State private var loadingMessage = "Opening model…"
    @State private var isLoading = false
    @State private var viewportResetID = 0
    @State private var loadGeneration = UUID()
    @State private var importTask: Task<Void, Never>?
    @State private var importClient = StepImportClient()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.55)
            viewport
            if let model {
                statusBar(for: model)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .fileImporter(
            isPresented: $isChoosingFile,
            allowedContentTypes: [.stepModel, .shaprSTEP, .shaprSTP],
            allowsMultipleSelection: false,
            onCompletion: handleFileSelection
        )
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
        .onDisappear {
            importTask?.cancel()
            importClient.cancel()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedURL?.lastPathComponent ?? "LookSTEP")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(headerSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 16)

            if model != nil {
                Button {
                    viewportResetID &+= 1
                } label: {
                    Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .help("Fit the model in the window")
                .keyboardShortcut("0", modifiers: .command)
            }

            Button {
                isChoosingFile = true
            } label: {
                Label("Open…", systemImage: "folder")
            }
            .keyboardShortcut("o", modifiers: .command)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .frame(height: 54)
    }

    private var viewport: some View {
        ZStack {
            Color.white

            if let model {
                StepInteractiveView(model: model, fitRequest: viewportResetID) { message in
                    self.model = nil
                    errorMessage = message
                }
                    .transition(.opacity)
            } else if isLoading {
                loadingView
            } else if let errorMessage {
                errorView(errorMessage)
            } else {
                emptyView
            }

            if isDropTarget {
                dropOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(.easeOut(duration: 0.18), value: isDropTarget)
    }

    private var emptyView: some View {
        VStack(spacing: 15) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))

            VStack(spacing: 5) {
                Text("Preview a STEP model")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Drop a STEP file here, or choose one.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Button("Open STEP File…") {
                isChoosingFile = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(32)
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(loadingMessage)
                .font(.system(size: 14, weight: .medium))
            if let selectedURL {
                Text(selectedURL.lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button("Cancel") {
                cancelImport()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(32)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.orange)
            VStack(spacing: 5) {
                Text("Can’t preview this STEP file")
                    .font(.system(size: 16, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            HStack(spacing: 8) {
                if let selectedURL {
                    Button("Try Again") {
                        open(selectedURL)
                    }
                    .buttonStyle(.bordered)
                }
                Button("Choose Another File…") {
                    isChoosingFile = true
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(32)
    }

    private var dropOverlay: some View {
        ZStack {
            Color.accentColor.opacity(0.07)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
                .padding(14)
            Label("Drop to preview", systemImage: "square.and.arrow.down")
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
        }
        .allowsHitTesting(false)
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
            statusItem("Opened", value: duration(model.parseSeconds + model.meshSeconds))

            if model.isIncomplete {
                Spacer()
                Label(missingFaceSummary(model.missingFaceCount), systemImage: "exclamationmark.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
            }

            Spacer()
            Text("Drag to rotate  •  Shift-drag to pan  •  Scroll to zoom")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { Divider().opacity(0.55) }
    }

    private func statusItem(_ label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .font(.system(size: 10, weight: .medium))
    }

    private var statusDivider: some View {
        Divider()
            .frame(height: 12)
            .padding(.horizontal, 10)
    }

    private var headerSubtitle: String {
        if isLoading { return loadingMessage }
        if errorMessage != nil { return "Preview unavailable" }
        if model != nil { return "Ready" }
        return "Open or drop a STEP file"
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let url = urls.first { open(url) }
        case .failure(let error):
            guard (error as NSError).code != NSUserCancelledError else { return }
            errorMessage = friendlyMessage(for: error)
        }
    }

    private func open(_ url: URL) {
        importTask?.cancel()
        importClient.cancel()

        let generation = UUID()
        loadGeneration = generation

        selectedURL = url
        model = nil
        errorMessage = nil
        isLoading = true
        loadingMessage = "Opening model…"

        importTask = Task {
            await loadModel(at: url, generation: generation)
        }
    }

    private func loadModel(at url: URL, generation: UUID) async {
        let hasScopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let budget = ImportBudget(for: url)
            if let cached = try await Task.detached(priority: .userInitiated, operation: {
                try StepPreviewCache(profileIdentifier: budget.cacheProfileIdentifier).load(for: url)
            }).value {
                try Task.checkCancellation()
                guard loadGeneration == generation else { throw CancellationError() }
                model = cached
                isLoading = false
                loadingMessage = "Ready"
                return
            }

            loadingMessage = "Preparing model…"
            let result = try await importClient.importFile(
                at: url,
                maxSeconds: budget.seconds,
                maxTriangles: budget.maximumTriangles,
                relativeDeflection: budget.relativeDeflection
            )
            try Task.checkCancellation()
            guard loadGeneration == generation else { throw CancellationError() }

            loadingMessage = "Rendering model…"
            let decoded = try await Task.detached(priority: .userInitiated) {
                try StepPreviewCache(profileIdentifier: budget.cacheProfileIdentifier)
                    .store(result.archive, for: url)
            }.value
            try Task.checkCancellation()
            guard loadGeneration == generation else { throw CancellationError() }

            model = decoded
            isLoading = false
        } catch is CancellationError {
            finishCancellation(generation: generation)
        } catch {
            if Task.isCancelled {
                finishCancellation(generation: generation)
            } else if loadGeneration != generation {
                return
            } else {
                model = nil
                isLoading = false
                errorMessage = friendlyMessage(for: error)
            }
        }
    }

    private func cancelImport() {
        loadGeneration = UUID()
        importTask?.cancel()
        importTask = nil
        importClient.cancel()
        finishCancellation()
    }

    private func finishCancellation(generation: UUID? = nil) {
        if let generation, generation != loadGeneration { return }
        isLoading = false
        model = nil
        errorMessage = nil
        loadingMessage = "Opening model…"
    }

    private func friendlyMessage(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.code == NSUserCancelledError { return "Opening was canceled." }
        return StepPreviewErrorMessage.userMessage(for: error)
    }

    private func missingFaceSummary(_ count: Int) -> String {
        count == 1 ? "1 face couldn’t be shown" : "\(count.formatted()) faces couldn’t be shown"
    }

    private func duration(_ seconds: Double) -> String {
        if seconds < 1 { return "\(Int((seconds * 1_000).rounded())) ms" }
        return "\(seconds.formatted(.number.precision(.fractionLength(1)))) s"
    }

    nonisolated private static func isSTEPFile(_ url: URL) -> Bool {
        ["step", "stp"].contains(url.pathExtension.lowercased())
    }
}

private nonisolated struct ImportBudget {
    let seconds: Double
    let maximumTriangles: Int
    let relativeDeflection: Double

    var cacheProfileIdentifier: String {
        "host-v1-\(maximumTriangles)-\(relativeDeflection)"
    }

    init(for url: URL) {
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        switch fileSize {
        case ..<2_000_000:
            seconds = 10
            maximumTriangles = 600_000
            relativeDeflection = 0.0015
        case ..<25_000_000:
            seconds = 20
            maximumTriangles = 900_000
            relativeDeflection = 0.0025
        default:
            seconds = 35
            maximumTriangles = 1_200_000
            relativeDeflection = 0.004
        }
    }
}

private extension UTType {
    static let stepModel = UTType(importedAs: "com.local.stepviewer.step", conformingTo: .data)
    static let shaprSTEP = UTType(importedAs: "com.shapr3d.step", conformingTo: .data)
    static let shaprSTP = UTType(importedAs: "com.shapr3d.stp", conformingTo: .data)
}
