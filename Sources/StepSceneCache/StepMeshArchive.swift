import CryptoKit
import Foundation
import simd

nonisolated enum StepMeshArchiveError: LocalizedError {
    case invalidHeader
    case unsupportedVersion(UInt32)
    case unsupportedColorEncoding(UInt32)
    case invalidCounts
    case truncated
    case invalidIndex

    var errorDescription: String? {
        switch self {
        case .invalidHeader: "The cached preview is not a LookSTEP mesh."
        case .unsupportedVersion, .unsupportedColorEncoding:
            "The cached preview was created by an incompatible version of LookSTEP."
        case .invalidCounts, .truncated, .invalidIndex: "The cached preview is damaged and will be rebuilt."
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
    let positions: [SIMD3<Float>]
    let normals: [SIMD3<Float>]
    let indices: [UInt32]
    let materialGroups: [StepMeshMaterialGroup]
    let boundsMin: SIMD3<Float>
    let boundsMax: SIMD3<Float>
}

nonisolated struct StepMeshOccurrence: Sendable {
    let definitionIndex: Int
    let transform: simd_float4x4
    let color: SIMD4<Float>?
}

nonisolated struct StepMeshData: Sendable {
    let colorEncoding: StepColorEncoding
    let definitions: [StepMeshDefinition]
    let occurrences: [StepMeshOccurrence]
    let boundsMin: SIMD3<Float>
    let boundsMax: SIMD3<Float>
    let triangleCount: Int
    let faceCount: Int
    let missingFaceCount: Int
    let parseSeconds: Double
    let meshSeconds: Double

    var center: SIMD3<Float> { (boundsMin + boundsMax) * 0.5 }
    var diagonal: Float { simd_length(boundsMax - boundsMin) }
    var isIncomplete: Bool { missingFaceCount > 0 }
}

nonisolated enum StepMeshArchive {
    static let version: UInt32 = 3
    static let importerCompatibility = "step-importer-v7-preview-healing-occt-7.9.3"
    private static let headerSize = 76
    private static let maximumDefinitions = 20_000
    private static let maximumOccurrences = 200_000
    private static let maximumVerticesPerDefinition = 4_500_000
    private static let maximumIndicesPerDefinition = 5_000_000
    private static let maximumMaterialGroupsPerDefinition = 1_666_666
    private static let maximumTotalVertices = 5_000_000
    private static let maximumTotalIndices = 5_000_000
    private static let maximumTotalMaterialGroups = 1_666_666

    static func decode(_ data: Data) throws -> StepMeshData {
        guard data.count >= headerSize else { throw StepMeshArchiveError.truncated }
        guard data.prefix(4) == Data([0x53, 0x54, 0x4c, 0x4b]) else { throw StepMeshArchiveError.invalidHeader }

        var reader = ArchiveReader(data: data, offset: 4)
        let archiveVersion = try reader.readUInt32()
        guard archiveVersion == version else { throw StepMeshArchiveError.unsupportedVersion(archiveVersion) }
        _ = try reader.readUInt32() // flags; diagnostics are represented by explicit counts below
        let definitionCount = Int(try reader.readUInt32())
        let occurrenceCount = Int(try reader.readUInt32())
        let triangleCount = Int(try reader.readUInt32())
        let faceCount = Int(try reader.readUInt32())
        let missingFaceCount = Int(try reader.readUInt32())
        let colorEncodingValue = try reader.readUInt32()
        guard let colorEncoding = StepColorEncoding(rawValue: colorEncodingValue) else {
            throw StepMeshArchiveError.unsupportedColorEncoding(colorEncodingValue)
        }
        guard (1...maximumDefinitions).contains(definitionCount),
              (1...maximumOccurrences).contains(occurrenceCount),
              triangleCount > 0, faceCount > 0, missingFaceCount <= faceCount else {
            throw StepMeshArchiveError.invalidCounts
        }

        let boundsMin = try reader.readVector3()
        let boundsMax = try reader.readVector3()
        let parseSeconds = try reader.readDouble()
        let meshSeconds = try reader.readDouble()
        guard boundsMin.allFinite, boundsMax.allFinite,
              boundsMax.x >= boundsMin.x, boundsMax.y >= boundsMin.y, boundsMax.z >= boundsMin.z,
              parseSeconds.isFinite, parseSeconds >= 0,
              meshSeconds.isFinite, meshSeconds >= 0 else {
            throw StepMeshArchiveError.invalidCounts
        }

        var definitions: [StepMeshDefinition] = []
        definitions.reserveCapacity(definitionCount)
        var totalVertices = 0
        var totalIndices = 0
        var totalMaterialGroups = 0
        for _ in 0..<definitionCount {
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
                boundsMin: definitionMin, boundsMax: definitionMax
            ))
        }

        var occurrences: [StepMeshOccurrence] = []
        occurrences.reserveCapacity(occurrenceCount)
        var displayedTriangleCount: UInt64 = 0
        for _ in 0..<occurrenceCount {
            let definitionIndex = Int(try reader.readUInt32())
            let hasColorValue = try reader.readUInt32()
            guard hasColorValue <= 1 else { throw StepMeshArchiveError.invalidCounts }
            guard definitions.indices.contains(definitionIndex) else { throw StepMeshArchiveError.invalidIndex }
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
                color: hasColorValue == 1 ? rgba : nil
            ))
            displayedTriangleCount += UInt64(definitions[definitionIndex].indices.count / 3)
            guard displayedTriangleCount <= UInt64(UInt32.max) else {
                throw StepMeshArchiveError.invalidCounts
            }
        }
        guard displayedTriangleCount == UInt64(triangleCount),
              reader.offset == data.count else {
            throw StepMeshArchiveError.invalidCounts
        }

        return StepMeshData(
            colorEncoding: colorEncoding,
            definitions: definitions, occurrences: occurrences,
            boundsMin: boundsMin, boundsMax: boundsMax,
            triangleCount: triangleCount, faceCount: faceCount, missingFaceCount: missingFaceCount,
            parseSeconds: parseSeconds, meshSeconds: meshSeconds
        )
    }
}

nonisolated struct StepPreviewCache {
    private let fileManager = FileManager.default
    private let rootURL: URL?
    private let profileIdentifier: String
    private let maximumBytes: UInt64

    nonisolated init(
        rootURL: URL? = nil,
        profileIdentifier: String = "default-v1",
        maximumBytes: UInt64 = 512 * 1_024 * 1_024
    ) {
        self.rootURL = rootURL
        self.profileIdentifier = profileIdentifier
        self.maximumBytes = maximumBytes
    }

    nonisolated func load(for sourceURL: URL) throws -> StepMeshData? {
        let url = try cacheURL(for: sourceURL)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let decoded = try StepMeshArchive.decode(Data(contentsOf: url, options: [.mappedIfSafe]))
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return decoded
        } catch {
            try? fileManager.removeItem(at: url)
            return nil
        }
    }

    nonisolated func store(_ archive: Data, for sourceURL: URL) throws -> StepMeshData {
        let decoded = try StepMeshArchive.decode(archive)
        let destination = try cacheURL(for: sourceURL)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try archive.write(to: destination, options: [.atomic])
        pruneIfNeeded(in: destination.deletingLastPathComponent(), preserving: destination)
        return decoded
    }

    nonisolated private func pruneIfNeeded(in directory: URL, preserving newestURL: URL) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        var entries: [(url: URL, size: UInt64, date: Date)] = []
        var totalBytes: UInt64 = 0
        for url in urls where url.pathExtension == "stlk" {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            let size = UInt64(max(0, values.fileSize ?? 0))
            totalBytes &+= size
            entries.append((url, size, values.contentModificationDate ?? .distantPast))
        }

        for entry in entries.sorted(by: { $0.date < $1.date }) {
            guard totalBytes > maximumBytes else { break }
            guard entry.url != newestURL else { continue }
            guard (try? fileManager.removeItem(at: entry.url)) != nil else { continue }
            totalBytes = totalBytes >= entry.size ? totalBytes - entry.size : 0
        }
    }

    nonisolated private func cacheURL(for sourceURL: URL) throws -> URL {
        let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let contentDigest = try sourceContentDigest(for: sourceURL)
        let fingerprint = [sourceURL.standardizedFileURL.path, String(size), String(modified), String(fileNumber),
                           contentDigest, String(StepMeshArchive.version), StepMeshArchive.importerCompatibility,
                           profileIdentifier].joined(separator: "|")
        let digest = SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
        let root = rootURL ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StepLook", isDirectory: true)
            .appendingPathComponent("PreviewCache", isDirectory: true)
        return root.appendingPathComponent(digest).appendingPathExtension("stlk")
    }

    nonisolated private func sourceContentDigest(for sourceURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private nonisolated struct ArchiveReader {
    let data: Data
    var offset: Int

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
