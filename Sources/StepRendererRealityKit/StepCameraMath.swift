import simd

struct StepCameraBasis {
    let outward: SIMD3<Float>
    let right: SIMD3<Float>
    let up: SIMD3<Float>
}

enum StepCameraMath {
    static func basis(yaw: Float, pitch: Float) -> StepCameraBasis {
        let outward = simd_normalize(SIMD3<Float>(
            cos(pitch) * sin(yaw),
            sin(pitch),
            cos(pitch) * cos(yaw)
        ))
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), outward))
        let up = simd_normalize(simd_cross(outward, right))
        return StepCameraBasis(outward: outward, right: right, up: up)
    }

    static func fitScale(
        boundsMin: SIMD3<Float>,
        boundsMax: SIMD3<Float>,
        basis: StepCameraBasis,
        aspectRatio: Float,
        occupancy: Float = 0.93
    ) -> Float {
        var minimumRight = Float.infinity
        var maximumRight = -Float.infinity
        var minimumUp = Float.infinity
        var maximumUp = -Float.infinity

        for x in [boundsMin.x, boundsMax.x] {
            for y in [boundsMin.y, boundsMax.y] {
                for z in [boundsMin.z, boundsMax.z] {
                    let corner = SIMD3<Float>(x, y, z)
                    let projectedRight = simd_dot(corner, basis.right)
                    let projectedUp = simd_dot(corner, basis.up)
                    minimumRight = min(minimumRight, projectedRight)
                    maximumRight = max(maximumRight, projectedRight)
                    minimumUp = min(minimumUp, projectedUp)
                    maximumUp = max(maximumUp, projectedUp)
                }
            }
        }

        let safeAspect = max(aspectRatio, 0.01)
        let safeOccupancy = min(0.99, max(occupancy, 0.5))
        let projectedWidth = max(0, maximumRight - minimumRight)
        let projectedHeight = max(0, maximumUp - minimumUp)
        return max(0.025, max(projectedHeight, projectedWidth / safeAspect) * 0.5 / safeOccupancy)
    }

    static func screenOffset(
        xFromCenter: Float,
        yFromCenter: Float,
        viewportHeight: Float,
        scale: Float,
        basis: StepCameraBasis
    ) -> SIMD3<Float> {
        let worldPerPoint = 2 * scale / max(1, viewportHeight)
        return basis.right * xFromCenter * worldPerPoint
            + basis.up * yFromCenter * worldPerPoint
    }

    static func viewCenterKeepingAnchor(
        _ anchor: SIMD3<Float>,
        xFromCenter: Float,
        yFromCenter: Float,
        viewportHeight: Float,
        scale: Float,
        basis: StepCameraBasis
    ) -> SIMD3<Float> {
        anchor - screenOffset(
            xFromCenter: xFromCenter,
            yFromCenter: yFromCenter,
            viewportHeight: viewportHeight,
            scale: scale,
            basis: basis
        )
    }

    static func pannedViewCenter(
        _ center: SIMD3<Float>,
        dx: Float,
        dy: Float,
        viewportHeight: Float,
        scale: Float,
        basis: StepCameraBasis
    ) -> SIMD3<Float> {
        center - screenOffset(
            xFromCenter: dx,
            yFromCenter: dy,
            viewportHeight: viewportHeight,
            scale: scale,
            basis: basis
        )
    }
}
