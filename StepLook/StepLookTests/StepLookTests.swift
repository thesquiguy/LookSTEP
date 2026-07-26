//
//  StepLookTests.swift
//  StepLookTests
//
//  Created by Aaron Squier on 7/20/26.
//

import AppKit
import Foundation
import MetalKit
import Testing
@testable import LookSTEP

@Suite(.serialized)
struct StepLookTests {
    @Test @MainActor
    func stepMetalViewDecoderRestoresRendererConfiguration() throws {
        let original = StepMetalView(frame: NSRect.zero)
        let archive = try NSKeyedArchiver.archivedData(
            withRootObject: original,
            requiringSecureCoding: false
        )
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archive)
        unarchiver.requiresSecureCoding = false
        defer { unarchiver.finishDecoding() }
        let decoded = try #require(
            unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? StepMetalView
        )

        #expect((decoded.device != nil) == (original.device != nil))
        #expect(decoded.delegate === decoded)
        #expect(decoded.accessibilityLabel() == "3D model viewport")
        #expect(decoded.isPaused)
        #expect(decoded.colorPixelFormat == .bgra8Unorm_srgb)
        #expect(!decoded.framebufferOnly)
    }

    @Test @MainActor
    func dismantlingInteractiveViewCancelsAndReleasesRendererWork() throws {
        let model = try StepMeshArchive.decode(makeArchive())
        let loadIdentifier = UUID()
        let view = StepMetalView(frame: NSRect.zero)
        view.load(model)
        #expect(view.hasActiveLoadTask)

        StepInteractiveView.dismantleNSView(
            view,
            coordinator: .init(fitRequest: 0, loadIdentifier: loadIdentifier)
        )

        #expect(!view.hasActiveLoadTask)
        #expect(view.isPaused)
    }

    @Test func firstFrameTimingIncludesDeferredRendererCreation() {
        let start = StepMetalView.firstFrameMeasurementStart(
            rendererNow: 100,
            systemUptime: 80,
            requestStartUptime: 75
        )

        #expect(start == 95)
    }

    @Test func previewBackgroundDefaultsToWhiteAndHonorsOptOut() {
        #expect(StepPreviewBackgroundPreference.isAlwaysWhite(storedValue: nil))
        #expect(!StepPreviewBackgroundPreference.isAlwaysWhite(
            storedValue: false
        ))
    }

    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["STEPLOOK_TEST_FILE"]?.isEmpty == false,
        "Set STEPLOOK_TEST_FILE to run the licensed opt-in STEP fixture."
    ))
    func importsOptInSTEPFixtureThroughSandboxedService() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["STEPLOOK_TEST_FILE"])

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
                // Sandboxed XPC cold launch and OCCT initialization can exceed
                // two seconds on a loaded QA machine. This test verifies file
                // descriptor transfer and the importer diagnostic, not latency.
                maxSeconds: 10,
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

    @Test func importServiceRejectsOversizedSourceBeforeCopying() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StepLook-XPC-Oversized-\(UUID().uuidString).step")
        FileManager.default.createFile(atPath: sourceURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: sourceURL)
        try handle.truncate(atOffset: 513 * 1_024 * 1_024)
        try handle.close()
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        do {
            _ = try await StepImportClient().importFile(
                at: sourceURL,
                maxSeconds: 2,
                maxTriangles: 1,
                relativeDeflection: 0.0035
            )
            Issue.record("Oversized source unexpectedly reached the importer")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "com.local.stepviewer.import")
            #expect(nsError.code == 4)
        }
    }

    @Test func importServiceRejectsExceededResidentLimitBeforeCopying() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StepLook-XPC-Resident-Limit-\(UUID().uuidString).step")
        try Data("not a STEP file".utf8).write(to: sourceURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        do {
            _ = try await StepImportClient().importFile(
                at: sourceURL,
                maxSeconds: 10,
                maxTriangles: 1,
                relativeDeflection: 0.0035,
                maxResidentBytes: 1
            )
            Issue.record("Exceeded resident limit unexpectedly reached the importer")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "com.local.stepviewer.import")
            #expect(nsError.code == 4)
        }
    }

    @Test func preCancelledImportStopsBeforeOpeningSource() async {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StepLook-Precancelled-\(UUID().uuidString).step")
        let client = StepImportClient()
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return try await client.importFile(
                at: missingURL,
                maxSeconds: 10,
                maxTriangles: 1,
                relativeDeflection: 0.0035
            )
        }

        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Pre-cancelled import unexpectedly reached source access")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(!client.hasActiveRequest)
    }

    @Test func cancellingClientTimeoutReleasesCapturedStateImmediately() {
        let (timeout, weakProbe) = makeTimeoutLifetimeFixture()

        #expect(weakProbe.value != nil)
        timeout.cancel()
        #expect(weakProbe.value == nil)

        // Cancellation is intentionally idempotent because reply,
        // interruption, and invalidation paths can converge.
        timeout.cancel()
    }

    @Test func connectionTeardownIsExactOnceAndReleasesCapturedState() {
        let invalidated = makeConnectionTeardownLifetimeFixture()

        #expect(invalidated.weakProbe.value != nil)
        invalidated.teardown.invalidate()
        #expect(invalidated.counter.value == 1)
        #expect(invalidated.weakProbe.value == nil)

        invalidated.teardown.invalidate()
        #expect(invalidated.counter.value == 1)

        let externallyInvalidated = makeConnectionTeardownLifetimeFixture()
        #expect(externallyInvalidated.weakProbe.value != nil)
        externallyInvalidated.teardown.connectionDidInvalidate()
        #expect(externallyInvalidated.counter.value == 0)
        #expect(externallyInvalidated.weakProbe.value == nil)

        externallyInvalidated.teardown.invalidate()
        #expect(externallyInvalidated.counter.value == 0)
    }

    @Test func importCancellationIsAcknowledgedBeforeServiceRestart() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StepLook-XPC-Cancel-\(UUID().uuidString).step")
        FileManager.default.createFile(atPath: sourceURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: sourceURL)
        try handle.truncate(atOffset: 32 * 1_024 * 1_024)
        try handle.close()
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let client = StepImportClient()
        let importTask = Task {
            try await client.importFile(
                at: sourceURL,
                maxSeconds: 20,
                maxTriangles: 750_000,
                relativeDeflection: 0.0035
            )
        }
        for _ in 0..<100 where !client.hasActiveRequest {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(client.hasActiveRequest)
        let acknowledged = await client.cancelAndWait()
        #expect(acknowledged)

        do {
            _ = try await importTask.value
            Issue.record("Cancelled import unexpectedly completed")
        } catch {
            // The acknowledgement is the teardown contract. Depending on XPC
            // delivery timing, the in-flight call observes cancellation or
            // connection invalidation, but it must never publish an archive.
        }

        try await Task.sleep(nanoseconds: 1_250_000_000)
        let invalidURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StepLook-XPC-Restart-\(UUID().uuidString).step")
        try Data("not a STEP file".utf8).write(to: invalidURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: invalidURL) }
        do {
            _ = try await StepImportClient().importFile(
                at: invalidURL,
                maxSeconds: 10,
                maxTriangles: 1,
                relativeDeflection: 0.0035
            )
            Issue.record("Invalid source unexpectedly imported after service restart")
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
        #expect(first.definitions[0].stableID == "d:1")
        #expect(first.definitions[0].name == "Part")
        #expect(first.hierarchy.count == 1)
        #expect(first.hierarchy[0].stableID == "n:1")
        #expect(first.hierarchy[0].name == "Part")
        #expect(first.occurrences[0].nodeIndex == 0)
        #expect(first.unitScaleToMeters == 0.001)
        #expect(first.hasExplicitLengthUnit)
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

    @Test func cacheUsesVersionedIntegrityEnvelopeAndRejectsPayloadCorruption() throws {
        let fixture = try CacheFixture()
        defer { fixture.remove() }
        _ = try fixture.cache.store(makeArchive(), for: fixture.sourceURL)

        let cacheFile = try #require(try fixture.onlyCacheFile())
        var entry = try Data(contentsOf: cacheFile)
        #expect(entry.prefix(4) == Data("STLC".utf8))
        #expect(entry.prefix(4) != Data("STLK".utf8))
        entry[entry.index(before: entry.endIndex)] ^= 0xff
        try entry.write(to: cacheFile, options: .atomic)

        #expect(try fixture.cache.load(for: fixture.sourceURL) == nil)
        #expect(!FileManager.default.fileExists(atPath: cacheFile.path))
    }

    @Test func oversizedEnvelopeIsRejectedBeforePayloadDecode() throws {
        let fixture = try CacheFixture()
        defer { fixture.remove() }
        _ = try fixture.cache.store(makeArchive(), for: fixture.sourceURL)

        let cacheFile = try #require(try fixture.onlyCacheFile())
        var entry = try Data(contentsOf: cacheFile)
        replaceUInt64(in: &entry, at: 16, with: UInt64.max)
        try entry.write(to: cacheFile, options: .atomic)

        #expect(try fixture.cache.load(for: fixture.sourceURL) == nil)
        #expect(!FileManager.default.fileExists(atPath: cacheFile.path))
    }

    @Test func concurrentWritersPublishOneDecodableEntry() async throws {
        let fixture = try CacheFixture()
        defer { fixture.remove() }
        let archive = makeArchive()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = try fixture.cache.store(archive, for: fixture.sourceURL)
                }
            }
            try await group.waitForAll()
        }

        #expect(try fixture.cacheFiles().count == 1)
        #expect(try fixture.cache.load(for: fixture.sourceURL)?.triangleCount == 1)
    }

    @Test func simultaneousColdMissesInvokeOneImporterAndCoalesceTheWaiter() async throws {
        let fixture = try CacheFixture()
        defer { fixture.remove() }
        let counter = CacheImportCounter(archive: makeArchive())
        let secondCache = StepPreviewCache(
            rootURL: fixture.cacheRootURL,
            profileIdentifier: "test-v1"
        )

        async let first = fixture.cache.loadOrImport(for: fixture.sourceURL) {
            try await counter.importArchive()
        }
        async let second = secondCache.loadOrImport(for: fixture.sourceURL) {
            try await counter.importArchive()
        }
        let (firstResult, secondResult) = try await (first, second)
        let results = [firstResult, secondResult]

        #expect(await counter.invocationCount == 1)
        #expect(results.allSatisfy { $0.model.triangleCount == 1 })
        #expect(Set(results.map(\.source)) == Set([.imported, .coalesced]))
        #expect(try fixture.cacheFiles().count == 1)
    }

    @Test func sourceMutationDuringColdImportDoesNotPublishStaleGeometry() async throws {
        let fixture = try CacheFixture()
        defer { fixture.remove() }

        do {
            _ = try await fixture.cache.loadOrImport(for: fixture.sourceURL) {
                let handle = try FileHandle(forWritingTo: fixture.sourceURL)
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: Data("mutated during import".utf8))
                try handle.close()
                return makeArchive()
            }
            Issue.record("Source mutation during cold import was cached")
        } catch StepPreviewCacheError.sourceChangedDuringStore {
            // Expected: the archive describes the pre-mutation source identity.
        } catch {
            Issue.record("Source mutation returned the wrong error: \(error)")
        }

        #expect(try fixture.cacheFiles().isEmpty)
    }

    @Test @MainActor
    func cacheLocationEvidenceIsStablePathFreeAndOffMain() async throws {
        let fixture = try CacheFixture()
        defer { fixture.remove() }
        let first = try await fixture.cache.locationEvidence()
        let second = try await fixture.cache.locationEvidence()
        let otherRoot = fixture.rootURL.appendingPathComponent("other-cache", isDirectory: true)
        let other = try await StepPreviewCache(rootURL: otherRoot).locationEvidence()
        let budgetResolution = await StepPreviewImportBudget.resolve(for: fixture.sourceURL)

        #expect(first.scope == .explicitRoot)
        #expect(first.identifierFingerprint == second.identifierFingerprint)
        #expect(first.identifierFingerprint.count == 16)
        #expect(first.identifierFingerprint != other.identifierFingerprint)
        #expect(!first.identifierFingerprint.contains(fixture.rootURL.path))
        #expect(first.workerThread)
        #expect(second.workerThread)
        #expect(other.workerThread)
        #expect(budgetResolution.workerThread)
    }

    @Test @MainActor
    func interactiveScenePlanPreparesMaterialLayoutOffMain() async throws {
        let model = try StepMeshArchive.decode(makeArchive())
        let plan = try await StepInteractiveScenePlan.prepare(model)

        #expect(plan.workerThread)
        #expect(plan.preparationMilliseconds >= 0)
        #expect(plan.materialLayouts.count == model.definitions.count)
        #expect(plan.materialLayouts[0].perFaceMaterialIndices.count == model.triangleCount)
        let inverseDiagonal = 1 / max(model.diagonal, 1.0e-6)
        #expect(
            plan.normalizedBoundsMin
                == (model.boundsMin - model.center) * inverseDiagonal
        )
        #expect(
            plan.normalizedBoundsMax
                == (model.boundsMax - model.center) * inverseDiagonal
        )
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

    @Test func ordinaryCacheHitSourceValidationHasBoundedReads() {
        let sourceBytes: UInt64 = 1_024 * 1_024 * 1_024
        let sampledBytes = StepCacheSourceIdentity.sampledByteCountUpperBound(
            for: sourceBytes
        )

        #expect(StepCacheSourceIdentity.sampleOffsets(for: sourceBytes).count == 3)
        #expect(sampledBytes <= 3 * StepCacheSourceIdentity.sampleByteCount)
        #expect(sampledBytes == 192 * 1_024)
        #expect(sampledBytes < sourceBytes)
    }

    @Test func unsampledSameSizeAndTimestampChangeInvalidatesCache() throws {
        let fixture = try CacheFixture()
        defer { fixture.remove() }
        let sourceBytes = 1_024 * 1_024
        try Data(repeating: 0x41, count: sourceBytes).write(to: fixture.sourceURL)
        _ = try fixture.cache.store(makeArchive(), for: fixture.sourceURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.sourceURL.path)
        let originalDate = try #require(attributes[.modificationDate] as? Date)

        let changedOffset: UInt64 = 256 * 1_024
        let sampledRanges = StepCacheSourceIdentity.sampleOffsets(
            for: UInt64(sourceBytes)
        ).map { $0..<min(UInt64(sourceBytes), $0 + StepCacheSourceIdentity.sampleByteCount) }
        #expect(!sampledRanges.contains(where: { $0.contains(changedOffset) }))
        let handle = try FileHandle(forWritingTo: fixture.sourceURL)
        try handle.seek(toOffset: changedOffset)
        try handle.write(contentsOf: Data([0x42]))
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: originalDate],
            ofItemAtPath: fixture.sourceURL.path
        )

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

    @Test func sharedPreviewBudgetHasStableTierBoundaries() throws {
        let small = StepPreviewImportBudget(fileSize: 10_000_000)
        let medium = StepPreviewImportBudget(fileSize: 10_000_001)
        let large = StepPreviewImportBudget(fileSize: 50_000_001)
        let extreme = StepPreviewImportBudget(fileSize: 200_000_001)

        #expect(small.sourceClass == .small && small.allowsColdImport)
        #expect(medium.sourceClass == .medium && medium.allowsColdImport)
        #expect(large.sourceClass == .large && large.allowsColdImport)
        #expect(extreme.sourceClass == .extreme && !extreme.allowsColdImport)
        #expect(small.cacheProfileIdentifier == "preview-refined-v4-small-750000")
        #expect(medium.cacheProfileIdentifier == "preview-refined-v4-medium-750000")
        #expect(large.cacheProfileIdentifier == "preview-refined-v4-large-750000")
        #expect(extreme.cacheProfileIdentifier == "preview-refined-v4-extreme-750000")
        #expect([small, medium, large, extreme].allSatisfy { $0.maximumTriangles == 750_000 })
        #expect(throws: StepPreviewImportBudgetError.self) {
            try extreme.checkColdImportAllowed()
        }
        try large.checkColdImportAllowed()
    }

    /// Every cold tier must reach a result or an actionable refusal inside the
    /// 15 s ceiling, including the import client's 1.5 s reply grace.
    @Test func everyColdImportTierFailsWithinFifteenSeconds() {
        let clientReplyGrace = 1.5
        for size in [1_000, 10_000_000, 10_000_001, 50_000_001, 200_000_000] {
            let budget = StepPreviewImportBudget(fileSize: UInt64(size))
            #expect(budget.seconds >= 10)
            #expect(budget.seconds + clientReplyGrace <= 15)
        }
    }

    /// A coarsened mesh must stay marked as such all the way from the archive
    /// header to the badge, including on every later cache hit.
    @Test func simplifiedTessellationSurvivesTheArchiveAndReachesTheBadge() throws {
        let exact = try StepMeshArchive.decode(makeArchive())
        #expect(exact.isSimplified == false)
        #expect(exact.simplifiedPreviewNotice(caliperInstalled: true) == nil)

        let simplified = try StepMeshArchive.decode(makeArchive(
            flags: StepMeshArchive.Flag.explicitLengthUnit
                | StepMeshArchive.Flag.simplified
        ))
        #expect(simplified.isSimplified)
        // Whether the badge names Caliper is covered by StepPreviewAdviceTests;
        // what matters here is that the flag survives the archive at all.
        let notice = try #require(
            simplified.simplifiedPreviewNotice(caliperInstalled: true)
        )
        #expect(notice.summary == "Simplified preview")
        #expect(notice.detail.contains("Caliper"))
        #expect(notice.accessibilityLabel.hasPrefix(notice.summary))

        // Flags the writer never sets are still rejected, so the header cannot
        // quietly acquire meaning a decoder does not understand.
        #expect(throws: StepMeshArchiveError.self) {
            try StepMeshArchive.decode(makeArchive(flags: 8))
        }
    }

    @Test func telemetryFailureCategoriesAreStableAndPathFree() {
        let importError = NSError(
            domain: "com.local.stepviewer.import",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "/private/customer/secret.step"]
        )
        #expect(StepTelemetryFailureCategory.label(for: importError) == "empty_geometry")
        #expect(
            StepTelemetryFailureCategory.label(
                for: StepImportClientError.unavailable
            ) == "service_unavailable"
        )
        #expect(
            StepTelemetryFailureCategory.label(
                for: StepPreviewImportBudgetError.compatibleCacheRequired
            ) == "resource_policy"
        )
        #expect(
            StepTelemetryFailureCategory.label(
                for: StepPreviewImportBudgetError.predictedCostExceedsBudget(
                    predictedSeconds: 41,
                    budgetSeconds: 13.5
                )
            ) == "predicted_cost_policy"
        )
        #expect(StepTelemetryFailureCategory.label(for: CancellationError()) == "cancelled")
        #expect(!StepTelemetryFailureCategory.label(for: importError).contains("secret"))
    }

    @Test func hostBundleEmbedsPreviewButNotThumbnailExtension() throws {
        let plugInsURL = try #require(Bundle.main.builtInPlugInsURL)
        let previewURL = plugInsURL.appendingPathComponent(
            "StepLookPreview.appex",
            isDirectory: true
        )
        let thumbnailURL = plugInsURL.appendingPathComponent(
            "StepLookThumbnail.appex",
            isDirectory: true
        )

        #expect(FileManager.default.fileExists(atPath: previewURL.path))
        #expect(!FileManager.default.fileExists(atPath: thumbnailURL.path))

        let previewBundle = try #require(Bundle(url: previewURL))
        let extensionDictionary = try #require(
            previewBundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any]
        )
        #expect(
            extensionDictionary["NSExtensionPointIdentifier"] as? String
                == "com.apple.quicklook.preview"
        )
    }

    @Test func appGroupIdentifierAcceptsMacAndProvisionedFormsOnly() {
        #expect(StepCacheLocation.isValidAppGroupIdentifier("ABCDE12345.com.example.LookSTEP"))
        #expect(StepCacheLocation.isValidAppGroupIdentifier("group.com.example.LookSTEP"))
        #expect(!StepCacheLocation.isValidAppGroupIdentifier("com.example.LookSTEP"))
        #expect(!StepCacheLocation.isValidAppGroupIdentifier("$(DEVELOPMENT_TEAM).LookSTEP"))
        #expect(!StepCacheLocation.isValidAppGroupIdentifier("ABCDE12345 bad"))
    }

    @Test func cacheEvictsLeastRecentlyUsedEntriesWhenSizeLimitIsExceeded() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StepLookTests-\(UUID().uuidString)", isDirectory: true)
        let cacheRootURL = rootURL.appendingPathComponent("cache", isDirectory: true)
        let firstSource = rootURL.appendingPathComponent("first.step")
        let secondSource = rootURL.appendingPathComponent("second.step")
        let archive = makeArchive()
        let unboundedCache = StepPreviewCache(
            rootURL: cacheRootURL,
            profileIdentifier: "eviction-test-v1"
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data("first source".utf8).write(to: firstSource)
        try Data("second source".utf8).write(to: secondSource)

        _ = try unboundedCache.store(archive, for: firstSource)
        let firstCacheURL = try #require(
            FileManager.default.contentsOfDirectory(
                at: cacheRootURL,
                includingPropertiesForKeys: nil
            ).first
        )
        let firstSize = try #require(
            FileManager.default.attributesOfItem(atPath: firstCacheURL.path)[.size] as? NSNumber
        ).uint64Value
        let cache = StepPreviewCache(
            rootURL: cacheRootURL,
            profileIdentifier: "eviction-test-v1",
            maximumBytes: firstSize + firstSize / 2
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
        replaceUInt64(in: &invalidTiming, at: 64, with: Double.nan.bitPattern)
        #expect(throws: StepMeshArchiveError.self) {
            try StepMeshArchive.decode(invalidTiming)
        }

        var invalidDefinitionBounds = valid
        replaceUInt32(in: &invalidDefinitionBounds, at: 115, with: Float.nan.bitPattern)
        #expect(throws: StepMeshArchiveError.self) {
            try StepMeshArchive.decode(invalidDefinitionBounds)
        }

        var excessiveIndexCount = valid
        replaceUInt32(in: &excessiveIndexCount, at: 107, with: UInt32.max)
        #expect(throws: StepMeshArchiveError.self) {
            try StepMeshArchive.decode(excessiveIndexCount)
        }

        var invalidColorEncoding = valid
        replaceUInt32(in: &invalidColorEncoding, at: 36, with: UInt32.max)
        #expect(throws: StepMeshArchiveError.self) {
            try StepMeshArchive.decode(invalidColorEncoding)
        }

        var noncontiguousMaterialGroup = valid
        replaceUInt32(in: &noncontiguousMaterialGroup, at: 223, with: 3)
        #expect(throws: StepMeshArchiveError.self) {
            try StepMeshArchive.decode(noncontiguousMaterialGroup)
        }

        var invalidMaterialColor = valid
        replaceUInt32(in: &invalidMaterialColor, at: 235, with: Float.nan.bitPattern)
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

    @Test func incompleteGeometryUsesVisibleAccessibleProductionNotice() throws {
        let completeModel = try StepMeshArchive.decode(makeArchive())
        #expect(completeModel.incompleteGeometryNotice == nil)

        var incompleteArchive = makeArchive()
        replaceUInt32(in: &incompleteArchive, at: 32, with: 1)
        let incompleteModel = try StepMeshArchive.decode(incompleteArchive)
        let notice = try #require(incompleteModel.incompleteGeometryNotice)

        #expect(notice.summary == "1 face couldn’t be shown")
        #expect(notice.detail.contains("preview is incomplete"))
        #expect(notice.accessibilityLabel.contains(notice.summary))
        #expect(notice.accessibilityLabel.contains(notice.detail))
    }

    @Test func visibleViewerStatesUseStableAccessibleProductionStatuses() {
        let empty = StepAccessibilityStatus.empty(
            detail: "Drop a .step or .stp file here, or choose one."
        )
        #expect(empty.identifier == "lookstep.status.empty")
        #expect(empty.label == "No STEP model open")
        #expect(empty.value.contains(".step"))

        let loading = StepAccessibilityStatus.loading(
            phase: "Preparing model…",
            fileName: "gear.step"
        )
        #expect(loading.identifier == "lookstep.status.loading")
        #expect(loading.label == "Opening STEP model")
        #expect(loading.value == "Preparing model…, gear.step")

        let failure = StepAccessibilityStatus.failure(
            title: "Can’t open this STEP file",
            message: "The file is damaged."
        )
        #expect(failure.identifier == "lookstep.status.failure")
        #expect(failure.label == "Can’t open this STEP file")
        #expect(failure.value == "The file is damaged.")
    }
}

private final class TimeoutLifetimeProbe: @unchecked Sendable {}

private func makeTimeoutLifetimeFixture() -> (StepImportClientTimeout, TimeoutWeakProbe) {
    let probe = TimeoutLifetimeProbe()
    let weakProbe = TimeoutWeakProbe(probe)
    let timeout = StepImportClientTimeout(after: 60) {
        _ = probe
    }
    return (timeout, weakProbe)
}

private final class TimeoutWeakProbe: @unchecked Sendable {
    weak var value: TimeoutLifetimeProbe?

    init(_ value: TimeoutLifetimeProbe) {
        self.value = value
    }
}

private final class ConnectionTeardownInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private func makeConnectionTeardownLifetimeFixture() -> (
    teardown: StepImportClientConnectionTeardown,
    weakProbe: TimeoutWeakProbe,
    counter: ConnectionTeardownInvocationCounter
) {
    let probe = TimeoutLifetimeProbe()
    let weakProbe = TimeoutWeakProbe(probe)
    let counter = ConnectionTeardownInvocationCounter()
    let teardown = StepImportClientConnectionTeardown {
        counter.increment()
        _ = probe
    }
    return (teardown, weakProbe, counter)
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
        return try cacheFiles().first
    }

    func cacheFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: cacheRootURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "stlc" }
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private actor CacheImportCounter {
    private let archive: Data
    private(set) var invocationCount = 0

    init(archive: Data) {
        self.archive = archive
    }

    func importArchive() async throws -> Data {
        invocationCount += 1
        // Hold the winner long enough for the second cache instance to miss
        // and contend on the same process-shared flock path.
        try await Task.sleep(nanoseconds: 150_000_000)
        return archive
    }
}

private func makeArchive(flags: UInt32 = StepMeshArchive.Flag.explicitLengthUnit) -> Data {
    var data = Data("STLK".utf8)
    appendUInt32(StepMeshArchive.version, to: &data)
    appendUInt32(flags, to: &data)
    appendUInt32(1, to: &data) // definitions
    appendUInt32(1, to: &data) // occurrences
    appendUInt32(1, to: &data) // hierarchy nodes
    appendUInt32(1, to: &data) // displayed triangles
    appendUInt32(1, to: &data) // faces
    appendUInt32(0, to: &data) // missing faces
    appendUInt32(StepColorEncoding.linearSRGB.rawValue, to: &data)
    appendVector(SIMD3(0, 0, 0), to: &data)
    appendVector(SIMD3(1, 1, 0), to: &data)
    appendDouble(0.01, to: &data)
    appendDouble(0.02, to: &data)
    appendDouble(0.001, to: &data) // millimeters to meters

    appendString("d:1", to: &data)
    appendString("Part", to: &data)
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

    appendUInt32(0, to: &data) // hierarchy node index
    appendUInt32(0, to: &data) // definition index
    appendUInt32(1, to: &data) // occurrence/part color
    for value: Float in [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0] {
        appendUInt32(value.bitPattern, to: &data)
    }
    for value: Float in [0.1, 0.2, 0.3, 1] {
        appendUInt32(value.bitPattern, to: &data)
    }

    appendString("n:1", to: &data)
    appendString("Part", to: &data)
    appendUInt32(UInt32.max, to: &data) // root has no parent
    appendUInt32(0, to: &data) // definition index
    appendUInt32(0, to: &data) // leaf node
    for value: Float in [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0] {
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

private func appendString(_ value: String, to data: inout Data) {
    let bytes = Data(value.utf8)
    appendUInt32(UInt32(bytes.count), to: &data)
    data.append(bytes)
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
