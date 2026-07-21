import AppKit
import CoreGraphics
@preconcurrency import Metal
import RealityKit

enum StepThumbnailRendererError: Error {
    case noMetalDevice
    case textureCreationFailed
    case imageCreationFailed
}

@MainActor
enum StepThumbnailRenderer {
    static func render(_ model: StepMeshData, pixelSize: CGSize) async throws -> CGImage {
        let width = min(2048, max(64, Int(pixelSize.width.rounded(.up))))
        let height = min(2048, max(64, Int(pixelSize.height.rounded(.up))))
        guard let device = MTLCreateSystemDefaultDevice() else { throw StepThumbnailRendererError.noMetalDevice }

        let root = Entity()
        var resources: [MeshResource] = []
        resources.reserveCapacity(model.definitions.count)
        for (index, definition) in model.definitions.enumerated() {
            var descriptor = MeshDescriptor(name: "thumbnail-definition-\(index)")
            descriptor.positions = MeshBuffers.Positions(definition.positions)
            descriptor.normals = MeshBuffers.Normals(definition.normals)
            descriptor.primitives = .triangles(definition.indices)
            resources.append(try await MeshResource(from: [descriptor]))
        }
        let diagonal = max(model.diagonal, 1.0e-6)
        let inverseDiagonal = 1 / diagonal
        var normalization = matrix_identity_float4x4
        normalization.columns.0.x = inverseDiagonal
        normalization.columns.1.y = inverseDiagonal
        normalization.columns.2.z = inverseDiagonal
        normalization.columns.3 = SIMD4(-model.center * inverseDiagonal, 1)
        for occurrence in model.occurrences {
            let rgba = occurrence.color ?? SIMD4<Float>(0.70, 0.72, 0.75, 1)
            var material = SimpleMaterial(
                color: NSColor(calibratedRed: CGFloat(rgba.x), green: CGFloat(rgba.y),
                               blue: CGFloat(rgba.z), alpha: CGFloat(max(0.15, rgba.w))),
                roughness: 0.72,
                isMetallic: false
            )
            material.faceCulling = .none
            let entity = ModelEntity(mesh: resources[occurrence.definitionIndex], materials: [material])
            entity.transform.matrix = normalization * occurrence.transform
            root.addChild(entity)
        }

        let camera = Entity()
        var projection = OrthographicCameraComponent()
        projection.near = 0.01
        projection.far = 100
        projection.scale = 1.08 * max(1, Float(height) / Float(width))
        projection.scaleDirection = .vertical
        camera.components.set(projection)
        camera.look(at: .zero, from: SIMD3<Float>(2.6, 2.1, 3.0), relativeTo: nil)

        let key = DirectionalLight()
        key.light.intensity = 2_200
        key.look(at: .zero, from: SIMD3<Float>(3, 4, 5), relativeTo: nil)
        let fill = DirectionalLight()
        fill.light.intensity = 650
        fill.look(at: .zero, from: SIMD3<Float>(-4, 1, 2), relativeTo: nil)

        let renderer = try RealityRenderer()
        renderer.entities.append(root)
        renderer.entities.append(camera)
        renderer.entities.append(key)
        renderer.entities.append(fill)
        renderer.activeCamera = camera
        var settings = renderer.cameraSettings
        settings.colorBackground = .color(CGColor(gray: 1, alpha: 1))
        settings.antialiasing = .multisample4X
        renderer.cameraSettings = settings

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw StepThumbnailRendererError.textureCreationFailed
        }
        let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try renderer.updateAndRender(deltaTime: 0, cameraOutput: output, onComplete: { _ in
                    continuation.resume()
                })
            } catch {
                continuation.resume(throwing: error)
            }
        }

        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                texture.getBytes(baseAddress, bytesPerRow: bytesPerRow,
                                 from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                    .union(.byteOrder32Little),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else { throw StepThumbnailRendererError.imageCreationFailed }
        return image
    }
}
