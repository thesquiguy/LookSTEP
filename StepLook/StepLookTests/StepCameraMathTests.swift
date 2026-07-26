import simd
import Testing
@testable import LookSTEP

struct StepCameraMathTests {
    @Test func linearColorsConvertToDisplaySRGB() {
        #expect(abs(StepColorSpace.linearToSRGB(0) - 0) < 0.0001)
        #expect(abs(StepColorSpace.linearToSRGB(0.003_130_8) - 0.04045) < 0.0001)
        #expect(abs(StepColorSpace.linearToSRGB(0.5) - 0.735_357) < 0.0001)
        #expect(abs(StepColorSpace.linearToSRGB(1) - 1) < 0.0001)
        let dark = StepColorSpace.displayRGBA(fromLinear: SIMD4(0, 0, 0, 1))
        #expect(dark.x >= 0.12 && dark.y >= 0.12 && dark.z >= 0.12)
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

    @Test func uncoloredOccurrencesAlwaysUseTheNeutralFallback() {
        let first = StepMeshOccurrence(definitionIndex: 0, transform: matrix_identity_float4x4, color: nil)
        let second = StepMeshOccurrence(definitionIndex: 1, transform: matrix_identity_float4x4, color: nil)
        #expect(StepFallbackColorPolicy.baseLinearColor(for: first)
            == StepFallbackColorPolicy.neutralLinearRGBA)
        #expect(StepFallbackColorPolicy.baseLinearColor(for: second)
            == StepFallbackColorPolicy.neutralLinearRGBA)

        let sourceBlue = SIMD4<Float>(0.1, 0.2, 0.8, 1)
        let coloredOccurrence = StepMeshOccurrence(
            definitionIndex: 0,
            transform: matrix_identity_float4x4,
            color: sourceBlue
        )
        #expect(StepFallbackColorPolicy.baseLinearColor(for: coloredOccurrence) == sourceBlue)
        #expect(StepFallbackColorPolicy.baseLinearColor(for: second)
            == StepFallbackColorPolicy.neutralLinearRGBA)
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

    @Test func orbitPivotUsesTheVisibleTriangleUnderAnOffCenterClick() throws {
        let definition = StepMeshDefinition(
            positions: [
                SIMD3(-1, -1, 0),
                SIMD3(1, -1, 0),
                SIMD3(0, 1, 0),
            ],
            normals: [
                SIMD3(0, 0, 1),
                SIMD3(0, 0, 1),
                SIMD3(0, 0, 1),
            ],
            indices: [0, 1, 2],
            materialGroups: [
                StepMeshMaterialGroup(
                    indexOffset: 0,
                    indexCount: 3,
                    linearColor: nil
                ),
            ],
            boundsMin: SIMD3(-1, -1, 0),
            boundsMax: SIMD3(1, 1, 0)
        )
        let model = StepMeshData(
            colorEncoding: .linearSRGB,
            definitions: [definition],
            occurrences: [
                StepMeshOccurrence(
                    definitionIndex: 0,
                    transform: matrix_identity_float4x4,
                    color: nil
                ),
            ],
            hierarchy: [],
            boundsMin: definition.boundsMin,
            boundsMax: definition.boundsMax,
            triangleCount: 1,
            faceCount: 1,
            missingFaceCount: 0,
            parseSeconds: 0,
            meshSeconds: 0,
            unitScaleToMeters: 1,
            hasExplicitLengthUnit: true
        )

        let hit = try #require(StepCameraMath.nearestModelIntersection(
            model: model,
            normalization: matrix_identity_float4x4,
            origin: SIMD3(0.35, 0.1, 2),
            direction: SIMD3(0, 0, -1)
        ))

        #expect(simd_distance(hit, SIMD3(0.35, 0.1, 0)) < 0.0001)
        #expect(StepCameraMath.nearestModelIntersection(
            model: model,
            normalization: matrix_identity_float4x4,
            origin: SIMD3(2, 2, 2),
            direction: SIMD3(0, 0, -1)
        ) == nil)
    }
}
