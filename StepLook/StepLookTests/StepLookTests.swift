//
//  StepLookTests.swift
//  StepLookTests
//
//  Created by Aaron Squier on 7/20/26.
//

import Foundation
import Testing
@testable import LookSTEP

struct StepLookTests {
    @Test func importsOptInSTEPFixtureThroughSandboxedService() async throws {
        guard let path = ProcessInfo.processInfo.environment["STEPLOOK_TEST_FILE"], !path.isEmpty else {
            return
        }

        let sourceURL = URL(fileURLWithPath: path)
        let result = try await StepImportClient().importFile(
            at: sourceURL,
            maxSeconds: 40,
            maxTriangles: 1_200_000,
            relativeDeflection: 0.0025
        )
        let model = try StepMeshArchive.decode(result.archive)

        #expect(model.triangleCount > 0)
        #expect(!model.definitions.isEmpty)
        #expect(!model.occurrences.isEmpty)
    }

    @Test func importServiceReadsFromTransferredFileDescriptor() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StepLook-XPC-\(UUID().uuidString).step")
        try Data("not a STEP file".utf8).write(to: sourceURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        do {
            _ = try await StepImportClient().importFile(
                at: sourceURL,
                maxSeconds: 2,
                maxTriangles: 1,
                relativeDeflection: 0.0035
            )
            Issue.record("Invalid source unexpectedly imported")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "com.local.stepviewer.import")
            #expect(nsError.code == 1)
        }
    }

    @Test func archiveRoundTripAndRepeatCacheLoad() throws {
        let fixture = try CacheFixture()
        defer { fixture.remove() }
        let archive = makeArchive()

        let stored = try fixture.cache.store(archive, for: fixture.sourceURL)
        let first = try #require(try fixture.cache.load(for: fixture.sourceURL))
        let second = try #require(try fixture.cache.load(for: fixture.sourceURL))

        #expect(stored.triangleCount == 1)
        #expect(first.definitions.count == 1)
        #expect(first.occurrences.count == 1)
        #expect(first.definitions[0].indices == [0, 1, 2])
        #expect(first.colorEncoding == .linearSRGB)
        #expect(first.definitions[0].materialGroups.count == 1)
        #expect(first.definitions[0].materialGroups[0].linearColor == SIMD4(0.25, 0.5, 0.75, 1))
        #expect(second.triangleCount == first.triangleCount)
        #expect(second.boundsMin == first.boundsMin)
        #expect(second.boundsMax == first.boundsMax)
    }

    @Test func damagedCacheIsEvictedAndCanBeRebuilt() throws {
        let fixture = try CacheFixture()
        defer { fixture.remove() }
        let archive = makeArchive()
        _ = try fixture.cache.store(archive, for: fixture.sourceURL)

        let cacheFile = try #require(try fixture.onlyCacheFile())
        try Data("damaged".utf8).write(to: cacheFile, options: .atomic)

        #expect(try fixture.cache.load(for: fixture.sourceURL) == nil)
        #expect(!FileManager.default.fileExists(atPath: cacheFile.path))

        let rebuilt = try fixture.cache.store(archive, for: fixture.sourceURL)
        #expect(rebuilt.triangleCount == 1)
        #expect(try fixture.cache.load(for: fixture.sourceURL)?.triangleCount == 1)
    }

    @Test func changedSourceDoesNotReuseStaleCache() throws {
        let fixture = try CacheFixture()
        defer { fixture.remove() }
        _ = try fixture.cache.store(makeArchive(), for: fixture.sourceURL)

        try Data("source changed and grew".utf8).write(to: fixture.sourceURL, options: .atomic)

        #expect(try fixture.cache.load(for: fixture.sourceURL) == nil)
    }

    @Test func sameSizeAndTimestampContentChangeInvalidatesCache() throws {
        let fixture = try CacheFixture()
        defer { fixture.remove() }
        _ = try fixture.cache.store(makeArchive(), for: fixture.sourceURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.sourceURL.path)
        let originalDate = try #require(attributes[.modificationDate] as? Date)

        let handle = try FileHandle(forWritingTo: fixture.sourceURL)
        try handle.write(contentsOf: Data("change".utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: fixture.sourceURL.path)

        #expect(try fixture.cache.load(for: fixture.sourceURL) == nil)
    }

    @Test func conversionProfilesDoNotShareEntries() throws {
        let fixture = try CacheFixture(profileIdentifier: "refined-v1")
        defer { fixture.remove() }
        _ = try fixture.cache.store(makeArchive(), for: fixture.sourceURL)
        let coarse = StepPreviewCache(
            rootURL: fixture.cacheRootURL,
            profileIdentifier: "coarse-v1"
        )

        #expect(try coarse.load(for: fixture.sourceURL) == nil)
        #expect(try fixture.cache.load(for: fixture.sourceURL)?.triangleCount == 1)
    }

    @Test func cacheEvictsLeastRecentlyUsedEntriesWhenSizeLimitIsExceeded() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StepLookTests-\(UUID().uuidString)", isDirectory: true)
        let cacheRootURL = rootURL.appendingPathComponent("cache", isDirectory: true)
        let firstSource = rootURL.appendingPathComponent("first.step")
        let secondSource = rootURL.appendingPathComponent("second.step")
        let archive = makeArchive()
        let cache = StepPreviewCache(
            rootURL: cacheRootURL,
            profileIdentifier: "eviction-test-v1",
            maximumBytes: UInt64(archive.count + 1)
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data("first source".utf8).write(to: firstSource)
        try Data("second source".utf8).write(to: secondSource)

        _ = try cache.store(archive, for: firstSource)
        let firstCacheURL = try #require(
            FileManager.default.contentsOfDirectory(at: cacheRootURL, includingPropertiesForKeys: nil).first
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: firstCacheURL.path
        )
        _ = try cache.store(archive, for: secondSource)

        #expect(try cache.load(for: firstSource) == nil)
        #expect(try cache.load(for: secondSource)?.triangleCount == 1)
    }

    @Test func malformedArchivesAreRejected() throws {
        let valid = makeArchive()
        var obsoleteVersion = valid
        replaceUInt32(in: &obsoleteVersion, at: 4, with: StepMeshArchive.version - 1)
        #expect(throws: StepMeshArchiveError.self) {
            try StepMeshArchive.decode(obsoleteVersion)
        }

        #expect(throws: StepMeshArchiveError.self) {
            try StepMeshArchive.decode(Data(valid.prefix(valid.count - 1)))
        }

        var invalidTiming = valid
        replaceUInt64(in: &invalidTiming, at: 60, with: Double.nan.bitPattern)
        #expect(throws: StepMeshArchiveError.self) {
            try StepMeshArchive.decode(invalidTiming)
        }

        var invalidDefinitionBounds = valid
        replaceUInt32(in: &invalidDefinitionBounds, at: 88, with: Float.nan.bitPattern)
        #expect(throws: StepMeshArchiveError.self) {
            try StepMeshArchive.decode(invalidDefinitionBounds)
        }

        var excessiveIndexCount = valid
        replaceUInt32(in: &excessiveIndexCount, at: 80, with: UInt32.max)
        #expect(throws: StepMeshArchiveError.self) {
            try StepMeshArchive.decode(excessiveIndexCount)
        }

        var invalidColorEncoding = valid
        replaceUInt32(in: &invalidColorEncoding, at: 32, with: UInt32.max)
        #expect(throws: StepMeshArchiveError.self) {
            try StepMeshArchive.decode(invalidColorEncoding)
        }

        var noncontiguousMaterialGroup = valid
        replaceUInt32(in: &noncontiguousMaterialGroup, at: 196, with: 3)
        #expect(throws: StepMeshArchiveError.self) {
            try StepMeshArchive.decode(noncontiguousMaterialGroup)
        }

        var invalidMaterialColor = valid
        replaceUInt32(in: &invalidMaterialColor, at: 208, with: Float.nan.bitPattern)
        #expect(throws: StepMeshArchiveError.self) {
            try StepMeshArchive.decode(invalidMaterialColor)
        }
    }

    @Test func faceColorPrecedesOccurrenceAndNeutralFallback() throws {
        let model = try StepMeshArchive.decode(makeArchive())
        let group = model.definitions[0].materialGroups[0]
        let occurrenceColor = try #require(model.occurrences[0].color)
        let neutral = SIMD4<Float>(0.7, 0.72, 0.75, 1)

        #expect(group.resolvedLinearColor(
            occurrenceColor: occurrenceColor,
            neutralFallback: neutral
        ) == SIMD4(0.25, 0.5, 0.75, 1))
        let uncoloredGroup = StepMeshMaterialGroup(indexOffset: 0, indexCount: 3, linearColor: nil)
        #expect(uncoloredGroup.resolvedLinearColor(
            occurrenceColor: occurrenceColor,
            neutralFallback: neutral
        ) == occurrenceColor)
        #expect(uncoloredGroup.resolvedLinearColor(
            occurrenceColor: nil,
            neutralFallback: neutral
        ) == neutral)
    }
}

private struct CacheFixture {
    let rootURL: URL
    let sourceURL: URL
    let cache: StepPreviewCache
    var cacheRootURL: URL { rootURL.appendingPathComponent("cache", isDirectory: true) }

    init(profileIdentifier: String = "test-v1") throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StepLookTests-\(UUID().uuidString)", isDirectory: true)
        sourceURL = rootURL.appendingPathComponent("fixture.step")
        cache = StepPreviewCache(
            rootURL: rootURL.appendingPathComponent("cache", isDirectory: true),
            profileIdentifier: profileIdentifier
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: sourceURL)
    }

    func onlyCacheFile() throws -> URL? {
        return try FileManager.default.contentsOfDirectory(
            at: cacheRootURL,
            includingPropertiesForKeys: nil
        ).first
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private func makeArchive() -> Data {
    var data = Data("STLK".utf8)
    appendUInt32(StepMeshArchive.version, to: &data)
    appendUInt32(0, to: &data)
    appendUInt32(1, to: &data) // definitions
    appendUInt32(1, to: &data) // occurrences
    appendUInt32(1, to: &data) // displayed triangles
    appendUInt32(1, to: &data) // faces
    appendUInt32(0, to: &data) // missing faces
    appendUInt32(StepColorEncoding.linearSRGB.rawValue, to: &data)
    appendVector(SIMD3(0, 0, 0), to: &data)
    appendVector(SIMD3(1, 1, 0), to: &data)
    appendDouble(0.01, to: &data)
    appendDouble(0.02, to: &data)

    appendUInt32(3, to: &data) // vertices
    appendUInt32(3, to: &data) // indices
    appendUInt32(1, to: &data) // material groups
    appendVector(SIMD3(0, 0, 0), to: &data)
    appendVector(SIMD3(1, 1, 0), to: &data)
    appendVector(SIMD3(0, 0, 0), to: &data)
    appendVector(SIMD3(1, 0, 0), to: &data)
    appendVector(SIMD3(0, 1, 0), to: &data)
    for _ in 0..<3 { appendVector(SIMD3(0, 0, 1), to: &data) }
    appendUInt32(0, to: &data)
    appendUInt32(1, to: &data)
    appendUInt32(2, to: &data)

    appendUInt32(0, to: &data) // group index offset
    appendUInt32(3, to: &data) // group index count
    appendUInt32(1, to: &data) // explicit face color
    for value: Float in [0.25, 0.5, 0.75, 1] {
        appendUInt32(value.bitPattern, to: &data)
    }

    appendUInt32(0, to: &data) // definition index
    appendUInt32(1, to: &data) // occurrence/part color
    for value: Float in [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0] {
        appendUInt32(value.bitPattern, to: &data)
    }
    for value: Float in [0.1, 0.2, 0.3, 1] {
        appendUInt32(value.bitPattern, to: &data)
    }
    return data
}

private func appendUInt32(_ value: UInt32, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
}

private func appendDouble(_ value: Double, to data: inout Data) {
    var littleEndian = value.bitPattern.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
}

private func appendVector(_ value: SIMD3<Float>, to data: inout Data) {
    appendUInt32(value.x.bitPattern, to: &data)
    appendUInt32(value.y.bitPattern, to: &data)
    appendUInt32(value.z.bitPattern, to: &data)
}

private func replaceUInt32(in data: inout Data, at offset: Int, with value: UInt32) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { bytes in
        data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
}

private func replaceUInt64(in data: inout Data, at offset: Int, with value: UInt64) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { bytes in
        data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
}
