import Darwin
import Foundation

/// Counts the STEP entity keywords that predict import cost, tolerating any
/// chunk boundary.
///
/// The counter is deliberately byte-oriented rather than a parser. It never
/// decodes text, allocates per entity, or interprets the file, so it runs at
/// roughly disk speed and cannot fail on a malformed source.
nonisolated struct StepEntityCounter: Sendable {
    private static let advancedFace = Array("ADVANCED_FACE".utf8)
    private static let bSplineSurface = Array("B_SPLINE_SURFACE".utf8)
    /// Enough trailing bytes to complete the longest token across a boundary.
    private static let carryCapacity = max(advancedFace.count, bSplineSurface.count) - 1

    private(set) var advancedFaceCount = 0
    private(set) var bSplineSurfaceCount = 0
    private var carry: [UInt8] = []

    init() {}

    mutating func consume(_ data: Data) {
        data.withUnsafeBytes { consume($0) }
    }

    mutating func consume(_ chunk: UnsafeRawBufferPointer) {
        guard !chunk.isEmpty else { return }
        // Two separate regions, so no byte is ever examined twice:
        //   1. a boundary buffer only long enough to complete a token that was
        //      cut in half by the previous chunk, counted only when the match
        //      actually reaches into the new bytes, and
        //   2. the new chunk itself, scanned by memmem.
        // Doing the whole thing in a Swift byte loop instead runs at roughly
        // 13 MB/s unoptimized, which would cost more than it saves.
        countAcrossBoundary(chunk)
        advancedFaceCount += Self.count(Self.advancedFace, in: chunk)
        bSplineSurfaceCount += Self.count(Self.bSplineSurface, in: chunk)
        updateCarry(with: chunk)
    }

    private mutating func countAcrossBoundary(_ chunk: UnsafeRawBufferPointer) {
        guard !carry.isEmpty else { return }
        var boundary = carry
        boundary.append(contentsOf: chunk.prefix(Self.carryCapacity)
            .bindMemory(to: UInt8.self))
        let carriedCount = carry.count
        advancedFaceCount += Self.countStraddling(
            Self.advancedFace, in: boundary, carriedCount: carriedCount)
        bSplineSurfaceCount += Self.countStraddling(
            Self.bSplineSurface, in: boundary, carriedCount: carriedCount)
    }

    private mutating func updateCarry(with chunk: UnsafeRawBufferPointer) {
        let tail = chunk.suffix(Self.carryCapacity).bindMemory(to: UInt8.self)
        if tail.count >= Self.carryCapacity {
            carry = Array(tail)
        } else {
            carry.append(contentsOf: tail)
            carry.removeFirst(max(0, carry.count - Self.carryCapacity))
        }
    }

    /// Counts only matches that begin in the carried tail and end in the new
    /// bytes. A match wholly inside either side was already counted by the
    /// chunk it belongs to.
    private static func countStraddling(
        _ token: [UInt8],
        in boundary: [UInt8],
        carriedCount: Int
    ) -> Int {
        var total = 0
        var start = 0
        while start < carriedCount, start + token.count <= boundary.count {
            defer { start += 1 }
            guard start + token.count > carriedCount else { continue }
            var matched = true
            for offset in 0..<token.count where boundary[start + offset] != token[offset] {
                matched = false
                break
            }
            if matched { total += 1 }
        }
        return total
    }

    private static func count(
        _ token: [UInt8],
        in buffer: UnsafeRawBufferPointer
    ) -> Int {
        guard let rawBase = buffer.baseAddress, buffer.count >= token.count else {
            return 0
        }
        return token.withUnsafeBufferPointer { needle -> Int in
            guard let needleBase = needle.baseAddress else { return 0 }
            var total = 0
            var offset = 0
            while offset + token.count <= buffer.count {
                guard let hit = memmem(
                    rawBase + offset,
                    buffer.count - offset,
                    needleBase,
                    token.count
                ) else { break }
                total += 1
                // Neither token has a proper border, so occurrences cannot
                // overlap and advancing past this one cannot skip a match.
                offset = UnsafeRawPointer(hit) - rawBase + token.count
            }
            return total
        }
    }
}

/// The measured cost model behind LookSTEP's immediate-refusal gate.
///
/// File size is a weak predictor of STEP import cost: the local corpus spans a
/// 2.8x multiplicative error band on bytes alone. Counting `ADVANCED_FACE` and
/// `B_SPLINE_SURFACE` occurrences narrows that to 1.9x for a scan that costs
/// well under a tenth of a second even on the largest source measured.
///
/// Calibration, 2026-07-24, `StepMeshImporter` run over the licensed local
/// corpus at each source's own tier deflection. Columns are weighted entity
/// count and measured preparation seconds; no file name or path is recorded.
///
/// | Weighted entities | Measured | Predicted |
/// | ---: | ---: | ---: |
/// | 45 | 0.02 s | 0.04 s |
/// | 58 | 0.09 s | 0.05 s |
/// | 102 | 0.09 s | 0.09 s |
/// | 119 | 0.05 s | 0.10 s |
/// | 244 | 0.36 s | 0.21 s |
/// | 2,413 | 2.78 s | 2.10 s |
/// | 3,442 | 2.04 s | 3.00 s |
/// | 8,718 | 8.30 s | 7.59 s |
/// | 9,457 | 10.92 s | 8.23 s |
/// | 19,530 | 12.10 s | 17.00 s |
/// | 19,769 | 15.89 s | 17.21 s |
/// | 47,083 | 78.45 s | 40.98 s |
nonisolated enum StepSourceComplexityModel {
    /// Minimax fit over the corpus above. Both keywords carry the same weight;
    /// separating them did not improve the fit, because a B-spline surface is
    /// attached to a face that is already counted.
    static let millisecondsPerWeightedEntity = 0.8704

    /// How far past the budget a prediction must land before a source is
    /// refused without trying.
    ///
    /// The model's worst overestimate on the corpus is 1.47x, so a 2x gate
    /// cannot refuse a source that would in fact have finished. The asymmetry
    /// is intended: a wrong refusal costs the user a preview they could have
    /// had, while a wrong attempt costs at most the tier's own deadline.
    static let refusalMargin = 2.0

    static func predictedSeconds(weightedEntityCount: Int) -> Double {
        Double(max(0, weightedEntityCount)) * millisecondsPerWeightedEntity / 1_000
    }
}

/// One bounded streaming pass over a STEP source, taken before any OCCT work.
nonisolated struct StepSourceComplexityScan: Sendable {
    /// No cold-import tier admits a source this large — the extreme tier is
    /// cache-only above 200 MB — so a complete scan is always possible for any
    /// source that could actually be imported.
    static let maximumScanBytes: UInt64 = 256 * 1_024 * 1_024
    static let chunkBytes = 4 * 1_024 * 1_024

    let advancedFaceCount: Int
    let bSplineSurfaceCount: Int
    let sourceBytes: UInt64
    let scannedBytes: UInt64
    let scanSeconds: Double

    /// True when the source was larger than the scan ceiling and the counts are
    /// extrapolated from the portion actually read.
    var isExtrapolated: Bool {
        scannedBytes < sourceBytes
    }

    var weightedEntityCount: Int {
        let counted = advancedFaceCount + bSplineSurfaceCount
        guard isExtrapolated, scannedBytes > 0 else { return counted }
        let scale = Double(sourceBytes) / Double(scannedBytes)
        return Int((Double(counted) * scale).rounded())
    }

    var predictedColdImportSeconds: Double {
        StepSourceComplexityModel.predictedSeconds(
            weightedEntityCount: weightedEntityCount
        )
    }

    @concurrent
    static func scan(
        _ url: URL,
        maximumBytes: UInt64 = maximumScanBytes
    ) async throws -> Self {
        let started = ProcessInfo.processInfo.systemUptime
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let sourceBytes = (try? handle.seekToEnd()) ?? 0
        try handle.seek(toOffset: 0)

        var counter = StepEntityCounter()
        var scannedBytes: UInt64 = 0
        while scannedBytes < maximumBytes {
            try Task.checkCancellation()
            let remaining = maximumBytes - scannedBytes
            let request = Int(min(UInt64(chunkBytes), remaining))
            guard let chunk = try handle.read(upToCount: request), !chunk.isEmpty else {
                break
            }
            counter.consume(chunk)
            scannedBytes += UInt64(chunk.count)
        }

        return Self(
            advancedFaceCount: counter.advancedFaceCount,
            bSplineSurfaceCount: counter.bSplineSurfaceCount,
            sourceBytes: max(sourceBytes, scannedBytes),
            scannedBytes: scannedBytes,
            scanSeconds: ProcessInfo.processInfo.systemUptime - started
        )
    }
}
