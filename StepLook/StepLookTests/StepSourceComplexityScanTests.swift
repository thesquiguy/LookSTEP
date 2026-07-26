import Foundation
import Testing
@testable import LookSTEP

struct StepEntityCounterTests {
    private func counted(_ text: String, chunkSize: Int) -> (Int, Int) {
        var counter = StepEntityCounter()
        let bytes = Array(text.utf8)
        var index = 0
        while index < bytes.count {
            let end = min(index + chunkSize, bytes.count)
            counter.consume(Data(bytes[index..<end]))
            index = end
        }
        return (counter.advancedFaceCount, counter.bSplineSurfaceCount)
    }

    @Test func anEmptySourceCountsNothing() {
        var counter = StepEntityCounter()
        counter.consume(Data())
        #expect(counter.advancedFaceCount == 0)
        #expect(counter.bSplineSurfaceCount == 0)
    }

    @Test func bothKeywordsAreCountedInOnePass() {
        let text = """
        #12=ADVANCED_FACE('',(#13),#14,.T.);
        #15=B_SPLINE_SURFACE_WITH_KNOTS('',3,3,((#16)),.UNSPECIFIED.);
        #17=ADVANCED_FACE('',(#18),#19,.F.);
        """
        let (faces, surfaces) = counted(text, chunkSize: text.utf8.count)
        #expect(faces == 2)
        #expect(surfaces == 1)
    }

    /// The counter carries a tail between chunks. A token split at any offset
    /// must be counted exactly once, and one already counted must never be
    /// counted again when it reappears inside the carry.
    @Test func chunkBoundariesNeverDoubleCountOrDropAKeyword() {
        let text = """
        ADVANCED_FACE B_SPLINE_SURFACE ADVANCED_FACE xx ADVANCED_FACE\
        B_SPLINE_SURFACE_WITH_KNOTS
        """
        for chunkSize in 1...40 {
            let (faces, surfaces) = counted(text, chunkSize: chunkSize)
            #expect(faces == 3, "chunk size \(chunkSize) counted \(faces) faces")
            #expect(surfaces == 2, "chunk size \(chunkSize) counted \(surfaces) surfaces")
        }
    }

    @Test func adjacentAndOverlappingCandidatesAreNotConfused() {
        // A near-miss prefix, and a keyword immediately followed by another.
        let (faces, surfaces) = counted(
            "ADVANCED_FACADVANCED_FACEADVANCED_FACE B_SPLINE_SURFAC",
            chunkSize: 7
        )
        #expect(faces == 2)
        #expect(surfaces == 0)
    }
}

struct StepSourceComplexityModelTests {
    /// The corpus that calibrated the model, as weighted entity count against
    /// the measured `StepMeshImporter` preparation time. Privacy-safe: counts
    /// and seconds only, no name, path, or size.
    private static let corpus: [(entities: Int, measuredSeconds: Double)] = [
        (45, 0.021), (58, 0.089), (102, 0.093), (119, 0.054), (244, 0.360),
        (2_413, 2.781), (3_442, 2.039), (8_718, 8.295), (9_457, 10.918),
        (19_530, 12.099), (19_769, 15.895), (47_083, 78.452),
    ]

    @Test func thePredictionStaysWithinTheCalibratedErrorBand() {
        for row in Self.corpus {
            let predicted = StepSourceComplexityModel.predictedSeconds(
                weightedEntityCount: row.entities
            )
            let ratio = predicted / row.measuredSeconds
            #expect(
                ratio >= 0.5 && ratio <= 2.0,
                "\(row.entities) entities predicted \(predicted)s against \(row.measuredSeconds)s"
            )
        }
    }

    /// The gate exists to catch the sources that cannot possibly finish. It
    /// must fire on the extreme corpus row and on nothing that succeeded.
    @Test func onlyHopelessSourcesAreRefusedBeforeTrying() throws {
        let large = StepPreviewImportBudget(fileSize: 60_000_000)
        #expect(large.predictedCostRefusalSeconds == 27)

        // Every corpus row that completed inside its own tier's deadline.
        for entities in [45, 58, 102, 119, 244, 2_413, 3_442] {
            try StepPreviewImportBudget(fileSize: 5_000_000)
                .checkPredictedCostAllowed(scan(entities))
        }
        for entities in [8_718, 9_457] {
            try StepPreviewImportBudget(fileSize: 30_000_000)
                .checkPredictedCostAllowed(scan(entities))
        }
        for entities in [19_530, 19_769] {
            try large.checkPredictedCostAllowed(scan(entities))
        }

        // The 78 s source is refused outright rather than after 13.5 s.
        #expect(throws: StepPreviewImportBudgetError.self) {
            try large.checkPredictedCostAllowed(scan(47_083))
        }
    }

    @Test func aRefusalReportsWhatItPredictedAndWhatItAllowed() {
        let large = StepPreviewImportBudget(fileSize: 60_000_000)
        do {
            try large.checkPredictedCostAllowed(scan(47_083))
            Issue.record("the 47,083-entity source should have been refused")
        } catch let error as StepPreviewImportBudgetError {
            guard case .predictedCostExceedsBudget(let predicted, let budget) = error else {
                Issue.record("unexpected budget error \(error)")
                return
            }
            #expect(predicted > 27)
            #expect(budget == 13.5)
            #expect(error.errorDescription?.isEmpty == false)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func expensiveColdImportsStartCoarseBeforeThermalVarianceConsumesTheDeadline() {
        let small = StepPreviewColdImportPreflight(
            scan: scan(3_442),
            budgetSeconds: 10
        )
        let medium = StepPreviewColdImportPreflight(
            scan: scan(9_457),
            budgetSeconds: 12
        )
        let large = StepPreviewColdImportPreflight(
            scan: scan(19_530),
            budgetSeconds: 13.5
        )

        #expect(small.startingSimplificationLevel == 0)
        #expect(medium.startingSimplificationLevel == 2)
        #expect(large.startingSimplificationLevel == 2)
    }

    private func scan(_ entities: Int) -> StepSourceComplexityScan {
        StepSourceComplexityScan(
            advancedFaceCount: entities,
            bSplineSurfaceCount: 0,
            sourceBytes: 1_000,
            scannedBytes: 1_000,
            scanSeconds: 0
        )
    }
}

struct StepSourceComplexityScanTests {
    private func write(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("step")
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func aScanCountsTheWholeSource() async throws {
        let body = String(
            repeating: "#1=ADVANCED_FACE('',(#2),#3,.T.);\n#4=B_SPLINE_SURFACE_WITH_KNOTS();\n",
            count: 5_000
        )
        let url = try write("ISO-10303-21;\nHEADER;\nENDSEC;\nDATA;\n" + body + "ENDSEC;\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let scan = try await StepSourceComplexityScan.scan(url)
        #expect(scan.advancedFaceCount == 5_000)
        #expect(scan.bSplineSurfaceCount == 5_000)
        #expect(scan.isExtrapolated == false)
        #expect(scan.weightedEntityCount == 10_000)
        #expect(scan.scannedBytes == scan.sourceBytes)
    }

    @Test func aTruncatedScanExtrapolatesAndSaysSo() async throws {
        let body = String(repeating: "ADVANCED_FACE;\n", count: 4_000)
        let url = try write(body)
        defer { try? FileManager.default.removeItem(at: url) }

        let half = UInt64(body.utf8.count / 2)
        let scan = try await StepSourceComplexityScan.scan(url, maximumBytes: half)
        #expect(scan.isExtrapolated)
        #expect(scan.advancedFaceCount < 4_000)
        // Extrapolation recovers the true count to within a token's worth.
        #expect(abs(scan.weightedEntityCount - 4_000) <= 2)
    }

    /// The pre-scan only pays for itself if it is far cheaper than the import
    /// it is deciding about. A 20 MB source must scan in well under a second.
    @Test func theScanIsCheapEnoughToRunBeforeEveryColdImport() async throws {
        let line = "#1=ADVANCED_FACE('',(#2,#3,#4),#5,.T.);\n"
        let url = try write(String(repeating: line, count: 500_000))
        defer { try? FileManager.default.removeItem(at: url) }

        let scan = try await StepSourceComplexityScan.scan(url)
        #expect(scan.advancedFaceCount == 500_000)
        #expect(scan.sourceBytes > 19_000_000)
        // Measured at well under 0.08 s unoptimized; the bound leaves room for
        // a loaded machine while still failing if the memmem path regresses to
        // a Swift byte loop, which ran ~20x slower.
        #expect(scan.scanSeconds < 0.5)
    }

    @Test func anUnreadableSourceFailsOpenRatherThanRefusing() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("step")
        let budget = StepPreviewImportBudget(fileSize: 1_000_000)
        #expect(try await budget.preflightColdImport(for: missing) == nil)
    }
}
