import Darwin
import Foundation
import simd

@main
struct StepMeshArchiveAllocationTests {
    static func main() {
        expectAllocationPreflight(
            impossibleDefinitionTableArchive(),
            description: "impossible definition table"
        )
        do {
            _ = try StepMeshArchive.decode(impossibleDefinitionArchive())
            fail("impossible definition payload was accepted")
        } catch StepMeshArchiveError.declaredPayloadExceedsArchive {
            // Expected before any vertex, normal, index, or group reservation.
        } catch {
            fail("impossible definition payload reached a later decoder error: \(error)")
        }
        expectAllocationPreflight(
            impossibleOccurrenceTableArchive(),
            description: "impossible occurrence table"
        )
        expectAllocationPreflight(
            impossibleHierarchyTableArchive(),
            description: "impossible hierarchy table"
        )
        do {
            let model = try StepMeshArchive.decode(validArchive())
            guard model.definitions.count == 1,
                  model.occurrences.count == 1,
                  model.hierarchy.count == 1 else {
                fail("valid archive changed shape after allocation preflight")
            }
        } catch {
            fail("valid archive was rejected after allocation preflight: \(error)")
        }

        print("Step mesh archive allocation tests passed")
    }

    private static func expectAllocationPreflight(_ data: Data, description: String) {
        do {
            _ = try StepMeshArchive.decode(data)
            fail("\(description) was accepted")
        } catch StepMeshArchiveError.declaredPayloadExceedsArchive {
            // Expected before reserving storage for the declared table.
        } catch {
            fail("\(description) reached a later decoder error: \(error)")
        }
    }

    private static func impossibleDefinitionTableArchive() -> Data {
        archiveHeader(definitions: 20_000, occurrences: 1, hierarchyNodes: 1)
    }

    private static func impossibleDefinitionArchive() -> Data {
        var data = archiveHeader(definitions: 1, occurrences: 1, hierarchyNodes: 1)
        appendString("definition", to: &data)
        appendString("", to: &data)
        appendUInt32(1_000_000, to: &data) // valid count, impossible payload
        appendUInt32(3, to: &data)
        appendUInt32(1, to: &data)
        appendVector(SIMD3(0, 0, 0), to: &data)
        appendVector(SIMD3(1, 1, 1), to: &data)
        return data
    }

    private static func impossibleOccurrenceTableArchive() -> Data {
        var data = archiveHeader(
            definitions: 1,
            occurrences: 200_000,
            hierarchyNodes: 200_000
        )
        appendValidDefinition(to: &data)
        return data
    }

    private static func impossibleHierarchyTableArchive() -> Data {
        var data = archiveHeader(
            definitions: 1,
            occurrences: 1,
            hierarchyNodes: 250_000
        )
        appendValidDefinition(to: &data)
        appendValidOccurrence(to: &data)
        return data
    }

    private static func validArchive() -> Data {
        var data = archiveHeader(definitions: 1, occurrences: 1, hierarchyNodes: 1)
        appendValidDefinition(to: &data)
        appendValidOccurrence(to: &data)
        appendValidHierarchyNode(to: &data)
        return data
    }

    private static func archiveHeader(
        definitions: UInt32,
        occurrences: UInt32,
        hierarchyNodes: UInt32
    ) -> Data {
        var data = Data("STLK".utf8)
        appendUInt32(StepMeshArchive.version, to: &data)
        appendUInt32(0, to: &data)
        appendUInt32(definitions, to: &data)
        appendUInt32(occurrences, to: &data)
        appendUInt32(hierarchyNodes, to: &data)
        appendUInt32(1, to: &data) // displayed triangles
        appendUInt32(1, to: &data) // faces
        appendUInt32(0, to: &data) // missing faces
        appendUInt32(StepColorEncoding.linearSRGB.rawValue, to: &data)
        appendVector(SIMD3(0, 0, 0), to: &data)
        appendVector(SIMD3(1, 1, 1), to: &data)
        appendDouble(0, to: &data)
        appendDouble(0, to: &data)
        appendDouble(1, to: &data)
        return data
    }

    private static func appendValidDefinition(to data: inout Data) {
        appendString("definition", to: &data)
        appendString("", to: &data)
        appendUInt32(3, to: &data)
        appendUInt32(3, to: &data)
        appendUInt32(1, to: &data)
        appendVector(SIMD3(0, 0, 0), to: &data)
        appendVector(SIMD3(1, 1, 0), to: &data)
        appendVector(SIMD3(0, 0, 0), to: &data)
        appendVector(SIMD3(1, 0, 0), to: &data)
        appendVector(SIMD3(0, 1, 0), to: &data)
        appendVector(SIMD3(0, 0, 1), to: &data)
        appendVector(SIMD3(0, 0, 1), to: &data)
        appendVector(SIMD3(0, 0, 1), to: &data)
        appendUInt32(0, to: &data)
        appendUInt32(1, to: &data)
        appendUInt32(2, to: &data)
        appendUInt32(0, to: &data)
        appendUInt32(3, to: &data)
        appendUInt32(0, to: &data)
        appendColor(SIMD4(0, 0, 0, 0), to: &data)
    }

    private static func appendValidOccurrence(to data: inout Data) {
        appendUInt32(0, to: &data)
        appendUInt32(0, to: &data)
        appendUInt32(0, to: &data)
        appendColor(SIMD4(1, 0, 0, 0), to: &data)
        appendColor(SIMD4(0, 1, 0, 0), to: &data)
        appendColor(SIMD4(0, 0, 1, 0), to: &data)
        appendColor(SIMD4(0, 0, 0, 0), to: &data)
    }

    private static func appendValidHierarchyNode(to data: inout Data) {
        appendString("node", to: &data)
        appendString("", to: &data)
        appendUInt32(UInt32.max, to: &data)
        appendUInt32(0, to: &data)
        appendUInt32(0, to: &data)
        appendColor(SIMD4(1, 0, 0, 0), to: &data)
        appendColor(SIMD4(0, 1, 0, 0), to: &data)
        appendColor(SIMD4(0, 0, 1, 0), to: &data)
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendDouble(_ value: Double, to data: inout Data) {
        var littleEndian = value.bitPattern.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendString(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        appendUInt32(UInt32(bytes.count), to: &data)
        data.append(bytes)
    }

    private static func appendColor(_ value: SIMD4<Float>, to data: inout Data) {
        appendUInt32(value.x.bitPattern, to: &data)
        appendUInt32(value.y.bitPattern, to: &data)
        appendUInt32(value.z.bitPattern, to: &data)
        appendUInt32(value.w.bitPattern, to: &data)
    }

    private static func appendVector(_ value: SIMD3<Float>, to data: inout Data) {
        appendUInt32(value.x.bitPattern, to: &data)
        appendUInt32(value.y.bitPattern, to: &data)
        appendUInt32(value.z.bitPattern, to: &data)
    }

    private static func fail(_ message: String) -> Never {
        fputs("FAIL: \(message)\n", stderr)
        exit(EXIT_FAILURE)
    }
}
