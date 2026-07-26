import Foundation

nonisolated enum StepExecutionContext {
    static var isWorkerThread: Bool {
        !Thread.isMainThread
    }
}

nonisolated enum StepPreviewSourceClass: String, Sendable {
    case small
    case medium
    case large
    case extreme
}

nonisolated enum StepPreviewImportBudgetError: LocalizedError {
    case compatibleCacheRequired
    /// The pre-scan predicted a cold import well past this tier's deadline, so
    /// the refusal is delivered immediately instead of after the full window.
    case predictedCostExceedsBudget(predictedSeconds: Double, budgetSeconds: Double)

    /// What happened, with no advice attached.
    ///
    /// The advice clause is chosen at presentation time by `StepPreviewAdvice`,
    /// because whether Caliper may be named depends on whether it is installed.
    var baseMessage: String {
        switch self {
        case .compatibleCacheRequired:
            "This model is too large for a cold Finder preview."
        case .predictedCostExceedsBudget:
            "This model is too complex for a Finder preview."
        }
    }

    var fallbackClause: String? {
        "Try again after a compatible preview has been cached."
    }

    /// Deliberately excludes the Caliper clause: this string reaches logs and
    /// `NSError` bridging, where installation state is unknown.
    var errorDescription: String? {
        [baseMessage, fallbackClause].compactMap(\.self).joined(separator: " ")
    }
}

/// What the pre-scan learned about a source that is about to be cold-imported.
nonisolated struct StepPreviewColdImportPreflight: Sendable {
    let scan: StepSourceComplexityScan
    let budgetSeconds: Double

    var predictedSeconds: Double { scan.predictedColdImportSeconds }

    /// The tessellation tier the importer should start from.
    ///
    /// A source predicted to consume at least half its deadline at full quality
    /// starts at the coarsest supported Finder-preview tier rather than leaving
    /// no thermal or XPC headroom. On the local 35.5 MB colored model this cut
    /// shipping importer time from 17.48 s to 9.15 s and triangles from 207,346
    /// to 54,966 while retaining the same definition, occurrence, and incomplete
    /// face counts. The 61.8 MB assembly completes in 9.12 s with 252,541
    /// displayed triangles, where the intermediate tier repeatedly exhausted
    /// the bounded Finder deadline.
    var startingSimplificationLevel: Int {
        predictedSeconds >= budgetSeconds * 0.5 ? 2 : 0
    }
}

nonisolated struct StepPreviewImportBudgetResolution: Sendable {
    let budget: StepPreviewImportBudget
    let workerThread: Bool
}

/// One render-compatible preview profile shared by the host and Finder preview.
/// The time limit varies by tier, but every value that affects mesh output is in
/// `cacheProfileIdentifier` so either process can reuse the other process's entry.
nonisolated struct StepPreviewImportBudget: Sendable {
    let seconds: Double
    let maximumTriangles: Int
    let relativeDeflection: Double
    let minimumDeflection: Double
    let maximumDeflection: Double
    let cacheProfileIdentifier: String
    let sourceClass: StepPreviewSourceClass
    let allowsColdImport: Bool

    init(for url: URL) {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        self.init(fileSize: UInt64(max(0, bytes)))
    }

    @concurrent
    static func resolve(for url: URL) async -> StepPreviewImportBudgetResolution {
        StepPreviewImportBudgetResolution(
            budget: Self(for: url),
            workerThread: StepExecutionContext.isWorkerThread
        )
    }

    init(fileSize: UInt64) {
        maximumTriangles = 750_000
        switch fileSize {
        case ...10_000_000:
            seconds = 10
            relativeDeflection = 0.0008
            minimumDeflection = 0.02
            maximumDeflection = 0.2
            cacheProfileIdentifier = "preview-refined-v4-small-750000"
            sourceClass = .small
            allowsColdImport = true
        case ...50_000_000:
            // The client adds 1.5 s of reply grace, keeping the complete
            // failure path at the same hard 15 s ceiling as the large tier.
            seconds = 13.5
            relativeDeflection = 0.0012
            minimumDeflection = 0.03
            maximumDeflection = 0.3
            cacheProfileIdentifier = "preview-refined-v4-medium-750000"
            sourceClass = .medium
            allowsColdImport = true
        case ...200_000_000:
            // 13.5 s plus the client's 1.5 s reply grace lands exactly on the
            // 15 s ceiling this tier is required to fail gracefully within.
            seconds = 13.5
            relativeDeflection = 0.0032
            minimumDeflection = 0.08
            maximumDeflection = 0.8
            cacheProfileIdentifier = "preview-refined-v4-large-750000"
            sourceClass = .large
            allowsColdImport = true
        default:
            // Extreme sources only decode an existing compatible cache. This
            // makes the documented actionable fallback immediate instead of
            // spending 15–60 seconds cold-starting OCCT inside Finder flow.
            seconds = 2
            relativeDeflection = 0.0064
            minimumDeflection = 0.16
            maximumDeflection = 1.6
            cacheProfileIdentifier = "preview-refined-v4-extreme-750000"
            sourceClass = .extreme
            allowsColdImport = false
        }
    }

    func checkColdImportAllowed() throws {
        guard allowsColdImport else {
            throw StepPreviewImportBudgetError.compatibleCacheRequired
        }
    }

    /// The threshold a predicted cold import must cross to be refused outright.
    var predictedCostRefusalSeconds: Double {
        seconds * StepSourceComplexityModel.refusalMargin
    }

    func checkPredictedCostAllowed(_ scan: StepSourceComplexityScan) throws {
        let predicted = scan.predictedColdImportSeconds
        guard predicted > predictedCostRefusalSeconds else { return }
        throw StepPreviewImportBudgetError.predictedCostExceedsBudget(
            predictedSeconds: predicted,
            budgetSeconds: seconds
        )
    }

    /// Everything that must be true before OCCT is allowed to start.
    ///
    /// The tier gate runs first because it needs no I/O. The pre-scan runs
    /// second and fails open: if the source cannot be read here, the importer's
    /// own error is more accurate than a refusal invented from a failed read.
    @concurrent
    func preflightColdImport(
        for url: URL
    ) async throws -> StepPreviewColdImportPreflight? {
        try checkColdImportAllowed()
        guard let scan = try? await StepSourceComplexityScan.scan(url) else {
            return nil
        }
        try Task.checkCancellation()
        try checkPredictedCostAllowed(scan)
        return StepPreviewColdImportPreflight(scan: scan, budgetSeconds: seconds)
    }
}
