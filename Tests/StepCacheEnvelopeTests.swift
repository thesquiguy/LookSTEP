import Darwin
import Dispatch
import Foundation

@main
struct StepCacheEnvelopeTests {
    static func main() async throws {
        let digest = Data(repeating: 0x5a, count: StepCacheSourceIdentity.digestByteCount)
        let source = StepCacheSourceIdentity(
            size: 7,
            modifiedBitPattern: 11,
            fileNumber: 13,
            generationDigest: digest,
            sampleDigest: digest
        )
        var envelope = try StepCacheEnvelope.encode(
            archive: Data("archive".utf8),
            source: source,
            sourceContentDigest: digest
        )
        let decoded = try StepCacheEnvelope.decode(
            envelope,
            maximumArchiveBytes: StepPreviewCache.maximumDecodedArchiveBytes
        )
        expect(decoded.archive == Data("archive".utf8), "valid envelope changed its archive")
        expect(decoded.sourceContentDigest == digest, "valid envelope changed its source digest")

        replaceUInt32(in: &envelope, at: 12, with: 1)
        do {
            _ = try StepCacheEnvelope.decode(
                envelope,
                maximumArchiveBytes: StepPreviewCache.maximumDecodedArchiveBytes
            )
            fail("envelope with unknown reserved bits was accepted")
        } catch StepPreviewCacheError.damagedEnvelope {
            // Expected: unknown feature bits cannot be interpreted safely.
        } catch {
            fail("reserved bits returned the wrong error: \(error)")
        }

        try await verifyMutationDuringColdImportIsNotPublished()
        try await verifyMutationDuringCacheHitIsNotReturned()
        try verifyDigestValidatedEntryRefreshesFastIdentity()
        try verifyUnreadableEntryIsPreserved()
        try verifySourceSnapshotDoesNotMixReplacementInodes()
        try verifyFullDigestTracksCurrentPathAfterReplacement()
        try verifySnapshotRetryBoundAndRegularFileRequirement()

        print("Step cache integrity tests passed")
    }

    private static func verifySourceSnapshotDoesNotMixReplacementInodes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StepCacheSnapshotRaceTests-\(UUID().uuidString)")
        let sourceURL = root.appendingPathComponent("source.step")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0x41, count: 256 * 1_024).write(to: sourceURL)
        let before = try StepCacheSourceIdentity.capture(
            sourceURL,
            fileManager: FileManager.default
        )

        var replaced = false
        let raced = try StepCacheSourceIdentity.captureForTesting(
            sourceURL,
            fileManager: FileManager.default
        ) {
            guard !replaced else { return }
            replaced = true
            do {
                try Data(repeating: 0x42, count: 256 * 1_024).write(
                    to: sourceURL,
                    options: .atomic
                )
            } catch {
                fail("could not replace source during identity capture: \(error)")
            }
        }
        let after = try StepCacheSourceIdentity.capture(
            sourceURL,
            fileManager: FileManager.default
        )

        let replacedSource = replaced
        let coherent = raced.fastMatches(before) || raced.fastMatches(after)
        try? FileManager.default.removeItem(at: root)
        expect(replacedSource, "snapshot race did not replace its source")
        expect(
            coherent,
            "one source identity mixed metadata and samples from different inodes"
        )
    }

    private static func verifyFullDigestTracksCurrentPathAfterReplacement() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StepCacheDigestRaceTests-\(UUID().uuidString)")
        let sourceURL = root.appendingPathComponent("source.step")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0x31, count: 256 * 1_024).write(to: sourceURL)

        var replaced = false
        let racedDigest = try StepCacheSourceIdentity.fullContentDigestForTesting(
            sourceURL,
            fileManager: FileManager.default
        ) {
            guard !replaced else { return }
            replaced = true
            do {
                try Data(repeating: 0x32, count: 256 * 1_024).write(
                    to: sourceURL,
                    options: .atomic
                )
            } catch {
                fail("could not replace source during full digest: \(error)")
            }
        }
        let currentDigest = try StepCacheSourceIdentity.fullContentDigest(
            sourceURL,
            fileManager: FileManager.default
        )
        let followedCurrentPath = racedDigest == currentDigest
        try? FileManager.default.removeItem(at: root)

        expect(replaced, "full-digest race did not replace its source")
        expect(
            followedCurrentPath,
            "full digest validated the unlinked inode instead of the current source path"
        )
    }

    private static func verifySnapshotRetryBoundAndRegularFileRequirement() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StepCacheSnapshotBoundTests-\(UUID().uuidString)")
        let sourceURL = root.appendingPathComponent("source.step")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0x61, count: 64 * 1_024).write(to: sourceURL)

        var attempts = 0
        var bounded = false
        do {
            _ = try StepCacheSourceIdentity.captureForTesting(
                sourceURL,
                fileManager: FileManager.default
            ) {
                attempts += 1
                do {
                    try Data(
                        repeating: attempts.isMultiple(of: 2) ? 0x61 : 0x62,
                        count: 64 * 1_024
                    ).write(to: sourceURL, options: .atomic)
                } catch {
                    fail("could not replace source during retry-bound test: \(error)")
                }
            }
        } catch StepPreviewCacheError.sourceChangedDuringSnapshot {
            bounded = attempts == 3
        }

        var rejectedDirectory = false
        do {
            _ = try StepCacheSourceIdentity.capture(
                root,
                fileManager: FileManager.default
            )
        } catch StepPreviewCacheError.unsupportedSource {
            rejectedDirectory = true
        }
        try? FileManager.default.removeItem(at: root)

        expect(bounded, "unstable source capture did not stop after three attempts")
        expect(rejectedDirectory, "source identity capture accepted a non-regular file")
    }

    private static func verifyMutationDuringColdImportIsNotPublished() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StepCacheImportMutationTests-\(UUID().uuidString)")
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        let sourceURL = root.appendingPathComponent("source.step")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("source before import".utf8).write(to: sourceURL)
        let cache = StepPreviewCache(
            rootURL: cacheRoot,
            profileIdentifier: "import-mutation-test"
        )

        do {
            _ = try await cache.loadOrImport(for: sourceURL) {
                let handle = try FileHandle(forWritingTo: sourceURL)
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: Data("source mutated during import".utf8))
                try handle.close()
                return validMeshArchive()
            }
            fail("source mutation during cold import was cached")
        } catch StepPreviewCacheError.sourceChangedDuringStore {
            // Expected: imported bytes no longer describe the current source.
        } catch {
            fail("source mutation returned the wrong error: \(error)")
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: nil
        )
        expect(
            !entries.contains(where: { $0.pathExtension == "stlc" }),
            "source mutation published a stale cache entry"
        )
    }

    private static func verifyMutationDuringCacheHitIsNotReturned() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StepCacheHitMutationTests-\(UUID().uuidString)")
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        let sourceURL = root.appendingPathComponent("source.step")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("source before cache hit".utf8).write(to: sourceURL)
        let cache = StepPreviewCache(
            rootURL: cacheRoot,
            profileIdentifier: "hit-mutation-test"
        )
        let source = try StepCacheSourceIdentity.capture(
            sourceURL,
            fileManager: FileManager.default
        )
        let archive = validMeshArchive()
        _ = try StepMeshArchive.decode(archive)
        let entry = try StepCacheEnvelope.encode(
            archive: archive,
            source: source,
            sourceContentDigest: StepCacheSourceIdentity.fullContentDigest(
                sourceURL,
                fileManager: FileManager.default
            )
        )
        let cacheURL = try cache.cacheURLForTesting(for: sourceURL, source: source)
        try FileManager.default.createDirectory(
            at: cacheRoot,
            withIntermediateDirectories: true
        )
        try entry.write(to: cacheURL, options: .atomic)
        let baseline = try cache.load(for: sourceURL)
        expect(
            baseline != nil,
            "cache-hit mutation fixture is not readable through production load"
        )

        let sourceCaptured = DispatchSemaphore(value: 0)
        let allowCacheRead = DispatchSemaphore(value: 0)
        let loadTask = Task.detached {
            try cache.loadForTesting(for: sourceURL) {
                sourceCaptured.signal()
                allowCacheRead.wait()
            }
        }
        guard await wait(for: sourceCaptured, timeout: .now() + 2) else {
            allowCacheRead.signal()
            fail("cache-hit read did not capture its initial source identity")
        }
        try Data("source replaced during cache hit".utf8).write(
            to: sourceURL,
            options: .atomic
        )
        allowCacheRead.signal()

        let loaded = try await loadTask.value
        expect(loaded == nil, "source mutation during a cache hit returned stale geometry")
    }

    private static func verifyDigestValidatedEntryRefreshesFastIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StepCacheIdentityRefreshTests-\(UUID().uuidString)")
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        let sourceURL = root.appendingPathComponent("source.step")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("source with stable content".utf8).write(to: sourceURL)
        let cache = StepPreviewCache(
            rootURL: cacheRoot,
            profileIdentifier: "identity-refresh-test"
        )
        let initialSource = try StepCacheSourceIdentity.capture(
            sourceURL,
            fileManager: FileManager.default
        )
        let archive = validMeshArchive()
        let entry = try StepCacheEnvelope.encode(
            archive: archive,
            source: initialSource,
            sourceContentDigest: StepCacheSourceIdentity.fullContentDigest(
                sourceURL,
                fileManager: FileManager.default
            )
        )
        let cacheURL = try cache.cacheURLForTesting(
            for: sourceURL,
            source: initialSource
        )
        try FileManager.default.createDirectory(
            at: cacheRoot,
            withIntermediateDirectories: true
        )
        try entry.write(to: cacheURL, options: .atomic)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 60)],
            ofItemAtPath: sourceURL.path
        )
        let updatedSource = try StepCacheSourceIdentity.capture(
            sourceURL,
            fileManager: FileManager.default
        )
        expect(
            !initialSource.fastMatches(updatedSource),
            "metadata-only cache fixture did not change its fast identity"
        )
        let digestValidatedHit = try cache.load(for: sourceURL)
        expect(
            digestValidatedHit != nil,
            "matching full digest did not preserve the cache hit"
        )

        let refreshedEntry = try Data(contentsOf: cacheURL)
        let refreshedEnvelope = try StepCacheEnvelope.decode(
            refreshedEntry,
            maximumArchiveBytes: StepPreviewCache.maximumDecodedArchiveBytes
        )
        expect(
            refreshedEnvelope.source.fastMatches(updatedSource),
            "digest-validated cache hit left a stale fast identity and will rehash again"
        )
    }

    private static func verifyUnreadableEntryIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StepCacheReadFailureTests-\(UUID().uuidString)")
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        let sourceURL = root.appendingPathComponent("source.step")
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("source for transient cache failure".utf8).write(to: sourceURL)
        let cache = StepPreviewCache(
            rootURL: cacheRoot,
            profileIdentifier: "read-failure-test"
        )
        let source = try StepCacheSourceIdentity.capture(
            sourceURL,
            fileManager: FileManager.default
        )
        let entry = try StepCacheEnvelope.encode(
            archive: validMeshArchive(),
            source: source,
            sourceContentDigest: StepCacheSourceIdentity.fullContentDigest(
                sourceURL,
                fileManager: FileManager.default
            )
        )
        let cacheURL = try cache.cacheURLForTesting(for: sourceURL, source: source)
        try entry.write(to: cacheURL, options: .atomic)
        guard chmod(cacheURL.path, 0) == 0 else {
            fail("could not make the cache entry unreadable")
        }
        defer {
            _ = chmod(cacheURL.path, mode_t(S_IRUSR | S_IWUSR))
        }

        var readFailurePropagated = false
        do {
            _ = try cache.load(for: sourceURL)
        } catch {
            readFailurePropagated = true
        }
        let entryPreserved = FileManager.default.fileExists(atPath: cacheURL.path)
        expect(
            readFailurePropagated,
            "transient cache read failure was silently converted to a cache miss"
        )
        expect(
            entryPreserved,
            "transient cache read failure evicted an entry that was not proven invalid"
        )
    }

    private static func wait(
        for semaphore: DispatchSemaphore,
        timeout: DispatchTime
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: semaphore.wait(timeout: timeout) == .success)
            }
        }
    }

    private static func validMeshArchive() -> Data {
        var data = Data("STLK".utf8)
        appendUInt32(StepMeshArchive.version, to: &data)
        appendUInt32(0, to: &data)
        appendUInt32(1, to: &data) // definitions
        appendUInt32(1, to: &data) // occurrences
        appendUInt32(1, to: &data) // hierarchy nodes
        appendUInt32(1, to: &data) // displayed triangles
        appendUInt32(1, to: &data) // faces
        appendUInt32(0, to: &data) // missing faces
        appendUInt32(StepColorEncoding.linearSRGB.rawValue, to: &data)
        appendVector(SIMD3(0, 0, 0), to: &data)
        appendVector(SIMD3(1, 1, 0), to: &data)
        appendDouble(0, to: &data)
        appendDouble(0, to: &data)
        appendDouble(1, to: &data)
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
        appendVector(SIMD4(0, 0, 0, 0), to: &data)
        appendUInt32(0, to: &data)
        appendUInt32(0, to: &data)
        appendUInt32(0, to: &data)
        appendVector(SIMD4(1, 0, 0, 0), to: &data)
        appendVector(SIMD4(0, 1, 0, 0), to: &data)
        appendVector(SIMD4(0, 0, 1, 0), to: &data)
        appendVector(SIMD4(0, 0, 0, 0), to: &data)
        appendString("node", to: &data)
        appendString("", to: &data)
        appendUInt32(UInt32.max, to: &data)
        appendUInt32(0, to: &data)
        appendUInt32(0, to: &data)
        appendVector(SIMD4(1, 0, 0, 0), to: &data)
        appendVector(SIMD4(0, 1, 0, 0), to: &data)
        appendVector(SIMD4(0, 0, 1, 0), to: &data)
        return data
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else { fail(message) }
    }

    private static func replaceUInt32(
        in data: inout Data,
        at offset: Int,
        with value: UInt32
    ) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
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

    private static func appendVector(_ value: SIMD3<Float>, to data: inout Data) {
        appendUInt32(value.x.bitPattern, to: &data)
        appendUInt32(value.y.bitPattern, to: &data)
        appendUInt32(value.z.bitPattern, to: &data)
    }

    private static func appendVector(_ value: SIMD4<Float>, to data: inout Data) {
        appendUInt32(value.x.bitPattern, to: &data)
        appendUInt32(value.y.bitPattern, to: &data)
        appendUInt32(value.z.bitPattern, to: &data)
        appendUInt32(value.w.bitPattern, to: &data)
    }

    private static func fail(_ message: String) -> Never {
        fputs("FAIL: \(message)\n", stderr)
        exit(EXIT_FAILURE)
    }
}
