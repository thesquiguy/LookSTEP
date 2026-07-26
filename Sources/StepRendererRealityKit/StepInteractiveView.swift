import AppKit
import CoreGraphics
import Darwin
@preconcurrency import Metal
@preconcurrency import MetalKit
@preconcurrency import QuartzCore
import OSLog
import RealityKit
import SwiftUI

nonisolated struct StepInteractiveScenePlan: Sendable {
    let materialLayouts: [StepMaterialLayout]
    let normalization: simd_float4x4
    let normalizedBoundsMin: SIMD3<Float>
    let normalizedBoundsMax: SIMD3<Float>
    let workerThread: Bool
    let preparationMilliseconds: Double

    @concurrent
    static func prepare(_ model: StepMeshData) async throws -> Self {
        let started = ProcessInfo.processInfo.systemUptime
        let workerThread = StepExecutionContext.isWorkerThread
        var materialLayouts: [StepMaterialLayout] = []
        materialLayouts.reserveCapacity(model.definitions.count)
        for (index, definition) in model.definitions.enumerated() {
            if index.isMultiple(of: 32) {
                try Task.checkCancellation()
                await Task.yield()
            }
            materialLayouts.append(try StepMaterialLayout.make(
                for: definition,
                isCancelled: { Task.isCancelled }
            ))
        }
        try Task.checkCancellation()

        let diagonal = max(model.diagonal, 1.0e-6)
        let inverseDiagonal = 1 / diagonal
        var normalization = matrix_identity_float4x4
        normalization.columns.0.x = inverseDiagonal
        normalization.columns.1.y = inverseDiagonal
        normalization.columns.2.z = inverseDiagonal
        normalization.columns.3 = SIMD4(-model.center * inverseDiagonal, 1)
        return Self(
            materialLayouts: materialLayouts,
            normalization: normalization,
            normalizedBoundsMin: (model.boundsMin - model.center) * inverseDiagonal,
            normalizedBoundsMax: (model.boundsMax - model.center) * inverseDiagonal,
            workerThread: workerThread,
            preparationMilliseconds:
                (ProcessInfo.processInfo.systemUptime - started) * 1_000
        )
    }
}

struct StepInteractiveView: NSViewRepresentable {
    let model: StepMeshData?
    let loadIdentifier: UUID?
    var fitRequest = 0
    var requestStartUptime: TimeInterval?
    var loadSource: String?
    var alwaysWhiteBackground = true
    var onReady: (() -> Void)? = nil
    var onFailure: ((String) -> Void)?

    func makeNSView(context: Context) -> StepMetalView {
        let view = StepMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.alwaysWhiteBackground = alwaysWhiteBackground
        view.onReady = onReady
        view.onFailure = onFailure
        if let model {
            view.load(
                model,
                requestStartUptime: requestStartUptime,
                source: loadSource
            )
        }
        return view
    }

    func updateNSView(_ view: StepMetalView, context: Context) {
        view.alwaysWhiteBackground = alwaysWhiteBackground
        view.onFailure = onFailure
        view.onReady = onReady
        if let model, let loadIdentifier,
           context.coordinator.lastLoadIdentifier != loadIdentifier {
            context.coordinator.lastLoadIdentifier = loadIdentifier
            view.load(
                model,
                requestStartUptime: requestStartUptime,
                source: loadSource
            )
        } else if model == nil,
                  context.coordinator.lastLoadIdentifier != nil {
            context.coordinator.lastLoadIdentifier = nil
            view.cancelLoad()
        }
        if context.coordinator.lastFitRequest != fitRequest {
            context.coordinator.lastFitRequest = fitRequest
            view.fit()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(fitRequest: fitRequest, loadIdentifier: loadIdentifier)
    }

    static func dismantleNSView(_ view: StepMetalView, coordinator: Coordinator) {
        view.cancelLoad()
    }

    final class Coordinator {
        var lastFitRequest: Int
        var lastLoadIdentifier: UUID?

        init(fitRequest: Int, loadIdentifier: UUID?) {
            self.lastFitRequest = fitRequest
            self.lastLoadIdentifier = loadIdentifier
        }
    }
}

@MainActor
final class StepMetalView: MTKView, MTKViewDelegate {
    private struct PreparedDefinition: @unchecked Sendable {
        let resource: MeshResource
        let explicitLinearColors: [SIMD4<Float>]
    }

    private static let meshResourceConcurrency = 4
    private static let lifecycleLog = Logger(
        subsystem: "com.local.stepviewer.StepLook",
        category: "RendererLifecycle"
    )
    nonisolated private static let performanceSignposter = OSSignposter(
        subsystem: "com.local.stepviewer.StepLook",
        category: "RendererPerformance"
    )

    var onFailure: ((String) -> Void)?
    var onReady: (() -> Void)?
    var alwaysWhiteBackground = true {
        didSet {
            guard alwaysWhiteBackground != oldValue else { return }
            updateViewportAppearance()
        }
    }

    private let realityRenderer: RealityRenderer?
    private let camera = Entity()
    private let sceneRoot = Entity()
    private var loadTask: Task<Void, Never>?
    private var yaw: Float = .pi / 4
    private var pitch: Float = .pi / 7
    private var viewCenter = SIMD3<Float>.zero
    private var cameraScale: Float = 1.08
    private var lastPointer = NSPoint.zero
    private var orbitAnchor: SIMD3<Float>?
    private var orbitScreenPoint = NSPoint.zero
    private var raycastModel: StepMeshData?
    private var modelNormalization = matrix_identity_float4x4
    private var normalizedBoundsMin = SIMD3<Float>(repeating: -0.5)
    private var normalizedBoundsMax = SIMD3<Float>(repeating: 0.5)
    private var hasLoadedModel = false
    private var needsInitialFit = true
    private var isAutoFitted = true
    private var lastFrameTime = CACurrentMediaTime()
    private var didReportRenderFailure = false
    private var rendererLoadStart = CACurrentMediaTime()
    private var loadSource = "direct"
    private var didLogFirstFrame = false
    private var rendererGeneration = UUID()
    private var pendingReadyCallback: (() -> Void)?
    private var firstFrameSignpostGeneration: UUID?
    private var firstFrameSignpostState: OSSignpostIntervalState?
    private var redrawScheduler = StepRedrawScheduler()

    /// A published scene is given a few frames rather than one. The first
    /// presentation after publication is the one most likely to catch RealityKit
    /// mid-upload, and a paused view has no later frame to correct itself with.
    private static let scenePublicationSettleFrames = 3

    var hasActiveLoadTask: Bool {
        loadTask != nil
    }

    override init(frame frameRect: NSRect, device: (any MTLDevice)? = nil) {
        let selectedDevice = device ?? MTLCreateSystemDefaultDevice()
        realityRenderer = selectedDevice == nil ? nil : try? RealityRenderer()
        super.init(frame: frameRect, device: selectedDevice)
        configureRenderer(device: selectedDevice)
    }

    required init(coder: NSCoder) {
        let selectedDevice = MTLCreateSystemDefaultDevice()
        realityRenderer = selectedDevice == nil ? nil : try? RealityRenderer()
        super.init(coder: coder)
        configureRenderer(device: device ?? selectedDevice)
    }

    private func configureRenderer(device selectedDevice: (any MTLDevice)?) {
        self.device = selectedDevice
        colorPixelFormat = .bgra8Unorm_srgb
        framebufferOnly = false
        // On-demand presentation. The scene is static between user input, so a
        // continuous loop would spend the whole life of a Quick Look panel
        // redrawing an unchanged image. Every state mutation below is
        // responsible for asking for its own frame.
        enableSetNeedsDisplay = true
        isPaused = true
        updatePreferredFramesPerSecond()
        clearColor = MTLClearColorMake(1, 1, 1, 1)
        delegate = self
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("3D model viewport")
        setAccessibilityHelp(
            "Drag to rotate, Shift-drag to pan, scroll to zoom, or use the arrow and plus or minus keys."
        )

        var projection = OrthographicCameraComponent()
        projection.near = 0.01
        projection.far = 100
        projection.scale = cameraScale
        projection.scaleDirection = .vertical
        camera.components.set(projection)

        StepCADAppearance.addCameraRelativeLights(to: camera)

        if let realityRenderer {
            realityRenderer.entities.append(sceneRoot)
            realityRenderer.entities.append(camera)
            realityRenderer.activeCamera = camera
        }
        updateViewportAppearance()
        updateCamera()
    }

    deinit {
        loadTask?.cancel()
        if let state = firstFrameSignpostState {
            Self.performanceSignposter.endInterval("First geometry frame", state)
        }
    }

    func cancelLoad() {
        endFirstFrameSignpost()
        rendererGeneration = UUID()
        loadTask?.cancel()
        loadTask = nil
        pendingReadyCallback = nil
        hasLoadedModel = false
        didLogFirstFrame = false
        raycastModel = nil
        sceneRoot.children.removeAll()
        setAccessibilityValue("No model loaded")
        // The emptied scene still has to be painted once, or the viewport keeps
        // showing geometry that is no longer loaded.
        requestRedraw()
    }

    func load(
        _ model: StepMeshData,
        requestStartUptime: TimeInterval? = nil,
        source: String? = nil
    ) {
        loadTask?.cancel()
        endFirstFrameSignpost()
        didReportRenderFailure = false
        redrawScheduler.reset()
        rendererLoadStart = Self.firstFrameMeasurementStart(
            rendererNow: CACurrentMediaTime(),
            systemUptime: ProcessInfo.processInfo.systemUptime,
            requestStartUptime: requestStartUptime
        )
        loadSource = source ?? "direct"
        rendererGeneration = UUID()
        pendingReadyCallback = onReady
        hasLoadedModel = false
        didLogFirstFrame = false
        let generation = rendererGeneration
        beginFirstFrameSignpost(generation: generation)
        let failureCallback = onFailure
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if rendererGeneration == generation {
                    loadTask = nil
                }
            }
            guard realityRenderer != nil, device != nil else {
                reportFailure(
                    "The 3D preview couldn’t start on this Mac.",
                    callback: failureCallback
                )
                return
            }
            do {
                let plan = try await StepInteractiveScenePlan.prepare(model)
                try Task.checkCancellation()
                guard rendererGeneration == generation else {
                    throw CancellationError()
                }
                Self.lifecycleLog.info(
                    "scene_plan_ready worker_thread=\(plan.workerThread) milliseconds=\(plan.preparationMilliseconds, format: .fixed(precision: 3)) definitions=\(plan.materialLayouts.count) occurrences=\(model.occurrences.count)"
                )
                let resourceStarted = CACurrentMediaTime()
                var indexedResources = [PreparedDefinition?](
                    repeating: nil,
                    count: model.definitions.count
                )
                try await withThrowingTaskGroup(
                    of: (Int, PreparedDefinition).self
                ) { group in
                    let initialCount = min(
                        Self.meshResourceConcurrency,
                        model.definitions.count
                    )
                    for index in 0..<initialCount {
                        let definition = model.definitions[index]
                        let layout = plan.materialLayouts[index]
                        group.addTask {
                            try await Self.prepareDefinition(
                                index: index,
                                definition: definition,
                                materialLayout: layout
                            )
                        }
                    }
                    var nextIndex = initialCount
                    while let (index, resource) = try await group.next() {
                        indexedResources[index] = resource
                        if nextIndex < model.definitions.count {
                            let queuedIndex = nextIndex
                            let definition = model.definitions[queuedIndex]
                            let layout = plan.materialLayouts[queuedIndex]
                            group.addTask {
                                try await Self.prepareDefinition(
                                    index: queuedIndex,
                                    definition: definition,
                                    materialLayout: layout
                                )
                            }
                            nextIndex += 1
                        }
                    }
                }
                let resources = indexedResources.compactMap(\.self)
                guard resources.count == model.definitions.count else {
                    throw StepMaterialLayoutError.invalidGroups
                }
                Self.lifecycleLog.info(
                    "mesh_resources_ready concurrency=\(Self.meshResourceConcurrency) milliseconds=\((CACurrentMediaTime() - resourceStarted) * 1_000, format: .fixed(precision: 3)) definitions=\(resources.count)"
                )

                let replacementRoot = Entity()
                let publicationStarted = CACurrentMediaTime()
                var sliceStarted = publicationStarted
                var publicationSlices = 0
                var maximumSliceMilliseconds = 0.0
                for (index, occurrence) in model.occurrences.enumerated() {
                    let prepared = resources[occurrence.definitionIndex]
                    let baseColor = StepFallbackColorPolicy.baseLinearColor(for: occurrence)
                    var materials = [StepCADAppearance.material(linearRGBA: baseColor)]
                    materials.append(contentsOf: prepared.explicitLinearColors.map {
                        StepCADAppearance.material(linearRGBA: $0)
                    })
                    guard prepared.resource.expectedMaterialCount == materials.count else {
                        throw StepMaterialLayoutError.invalidGroups
                    }
                    let entity = ModelEntity(mesh: prepared.resource, materials: materials)
                    entity.transform.matrix = plan.normalization * occurrence.transform
                    replacementRoot.addChild(entity)
                    if (index + 1).isMultiple(of: 8) {
                        let sliceMilliseconds =
                            (CACurrentMediaTime() - sliceStarted) * 1_000
                        if sliceMilliseconds >= 8
                            || (index + 1).isMultiple(of: 128) {
                            publicationSlices += 1
                            maximumSliceMilliseconds = max(
                                maximumSliceMilliseconds,
                                sliceMilliseconds
                            )
                            try Task.checkCancellation()
                            await Task.yield()
                            sliceStarted = CACurrentMediaTime()
                        }
                    }
                }
                let finalSliceMilliseconds =
                    (CACurrentMediaTime() - sliceStarted) * 1_000
                if finalSliceMilliseconds > 0 {
                    publicationSlices += 1
                    maximumSliceMilliseconds = max(
                        maximumSliceMilliseconds,
                        finalSliceMilliseconds
                    )
                }
                try Task.checkCancellation()
                guard rendererGeneration == generation else {
                    throw CancellationError()
                }
                sceneRoot.children.removeAll()
                sceneRoot.addChild(replacementRoot)
                raycastModel = model
                setAccessibilityValue(
                    "\(model.definitions.count) parts, \(model.occurrences.count) instances, \(model.triangleCount) triangles"
                )
                modelNormalization = plan.normalization
                normalizedBoundsMin = plan.normalizedBoundsMin
                normalizedBoundsMax = plan.normalizedBoundsMax
                hasLoadedModel = true
                requestRedraw(frames: Self.scenePublicationSettleFrames)
                Self.lifecycleLog.info(
                    "scene_published slices=\(publicationSlices) maximum_slice_ms=\(maximumSliceMilliseconds, format: .fixed(precision: 3)) milliseconds=\((CACurrentMediaTime() - publicationStarted) * 1_000, format: .fixed(precision: 3)) occurrences=\(model.occurrences.count)"
                )
                fit()
            } catch is CancellationError {
                endFirstFrameSignpost(generation: generation)
                Self.lifecycleLog.info("renderer_cancelled phase=preparation")
                return
            } catch {
                reportFailure(
                    "The model’s geometry couldn’t be displayed.",
                    callback: failureCallback
                )
            }
        }
    }

    nonisolated static func firstFrameMeasurementStart(
        rendererNow: TimeInterval,
        systemUptime: TimeInterval,
        requestStartUptime: TimeInterval?
    ) -> TimeInterval {
        guard let requestStartUptime else { return rendererNow }
        return rendererNow - max(0, systemUptime - requestStartUptime)
    }

    nonisolated private static func prepareDefinition(
        index: Int,
        definition: StepMeshDefinition,
        materialLayout: StepMaterialLayout
    ) async throws -> (Int, PreparedDefinition) {
        var descriptor = MeshDescriptor(name: "definition-\(index)")
        descriptor.positions = MeshBuffers.Positions(definition.positions)
        descriptor.normals = MeshBuffers.Normals(definition.normals)
        descriptor.primitives = .triangles(definition.indices)
        descriptor.materials = .perFace(materialLayout.perFaceMaterialIndices)
        return (
            index,
            PreparedDefinition(
                resource: try await MeshResource(from: [descriptor]),
                explicitLinearColors: materialLayout.explicitLinearColors
            )
        )
    }

    func fit(aspectRatio preferredAspectRatio: Float? = nil) {
        guard bounds.width > 1, bounds.height > 1 || preferredAspectRatio != nil else {
            needsInitialFit = true
            return
        }
        let basis = StepCameraMath.basis(yaw: yaw, pitch: pitch)
        let aspectRatio = preferredAspectRatio
            ?? Float(max(1, bounds.width) / max(1, bounds.height))
        if let fitted = fittedCamera(basis: basis, aspectRatio: aspectRatio) {
            viewCenter = fitted.center
            cameraScale = fitted.scale
        } else {
            viewCenter = .zero
            cameraScale = StepCameraMath.fitScale(
                boundsMin: normalizedBoundsMin,
                boundsMax: normalizedBoundsMax,
                basis: basis,
                aspectRatio: aspectRatio
            )
        }
        needsInitialFit = false
        isAutoFitted = true
        updateCamera()
    }

    private func updateCamera() {
        let basis = StepCameraMath.basis(yaw: yaw, pitch: pitch)
        camera.look(at: viewCenter, from: viewCenter + basis.outward * 4, relativeTo: nil)
        if var projection = camera.components[OrthographicCameraComponent.self] {
            projection.scale = cameraScale
            camera.components.set(projection)
        }
        requestRedraw()
    }

    /// The single entry point for putting a frame on screen. Every mutation that
    /// changes what the viewport should show has to come through here, because
    /// nothing else will ever ask a paused view to draw.
    private func requestRedraw(frames: Int = 1) {
        redrawScheduler.request(frames: frames)
        if redrawScheduler.wantsRedraw {
            needsDisplay = true
        }
    }

    private func updatePreferredFramesPerSecond() {
        preferredFramesPerSecond = StepDisplayRefreshPolicy.preferredFramesPerSecond(
            screenMaximum: window?.screen?.maximumFramesPerSecond
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateViewportAppearance()
    }

    private func updateViewportAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let gray: Double = alwaysWhiteBackground
            ? 1
            : (isDark ? 0.075 : 0.965)
        let blue = alwaysWhiteBackground
            ? gray
            : gray + (isDark ? 0.008 : 0.012)
        clearColor = MTLClearColorMake(gray, gray, blue, 1)
        if let realityRenderer {
            var settings = realityRenderer.cameraSettings
            settings.colorBackground = .color(CGColor(gray: gray, alpha: 1))
            settings.antialiasing = .multisample4X
            realityRenderer.cameraSettings = settings
        }
        requestRedraw()
    }

    func draw(in view: MTKView) {
        guard let realityRenderer, let drawable = currentDrawable else { return }
        do {
            let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: drawable.texture))
            let now = CACurrentMediaTime()
            let delta = min(now - lastFrameTime, 1.0 / 15.0)
            lastFrameTime = now
            let recordsFirstGeometryFrame = hasLoadedModel && !didLogFirstFrame
            var readyCallback: (() -> Void)?
            if recordsFirstGeometryFrame {
                didLogFirstFrame = true
                let loadStart = rendererLoadStart
                let source = loadSource
                let triangles = raycastModel?.triangleCount ?? 0
                let definitions = raycastModel?.definitions.count ?? 0
                let occurrences = raycastModel?.occurrences.count ?? 0
                let missingFaces = raycastModel?.missingFaceCount ?? 0
                let generation = rendererGeneration
                readyCallback = pendingReadyCallback
                pendingReadyCallback = nil
                drawable.addPresentedHandler { _ in
                    let seconds = CACurrentMediaTime() - loadStart
                    let peakResidentBytes = Self.peakResidentBytes()
                    Task { @MainActor [weak self] in
                        guard self?.rendererGeneration == generation else { return }
                        self?.endFirstFrameSignpost(generation: generation)
                        Self.lifecycleLog.info(
                            "first_geometry_frame source=\(source, privacy: .public) seconds=\(seconds, format: .fixed(precision: 3)) peak_resident_bytes=\(peakResidentBytes) triangles=\(triangles) definitions=\(definitions) occurrences=\(occurrences) missing_faces=\(missingFaces)"
                        )
                    }
                }
            }
            try realityRenderer.updateAndRender(
                deltaTime: delta,
                cameraOutput: output,
                whenScheduled: { _ in drawable.present() }
            )
            // RealityKit accepted and scheduled the geometry frame. Host
            // publication can now complete even on a drawable path that never
            // invokes addPresentedHandler; that handler remains authoritative
            // for first-pixel telemetry.
            readyCallback?()
            if redrawScheduler.consumeFrame() {
                needsDisplay = true
            }
        } catch {
            didLogFirstFrame = false
            reportFailure("The 3D preview stopped rendering. Try opening the file again.")
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // A resize always needs a frame, whether or not the camera refits: the
        // drawable is new and its contents are undefined.
        requestRedraw()
        guard hasLoadedModel, size.width > 1, size.height > 1,
              needsInitialFit || isAutoFitted else { return }
        fit(aspectRatio: Float(size.width / size.height))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePreferredFramesPerSecond()
        guard window != nil else { return }
        requestRedraw()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Moving between displays can change both the native refresh rate and
        // the backing scale, so re-derive the cadence and repaint.
        updatePreferredFramesPerSecond()
        requestRedraw()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        lastPointer = convert(event.locationInWindow, from: nil)
        guard !event.modifierFlags.contains(.shift) else {
            orbitAnchor = nil
            return
        }
        if let modelPoint = modelPoint(at: lastPointer) {
            orbitScreenPoint = lastPointer
            orbitAnchor = modelPoint
        } else {
            orbitScreenPoint = NSPoint(x: bounds.midX, y: bounds.midY)
            orbitAnchor = viewCenter
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let dx = Float(point.x - lastPointer.x)
        let dy = Float(point.y - lastPointer.y)
        lastPointer = point
        if dx != 0 || dy != 0 { isAutoFitted = false }
        if event.modifierFlags.contains(.shift) {
            pan(dx: dx, dy: dy)
        } else {
            yaw -= dx * 0.008
            pitch = min(.pi / 2 - 0.03, max(-.pi / 2 + 0.03, pitch - dy * 0.008))
            if let orbitAnchor {
                viewCenter = anchoredViewCenter(
                    anchor: orbitAnchor,
                    screenPoint: orbitScreenPoint,
                    scale: cameraScale,
                    basis: StepCameraMath.basis(yaw: yaw, pitch: pitch)
                )
            }
        }
        updateCamera()
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaY != 0 else { return }
        isAutoFitted = false
        let point = convert(event.locationInWindow, from: nil)
        let basis = StepCameraMath.basis(yaw: yaw, pitch: pitch)
        let anchor = modelPoint(at: point)
            ?? pointOnViewPlane(at: point, scale: cameraScale, basis: basis)
        let sensitivity: Float = event.hasPreciseScrollingDeltas ? 0.012 : 0.10
        cameraScale = min(20, max(0.025, cameraScale * exp(-Float(event.scrollingDeltaY) * sensitivity)))
        viewCenter = anchoredViewCenter(anchor: anchor, screenPoint: point, scale: cameraScale, basis: basis)
        updateCamera()
    }

    override func magnify(with event: NSEvent) {
        guard event.magnification != 0 else { return }
        isAutoFitted = false
        let point = convert(event.locationInWindow, from: nil)
        let basis = StepCameraMath.basis(yaw: yaw, pitch: pitch)
        let anchor = modelPoint(at: point)
            ?? pointOnViewPlane(at: point, scale: cameraScale, basis: basis)
        cameraScale = min(20, max(0.025, cameraScale * exp(-Float(event.magnification))))
        viewCenter = anchoredViewCenter(anchor: anchor, screenPoint: point, scale: cameraScale, basis: basis)
        updateCamera()
    }

    override func mouseUp(with event: NSEvent) {
        orbitAnchor = nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 123: // left arrow
            shift ? pan(dx: 24, dy: 0) : rotateFromKeyboard(yawDelta: 0.12, pitchDelta: 0)
        case 124: // right arrow
            shift ? pan(dx: -24, dy: 0) : rotateFromKeyboard(yawDelta: -0.12, pitchDelta: 0)
        case 125: // down arrow
            shift ? pan(dx: 0, dy: 24) : rotateFromKeyboard(yawDelta: 0, pitchDelta: -0.10)
        case 126: // up arrow
            shift ? pan(dx: 0, dy: -24) : rotateFromKeyboard(yawDelta: 0, pitchDelta: 0.10)
        default:
            switch event.charactersIgnoringModifiers {
            case "+", "=":
                isAutoFitted = false
                cameraScale = max(0.025, cameraScale * 0.82)
            case "-", "_":
                isAutoFitted = false
                cameraScale = min(20, cameraScale * 1.22)
            case "0":
                fit()
            default:
                super.keyDown(with: event)
                return
            }
        }
        updateCamera()
    }

    private func rotateFromKeyboard(yawDelta: Float, pitchDelta: Float) {
        isAutoFitted = false
        yaw += yawDelta
        pitch = min(.pi / 2 - 0.03, max(-.pi / 2 + 0.03, pitch + pitchDelta))
    }

    private func pan(dx: Float, dy: Float) {
        let basis = StepCameraMath.basis(yaw: yaw, pitch: pitch)
        viewCenter = StepCameraMath.pannedViewCenter(
            viewCenter,
            dx: dx,
            dy: dy,
            viewportHeight: Float(bounds.height),
            scale: cameraScale,
            basis: basis
        )
    }

    private func pointOnViewPlane(
        at point: NSPoint,
        scale: Float,
        basis: StepCameraBasis
    ) -> SIMD3<Float> {
        viewCenter + StepCameraMath.screenOffset(
            xFromCenter: Float(point.x - bounds.midX),
            yFromCenter: Float(point.y - bounds.midY),
            viewportHeight: Float(bounds.height),
            scale: scale,
            basis: basis
        )
    }

    private func anchoredViewCenter(
        anchor: SIMD3<Float>,
        screenPoint: NSPoint,
        scale: Float,
        basis: StepCameraBasis
    ) -> SIMD3<Float> {
        StepCameraMath.viewCenterKeepingAnchor(
            anchor,
            xFromCenter: Float(screenPoint.x - bounds.midX),
            yFromCenter: Float(screenPoint.y - bounds.midY),
            viewportHeight: Float(bounds.height),
            scale: scale,
            basis: basis
        )
    }

    private func fittedCamera(
        basis: StepCameraBasis,
        aspectRatio: Float
    ) -> (center: SIMD3<Float>, scale: Float)? {
        var minimumRight = Float.infinity
        var maximumRight = -Float.infinity
        var minimumUp = Float.infinity
        var maximumUp = -Float.infinity
        var minimumOutward = Float.infinity
        var maximumOutward = -Float.infinity

        // Fit the normalized world bounds, not every vertex of every
        // occurrence. This keeps Command-0 constant-time on large assemblies.
        for corner in 0..<8 {
            let world = SIMD3<Float>(
                corner & 1 == 0 ? normalizedBoundsMin.x : normalizedBoundsMax.x,
                corner & 2 == 0 ? normalizedBoundsMin.y : normalizedBoundsMax.y,
                corner & 4 == 0 ? normalizedBoundsMin.z : normalizedBoundsMax.z
            )
            let projectedRight = simd_dot(world, basis.right)
            let projectedUp = simd_dot(world, basis.up)
            let projectedOutward = simd_dot(world, basis.outward)
            minimumRight = min(minimumRight, projectedRight)
            maximumRight = max(maximumRight, projectedRight)
            minimumUp = min(minimumUp, projectedUp)
            maximumUp = max(maximumUp, projectedUp)
            minimumOutward = min(minimumOutward, projectedOutward)
            maximumOutward = max(maximumOutward, projectedOutward)
        }

        guard minimumRight.isFinite, maximumRight.isFinite,
              minimumUp.isFinite, maximumUp.isFinite,
              minimumOutward.isFinite, maximumOutward.isFinite else { return nil }
        let projectedWidth = maximumRight - minimumRight
        let projectedHeight = maximumUp - minimumUp
        let scale = max(
            0.025,
            max(projectedHeight, projectedWidth / max(0.01, aspectRatio)) * 0.5 / 0.93
        )
        let center = basis.right * ((minimumRight + maximumRight) * 0.5)
            + basis.up * ((minimumUp + maximumUp) * 0.5)
            + basis.outward * ((minimumOutward + maximumOutward) * 0.5)
        return (center, scale)
    }

    private func modelPoint(at point: NSPoint) -> SIMD3<Float>? {
        guard let raycastModel else { return nil }
        let basis = StepCameraMath.basis(yaw: yaw, pitch: pitch)
        let planePoint = pointOnViewPlane(at: point, scale: cameraScale, basis: basis)
        let rayOrigin = planePoint + basis.outward * 4
        let rayDirection = -basis.outward
        if let intersection = StepCameraMath.nearestModelIntersection(
            model: raycastModel,
            normalization: modelNormalization,
            origin: rayOrigin,
            direction: rayDirection
        ) {
            return intersection
        }

        // Extremely repeated scenes can exceed the bounded exact-pick budget.
        // Their box midpoint is a stable model-depth pivot and avoids falling
        // all the way back to the viewport center.
        guard let range = StepCameraMath.rayBoundsIntersectionRange(
            origin: rayOrigin,
            direction: rayDirection,
            minimum: normalizedBoundsMin,
            maximum: normalizedBoundsMax
        ) else { return nil }
        return rayOrigin + rayDirection * ((range.near + range.far) * 0.5)
    }

    private func reportFailure(_ message: String) {
        reportFailure(message, callback: onFailure)
    }

    private func reportFailure(_ message: String, callback: ((String) -> Void)?) {
        // Stop first and unconditionally: a renderer that has failed once must
        // not be handed further frames, even on a repeat report.
        redrawScheduler.stop()
        guard !didReportRenderFailure else { return }
        didReportRenderFailure = true
        endFirstFrameSignpost()
        Self.lifecycleLog.error("renderer_failed category=presentation")
        callback?(message)
    }

    private func beginFirstFrameSignpost(generation: UUID) {
        firstFrameSignpostGeneration = generation
        firstFrameSignpostState = Self.performanceSignposter.beginInterval(
            "First geometry frame"
        )
    }

    private func endFirstFrameSignpost(generation: UUID? = nil) {
        if let generation, firstFrameSignpostGeneration != generation { return }
        guard let state = firstFrameSignpostState else { return }
        firstFrameSignpostState = nil
        firstFrameSignpostGeneration = nil
        Self.performanceSignposter.endInterval("First geometry frame", state)
    }

    nonisolated private static func peakResidentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.resident_size_max) : 0
    }
}
