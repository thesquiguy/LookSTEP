import AppKit
import RealityKit

nonisolated enum StepColorSpace {
    static func linearToSRGB(_ component: Float) -> Float {
        let value = min(1, max(0, component))
        if value <= 0.003_130_8 { return value * 12.92 }
        return 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    static func displayRGBA(fromLinear rgba: SIMD4<Float>) -> SIMD4<Float> {
        var display = SIMD4(
            linearToSRGB(rgba.x),
            linearToSRGB(rgba.y),
            linearToSRGB(rgba.z),
            min(1, max(0.15, rgba.w))
        )
        // Preserve the source hue while lifting near-black CAD paint enough to
        // retain form against a dark macOS viewport. The cached source color
        // remains exact; this is a display-only accessibility adaptation.
        let luminance = 0.2126 * display.x + 0.7152 * display.y + 0.0722 * display.z
        let minimumLuminance: Float = 0.12
        if luminance < minimumLuminance {
            let lift = minimumLuminance - luminance
            display.x = min(1, display.x + lift)
            display.y = min(1, display.y + lift)
            display.z = min(1, display.z + lift)
        }
        return display
    }
}

nonisolated enum StepFallbackColorPolicy {
    // D-018: missing source color never implies material or grouping semantics.
    static let neutralLinearRGBA = SIMD4<Float>(0.423_268, 0.456_411, 0.496_933, 1)

    static func baseLinearColor(for occurrence: StepMeshOccurrence) -> SIMD4<Float> {
        occurrence.color ?? neutralLinearRGBA
    }
}

nonisolated struct StepMaterialLayout: Sendable {
    let perFaceMaterialIndices: [UInt32]
    let explicitLinearColors: [SIMD4<Float>]

    static func make(
        for definition: StepMeshDefinition,
        maximumMaterials: Int = 4_096,
        isCancelled: () -> Bool = { false }
    ) throws -> StepMaterialLayout {
        var explicitColors: [SIMD4<Float>] = []
        var colorSlots: [LinearColorKey: UInt32] = [:]
        var perFace: [UInt32] = []
        perFace.reserveCapacity(definition.indices.count / 3)

        for (index, group) in definition.materialGroups.enumerated() {
            if index.isMultiple(of: 4_096), isCancelled() {
                throw CancellationError()
            }
            let slot: UInt32
            if let color = group.linearColor {
                let key = LinearColorKey(color)
                if let existing = colorSlots[key] {
                    slot = existing
                } else {
                    guard explicitColors.count + 1 < maximumMaterials else {
                        throw StepMaterialLayoutError.tooManyMaterials
                    }
                    explicitColors.append(color)
                    slot = UInt32(explicitColors.count)
                    colorSlots[key] = slot
                }
            } else {
                slot = 0
            }
            perFace.append(contentsOf: repeatElement(slot, count: group.indexCount / 3))
        }

        guard perFace.count == definition.indices.count / 3 else {
            throw StepMaterialLayoutError.invalidGroups
        }
        return StepMaterialLayout(
            perFaceMaterialIndices: perFace,
            explicitLinearColors: explicitColors
        )
    }
}

nonisolated enum StepMaterialLayoutError: Error {
    case invalidGroups
    case tooManyMaterials
}

nonisolated private struct LinearColorKey: Hashable, Sendable {
    let red: UInt32
    let green: UInt32
    let blue: UInt32
    let alpha: UInt32

    init(_ color: SIMD4<Float>) {
        red = color.x.bitPattern
        green = color.y.bitPattern
        blue = color.z.bitPattern
        alpha = color.w.bitPattern
    }
}

@MainActor
enum StepCADAppearance {
    static func material(linearRGBA: SIMD4<Float>?) -> SimpleMaterial {
        let display = StepColorSpace.displayRGBA(
            fromLinear: linearRGBA ?? StepFallbackColorPolicy.neutralLinearRGBA
        )
        let color = NSColor(
            srgbRed: CGFloat(display.x),
            green: CGFloat(display.y),
            blue: CGFloat(display.z),
            alpha: CGFloat(display.w)
        )
        var material = SimpleMaterial(color: color, roughness: 0.82, isMetallic: false)
        material.faceCulling = .none
        return material
    }

    static func addCameraRelativeLights(to camera: Entity) {
        let headlight = DirectionalLight()
        headlight.light.intensity = 2_400
        headlight.look(
            at: SIMD3<Float>(0, 0, -1),
            from: SIMD3<Float>(0, 0, 4),
            relativeTo: camera
        )
        camera.addChild(headlight)

        let key = DirectionalLight()
        key.light.intensity = 900
        key.look(
            at: SIMD3<Float>(0, 0, -1),
            from: SIMD3<Float>(-2.5, 3.5, 4),
            relativeTo: camera
        )
        camera.addChild(key)

        let fill = DirectionalLight()
        fill.light.intensity = 700
        fill.look(
            at: SIMD3<Float>(0, 0, -1),
            from: SIMD3<Float>(3.5, 1, 2),
            relativeTo: camera
        )
        camera.addChild(fill)

        let rearFill = DirectionalLight()
        rearFill.light.intensity = 900
        rearFill.look(
            at: SIMD3<Float>(0, 0, 1),
            from: SIMD3<Float>(-1, 2.5, -4),
            relativeTo: camera
        )
        camera.addChild(rearFill)
    }
}
