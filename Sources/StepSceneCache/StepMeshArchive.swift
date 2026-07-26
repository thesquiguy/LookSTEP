import Foundation
import simd

nonisolated enum StepMeshArchiveError: LocalizedError {
    case invalidHeader
    case unsupportedVersion(UInt32)
    case unsupportedColorEncoding(UInt32)
    case invalidCounts
    case declaredPayloadExceedsArchive
    case truncated
    case invalidIndex

    var errorDescription: String? {
        switch self {
        case .invalidHeader: "The cached preview is not a LookSTEP mesh."
        case .unsupportedVersion, .unsupportedColorEncoding:
            "The cached preview was created by an incompatible version of LookSTEP."
        case .invalidCounts, .declaredPayloadExceedsArchive, .truncated, .invalidIndex:
            "The cached preview is damaged and will be rebuilt."
        }
    }
}

nonisolated enum StepColorEncoding: UInt32, Sendable {
    // OCCT Quantity_Color components are linear RGB values in the sRGB color space.
    case linearSRGB = 1
}

nonisolated struct StepMeshMaterialGroup: Sendable {
    let indexOffset: Int
    let indexCount: Int
    // Non-nil is an explicit face override. Nil resolves through occurrence/part, then neutral.
    let linearColor: SIMD4<Float>?

    func resolvedLinearColor(
        occurrenceColor: SIMD4<Float>?,
        neutralFallback: SIMD4<Float>
    ) -> SIMD4<Float> {
        linearColor ?? occurrenceColor ?? neutralFallback
    }
}

nonisolated struct StepMeshDefinition: Sendable {
    let stableID: String
    let name: String?
    let positions: [SIMD3<Float>]
    let normals: [SIMD3<Float>]
    let indices: [UInt32]
    let materialGroups: [StepMeshMaterialGroup]
    let boundsMin: SIMD3<Float>
    let boundsMax: SIMD3<Float>

    init(
        positions: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        indices: [UInt32],
        materialGroups: [StepMeshMaterialGroup],
        boundsMin: SIMD3<Float>,
        boundsMax: SIMD3<Float>,
        stableID: String = "",
        name: String? = nil
    ) {
        self.stableID = stableID
        self.name = name
        self.positions = positions
        self.normals = normals
        self.indices = indices
        self.materialGroups = materialGroups
        self.boundsMin = boundsMin
        self.boundsMax = boundsMax
    }
}

nonisolated struct StepMeshOccurrence: Sendable {
    let nodeIndex: Int
    let definitionIndex: Int
    let transform: simd_float4x4
    let color: SIMD4<Float>?

    init(
        definitionIndex: Int,
        transform: simd_float4x4,
        color: SIMD4<Float>?,
        nodeIndex: Int = 0
    ) {
        self.nodeIndex = nodeIndex
        self.definitionIndex = definitionIndex
        self.transform = transform
        self.color = color
    }
}

nonisolated struct StepMeshHierarchyNode: Sendable {
    let stableID: String
    let name: String?
    let parentIndex: Int?
    let definitionIndex: Int?
    let isAssembly: Bool
    let localTransform: simd_float4x4
}

nonisolated struct StepMeshData: Sendable {
    let colorEncoding: StepColorEncoding
    let definitions: [StepMeshDefinition]
    let occurrences: [StepMeshOccurrence]
    let hierarchy: [StepMeshHierarchyNode]
    let boundsMin: SIMD3<Float>
    let boundsMax: SIMD3<Float>
    let triangleCount: Int
    let faceCount: Int
    let missingFaceCount: Int
    let parseSeconds: Double
    let meshSeconds: Double
    let unitScaleToMeters: Double
    let hasExplicitLengthUnit: Bool
    /// The importer had to coarsen tessellation to fit the preview budget, so
    /// this geometry is deliberately less accurate than the source.
    var isSimplified: Bool = false

    var center: SIMD3<Float> { (boundsMin + boundsMax) * 0.5 }
    var diagonal: Float { simd_length(boundsMax - boundsMin) }
    var isIncomplete: Bool { missingFaceCount > 0 }
    var incompleteGeometryNotice: StepIncompleteGeometryNotice? {
        StepIncompleteGeometryNotice(missingFaceCount: missingFaceCount)
    }
    func simplifiedPreviewNotice(
        caliperInstalled: Bool = false
    ) -> StepSimplifiedPreviewNotice? {
        isSimplified
            ? StepSimplifiedPreviewNotice(caliperInstalled: caliperInstalled)
            : nil
    }
}

/// The persistent marker on a preview whose mesh was coarsened to fit the
/// budget. It stays visible for the life of the preview: a reduced-quality mesh
/// must never be mistaken for exact geometry.
nonisolated struct StepSimplifiedPreviewNotice: Equatable, Sendable {
    static let base = "This model was too detailed for a Finder preview, so it was reduced."

    let summary = "Simplified preview"
    let detail: String
    let offersCaliper: Bool

    /// `caliperInstalled` decides whether the badge may point at Caliper; the
    /// badge is otherwise identical, so an uninstalled Caliper simply removes
    /// the suggestion instead of leaving a dead end.
    init(caliperInstalled: Bool = false) {
        let advice = StepPreviewAdvice.make(
            base: Self.base,
            caliperClause: "Open it in Caliper for exact geometry.",
            fallbackClause: nil,
            caliperInstalled: caliperInstalled
        )
        detail = advice.message
        offersCaliper = advice.offersCaliper
    }

    var accessibilityLabel: String { "\(summary). \(detail)" }
}

nonisolated struct StepIncompleteGeometryNotice: Equatable, Sendable {
    let summary: String
    let detail: String
    let accessibilityLabel: String

    init?(missingFaceCount: Int) {
        guard missingFaceCount > 0 else { return nil }
        summary = missingFaceCount == 1
            ? "1 face couldn’t be shown"
            : "\(missingFaceCount.formatted()) faces couldn’t be shown"
        detail = "This preview is incomplete because some source faces did not produce geometry."
        accessibilityLabel = "\(summary). \(detail)"
    }
}

nonisolated enum StepMeshArchive {
    static let version: UInt32 = 4
    // v9 adds the simplified-tessellation header flag. Bumping this parts new
    // entries from old ones in the cache, so a build that predates the flag
    // never has to decode an archive it would reject.
    static let importerCompatibility = "step-importer-v9-graceful-degradation-bounded-occt-7.9.3"

    /// Header flag bits, mirroring the writer in `StepMeshImporter.mm`.
    enum Flag {
        static let incompleteGeometry: UInt32 = 1
        static let explicitLengthUnit: UInt32 = 2
        /// The mesh was retried at a coarser tessellation to fit the budget.
        static let simplified: UInt32 = 4
        static let all: UInt32 = incompleteGeometry | explicitLengthUnit | simplified
    }

    private static let headerSize = 88
    private static let maximumDefinitions = 20_000
    private static let maximumOccurrences = 200_000
    private static let maximumHierarchyNodes = 250_000
    private static let maximumMetadataStringBytes = 64 * 1_024
    private static let maximumVerticesPerDefinition = 4_500_000
    private static let maximumIndicesPerDefinition = 5_000_000
    private static let maximumMaterialGroupsPerDefinition = 1_666_666
    private static let maximumTotalVertices = 5_000_000
    private static let maximumTotalIndices = 5_000_000
    private static let maximumTotalMaterialGroups = 1_666_666
    private static let minimumDefinitionRecordBytes = MemoryLayout<UInt32>.size * 11
    private static let occurrenceRecordBytes = MemoryLayout<UInt32>.size * 19
    private static let minimumHierarchyRecordBytes = MemoryLayout<UInt32>.size * 17

    static func decode(_ data: Data) throws -> StepMeshData {
        guard data.count >= headerSize else { throw StepMeshArchiveError.truncated }
        guard data.prefix(4) == Data([0x53, 0x54, 0x4c, 0x4b]) else { throw StepMeshArchiveError.invalidHeader }

        var reader = ArchiveReader(data: data, offset: 4)
        let archiveVersion = try reader.readUInt32()
        guard archiveVersion == version else { throw StepMeshArchiveError.unsupportedVersion(archiveVersion) }
        let flags = try reader.readUInt32()
        guard flags & ~Flag.all == 0 else { throw StepMeshArchiveError.invalidCounts }
        let definitionCount = Int(try reader.readUInt32())
        let occurrenceCount = Int(try reader.readUInt32())
        let hierarchyNodeCount = Int(try reader.readUInt32())
        let triangleCount = Int(try reader.readUInt32())
        let faceCount = Int(try reader.readUInt32())
        let missingFaceCount = Int(try reader.readUInt32())
        let colorEncodingValue = try reader.readUInt32()
        guard let colorEncoding = StepColorEncoding(rawValue: colorEncodingValue) else {
            throw StepMeshArchiveError.unsupportedColorEncoding(colorEncodingValue)
        }
        guard (1...maximumDefinitions).contains(definitionCount),
              (1...maximumOccurrences).contains(occurrenceCount),
              (occurrenceCount...maximumHierarchyNodes).contains(hierarchyNodeCount),
              triangleCount > 0, faceCount > 0, missingFaceCount <= faceCount else {
            throw StepMeshArchiveError.invalidCounts
        }

        let boundsMin = try reader.readVector3()
        let boundsMax = try reader.readVector3()
        let parseSeconds = try reader.readDouble()
        let meshSeconds = try reader.readDouble()
        let unitScaleToMeters = try reader.readDouble()
        guard boundsMin.allFinite, boundsMax.allFinite,
              boundsMax.x >= boundsMin.x, boundsMax.y >= boundsMin.y, boundsMax.z >= boundsMin.z,
              parseSeconds.isFinite, parseSeconds >= 0,
              meshSeconds.isFinite, meshSeconds >= 0,
              unitScaleToMeters.isFinite, unitScaleToMeters > 0 else {
            throw StepMeshArchiveError.invalidCounts
        }

        try reader.requireRemaining([
            (count: definitionCount, stride: minimumDefinitionRecordBytes),
        ])
        var definitions: [StepMeshDefinition] = []
        definitions.reserveCapacity(definitionCount)
        var totalVertices = 0
        var totalIndices = 0
        var totalMaterialGroups = 0
        var definitionStableIDs: Set<String> = []
        for _ in 0..<definitionCount {
            let stableID = try reader.readString(maximumBytes: maximumMetadataStringBytes)
            let name = try reader.readString(maximumBytes: maximumMetadataStringBytes)
            guard !stableID.isEmpty, definitionStableIDs.insert(stableID).inserted else {
                throw StepMeshArchiveError.invalidCounts
            }
            let vertexCount = Int(try reader.readUInt32())
            let indexCount = Int(try reader.readUInt32())
            let materialGroupCount = Int(try reader.readUInt32())
            guard vertexCount > 0, vertexCount <= maximumVerticesPerDefinition,
                  indexCount > 0, indexCount <= maximumIndicesPerDefinition,
                  indexCount % 3 == 0,
                  materialGroupCount > 0,
                  materialGroupCount <= maximumMaterialGroupsPerDefinition,
                  materialGroupCount <= indexCount / 3,
                  totalVertices <= maximumTotalVertices - vertexCount,
                  totalIndices <= maximumTotalIndices - indexCount,
                  totalMaterialGroups <= maximumTotalMaterialGroups - materialGroupCount else {
                throw StepMeshArchiveError.invalidCounts
            }
            totalVertices += vertexCount
            totalIndices += indexCount
            totalMaterialGroups += materialGroupCount
            let definitionMin = try reader.readVector3()
            let definitionMax = try reader.readVector3()
            guard definitionMin.allFinite, definitionMax.allFinite,
                  definitionMax.x >= definitionMin.x,
                  definitionMax.y >= definitionMin.y,
                  definitionMax.z >= definitionMin.z else {
                throw StepMeshArchiveError.invalidCounts
            }
            let scalarBytes = MemoryLayout<UInt32>.size
            try reader.requireRemaining([
                (count: vertexCount, stride: scalarBytes * 6),
                (count: indexCount, stride: scalarBytes),
                (count: materialGroupCount, stride: scalarBytes * 7),
            ])
            var positions: [SIMD3<Float>] = []
            var normals: [SIMD3<Float>] = []
            positions.reserveCapacity(vertexCount)
            normals.reserveCapacity(vertexCount)
            for _ in 0..<vertexCount { positions.append(try reader.readVector3()) }
            for _ in 0..<vertexCount { normals.append(try reader.readVector3()) }
            guard positions.allSatisfy(\.allFinite), normals.allSatisfy(\.allFinite) else {
                throw StepMeshArchiveError.invalidCounts
            }
            var indices: [UInt32] = []
            indices.reserveCapacity(indexCount)
            for _ in 0..<indexCount {
                let index = try reader.readUInt32()
                guard index < UInt32(vertexCount) else { throw StepMeshArchiveError.invalidIndex }
                indices.append(index)
            }
            var materialGroups: [StepMeshMaterialGroup] = []
            materialGroups.reserveCapacity(materialGroupCount)
            var expectedIndexOffset = 0
            for _ in 0..<materialGroupCount {
                let indexOffset = Int(try reader.readUInt32())
                let groupIndexCount = Int(try reader.readUInt32())
                let hasColorValue = try reader.readUInt32()
                guard hasColorValue <= 1,
                      indexOffset == expectedIndexOffset,
                      groupIndexCount > 0,
                      groupIndexCount % 3 == 0,
                      groupIndexCount <= indexCount - indexOffset else {
                    throw StepMeshArchiveError.invalidCounts
                }
                let linearColor = try reader.readLinearColor()
                materialGroups.append(StepMeshMaterialGroup(
                    indexOffset: indexOffset,
                    indexCount: groupIndexCount,
                    linearColor: hasColorValue == 1 ? linearColor : nil
                ))
                expectedIndexOffset += groupIndexCount
            }
            guard expectedIndexOffset == indexCount else { throw StepMeshArchiveError.invalidCounts }
            definitions.append(StepMeshDefinition(
                positions: positions, normals: normals, indices: indices,
                materialGroups: materialGroups,
                boundsMin: definitionMin, boundsMax: definitionMax,
                stableID: stableID, name: name.isEmpty ? nil : name
            ))
        }

        try reader.requireRemaining([
            (count: occurrenceCount, stride: occurrenceRecordBytes),
        ])
        var occurrences: [StepMeshOccurrence] = []
        occurrences.reserveCapacity(occurrenceCount)
        var displayedTriangleCount: UInt64 = 0
        var occurrenceNodeIndices: Set<Int> = []
        for _ in 0..<occurrenceCount {
            let nodeIndex = Int(try reader.readUInt32())
            let definitionIndex = Int(try reader.readUInt32())
            let hasColorValue = try reader.readUInt32()
            guard hasColorValue <= 1 else { throw StepMeshArchiveError.invalidCounts }
            guard definitions.indices.contains(definitionIndex) else { throw StepMeshArchiveError.invalidIndex }
            guard (0..<hierarchyNodeCount).contains(nodeIndex),
                  occurrenceNodeIndices.insert(nodeIndex).inserted else {
                throw StepMeshArchiveError.invalidIndex
            }
            let row0 = SIMD4<Float>(try reader.readFloat(), try reader.readFloat(), try reader.readFloat(), try reader.readFloat())
            let row1 = SIMD4<Float>(try reader.readFloat(), try reader.readFloat(), try reader.readFloat(), try reader.readFloat())
            let row2 = SIMD4<Float>(try reader.readFloat(), try reader.readFloat(), try reader.readFloat(), try reader.readFloat())
            let rgba = try reader.readLinearColor()
            let transform = simd_float4x4(
                SIMD4(row0.x, row1.x, row2.x, 0),
                SIMD4(row0.y, row1.y, row2.y, 0),
                SIMD4(row0.z, row1.z, row2.z, 0),
                SIMD4(row0.w, row1.w, row2.w, 1)
            )
            guard transform.allFinite, rgba.allFinite else { throw StepMeshArchiveError.invalidCounts }
            occurrences.append(StepMeshOccurrence(
                definitionIndex: definitionIndex,
                transform: transform,
                color: hasColorValue == 1 ? rgba : nil,
                nodeIndex: nodeIndex
            ))
            displayedTriangleCount += UInt64(definitions[definitionIndex].indices.count / 3)
            guard displayedTriangleCount <= UInt64(UInt32.max) else {
                throw StepMeshArchiveError.invalidCounts
            }
        }

        try reader.requireRemaining([
            (count: hierarchyNodeCount, stride: minimumHierarchyRecordBytes),
        ])
        var hierarchy: [StepMeshHierarchyNode] = []
        hierarchy.reserveCapacity(hierarchyNodeCount)
        var hierarchyStableIDs: Set<String> = []
        var rootCount = 0
        for nodeIndex in 0..<hierarchyNodeCount {
            let stableID = try reader.readString(maximumBytes: maximumMetadataStringBytes)
            let name = try reader.readString(maximumBytes: maximumMetadataStringBytes)
            let rawParentIndex = try reader.readUInt32()
            let rawDefinitionIndex = try reader.readUInt32()
            let isAssemblyValue = try reader.readUInt32()
            guard !stableID.isEmpty, hierarchyStableIDs.insert(stableID).inserted,
                  isAssemblyValue <= 1 else {
                throw StepMeshArchiveError.invalidCounts
            }
            let parentIndex: Int?
            if rawParentIndex == UInt32.max {
                parentIndex = nil
                rootCount += 1
            } else {
                parentIndex = Int(rawParentIndex)
                guard parentIndex! < nodeIndex else { throw StepMeshArchiveError.invalidIndex }
            }
            let definitionIndex: Int?
            if rawDefinitionIndex == UInt32.max {
                definitionIndex = nil
            } else {
                definitionIndex = Int(rawDefinitionIndex)
                guard definitions.indices.contains(definitionIndex!) else {
                    throw StepMeshArchiveError.invalidIndex
                }
            }
            let row0 = SIMD4<Float>(try reader.readFloat(), try reader.readFloat(), try reader.readFloat(), try reader.readFloat())
            let row1 = SIMD4<Float>(try reader.readFloat(), try reader.readFloat(), try reader.readFloat(), try reader.readFloat())
            let row2 = SIMD4<Float>(try reader.readFloat(), try reader.readFloat(), try reader.readFloat(), try reader.readFloat())
            let localTransform = simd_float4x4(
                SIMD4(row0.x, row1.x, row2.x, 0),
                SIMD4(row0.y, row1.y, row2.y, 0),
                SIMD4(row0.z, row1.z, row2.z, 0),
                SIMD4(row0.w, row1.w, row2.w, 1)
            )
            guard localTransform.allFinite else { throw StepMeshArchiveError.invalidCounts }
            hierarchy.append(StepMeshHierarchyNode(
                stableID: stableID,
                name: name.isEmpty ? nil : name,
                parentIndex: parentIndex,
                definitionIndex: definitionIndex,
                isAssembly: isAssemblyValue == 1,
                localTransform: localTransform
            ))
        }
        guard rootCount > 0 else { throw StepMeshArchiveError.invalidCounts }
        for occurrence in occurrences {
            guard hierarchy[occurrence.nodeIndex].definitionIndex == occurrence.definitionIndex,
                  !hierarchy[occurrence.nodeIndex].isAssembly else {
                throw StepMeshArchiveError.invalidIndex
            }
        }
        guard displayedTriangleCount == UInt64(triangleCount),
              reader.offset == data.count else {
            throw StepMeshArchiveError.invalidCounts
        }

        return StepMeshData(
            colorEncoding: colorEncoding,
            definitions: definitions, occurrences: occurrences, hierarchy: hierarchy,
            boundsMin: boundsMin, boundsMax: boundsMax,
            triangleCount: triangleCount, faceCount: faceCount, missingFaceCount: missingFaceCount,
            parseSeconds: parseSeconds, meshSeconds: meshSeconds,
            unitScaleToMeters: unitScaleToMeters,
            hasExplicitLengthUnit: flags & Flag.explicitLengthUnit != 0,
            isSimplified: flags & Flag.simplified != 0
        )
    }
}

private nonisolated struct ArchiveReader {
    let data: Data
    var offset: Int

    func requireRemaining(_ components: [(count: Int, stride: Int)]) throws {
        var requiredBytes = 0
        for component in components {
            let (componentBytes, multiplicationOverflow) =
                component.count.multipliedReportingOverflow(by: component.stride)
            let (nextRequiredBytes, additionOverflow) =
                requiredBytes.addingReportingOverflow(componentBytes)
            guard component.count >= 0, component.stride >= 0,
                  !multiplicationOverflow, !additionOverflow else {
                throw StepMeshArchiveError.declaredPayloadExceedsArchive
            }
            requiredBytes = nextRequiredBytes
        }
        guard offset <= data.count, requiredBytes <= data.count - offset else {
            throw StepMeshArchiveError.declaredPayloadExceedsArchive
        }
    }

    mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else { throw StepMeshArchiveError.truncated }
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        offset += 4
        return UInt32(littleEndian: value)
    }

    mutating func readFloat() throws -> Float { Float(bitPattern: try readUInt32()) }

    mutating func readVector3() throws -> SIMD3<Float> {
        SIMD3(try readFloat(), try readFloat(), try readFloat())
    }

    mutating func readDouble() throws -> Double {
        guard offset + 8 <= data.count else { throw StepMeshArchiveError.truncated }
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
        offset += 8
        return Double(bitPattern: UInt64(littleEndian: value))
    }

    mutating func readString(maximumBytes: Int) throws -> String {
        let byteCount = Int(try readUInt32())
        guard byteCount <= maximumBytes, byteCount <= data.count - offset else {
            throw StepMeshArchiveError.truncated
        }
        let bytes = data[offset..<(offset + byteCount)]
        offset += byteCount
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw StepMeshArchiveError.invalidCounts
        }
        return value
    }

    mutating func readLinearColor() throws -> SIMD4<Float> {
        let color = SIMD4(try readFloat(), try readFloat(), try readFloat(), try readFloat())
        guard color.allFinite,
              (0...1).contains(color.x), (0...1).contains(color.y),
              (0...1).contains(color.z), (0...1).contains(color.w) else {
            throw StepMeshArchiveError.invalidCounts
        }
        return color
    }
}

private nonisolated extension SIMD3 where Scalar == Float {
    var allFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

private nonisolated extension SIMD4 where Scalar == Float {
    var allFinite: Bool { x.isFinite && y.isFinite && z.isFinite && w.isFinite }
}

private nonisolated extension simd_float4x4 {
    var allFinite: Bool { columns.0.allFinite && columns.1.allFinite && columns.2.allFinite && columns.3.allFinite }
}
