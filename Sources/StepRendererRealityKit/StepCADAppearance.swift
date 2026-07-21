import AppKit
import RealityKit

enum StepColorSpace {
    static func linearToSRGB(_ component: Float) -> Float {
        let value = min(1, max(0, component))
        if value <= 0.003_130_8 { return value * 12.92 }
        return 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    static func displayRGBA(fromLinear rgba: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4(
            linearToSRGB(rgba.x),
            linearToSRGB(rgba.y),
            linearToSRGB(rgba.z),
            min(1, max(0.15, rgba.w))
        )
    }
}

enum StepFallbackColorPolicy {
    // Neutral gray for a single uncolored part and for gaps in partially colored files.
    static let neutralLinearRGBA = SIMD4<Float>(0.423_268, 0.456_411, 0.496_933, 1)

    // A restrained CAD palette inspired by Onshape's deterministic eight-part rotation.
    // The neutral leads so a single definition and the first assembly definition agree.
    static let uncoloredPartPalette: [SIMD4<Float>] = [
        neutralLinearRGBA,
        SIMD4(0.254_152, 0.462_077, 0.623_960, 1),
        SIMD4(0.068_478, 0.147_027, 0.439_657, 1),
        SIMD4(0.651_406, 0.665_387, 0.686_685, 1),
        SIMD4(0.473_531, 0.658_375, 0.760_525, 1),
        SIMD4(0.887_923, 0.323_143, 0.020_289, 1),
        SIMD4(0.194_618, 0.215_861, 0.234_551, 1),
        SIMD4(0.723_055, 0.423_268, 0.014_444, 1),
    ]

    static func containsSourceColor(_ model: StepMeshData) -> Bool {
        model.occurrences.contains { $0.color != nil }
            || model.definitions.contains { definition in
                definition.materialGroups.contains { $0.linearColor != nil }
            }
    }

    static func baseLinearColor(
        for occurrence: StepMeshOccurrence,
        in model: StepMeshData,
        containsSourceColor: Bool
    ) -> SIMD4<Float> {
        if let sourceColor = occurrence.color { return sourceColor }
        guard !containsSourceColor, model.definitions.count > 1 else {
            return neutralLinearRGBA
        }
        return uncoloredPartPalette[occurrence.definitionIndex % uncoloredPartPalette.count]
    }
}

struct StepMaterialLayout {
    let perFaceMaterialIndices: [UInt32]
    let explicitLinearColors: [SIMD4<Float>]

    static func make(
        for definition: StepMeshDefinition,
        maximumMaterials: Int = 4_096
    ) throws -> StepMaterialLayout {
        var explicitColors: [SIMD4<Float>] = []
        var colorSlots: [LinearColorKey: UInt32] = [:]
        var perFace: [UInt32] = []
        perFace.reserveCapacity(definition.indices.count / 3)

        for group in definition.materialGroups {
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

enum StepMaterialLayoutError: Error {
    case invalidGroups
    case tooManyMaterials
}

private struct LinearColorKey: Hashable {
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
