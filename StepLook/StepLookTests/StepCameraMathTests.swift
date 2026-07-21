import simd
import Testing
@testable import LookSTEP

struct StepCameraMathTests {
    @Test func linearColorsConvertToDisplaySRGB() {
        #expect(abs(StepColorSpace.linearToSRGB(0) - 0) < 0.0001)
        #expect(abs(StepColorSpace.linearToSRGB(0.003_130_8) - 0.04045) < 0.0001)
        #expect(abs(StepColorSpace.linearToSRGB(0.5) - 0.735_357) < 0.0001)
        #expect(abs(StepColorSpace.linearToSRGB(1) - 1) < 0.0001)
    }

    @Test func materialLayoutUsesOccurrenceFallbackAndDeduplicatesFaceColors() throws {
        let blue = SIMD4<Float>(0.1, 0.2, 0.8, 1)
        let definition = StepMeshDefinition(
            positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            normals: [SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1)],
            indices: [0, 1, 2, 0, 1, 2, 0, 1, 2],
            materialGroups: [
                StepMeshMaterialGroup(indexOffset: 0, indexCount: 3, linearColor: nil),
                StepMeshMaterialGroup(indexOffset: 3, indexCount: 3, linearColor: blue),
                StepMeshMaterialGroup(indexOffset: 6, indexCount: 3, linearColor: blue),
            ],
            boundsMin: SIMD3(0, 0, 0),
            boundsMax: SIMD3(1, 1, 0)
        )

        let layout = try StepMaterialLayout.make(for: definition)
        #expect(layout.perFaceMaterialIndices == [0, 1, 1])
        #expect(layout.explicitLinearColors == [blue])
    }

    @Test func uncoloredPartPaletteDoesNotCompeteWithSourceColors() {
        let definition = StepMeshDefinition(
            positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            normals: [SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1)],
            indices: [0, 1, 2],
            materialGroups: [StepMeshMaterialGroup(indexOffset: 0, indexCount: 3, linearColor: nil)],
            boundsMin: SIMD3(0, 0, 0),
            boundsMax: SIMD3(1, 1, 0)
        )
        let first = StepMeshOccurrence(definitionIndex: 0, transform: matrix_identity_float4x4, color: nil)
        let second = StepMeshOccurrence(definitionIndex: 1, transform: matrix_identity_float4x4, color: nil)
        let uncolored = StepMeshData(
            colorEncoding: .linearSRGB,
            definitions: [definition, definition],
            occurrences: [first, second],
            boundsMin: .zero,
            boundsMax: SIMD3(1, 1, 0),
            triangleCount: 2,
            faceCount: 2,
            missingFaceCount: 0,
            parseSeconds: 0,
            meshSeconds: 0
        )

        #expect(!StepFallbackColorPolicy.containsSourceColor(uncolored))
        #expect(StepFallbackColorPolicy.baseLinearColor(
            for: first, in: uncolored, containsSourceColor: false
        ) == StepFallbackColorPolicy.neutralLinearRGBA)
        #expect(StepFallbackColorPolicy.baseLinearColor(
            for: second, in: uncolored, containsSourceColor: false
        ) == StepFallbackColorPolicy.uncoloredPartPalette[1])

        let sourceBlue = SIMD4<Float>(0.1, 0.2, 0.8, 1)
        let coloredOccurrence = StepMeshOccurrence(
            definitionIndex: 0,
            transform: matrix_identity_float4x4,
            color: sourceBlue
        )
        let partlyColored = StepMeshData(
            colorEncoding: .linearSRGB,
            definitions: [definition, definition],
            occurrences: [coloredOccurrence, second],
            boundsMin: .zero,
            boundsMax: SIMD3(1, 1, 0),
            triangleCount: 2,
            faceCount: 2,
            missingFaceCount: 0,
            parseSeconds: 0,
            meshSeconds: 0
        )

        #expect(StepFallbackColorPolicy.containsSourceColor(partlyColored))
        #expect(StepFallbackColorPolicy.baseLinearColor(
            for: coloredOccurrence, in: partlyColored, containsSourceColor: true
        ) == sourceBlue)
        #expect(StepFallbackColorPolicy.baseLinearColor(
            for: second, in: partlyColored, containsSourceColor: true
        ) == StepFallbackColorPolicy.neutralLinearRGBA)
    }

    @Test func basisIsOrthonormal() {
        let basis = StepCameraMath.basis(yaw: .pi / 4, pitch: .pi / 7)

        #expect(abs(simd_length(basis.outward) - 1) < 0.0001)
        #expect(abs(simd_length(basis.right) - 1) < 0.0001)
        #expect(abs(simd_length(basis.up) - 1) < 0.0001)
        #expect(abs(simd_dot(basis.outward, basis.right)) < 0.0001)
        #expect(abs(simd_dot(basis.outward, basis.up)) < 0.0001)
    }

    @Test func fitScaleRespectsProjectedBoundsAndOccupancy() {
        let basis = StepCameraBasis(
            outward: SIMD3(0, 0, 1),
            right: SIMD3(1, 0, 0),
            up: SIMD3(0, 1, 0)
        )

        let wideScale = StepCameraMath.fitScale(
            boundsMin: SIMD3(-1, -0.25, -0.1),
            boundsMax: SIMD3(1, 0.25, 0.1),
            basis: basis,
            aspectRatio: 2,
            occupancy: 0.93
        )
        let tallScale = StepCameraMath.fitScale(
            boundsMin: SIMD3(-0.25, -1, -0.1),
            boundsMax: SIMD3(0.25, 1, 0.1),
            basis: basis,
            aspectRatio: 2,
            occupancy: 0.93
        )

        #expect(abs(wideScale - 0.5 / 0.93) < 0.0001)
        #expect(abs(tallScale - 1 / 0.93) < 0.0001)
    }

    @Test func fitScaleIsFiniteForDegenerateBounds() {
        let scale = StepCameraMath.fitScale(
            boundsMin: .zero,
            boundsMax: .zero,
            basis: StepCameraMath.basis(yaw: 0, pitch: .pi / 2 - 0.03),
            aspectRatio: 0
        )

        #expect(scale.isFinite)
        #expect(scale == 0.025)
    }

    @Test func changingScaleKeepsTheCursorAnchorFixed() {
        let basis = StepCameraBasis(
            outward: SIMD3(0, 0, 1),
            right: SIMD3(1, 0, 0),
            up: SIMD3(0, 1, 0)
        )
        let anchor = SIMD3<Float>(0.4, -0.2, 0.1)
        let center = StepCameraMath.viewCenterKeepingAnchor(
            anchor,
            xFromCenter: 120,
            yFromCenter: -80,
            viewportHeight: 600,
            scale: 0.35,
            basis: basis
        )
        let reconstructedAnchor = center + StepCameraMath.screenOffset(
            xFromCenter: 120,
            yFromCenter: -80,
            viewportHeight: 600,
            scale: 0.35,
            basis: basis
        )

        #expect(simd_distance(anchor, reconstructedAnchor) < 0.0001)
    }

    @Test func panMakesTheModelFollowThePointer() {
        let basis = StepCameraBasis(
            outward: SIMD3(0, 0, 1),
            right: SIMD3(1, 0, 0),
            up: SIMD3(0, 1, 0)
        )
        let center = StepCameraMath.pannedViewCenter(
            .zero,
            dx: 60,
            dy: -30,
            viewportHeight: 600,
            scale: 0.5,
            basis: basis
        )

        #expect(simd_distance(center, SIMD3(-0.1, 0.05, 0)) < 0.0001)
    }
}
