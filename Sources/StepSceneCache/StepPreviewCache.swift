import Compression
import CryptoKit
import Darwin
import Foundation

nonisolated enum StepPreviewCacheError: LocalizedError {
    case appGroupUnavailable(String)
    case sourceChangedDuringSnapshot
    case sourceChangedDuringLoad
    case sourceChangedDuringStore
    case unsupportedSource
    case cacheEntryTooLarge
    case damagedEnvelope
    case compressionFailed
    case coordinationFailed
    case fillLockFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            "The shared preview cache is not available in this build."
        case .sourceChangedDuringSnapshot:
            "The STEP file changed while its identity was being inspected."
        case .sourceChangedDuringLoad:
            "The STEP file changed while its cached preview was being read."
        case .sourceChangedDuringStore:
            "The STEP file changed while its preview was being cached."
        case .unsupportedSource:
            "The selected STEP source is not a regular file."
        case .cacheEntryTooLarge:
            "The cached preview exceeds LookSTEP’s safe decode limit."
        case .damagedEnvelope, .compressionFailed:
            "The cached preview is damaged and will be rebuilt."
        case .coordinationFailed:
            "The shared preview cache could not coordinate this operation."
        case .fillLockFailed:
            "The shared preview cache could not coordinate a cold import."
        }
    }
}

nonisolated enum StepPreviewCacheLoadSource: String, Sendable {
    case cache
    case coalesced
    case imported = "import"
}

nonisolated struct StepPreviewCacheLoadResult: Sendable {
    let model: StepMeshData
    let source: StepPreviewCacheLoadSource
}

nonisolated enum StepPreviewCacheStorageScope: String, Equatable, Sendable {
    case appGroup = "app_group"
    case explicitRoot = "explicit_root"
    case userCaches = "user_caches"
}

nonisolated struct StepPreviewCacheLocationEvidence: Sendable {
    let scope: StepPreviewCacheStorageScope
    let identifierFingerprint: String
    let workerThread: Bool
}

// The zero-byte lock file deliberately remains in the cache. Removing a flock
// path after unlock can split waiters across different inodes and permit two
// importers. The descriptor owns the lock; the file itself consumes no model
// cache budget and is ignored by pruning.
private nonisolated final class StepPreviewCacheFillLease: @unchecked Sendable {
    private let descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
    }
}

nonisolated struct StepPreviewCache {
    static let envelopeVersion: UInt32 = 2
    static let maximumDecodedArchiveBytes: UInt64 = 512 * 1_024 * 1_024
    static let maximumStoredEntryBytes: UInt64 = 512 * 1_024 * 1_024

    private let fileManager = FileManager.default
    private let rootURL: URL?
    private let appGroupIdentifier: String?
    private let profileIdentifier: String
    private let maximumBytes: UInt64

    private enum LoadFailureDisposition {
        case miss
        case evict
        case propagate
    }

    nonisolated init(
        rootURL: URL? = nil,
        appGroupIdentifier: String? = StepCacheLocation.configuredAppGroupIdentifier,
        profileIdentifier: String = "default-v1",
        maximumBytes: UInt64 = 512 * 1_024 * 1_024
    ) {
        self.rootURL = rootURL
        self.appGroupIdentifier = appGroupIdentifier
        self.profileIdentifier = profileIdentifier
        self.maximumBytes = maximumBytes
    }

    // The app and Finder Preview can compare this path-free value in unified
    // logs. A successful app-group result proves container resolution; the
    // fingerprint proves both processes used the same configured group without
    // disclosing the Team ID or container path.
    @concurrent
    nonisolated func locationEvidence() async throws -> StepPreviewCacheLocationEvidence {
        let workerThread = StepExecutionContext.isWorkerThread
        if let rootURL {
            let standardizedPath = rootURL.standardizedFileURL.path
            return StepPreviewCacheLocationEvidence(
                scope: .explicitRoot,
                identifierFingerprint: Self.fingerprint(standardizedPath),
                workerThread: workerThread
            )
        }
        if let appGroupIdentifier {
            _ = try cacheRootURL()
            return StepPreviewCacheLocationEvidence(
                scope: .appGroup,
                identifierFingerprint: Self.fingerprint(appGroupIdentifier),
                workerThread: workerThread
            )
        }
        _ = try cacheRootURL()
        return StepPreviewCacheLocationEvidence(
            scope: .userCaches,
            identifierFingerprint: "local",
            workerThread: workerThread
        )
    }

    nonisolated func load(for sourceURL: URL) throws -> StepMeshData? {
        try load(for: sourceURL, afterInitialSourceCapture: nil)
    }

    nonisolated private func load(
        for sourceURL: URL,
        afterInitialSourceCapture: (() -> Void)?
    ) throws -> StepMeshData? {
        let source = try StepCacheSourceIdentity.capture(sourceURL, fileManager: fileManager)
        afterInitialSourceCapture?()
        let url = try cacheURL(for: sourceURL, source: source)
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        do {
            let storedBytes = try fileManager.attributesOfItem(atPath: url.path)[.size]
            let storedByteCount = (storedBytes as? NSNumber)?.uint64Value ?? 0
            guard storedByteCount >= UInt64(StepCacheEnvelope.headerSize),
                  storedByteCount <= Self.maximumStoredEntryBytes else {
                throw StepPreviewCacheError.cacheEntryTooLarge
            }
#if STEP_CACHE_TESTING
            let entry = try Data(contentsOf: url, options: [.mappedIfSafe])
#else
            let entry = try coordinateRead(at: url) { coordinatedURL in
                try Data(contentsOf: coordinatedURL, options: [.mappedIfSafe])
            }
#endif
            let envelope = try StepCacheEnvelope.decode(
                entry,
                maximumArchiveBytes: Self.maximumDecodedArchiveBytes
            )
            let needsIdentityRefresh = !envelope.source.fastMatches(source)
            if needsIdentityRefresh {
                let currentDigest = try StepCacheSourceIdentity.fullContentDigest(
                    sourceURL, fileManager: fileManager)
                guard currentDigest == envelope.sourceContentDigest else {
                    throw StepPreviewCacheError.damagedEnvelope
                }
            }
            let decoded = try StepMeshArchive.decode(envelope.archive)
            let sourceAfterDecode = try StepCacheSourceIdentity.capture(
                sourceURL,
                fileManager: fileManager
            )
            guard source.fastMatches(sourceAfterDecode) else {
                throw StepPreviewCacheError.sourceChangedDuringLoad
            }
            if needsIdentityRefresh {
                try? refreshSourceIdentity(
                    in: entry,
                    at: url,
                    source: sourceAfterDecode
                )
            }
            try? coordinateWrite(at: url) { coordinatedURL in
                try fileManager.setAttributes(
                    [.modificationDate: Date()],
                    ofItemAtPath: coordinatedURL.path
                )
            }
            return decoded
        } catch {
            switch Self.loadFailureDisposition(for: error) {
            case .miss:
                return nil
            case .evict:
                try? coordinateWrite(at: url) { coordinatedURL in
                    if fileManager.fileExists(atPath: coordinatedURL.path) {
                        try fileManager.removeItem(at: coordinatedURL)
                    }
                }
                return nil
            case .propagate:
                throw error
            }
        }
    }

    private static func loadFailureDisposition(
        for error: Error
    ) -> LoadFailureDisposition {
        if error is StepMeshArchiveError {
            return .evict
        }
        if let cacheError = error as? StepPreviewCacheError {
            switch cacheError {
            case .cacheEntryTooLarge, .damagedEnvelope, .compressionFailed,
                 .sourceChangedDuringLoad:
                return .evict
            default:
                return .propagate
            }
        }
        let nsError = error as NSError
        if (nsError.domain == NSCocoaErrorDomain
                && nsError.code == NSFileNoSuchFileError)
            || (nsError.domain == NSPOSIXErrorDomain
                && nsError.code == Int(ENOENT)) {
            return .miss
        }
        return .propagate
    }

    nonisolated private func refreshSourceIdentity(
        in originalEntry: Data,
        at url: URL,
        source: StepCacheSourceIdentity
    ) throws {
        let refreshedEntry = try StepCacheEnvelope.replacingSourceIdentity(
            in: originalEntry,
            with: source
        )
        let replaceIfUnchanged: (URL) throws -> Void = { coordinatedURL in
            let handle = try FileHandle(forReadingFrom: coordinatedURL)
            defer { try? handle.close() }
            let currentHeader = try handle.read(upToCount: StepCacheEnvelope.headerSize)
            let currentSize = try handle.seekToEnd()
            guard currentSize == UInt64(originalEntry.count),
                  currentHeader == originalEntry.prefix(StepCacheEnvelope.headerSize) else {
                return
            }
            try refreshedEntry.write(to: coordinatedURL, options: [.atomic])
        }
#if STEP_CACHE_TESTING
        try replaceIfUnchanged(url)
#else
        try coordinateWrite(at: url, replaceIfUnchanged)
#endif
    }

#if STEP_CACHE_TESTING
    nonisolated func loadForTesting(
        for sourceURL: URL,
        afterInitialSourceCapture: @escaping () -> Void
    ) throws -> StepMeshData? {
        try load(
            for: sourceURL,
            afterInitialSourceCapture: afterInitialSourceCapture
        )
    }

    nonisolated func cacheURLForTesting(
        for sourceURL: URL,
        source: StepCacheSourceIdentity
    ) throws -> URL {
        try cacheURL(for: sourceURL, source: source)
    }
#endif

    nonisolated func store(
        _ archive: Data,
        for sourceURL: URL,
        expectedSource: StepCacheSourceIdentity? = nil
    ) throws -> StepMeshData {
        guard UInt64(archive.count) <= Self.maximumDecodedArchiveBytes else {
            throw StepPreviewCacheError.cacheEntryTooLarge
        }
        let sourceBeforeHash = try StepCacheSourceIdentity.capture(
            sourceURL, fileManager: fileManager)
        if let expectedSource, !expectedSource.fastMatches(sourceBeforeHash) {
            throw StepPreviewCacheError.sourceChangedDuringStore
        }
        let decoded = try StepMeshArchive.decode(archive)
        let sourceContentDigest = try StepCacheSourceIdentity.fullContentDigest(
            sourceURL, fileManager: fileManager)
        let sourceAfterHash = try StepCacheSourceIdentity.capture(
            sourceURL, fileManager: fileManager)
        guard sourceBeforeHash.fastMatches(sourceAfterHash) else {
            throw StepPreviewCacheError.sourceChangedDuringStore
        }

        let entry = try StepCacheEnvelope.encode(
            archive: archive,
            source: sourceAfterHash,
            sourceContentDigest: sourceContentDigest
        )
        guard UInt64(entry.count) <= Self.maximumStoredEntryBytes else {
            throw StepPreviewCacheError.cacheEntryTooLarge
        }
        let destination = try cacheURL(for: sourceURL, source: sourceAfterHash)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try coordinateWrite(at: destination) { coordinatedURL in
            try entry.write(to: coordinatedURL, options: [.atomic])
        }
        pruneIfNeeded(in: destination.deletingLastPathComponent(), preserving: destination)
        return decoded
    }

    // A cache miss is serialized by source identity across the host, Preview,
    // and Thumbnail processes. The winner imports and atomically publishes;
    // waiters re-check the cache and reuse that archive instead of invoking
    // OCCT/XPC again. The lock wait is cancellation-aware and never blocks the
    // main thread.
    @concurrent
    nonisolated func loadOrImport(
        for sourceURL: URL,
        importer: @Sendable () async throws -> Data
    ) async throws -> StepPreviewCacheLoadResult {
        if let cached = try load(for: sourceURL) {
            return StepPreviewCacheLoadResult(model: cached, source: .cache)
        }

        let lockURL = try fillLockURL(for: sourceURL)
        let lease = try await acquireFillLease(at: lockURL)
        try Task.checkCancellation()

        if let coalesced = try load(for: sourceURL) {
            withExtendedLifetime(lease) {}
            return StepPreviewCacheLoadResult(model: coalesced, source: .coalesced)
        }

        let sourceBeforeImport = try StepCacheSourceIdentity.capture(
            sourceURL,
            fileManager: fileManager
        )
        let archive = try await importer()
        try Task.checkCancellation()
        let imported = try store(
            archive,
            for: sourceURL,
            expectedSource: sourceBeforeImport
        )
        withExtendedLifetime(lease) {}
        return StepPreviewCacheLoadResult(model: imported, source: .imported)
    }

    nonisolated private func cacheURL(
        for sourceURL: URL,
        source: StepCacheSourceIdentity
    ) throws -> URL {
        let fingerprint = [
            sourceURL.standardizedFileURL.path,
            String(source.fileNumber),
            String(Self.envelopeVersion),
            String(StepMeshArchive.version),
            StepMeshArchive.importerCompatibility,
            profileIdentifier,
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(fingerprint.utf8)).hexString
        return try cacheRootURL()
            .appendingPathComponent(digest)
            .appendingPathExtension("stlc")
    }

    nonisolated private static func fingerprint(_ value: String) -> String {
        String(SHA256.hash(data: Data(value.utf8)).hexString.prefix(16))
    }

    nonisolated private func fillLockURL(for sourceURL: URL) throws -> URL {
        let source = try StepCacheSourceIdentity.capture(sourceURL, fileManager: fileManager)
        let entryURL = try cacheURL(for: sourceURL, source: source)
        return entryURL.deletingPathExtension().appendingPathExtension("lock")
    }

    nonisolated private func acquireFillLease(
        at lockURL: URL
    ) async throws -> StepPreviewCacheFillLease {
        try fileManager.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw StepPreviewCacheError.fillLockFailed(errno)
        }

        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let lockError = errno
            guard lockError == EWOULDBLOCK || lockError == EAGAIN else {
                _ = Darwin.close(descriptor)
                throw StepPreviewCacheError.fillLockFailed(lockError)
            }
            do {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 20_000_000)
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }
        }
        return StepPreviewCacheFillLease(descriptor: descriptor)
    }

    nonisolated private func cacheRootURL() throws -> URL {
        if let rootURL { return rootURL }
        if let appGroupIdentifier {
            guard let groupURL = fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupIdentifier
            ) else {
                throw StepPreviewCacheError.appGroupUnavailable(appGroupIdentifier)
            }
            return groupURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent("LookSTEP", isDirectory: true)
                .appendingPathComponent("PreviewCache", isDirectory: true)
        }
        return fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LookSTEP", isDirectory: true)
            .appendingPathComponent("PreviewCache", isDirectory: true)
    }

    nonisolated private func pruneIfNeeded(in directory: URL, preserving newestURL: URL) {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey, .fileSizeKey, .isRegularFileKey,
        ]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        var entries: [(url: URL, size: UInt64, date: Date)] = []
        var totalBytes: UInt64 = 0
        for url in urls where url.pathExtension == "stlc" {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            let size = UInt64(max(0, values.fileSize ?? 0))
            let (sum, overflow) = totalBytes.addingReportingOverflow(size)
            totalBytes = overflow ? UInt64.max : sum
            entries.append((url, size, values.contentModificationDate ?? .distantPast))
        }

        for entry in entries.sorted(by: { $0.date < $1.date }) {
            guard totalBytes > maximumBytes else { break }
            guard entry.url.standardizedFileURL.path != newestURL.standardizedFileURL.path else {
                continue
            }
            let removed = (try? coordinateWrite(at: entry.url) { coordinatedURL in
                try fileManager.removeItem(at: coordinatedURL)
            }) != nil
            guard removed else { continue }
            totalBytes = totalBytes >= entry.size ? totalBytes - entry.size : 0
        }
    }

    nonisolated private func coordinateRead<T>(
        at url: URL,
        _ operation: (URL) throws -> T
    ) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) {
            coordinatedURL in
            result = Result { try operation(coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw StepPreviewCacheError.coordinationFailed }
        return try result.get()
    }

    nonisolated private func coordinateWrite<T>(
        at url: URL,
        _ operation: (URL) throws -> T
    ) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) {
            coordinatedURL in
            result = Result { try operation(coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw StepPreviewCacheError.coordinationFailed }
        return try result.get()
    }
}

nonisolated enum StepCacheLocation {
    static var configuredAppGroupIdentifier: String? {
        guard let value = Bundle.main.object(
            forInfoDictionaryKey: "StepLookCacheAppGroupIdentifier"
        ) as? String,
        isValidAppGroupIdentifier(value) else {
            return nil
        }
        return value
    }

    static func isValidAppGroupIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, !value.contains("$("),
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).contains($0)
              }) else {
            return false
        }
        if value.hasPrefix("group.") {
            return value.split(separator: ".").count >= 3
        }
        guard let firstDot = value.firstIndex(of: ".") else { return false }
        let teamIdentifier = value[..<firstDot]
        return teamIdentifier.count == 10 && teamIdentifier.allSatisfy {
            $0.isNumber || ($0.isLetter && $0.isUppercase)
        }
    }
}

nonisolated struct StepCacheSourceIdentity: Sendable {
    static let digestByteCount = SHA256.Digest.byteCount
    static let sampleByteCount: UInt64 = 64 * 1_024

    let size: UInt64
    let modifiedBitPattern: UInt64
    let fileNumber: UInt64
    let generationDigest: Data
    let sampleDigest: Data

    func fastMatches(_ other: Self) -> Bool {
        size == other.size
            && modifiedBitPattern == other.modifiedBitPattern
            && fileNumber == other.fileNumber
            && generationDigest == other.generationDigest
            && sampleDigest == other.sampleDigest
    }

    static func capture(_ url: URL, fileManager: FileManager) throws -> Self {
        try capture(
            url,
            fileManager: fileManager,
            afterDescriptorInspection: nil
        )
    }

    private static func capture(
        _ url: URL,
        fileManager: FileManager,
        afterDescriptorInspection: (() -> Void)?
    ) throws -> Self {
        _ = fileManager
        let (fileStatus, captured) = try withStableDescriptor(
            url,
            afterDescriptorInspection: afterDescriptorInspection
        ) { descriptor, status in
            (
                try url.resourceValues(forKeys: [.generationIdentifierKey]),
                try sampledContentDigest(
                    descriptor: descriptor,
                    size: UInt64(status.st_size)
                )
            )
        }
        let values = captured.0
        let sampleDigest = captured.1
        let size = UInt64(fileStatus.st_size)

        var generationMetadata = Data()
        var device = Int64(fileStatus.st_dev).littleEndian
        withUnsafeBytes(of: &device) {
            generationMetadata.append(contentsOf: $0)
        }
        var changeSeconds = Int64(fileStatus.st_ctimespec.tv_sec).littleEndian
        var changeNanoseconds = Int64(fileStatus.st_ctimespec.tv_nsec).littleEndian
        withUnsafeBytes(of: &changeSeconds) {
            generationMetadata.append(contentsOf: $0)
        }
        withUnsafeBytes(of: &changeNanoseconds) {
            generationMetadata.append(contentsOf: $0)
        }
        if let generation = values.generationIdentifier,
           let archived = try? NSKeyedArchiver.archivedData(
               withRootObject: generation,
               requiringSecureCoding: true
           ) {
            generationMetadata.append(archived)
        }
        // ctime changes when file content or metadata changes and cannot be
        // restored with ordinary file APIs. Pair it with the platform
        // generation identifier when available, then retain bounded content
        // sampling as a defense against metadata anomalies.
        let generationDigest = Data(SHA256.hash(data: generationMetadata))
        let modified = Double(fileStatus.st_mtimespec.tv_sec)
            + Double(fileStatus.st_mtimespec.tv_nsec) / 1_000_000_000
        return Self(
            size: size,
            modifiedBitPattern: modified.bitPattern,
            fileNumber: UInt64(fileStatus.st_ino),
            generationDigest: generationDigest,
            sampleDigest: sampleDigest
        )
    }

    private static func withStableDescriptor<T>(
        _ url: URL,
        afterDescriptorInspection: (() -> Void)?,
        operation: (Int32, stat) throws -> T
    ) throws -> (stat, T) {
        for _ in 0..<3 {
            if let result = try stableDescriptorAttempt(
                url,
                afterDescriptorInspection: afterDescriptorInspection,
                operation: operation
            ) {
                return result
            }
        }
        throw StepPreviewCacheError.sourceChangedDuringSnapshot
    }

    private static func stableDescriptorAttempt<T>(
        _ url: URL,
        afterDescriptorInspection: (() -> Void)?,
        operation: (Int32, stat) throws -> T
    ) throws -> (stat, T)? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { _ = Darwin.close(descriptor) }
        var fileStatus = stat()
        guard Darwin.fstat(descriptor, &fileStatus) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard fileStatus.st_mode & S_IFMT == S_IFREG,
              fileStatus.st_size >= 0 else {
            throw StepPreviewCacheError.unsupportedSource
        }

        afterDescriptorInspection?()
        let value = try operation(descriptor, fileStatus)
        var descriptorAfterRead = stat()
        guard Darwin.fstat(descriptor, &descriptorAfterRead) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var pathAfterRead = stat()
        let pathStatus = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.fstatat(AT_FDCWD, path, &pathAfterRead, 0)
        }
        guard pathStatus == 0,
              sameFileVersion(fileStatus, descriptorAfterRead),
              sameFileVersion(fileStatus, pathAfterRead) else {
            return nil
        }
        return (fileStatus, value)
    }

    private static func sameFileVersion(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev
            && first.st_ino == second.st_ino
            && first.st_mode == second.st_mode
            && first.st_size == second.st_size
            && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
            && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
            && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
            && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }

#if STEP_CACHE_TESTING
    static func captureForTesting(
        _ url: URL,
        fileManager: FileManager,
        afterDescriptorInspection: @escaping () -> Void
    ) throws -> Self {
        try capture(
            url,
            fileManager: fileManager,
            afterDescriptorInspection: afterDescriptorInspection
        )
    }
#endif

    static func fullContentDigest(_ url: URL, fileManager: FileManager) throws -> Data {
        try fullContentDigest(
            url,
            fileManager: fileManager,
            afterDescriptorOpen: nil
        )
    }

    private static func fullContentDigest(
        _ url: URL,
        fileManager: FileManager,
        afterDescriptorOpen: (() -> Void)?
    ) throws -> Data {
        _ = fileManager
        let (_, digest) = try withStableDescriptor(
            url,
            afterDescriptorInspection: afterDescriptorOpen
        ) { descriptor, _ in
            let handle = FileHandle(
                fileDescriptor: descriptor,
                closeOnDealloc: false
            )
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1_048_576),
                  !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return Data(hasher.finalize())
        }
        return digest
    }

#if STEP_CACHE_TESTING
    static func fullContentDigestForTesting(
        _ url: URL,
        fileManager: FileManager,
        afterDescriptorOpen: @escaping () -> Void
    ) throws -> Data {
        try fullContentDigest(
            url,
            fileManager: fileManager,
            afterDescriptorOpen: afterDescriptorOpen
        )
    }
#endif

    static func sampleOffsets(for size: UInt64) -> [UInt64] {
        let middle = size > sampleByteCount
            ? size / 2 - min(size / 2, sampleByteCount / 2) : 0
        let tail = size > sampleByteCount ? size - sampleByteCount : 0
        return Array(Set([UInt64(0), middle, tail])).sorted()
    }

    static func sampledByteCountUpperBound(for size: UInt64) -> UInt64 {
        sampleOffsets(for: size).reduce(0) { total, offset in
            total + min(sampleByteCount, size - offset)
        }
    }

    private static func sampledContentDigest(
        descriptor: Int32,
        size: UInt64
    ) throws -> Data {
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var hasher = SHA256()
        for offset in sampleOffsets(for: size) {
            try handle.seek(toOffset: offset)
            var littleOffset = offset.littleEndian
            withUnsafeBytes(of: &littleOffset) { hasher.update(bufferPointer: $0) }
            if let chunk = try handle.read(upToCount: Int(sampleByteCount)), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        }
        return Data(hasher.finalize())
    }
}

nonisolated struct StepCacheEnvelope {
    enum Codec: UInt32 {
        case uncompressed = 0
        case lzfse = 1
    }

    static let magic = Data([0x53, 0x54, 0x4c, 0x43]) // STLC
    static let headerSize = 184
    private static let sourceIdentityOffset = 32

    let archive: Data
    let source: StepCacheSourceIdentity
    let sourceContentDigest: Data

    static func encode(
        archive: Data,
        source: StepCacheSourceIdentity,
        sourceContentDigest: Data
    ) throws -> Data {
        let compressed = try LZFSE.compress(archive)
        let shouldCompress = compressed.map { $0.count < archive.count } ?? false
        let codec: Codec = shouldCompress ? .lzfse : .uncompressed
        let payload = shouldCompress ? (compressed ?? archive) : archive
        var result = Data()
        result.reserveCapacity(headerSize + payload.count)
        result.append(magic)
        result.appendLittleEndian(StepPreviewCache.envelopeVersion)
        result.appendLittleEndian(codec.rawValue)
        result.appendLittleEndian(UInt32(0))
        result.appendLittleEndian(UInt64(archive.count))
        result.appendLittleEndian(UInt64(payload.count))
        result.appendLittleEndian(source.size)
        result.appendLittleEndian(source.modifiedBitPattern)
        result.appendLittleEndian(source.fileNumber)
        result.append(source.generationDigest)
        result.append(source.sampleDigest)
        result.append(sourceContentDigest)
        result.append(Data(SHA256.hash(data: archive)))
        result.append(payload)
        return result
    }

    static func decode(_ data: Data, maximumArchiveBytes: UInt64) throws -> Self {
        guard data.count >= headerSize, data.prefix(4) == magic else {
            throw StepPreviewCacheError.damagedEnvelope
        }
        var reader = StepCacheEnvelopeReader(data: data, offset: 4)
        guard try reader.readUInt32() == StepPreviewCache.envelopeVersion,
              let codec = Codec(rawValue: try reader.readUInt32()) else {
            throw StepPreviewCacheError.damagedEnvelope
        }
        guard try reader.readUInt32() == 0 else {
            throw StepPreviewCacheError.damagedEnvelope
        }
        let archiveBytes = try reader.readUInt64()
        let payloadBytes = try reader.readUInt64()
        guard archiveBytes > 0, archiveBytes <= maximumArchiveBytes,
              payloadBytes > 0, payloadBytes <= StepPreviewCache.maximumStoredEntryBytes,
              archiveBytes <= UInt64(Int.max), payloadBytes <= UInt64(Int.max) else {
            throw StepPreviewCacheError.cacheEntryTooLarge
        }
        let sourceSize = try reader.readUInt64()
        let modifiedBitPattern = try reader.readUInt64()
        let fileNumber = try reader.readUInt64()
        let generationDigest = try reader.readData(count: StepCacheSourceIdentity.digestByteCount)
        let sampleDigest = try reader.readData(count: StepCacheSourceIdentity.digestByteCount)
        let sourceContentDigest = try reader.readData(count: StepCacheSourceIdentity.digestByteCount)
        let archiveDigest = try reader.readData(count: StepCacheSourceIdentity.digestByteCount)
        guard reader.offset == headerSize,
              Int(payloadBytes) <= data.count - reader.offset,
              reader.offset + Int(payloadBytes) == data.count else {
            throw StepPreviewCacheError.damagedEnvelope
        }
        let payload = data.subdata(in: reader.offset..<data.count)
        let archive: Data
        switch codec {
        case .uncompressed:
            guard payloadBytes == archiveBytes else {
                throw StepPreviewCacheError.damagedEnvelope
            }
            archive = payload
        case .lzfse:
            archive = try LZFSE.decompress(payload, expectedByteCount: Int(archiveBytes))
        }
        guard Data(SHA256.hash(data: archive)) == archiveDigest else {
            throw StepPreviewCacheError.damagedEnvelope
        }
        return Self(
            archive: archive,
            source: StepCacheSourceIdentity(
                size: sourceSize,
                modifiedBitPattern: modifiedBitPattern,
                fileNumber: fileNumber,
                generationDigest: generationDigest,
                sampleDigest: sampleDigest
            ),
            sourceContentDigest: sourceContentDigest
        )
    }

    static func replacingSourceIdentity(
        in entry: Data,
        with source: StepCacheSourceIdentity
    ) throws -> Data {
        guard entry.count >= headerSize,
              entry.prefix(magic.count) == magic,
              source.generationDigest.count == StepCacheSourceIdentity.digestByteCount,
              source.sampleDigest.count == StepCacheSourceIdentity.digestByteCount else {
            throw StepPreviewCacheError.damagedEnvelope
        }
        var refreshed = entry
        var offset = sourceIdentityOffset
        refreshed.replaceLittleEndian(source.size, at: &offset)
        refreshed.replaceLittleEndian(source.modifiedBitPattern, at: &offset)
        refreshed.replaceLittleEndian(source.fileNumber, at: &offset)
        refreshed.replaceSubrange(
            offset..<(offset + source.generationDigest.count),
            with: source.generationDigest
        )
        offset += source.generationDigest.count
        refreshed.replaceSubrange(
            offset..<(offset + source.sampleDigest.count),
            with: source.sampleDigest
        )
        return refreshed
    }
}

private nonisolated enum LZFSE {
    static func compress(_ data: Data) throws -> Data? {
        let (capacity, overflow) = data.count.addingReportingOverflow(max(65_536, data.count / 16))
        guard !overflow else { throw StepPreviewCacheError.cacheEntryTooLarge }
        var destination = Data(count: capacity)
        let encodedCount = destination.withUnsafeMutableBytes { destinationBytes in
            data.withUnsafeBytes { sourceBytes in
                compression_encode_buffer(
                    destinationBytes.bindMemory(to: UInt8.self).baseAddress!,
                    capacity,
                    sourceBytes.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }
        guard encodedCount > 0 else { return nil }
        destination.count = encodedCount
        return destination
    }

    static func decompress(_ data: Data, expectedByteCount: Int) throws -> Data {
        var destination = Data(count: expectedByteCount)
        let decodedCount = destination.withUnsafeMutableBytes { destinationBytes in
            data.withUnsafeBytes { sourceBytes in
                compression_decode_buffer(
                    destinationBytes.bindMemory(to: UInt8.self).baseAddress!,
                    expectedByteCount,
                    sourceBytes.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_LZFSE
                )
            }
        }
        guard decodedCount == expectedByteCount else {
            throw StepPreviewCacheError.compressionFailed
        }
        return destination
    }
}

private nonisolated struct StepCacheEnvelopeReader {
    let data: Data
    var offset: Int

    mutating func readUInt32() throws -> UInt32 {
        guard offset <= data.count - 4 else { throw StepPreviewCacheError.damagedEnvelope }
        let value = data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }
        offset += 4
        return UInt32(littleEndian: value)
    }

    mutating func readUInt64() throws -> UInt64 {
        guard offset <= data.count - 8 else { throw StepPreviewCacheError.damagedEnvelope }
        let value = data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
        }
        offset += 8
        return UInt64(littleEndian: value)
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count - count else {
            throw StepPreviewCacheError.damagedEnvelope
        }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
}

private nonisolated extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func replaceLittleEndian<T: FixedWidthInteger>(
        _ value: T,
        at offset: inout Int
    ) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            replaceSubrange(offset..<(offset + bytes.count), with: bytes)
            offset += bytes.count
        }
    }
}

private nonisolated extension SHA256.Digest {
    static var byteCount: Int { 32 }
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
