import simd

struct StepCameraBasis {
    let outward: SIMD3<Float>
    let right: SIMD3<Float>
    let up: SIMD3<Float>
}

enum StepCameraMath {
    static let maximumOrbitTriangleTests = 1_000_000

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

    static func nearestModelIntersection(
        model: StepMeshData,
        normalization: simd_float4x4,
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        maximumTriangleTests: Int = maximumOrbitTriangleTests
    ) -> SIMD3<Float>? {
        guard maximumTriangleTests > 0 else { return nil }
        var closestDistance = Float.infinity
        var triangleTests = 0

        for occurrence in model.occurrences {
            guard model.definitions.indices.contains(occurrence.definitionIndex) else {
                continue
            }
            let definition = model.definitions[occurrence.definitionIndex]
            let inverseTransform = simd_inverse(normalization * occurrence.transform)
            let localOrigin4 = inverseTransform * SIMD4(origin, 1)
            let localDirection4 = inverseTransform * SIMD4(direction, 0)
            let localOrigin = SIMD3(
                localOrigin4.x,
                localOrigin4.y,
                localOrigin4.z
            )
            let localDirection = SIMD3(
                localDirection4.x,
                localDirection4.y,
                localDirection4.z
            )
            guard localOrigin.allFinite, localDirection.allFinite,
                  let boundsRange = rayBoundsIntersectionRange(
                      origin: localOrigin,
                      direction: localDirection,
                      minimum: definition.boundsMin,
                      maximum: definition.boundsMax
                  ),
                  boundsRange.near <= closestDistance else {
                continue
            }

            var index = 0
            while index + 2 < definition.indices.count {
                triangleTests += 1
                guard triangleTests <= maximumTriangleTests else { return nil }
                let first = Int(definition.indices[index])
                let second = Int(definition.indices[index + 1])
                let third = Int(definition.indices[index + 2])
                guard definition.positions.indices.contains(first),
                      definition.positions.indices.contains(second),
                      definition.positions.indices.contains(third) else {
                    index += 3
                    continue
                }
                if let distance = rayTriangleIntersectionDistance(
                    origin: localOrigin,
                    direction: localDirection,
                    first: definition.positions[first],
                    second: definition.positions[second],
                    third: definition.positions[third]
                ), distance < closestDistance {
                    closestDistance = distance
                }
                index += 3
            }
        }

        guard closestDistance.isFinite else { return nil }
        return origin + direction * closestDistance
    }

    static func rayBoundsIntersectionRange(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        minimum: SIMD3<Float>,
        maximum: SIMD3<Float>
    ) -> (near: Float, far: Float)? {
        var near = -Float.infinity
        var far = Float.infinity
        for axis in 0..<3 {
            if abs(direction[axis]) < 1.0e-7 {
                if origin[axis] < minimum[axis] || origin[axis] > maximum[axis] {
                    return nil
                }
                continue
            }
            let first = (minimum[axis] - origin[axis]) / direction[axis]
            let second = (maximum[axis] - origin[axis]) / direction[axis]
            near = max(near, min(first, second))
            far = min(far, max(first, second))
            if near > far { return nil }
        }
        guard far >= 0 else { return nil }
        return (max(0, near), far)
    }

    static func rayTriangleIntersectionDistance(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        first: SIMD3<Float>,
        second: SIMD3<Float>,
        third: SIMD3<Float>
    ) -> Float? {
        let firstEdge = second - first
        let secondEdge = third - first
        let cross = simd_cross(direction, secondEdge)
        let determinant = simd_dot(firstEdge, cross)
        guard abs(determinant) > 1.0e-7 else { return nil }

        let inverseDeterminant = 1 / determinant
        let originOffset = origin - first
        let firstCoordinate = simd_dot(originOffset, cross) * inverseDeterminant
        guard firstCoordinate >= 0, firstCoordinate <= 1 else { return nil }

        let originCross = simd_cross(originOffset, firstEdge)
        let secondCoordinate =
            simd_dot(direction, originCross) * inverseDeterminant
        guard secondCoordinate >= 0,
              firstCoordinate + secondCoordinate <= 1 else {
            return nil
        }

        let distance = simd_dot(secondEdge, originCross) * inverseDeterminant
        return distance >= 0 ? distance : nil
    }
}

private extension SIMD3 where Scalar == Float {
    var allFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}
