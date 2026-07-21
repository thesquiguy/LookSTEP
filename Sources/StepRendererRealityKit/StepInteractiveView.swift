import AppKit
import CoreGraphics
@preconcurrency import Metal
@preconcurrency import MetalKit
@preconcurrency import QuartzCore
import OSLog
import RealityKit
import SwiftUI

struct StepInteractiveView: NSViewRepresentable {
    let model: StepMeshData
    var fitRequest = 0
    var onFailure: ((String) -> Void)?

    func makeNSView(context: Context) -> StepMetalView {
        let view = StepMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.onFailure = onFailure
        view.load(model)
        return view
    }

    func updateNSView(_ view: StepMetalView, context: Context) {
        view.onFailure = onFailure
        if context.coordinator.lastFitRequest != fitRequest {
            context.coordinator.lastFitRequest = fitRequest
            view.fit()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(fitRequest: fitRequest) }

    final class Coordinator {
        var lastFitRequest: Int
        init(fitRequest: Int) { self.lastFitRequest = fitRequest }
    }
}

@MainActor
final class StepMetalView: MTKView, MTKViewDelegate {
    private struct PreparedDefinition {
        let resource: MeshResource
        let explicitLinearColors: [SIMD4<Float>]
    }

    private static let lifecycleLog = Logger(
        subsystem: "com.local.stepviewer.StepLook",
        category: "RendererLifecycle"
    )

    var onFailure: ((String) -> Void)?

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
    private var rendererLoadStart = ProcessInfo.processInfo.systemUptime
    private var didLogFirstFrame = false

    override init(frame frameRect: NSRect, device: (any MTLDevice)? = nil) {
        realityRenderer = try? RealityRenderer()
        let selectedDevice = device ?? MTLCreateSystemDefaultDevice()
        super.init(frame: frameRect, device: selectedDevice)
        self.device = selectedDevice
        colorPixelFormat = .bgra8Unorm_srgb
        framebufferOnly = false
        preferredFramesPerSecond = 60
        enableSetNeedsDisplay = false
        isPaused = true
        clearColor = MTLClearColorMake(1, 1, 1, 1)
        delegate = self

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
            var settings = realityRenderer.cameraSettings
            settings.colorBackground = .color(CGColor(gray: 1, alpha: 1))
            settings.antialiasing = .multisample4X
            realityRenderer.cameraSettings = settings
        }
        updateCamera()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit { loadTask?.cancel() }

    func load(_ model: StepMeshData) {
        loadTask?.cancel()
        rendererLoadStart = ProcessInfo.processInfo.systemUptime
        didLogFirstFrame = false
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard realityRenderer != nil, device != nil else {
                reportFailure("The 3D preview couldn’t start on this Mac.")
                return
            }
            do {
                var resources: [PreparedDefinition] = []
                resources.reserveCapacity(model.definitions.count)
                for (index, definition) in model.definitions.enumerated() {
                    try Task.checkCancellation()
                    let materialLayout = try StepMaterialLayout.make(for: definition)
                    var descriptor = MeshDescriptor(name: "definition-\(index)")
                    descriptor.positions = MeshBuffers.Positions(definition.positions)
                    descriptor.normals = MeshBuffers.Normals(definition.normals)
                    descriptor.primitives = .triangles(definition.indices)
                    descriptor.materials = .perFace(materialLayout.perFaceMaterialIndices)
                    resources.append(PreparedDefinition(
                        resource: try await MeshResource(from: [descriptor]),
                        explicitLinearColors: materialLayout.explicitLinearColors
                    ))
                }

                sceneRoot.children.removeAll()
                let diagonal = max(model.diagonal, 1.0e-6)
                let inverseDiagonal = 1 / diagonal
                var normalization = matrix_identity_float4x4
                normalization.columns.0.x = inverseDiagonal
                normalization.columns.1.y = inverseDiagonal
                normalization.columns.2.z = inverseDiagonal
                normalization.columns.3 = SIMD4(-model.center * inverseDiagonal, 1)
                raycastModel = model
                modelNormalization = normalization
                normalizedBoundsMin = (model.boundsMin - model.center) * inverseDiagonal
                normalizedBoundsMax = (model.boundsMax - model.center) * inverseDiagonal
                let containsSourceColor = StepFallbackColorPolicy.containsSourceColor(model)
                for occurrence in model.occurrences {
                    let prepared = resources[occurrence.definitionIndex]
                    let baseColor = StepFallbackColorPolicy.baseLinearColor(
                        for: occurrence,
                        in: model,
                        containsSourceColor: containsSourceColor
                    )
                    var materials = [StepCADAppearance.material(linearRGBA: baseColor)]
                    materials.append(contentsOf: prepared.explicitLinearColors.map {
                        StepCADAppearance.material(linearRGBA: $0)
                    })
                    guard prepared.resource.expectedMaterialCount == materials.count else {
                        throw StepMaterialLayoutError.invalidGroups
                    }
                    let entity = ModelEntity(mesh: prepared.resource, materials: materials)
                    entity.transform.matrix = normalization * occurrence.transform
                    sceneRoot.addChild(entity)
                }
                hasLoadedModel = true
                fit()
            } catch is CancellationError {
                return
            } catch {
                sceneRoot.children.removeAll()
                reportFailure("The model’s geometry couldn’t be displayed.")
            }
        }
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
    }

    func draw(in view: MTKView) {
        guard let realityRenderer, let drawable = currentDrawable else { return }
        do {
            let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: drawable.texture))
            let now = CACurrentMediaTime()
            let delta = min(now - lastFrameTime, 1.0 / 15.0)
            lastFrameTime = now
            try realityRenderer.updateAndRender(
                deltaTime: delta,
                cameraOutput: output,
                whenScheduled: { _ in drawable.present() }
            )
            if !didLogFirstFrame {
                didLogFirstFrame = true
                let seconds = ProcessInfo.processInfo.systemUptime - rendererLoadStart
                Self.lifecycleLog.info("first_frame seconds=\(seconds, format: .fixed(precision: 3))")
            }
        } catch {
            isPaused = true
            reportFailure("The 3D preview stopped rendering. Try opening the file again.")
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard hasLoadedModel, size.width > 1, size.height > 1,
              needsInitialFit || isAutoFitted else { return }
        fit(aspectRatio: Float(size.width / size.height))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isPaused = window == nil
    }

    override func mouseDown(with event: NSEvent) {
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
        let anchor = pointOnViewPlane(at: point, scale: cameraScale, basis: basis)
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
        let anchor = pointOnViewPlane(at: point, scale: cameraScale, basis: basis)
        cameraScale = min(20, max(0.025, cameraScale * exp(-Float(event.magnification))))
        viewCenter = anchoredViewCenter(anchor: anchor, screenPoint: point, scale: cameraScale, basis: basis)
        updateCamera()
    }

    override func mouseUp(with event: NSEvent) {
        orbitAnchor = nil
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
        guard let model = raycastModel else { return nil }
        var minimumRight = Float.infinity
        var maximumRight = -Float.infinity
        var minimumUp = Float.infinity
        var maximumUp = -Float.infinity
        var minimumOutward = Float.infinity
        var maximumOutward = -Float.infinity

        for occurrence in model.occurrences {
            let transform = modelNormalization * occurrence.transform
            for position in model.definitions[occurrence.definitionIndex].positions {
                let world4 = transform * SIMD4(position, 1)
                let world = SIMD3(world4.x, world4.y, world4.z)
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
        let basis = StepCameraMath.basis(yaw: yaw, pitch: pitch)
        let planePoint = pointOnViewPlane(at: point, scale: cameraScale, basis: basis)
        let rayOrigin = planePoint + basis.outward * 4
        let rayDirection = -basis.outward
        return raycast(origin: rayOrigin, direction: rayDirection)
    }

    private func raycast(origin: SIMD3<Float>, direction: SIMD3<Float>) -> SIMD3<Float>? {
        guard let model = raycastModel else { return nil }
        var closestDistance = Float.infinity
        var closestPoint: SIMD3<Float>?

        for occurrence in model.occurrences {
            let definition = model.definitions[occurrence.definitionIndex]
            let transform = modelNormalization * occurrence.transform
            let inverseTransform = simd_inverse(transform)
            let localOrigin4 = inverseTransform * SIMD4(origin, 1)
            let localDirection4 = inverseTransform * SIMD4(direction, 0)
            let localOrigin = SIMD3(localOrigin4.x, localOrigin4.y, localOrigin4.z)
            let localDirection = simd_normalize(SIMD3(
                localDirection4.x, localDirection4.y, localDirection4.z
            ))
            guard rayIntersectsBounds(
                origin: localOrigin,
                direction: localDirection,
                minimum: definition.boundsMin,
                maximum: definition.boundsMax
            ) else { continue }

            let indices = definition.indices
            let positions = definition.positions
            for index in stride(from: 0, to: indices.count, by: 3) {
                let first = positions[Int(indices[index])]
                let second = positions[Int(indices[index + 1])]
                let third = positions[Int(indices[index + 2])]
                guard let localHit = rayTriangleIntersection(
                    origin: localOrigin,
                    direction: localDirection,
                    first: first,
                    second: second,
                    third: third
                ) else { continue }
                let worldHit4 = transform * SIMD4(localHit, 1)
                let worldHit = SIMD3(worldHit4.x, worldHit4.y, worldHit4.z)
                let distance = simd_dot(worldHit - origin, direction)
                if distance >= 0, distance < closestDistance {
                    closestDistance = distance
                    closestPoint = worldHit
                }
            }
        }
        return closestPoint
    }

    private func rayIntersectsBounds(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        minimum: SIMD3<Float>,
        maximum: SIMD3<Float>
    ) -> Bool {
        var near = -Float.infinity
        var far = Float.infinity
        for axis in 0..<3 {
            if abs(direction[axis]) < 1.0e-7 {
                if origin[axis] < minimum[axis] || origin[axis] > maximum[axis] { return false }
                continue
            }
            let first = (minimum[axis] - origin[axis]) / direction[axis]
            let second = (maximum[axis] - origin[axis]) / direction[axis]
            near = max(near, min(first, second))
            far = min(far, max(first, second))
            if near > far { return false }
        }
        return far >= 0
    }

    private func rayTriangleIntersection(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        first: SIMD3<Float>,
        second: SIMD3<Float>,
        third: SIMD3<Float>
    ) -> SIMD3<Float>? {
        let edge1 = second - first
        let edge2 = third - first
        let cross = simd_cross(direction, edge2)
        let determinant = simd_dot(edge1, cross)
        guard abs(determinant) > 1.0e-7 else { return nil }
        let inverseDeterminant = 1 / determinant
        let fromFirst = origin - first
        let u = simd_dot(fromFirst, cross) * inverseDeterminant
        guard u >= 0, u <= 1 else { return nil }
        let secondCross = simd_cross(fromFirst, edge1)
        let v = simd_dot(direction, secondCross) * inverseDeterminant
        guard v >= 0, u + v <= 1 else { return nil }
        let distance = simd_dot(edge2, secondCross) * inverseDeterminant
        guard distance >= 0 else { return nil }
        return origin + direction * distance
    }

    private func reportFailure(_ message: String) {
        guard !didReportRenderFailure else { return }
        didReportRenderFailure = true
        onFailure?(message)
    }
}
