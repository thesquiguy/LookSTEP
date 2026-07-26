import Darwin
import Foundation
import OSLog

final class StepImportService: NSObject, StepImportServiceProtocol, @unchecked Sendable {
    static let maximumSourceBytes: Int64 = 512 * 1_024 * 1_024
    static let maximumResidentBytes: Int64 = 1_536 * 1_024 * 1_024

    private static let log = Logger(
        subsystem: "com.local.stepviewer.StepLook",
        category: "ImportService"
    )
    fileprivate static let performanceSignposter = OSSignposter(
        subsystem: "com.local.stepviewer.StepLook",
        category: "ImportServicePerformance"
    )
    private static let restartDelay: TimeInterval = 1
    private static let reserveBytes: Int64 = 64 * 1_024 * 1_024

    private enum Lifecycle {
        case idle
        case running(ImportSession)
        case draining
    }

    private enum CancellationDisposition {
        case active(ImportSession)
        case drainBeforeStart
        case queuedBehindAnotherRequest
    }

    private enum StopAction {
        case continueProcess
        case recycleProcess
    }

    private struct Parameters {
        let seconds: Double
        let maximumTriangles: Int
        let maximumResidentBytes: Int64
        let relativeDeflection: Double
        let minimumDeflection: Double
        let maximumDeflection: Double
        let sourceBytes: Int64
        let sourceDescriptor: StepImportSourceDescriptorSnapshot
        let startingSimplificationLevel: Int
    }

    private let stateLock = NSLock()
    private let importQueue = DispatchQueue(
        label: "com.local.stepviewer.StepLook.StepImportService.import",
        qos: .userInitiated
    )
    private var lifecycle = Lifecycle.idle
    private var exitScheduled = false
    private var pendingCancellations = StepImportCancellationLedger()

    override init() {
        super.init()
        StepImportStagedFile.reapAbandoned()
    }

    func importSTEP(
        requestIdentifier: String,
        sourceFile: FileHandle,
        sourceExtension: String,
        maxSeconds: Double,
        maxTriangles: Int,
        maxResidentBytes: Int64,
        relativeDeflection: Double,
        minimumDeflection: Double,
        maximumDeflection: Double,
        startingSimplificationLevel: Int,
        with reply: @escaping (Data?, NSDictionary?, NSError?) -> Void
    ) {
        let parameters: Parameters
        do {
            parameters = try Self.validatedParameters(
                sourceFile: sourceFile,
                maxSeconds: maxSeconds,
                maxTriangles: maxTriangles,
                maxResidentBytes: maxResidentBytes,
                relativeDeflection: relativeDeflection,
                minimumDeflection: minimumDeflection,
                maximumDeflection: maximumDeflection,
                startingSimplificationLevel: startingSimplificationLevel
            )
        } catch {
            try? sourceFile.close()
            let nsError = error as NSError
            Self.log.error(
                "import_rejected category=\(Self.telemetryFailureCategory(for: nsError), privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code)"
            )
            reply(nil, nil, error as NSError)
            if nsError.domain == "com.local.stepviewer.import",
               nsError.code == 4,
               Self.currentResidentBytes() > UInt64(Self.maximumResidentBytes) {
                scheduleProcessExit()
            }
            return
        }


        let cancelledBeforeStart = stateLock.withLock {
            pendingCancellations.consume(
                requestIdentifier,
                now: ProcessInfo.processInfo.systemUptime
            )
        }
        if cancelledBeforeStart {
            try? sourceFile.close()
            Self.log.info("import_cancelled phase=before_start")
            reply(nil, nil, Self.error(
                code: NSUserCancelledError,
                message: "The import was cancelled."
            ))
            return
        }

        let session = ImportSession(identifier: requestIdentifier, reply: reply)
        let accepted = stateLock.withLock { () -> Bool in
            guard case .idle = lifecycle else { return false }
            lifecycle = .running(session)
            return true
        }
        guard accepted else {
            try? sourceFile.close()
            Self.log.notice("import_rejected reason=service_busy")
            reply(nil, nil, Self.error(
                code: 7,
                message: "The preview service is finishing another request. Try again."
            ))
            return
        }

        Self.log.info(
            "import_accepted source_bytes=\(parameters.sourceBytes) max_triangles=\(parameters.maximumTriangles) max_resident_bytes=\(parameters.maximumResidentBytes) timeout_seconds=\(parameters.seconds, format: .fixed(precision: 1))"
        )
        session.startWatchdog(after: parameters.seconds) { [weak self, weak session] in
            guard let self, let session else { return }
            self.stop(
                session,
                code: 6,
                message: "Preview took too long. Open the file in LookSTEP to continue.",
                reason: "timeout"
            )
        }
        session.startResidentMemoryWatchdog(every: 0.05) { [weak self, weak session] in
            guard let self, let session else { return }
            let residentBytes = Self.currentResidentBytes()
            guard residentBytes > 0 else {
                Self.log.error("resident_measurement_failed")
                self.stop(
                    session,
                    code: 5,
                    message: "The preview couldn’t monitor memory use safely. Try opening the file again.",
                    reason: "resident_memory_unavailable"
                )
                return
            }
            guard residentBytes > UInt64(parameters.maximumResidentBytes) else { return }
            Self.log.notice(
                "resident_limit_exceeded resident_bytes=\(residentBytes) max_resident_bytes=\(parameters.maximumResidentBytes)"
            )
            self.stop(
                session,
                code: 4,
                message: "This model exceeded Finder preview's memory limit. Open it in Caliper to continue.",
                reason: "resident_memory"
            )
        }

        importQueue.async { [weak self] in
            guard let self else {
                try? sourceFile.close()
                return
            }
            autoreleasepool {
                self.run(
                    session,
                    sourceFile: sourceFile,
                    sourceExtension: sourceExtension,
                    parameters: parameters
                )
            }
        }
    }

    func cancelImport(requestIdentifier: String, with reply: @escaping (Bool) -> Void) {
        let disposition = stateLock.withLock { () -> CancellationDisposition in
            if case .running(let active) = lifecycle,
               active.identifier == requestIdentifier {
                return .active(active)
            }
            recordPendingCancellationLocked(requestIdentifier)
            if case .idle = lifecycle {
                lifecycle = .draining
                return .drainBeforeStart
            }
            return .queuedBehindAnotherRequest
        }
        switch disposition {
        case .active(let session):
            let stopAction = claimStop(session, reason: "client")
            let acknowledged = stopAction != nil
            Self.log.info("cancel_acknowledged phase=active matched=\(acknowledged)")
            reply(acknowledged)
            if let stopAction {
                if stopAction == .recycleProcess {
                    scheduleProcessExit()
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    session.deliver(
                        data: nil,
                        metrics: nil,
                        error: Self.error(
                            code: NSUserCancelledError,
                            message: "The import was cancelled."
                        )
                    )
                }
            }
        case .drainBeforeStart:
            Self.log.info("cancel_acknowledged phase=before_start matched=true")
            reply(true)
            scheduleProcessExit()
        case .queuedBehindAnotherRequest:
            Self.log.info("cancel_acknowledged phase=queued matched=true")
            reply(true)
        }
    }

    fileprivate static func error(code: Int, message: String) -> NSError {
        NSError(
            domain: "com.local.stepviewer.import",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func run(
        _ session: ImportSession,
        sourceFile: FileHandle,
        sourceExtension: String,
        parameters: Parameters
    ) {
        let stagedFile: StepImportStagedFile
        do {
            stagedFile = try StepImportStagedFile.prepare(sourceExtension: sourceExtension)
        } catch {
            try? sourceFile.close()
            complete(
                session,
                data: nil,
                metrics: nil,
                error: Self.error(
                    code: 5,
                    message: "The preview couldn’t prepare a private copy of this file."
                )
            )
            return
        }
        defer {
            try? sourceFile.close()
            stagedFile.cleanup()
        }

        do {
            let copyStart = ProcessInfo.processInfo.systemUptime
            try Self.copy(
                sourceFile,
                to: stagedFile.fileURL,
                maximumBytes: Self.maximumSourceBytes,
                session: session
            )
            do {
                try StepImportSourceDescriptor.requireUnchanged(
                    sourceFile,
                    from: parameters.sourceDescriptor,
                    maximumBytes: Self.maximumSourceBytes
                )
            } catch let descriptorError as StepImportSourceDescriptorError {
                switch descriptorError {
                case .tooLarge:
                    throw Self.error(
                        code: 4,
                        message: "This STEP file is larger than the current preview limit."
                    )
                case .changed:
                    throw Self.error(
                        code: 2,
                        message: "The STEP file changed while its preview was being prepared."
                    )
                case .inspectionFailed, .negativeSize, .unsupportedFileType:
                    throw Self.error(
                        code: 5,
                        message: "The preview couldn’t verify the copied STEP file."
                    )
                }
            }
            let copySeconds = ProcessInfo.processInfo.systemUptime - copyStart
            // Copying is cooperatively cancellable. Once OCCT starts, its STEP
            // parser cannot be interrupted safely, so cancellation recycles
            // the helper instead of accepting a second in-process import.
            guard session.beginNonCooperativeImport() else { return }

            var importerMetrics: NSDictionary?
            let archive = try StepMeshImporter.importFile(
                atPath: stagedFile.fileURL.path,
                maxTriangles: UInt(parameters.maximumTriangles),
                relativeDeflection: parameters.relativeDeflection,
                minimumDeflection: parameters.minimumDeflection,
                maximumDeflection: parameters.maximumDeflection,
                startingSimplificationLevel: UInt(parameters.startingSimplificationLevel),
                metrics: &importerMetrics
            )
            let metrics = NSMutableDictionary(dictionary: importerMetrics ?? [:])
            metrics["sourceBytes"] = parameters.sourceBytes
            metrics["stageCopySeconds"] = copySeconds
            metrics["peakResidentBytes"] = Self.peakResidentBytes()
            complete(session, data: archive as Data, metrics: metrics, error: nil)
        } catch is CancellationError {
            // The stop path already owns the one XPC reply and process teardown.
        } catch {
            complete(session, data: nil, metrics: nil, error: error as NSError)
        }
    }

    private func complete(
        _ session: ImportSession,
        data: Data?,
        metrics: NSDictionary?,
        error: NSError?
    ) {
        guard session.claimReply() else { return }
        stateLock.withLock {
            if case .running(let active) = lifecycle, active === session {
                lifecycle = .idle
            }
        }
        Self.log.info(
            "import_completed outcome=\(error == nil ? "success" : "failure", privacy: .public) category=\(error.map { Self.telemetryFailureCategory(for: $0) } ?? "none", privacy: .public) archive_bytes=\(data?.count ?? 0) peak_resident_bytes=\(Self.metric("peakResidentBytes", in: metrics)) triangles=\(Self.metric("triangles", in: metrics)) definitions=\(Self.metric("definitions", in: metrics)) occurrences=\(Self.metric("occurrences", in: metrics)) missing_faces=\(Self.metric("missingFaces", in: metrics))"
        )
        session.deliver(data: data, metrics: metrics, error: error)
    }

    private static func metric(_ key: String, in metrics: NSDictionary?) -> UInt64 {
        (metrics?[key] as? NSNumber)?.uint64Value ?? 0
    }

    private static func telemetryFailureCategory(for error: NSError) -> String {
        if error.code == NSUserCancelledError { return "cancelled" }
        guard error.domain == "com.local.stepviewer.import" else { return "unexpected" }
        switch error.code {
        case 1: return "unreadable_source"
        case 2: return "transfer_failed"
        case 3: return "empty_geometry"
        case 4: return "resource_limit"
        case 5: return "importer_failure"
        case 6: return "timeout"
        case 7: return "service_busy"
        case 8: return "invalid_request"
        default: return "import_failure"
        }
    }

    @discardableResult
    private func stop(
        _ session: ImportSession,
        code: Int,
        message: String,
        reason: String
    ) -> Bool {
        guard let stopAction = claimStop(session, reason: reason) else { return false }
        if stopAction == .recycleProcess {
            scheduleProcessExit()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            session.deliver(data: nil, metrics: nil, error: Self.error(code: code, message: message))
        }
        return true
    }

    private func claimStop(_ session: ImportSession, reason: String) -> StopAction? {
        guard let requiresProcessRecycle = session.claimStop() else { return nil }
        let stopAction: StopAction = requiresProcessRecycle ? .recycleProcess : .continueProcess
        stateLock.withLock {
            if case .running(let active) = lifecycle, active === session {
                lifecycle = stopAction == .recycleProcess ? .draining : .idle
            }
        }
        Self.log.notice(
            "import_stopped reason=\(reason, privacy: .public) recycle=\(requiresProcessRecycle)"
        )
        return stopAction
    }

    private func scheduleProcessExit() {
        let shouldSchedule = stateLock.withLock { () -> Bool in
            guard !exitScheduled else { return false }
            exitScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.restartDelay
        ) {
            // This is a deliberate process recycle, not a crash. A successful
            // status lets launchd satisfy the next XPC request immediately
            // instead of applying crash-throttling backoff.
            _exit(EXIT_SUCCESS)
        }
    }

    private func recordPendingCancellationLocked(_ identifier: String) {
        pendingCancellations.record(
            identifier,
            now: ProcessInfo.processInfo.systemUptime
        )
    }

    private static func validatedParameters(
        sourceFile: FileHandle,
        maxSeconds: Double,
        maxTriangles: Int,
        maxResidentBytes: Int64,
        relativeDeflection: Double,
        minimumDeflection: Double,
        maximumDeflection: Double,
        startingSimplificationLevel: Int
    ) throws -> Parameters {
        guard maxSeconds.isFinite,
              relativeDeflection.isFinite,
              minimumDeflection.isFinite,
              maximumDeflection.isFinite,
              maxTriangles > 0,
              maxResidentBytes > 0,
              relativeDeflection > 0,
              minimumDeflection > 0,
              maximumDeflection > 0 else {
            throw error(code: 8, message: "The preview request contained invalid limits.")
        }

        let sourceDescriptor: StepImportSourceDescriptorSnapshot
        do {
            sourceDescriptor = try StepImportSourceDescriptor.validate(
                sourceFile,
                maximumBytes: maximumSourceBytes
            )
        } catch let descriptorError as StepImportSourceDescriptorError {
            switch descriptorError {
            case .tooLarge:
                throw error(
                    code: 4,
                    message: "This STEP file is larger than the current preview limit."
                )
            case .inspectionFailed, .negativeSize, .unsupportedFileType, .changed:
                throw error(code: 5, message: "The preview couldn’t inspect this file.")
            }
        }
        let sourceBytes = sourceDescriptor.byteCount

        let maximumResidentBytes = min(maxResidentBytes, Self.maximumResidentBytes)
        let residentBytes = Self.currentResidentBytes()
        guard residentBytes > 0 else {
            throw error(
                code: 5,
                message: "The preview couldn’t inspect memory use safely."
            )
        }
        guard residentBytes <= UInt64(maximumResidentBytes) else {
            throw error(
                code: 4,
                message: "This model exceeded Finder preview's memory limit. Open it in Caliper to continue."
            )
        }

        let (requiredCapacity, overflow) = sourceBytes.addingReportingOverflow(reserveBytes)
        if !overflow,
           let available = try? FileManager.default.temporaryDirectory.resourceValues(
               forKeys: [.volumeAvailableCapacityForImportantUsageKey]
           ).volumeAvailableCapacityForImportantUsage,
           available < requiredCapacity {
            throw error(code: 5, message: "There isn’t enough free space to prepare this preview.")
        }

        let minimum = max(0.000_001, minimumDeflection)
        return Parameters(
            seconds: min(60, max(1, maxSeconds)),
            maximumTriangles: min(2_000_000, maxTriangles),
            maximumResidentBytes: maximumResidentBytes,
            relativeDeflection: min(0.02, max(0.0005, relativeDeflection)),
            minimumDeflection: minimum,
            maximumDeflection: min(1_000_000_000, max(minimum, maximumDeflection)),
            sourceBytes: sourceBytes,
            sourceDescriptor: sourceDescriptor,
            // Clamped to the importer's own tier count. A caller asking for a
            // level the importer does not have must not silently disable
            // coarsening altogether.
            startingSimplificationLevel: min(2, max(0, startingSimplificationLevel))
        )
    }

    private static func peakResidentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.resident_size_max) : 0
    }

    private static func currentResidentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    private static func copy(
        _ source: FileHandle,
        to destination: URL,
        maximumBytes: Int64,
        session: ImportSession
    ) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw error(code: 5, message: "The preview couldn’t prepare a private copy of this file.")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try source.seek(toOffset: 0)
        var copiedBytes: Int64 = 0
        while let chunk = try source.read(upToCount: 1_048_576), !chunk.isEmpty {
            guard !session.hasReplied else { throw CancellationError() }
            let (nextBytes, overflow) = copiedBytes.addingReportingOverflow(Int64(chunk.count))
            guard !overflow, nextBytes <= maximumBytes else {
                throw error(code: 4, message: "This STEP file is larger than the current preview limit.")
            }
            try output.write(contentsOf: chunk)
            copiedBytes = nextBytes
        }
    }
}

private final class ImportSession: @unchecked Sendable {
    typealias Reply = (Data?, NSDictionary?, NSError?) -> Void

    let identifier: String
    private let lock = NSLock()
    private let reply: Reply
    private var didReply = false
    private var enteredNonCooperativeImport = false
    private var watchdog: DispatchSourceTimer?
    private var residentMemoryWatchdog: DispatchSourceTimer?
    private var signpostState: OSSignpostIntervalState?

    init(identifier: String, reply: @escaping Reply) {
        self.identifier = identifier
        self.reply = reply
        signpostState = StepImportService.performanceSignposter.beginInterval(
            "STEP import service"
        )
    }

    var hasReplied: Bool { lock.withLock { didReply } }

    func beginNonCooperativeImport() -> Bool {
        lock.withLock {
            guard !didReply else { return false }
            enteredNonCooperativeImport = true
            return true
        }
    }

    func startWatchdog(after seconds: Double, onTimeout: @escaping @Sendable () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler(handler: onTimeout)
        timer.resume()
        let shouldCancel = lock.withLock { () -> Bool in
            guard !didReply else { return true }
            watchdog = timer
            return false
        }
        if shouldCancel { timer.cancel() }
    }

    func startResidentMemoryWatchdog(
        every seconds: Double,
        onLimit: @escaping @Sendable () -> Void
    ) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(
            deadline: .now() + seconds,
            repeating: seconds,
            leeway: .milliseconds(10)
        )
        timer.setEventHandler(handler: onLimit)
        timer.resume()
        let shouldCancel = lock.withLock { () -> Bool in
            guard !didReply else { return true }
            residentMemoryWatchdog = timer
            return false
        }
        if shouldCancel { timer.cancel() }
    }

    func claimReply() -> Bool {
        lock.withLock {
            guard !didReply else { return false }
            didReply = true
            watchdog?.cancel()
            watchdog = nil
            residentMemoryWatchdog?.cancel()
            residentMemoryWatchdog = nil
            endSignpostLocked()
            return true
        }
    }

    /// Claims the one terminal reply and reports whether OCCT has already
    /// entered work that cannot be cancelled cooperatively.
    func claimStop() -> Bool? {
        lock.withLock {
            guard !didReply else { return nil }
            didReply = true
            watchdog?.cancel()
            watchdog = nil
            residentMemoryWatchdog?.cancel()
            residentMemoryWatchdog = nil
            endSignpostLocked()
            return enteredNonCooperativeImport
        }
    }

    func deliver(data: Data?, metrics: NSDictionary?, error: NSError?) {
        reply(data, metrics, error)
    }

    deinit {
        if let state = signpostState {
            StepImportService.performanceSignposter.endInterval(
                "STEP import service",
                state
            )
        }
    }

    private func endSignpostLocked() {
        guard let state = signpostState else { return }
        signpostState = nil
        StepImportService.performanceSignposter.endInterval(
            "STEP import service",
            state
        )
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
