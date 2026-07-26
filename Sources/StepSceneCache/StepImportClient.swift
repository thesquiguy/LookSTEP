import Foundation
import OSLog

@objc nonisolated protocol StepImportServiceProtocol {
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
    )
    func cancelImport(requestIdentifier: String, with reply: @escaping (Bool) -> Void)
}

nonisolated struct StepImportResult: Sendable {
    let archive: Data
    let metrics: [String: String]
}

nonisolated enum StepImportClientError: LocalizedError {
    case unavailable
    case invalidReply

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "The preview service stopped. Try opening the file again."
        case .invalidReply:
            "The preview couldn’t be completed. Try opening the file again."
        }
    }
}

/// Stable, privacy-safe labels for runtime telemetry. These deliberately avoid
/// localized descriptions, source names, and paths.
nonisolated enum StepTelemetryFailureCategory {
    static func label(for error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let budgetError = error as? StepPreviewImportBudgetError {
            switch budgetError {
            case .compatibleCacheRequired: return "resource_policy"
            case .predictedCostExceedsBudget: return "predicted_cost_policy"
            }
        }
        if let clientError = error as? StepImportClientError {
            switch clientError {
            case .unavailable: return "service_unavailable"
            case .invalidReply: return "invalid_service_reply"
            }
        }

        let nsError = error as NSError
        if nsError.code == NSUserCancelledError { return "cancelled" }
        guard nsError.domain == "com.local.stepviewer.import" else {
            return "unexpected"
        }
        switch nsError.code {
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
}

nonisolated enum StepPreviewErrorMessage {
    static func userMessage(for error: Error) -> String {
        advice(for: error, caliperInstalled: false).message
    }

    /// The message to show, plus whether an Open in Caliper action belongs
    /// beside it.
    ///
    /// Only failures Caliper can actually do better on offer the action. A
    /// damaged file or one with no usable geometry fails in Caliper too, so
    /// sending the user there would waste a cold OCCT import to reach the same
    /// answer.
    static func advice(for error: Error, caliperInstalled: Bool) -> StepPreviewAdvice {
        if let budgetError = error as? StepPreviewImportBudgetError {
            return StepPreviewAdvice.make(
                base: budgetError.baseMessage,
                caliperClause: "Open it in Caliper for exact geometry.",
                fallbackClause: budgetError.fallbackClause,
                caliperInstalled: caliperInstalled
            )
        }
        if let clientError = error as? StepImportClientError {
            return StepPreviewAdvice(
                message: clientError.errorDescription ?? generic,
                offersCaliper: false
            )
        }

        let nsError = error as NSError
        guard nsError.domain == "com.local.stepviewer.import" else {
            return StepPreviewAdvice(message: generic, offersCaliper: false)
        }
        switch nsError.code {
        case 1:
            return StepPreviewAdvice(
                message: "This file couldn’t be read. It may be damaged or use an unsupported STEP format.",
                offersCaliper: false
            )
        case 2, 3:
            return StepPreviewAdvice(
                message: "This file doesn’t contain usable 3D geometry.",
                offersCaliper: false
            )
        case 4:
            return StepPreviewAdvice.make(
                base: "This model is too complex for a Finder preview.",
                caliperClause: "Open it in Caliper for exact geometry.",
                fallbackClause: nil,
                caliperInstalled: caliperInstalled
            )
        case 5:
            return StepPreviewAdvice(
                message: "The preview stopped unexpectedly. Try opening the file again.",
                offersCaliper: false
            )
        case 6:
            return StepPreviewAdvice.make(
                base: "This model took too long to prepare.",
                caliperClause: "Open it in Caliper for exact geometry.",
                fallbackClause: "Try a smaller or simpler STEP file.",
                caliperInstalled: caliperInstalled
            )
        default:
            return StepPreviewAdvice(message: generic, offersCaliper: false)
        }
    }

    private static let generic = "This file couldn’t be opened. It may be damaged or unsupported."
}

nonisolated final class StepImportClientTimeout: @unchecked Sendable {
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var handler: (@Sendable () -> Void)?

    init(after seconds: Double, handler: @escaping @Sendable () -> Void) {
        self.handler = handler
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer = source
        source.schedule(deadline: .now() + max(0, seconds))
        source.setEventHandler { [weak self] in
            self?.fire()
        }
        source.resume()
    }

    func cancel() {
        lock.withLock {
            handler = nil
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
        }
    }

    private func fire() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            let action = handler
            handler = nil
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            return action
        }
        action?()
    }

    deinit {
        cancel()
    }
}

/// Owns the one terminal invalidation of an XPC connection.
///
/// Every request exit path uses this object so interruption and proxy errors
/// cannot leave a live connection behind. The connection remains retained
/// until this exact-once gate runs; clearing the invalidator breaks the
/// connection-handler cycle before invalidation is invoked.
nonisolated final class StepImportClientConnectionTeardown: @unchecked Sendable {
    private let lock = NSLock()
    private var invalidator: (@Sendable () -> Void)?

    init(invalidator: @escaping @Sendable () -> Void) {
        self.invalidator = invalidator
    }

    func invalidate() {
        let pending = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { invalidator = nil }
            return invalidator
        }
        pending?()
    }

    func connectionDidInvalidate() {
        lock.withLock { invalidator = nil }
    }

    deinit {
        invalidate()
    }
}

nonisolated final class StepImportClientConnectionReference<Connection: AnyObject>:
    @unchecked Sendable
{
    private var connection: Connection?
    private let invalidator: @Sendable (Connection) -> Void

    init(
        _ connection: Connection,
        invalidator: @escaping @Sendable (Connection) -> Void
    ) {
        self.connection = connection
        self.invalidator = invalidator
    }

    func invalidate() {
        let retained = connection
        connection = nil
        if let retained {
            invalidator(retained)
        }
    }
}

nonisolated final class StepImportClientRequestSlot<Request>: @unchecked Sendable {
    private let lock = NSLock()
    private var current: (identifier: String, request: Request)?

    var hasCurrent: Bool {
        lock.withLock { current != nil }
    }

    @discardableResult
    func install(identifier: String, request: Request) -> Request? {
        lock.withLock {
            let replaced = current?.request
            current = (identifier, request)
            return replaced
        }
    }

    func clear(identifier: String) {
        lock.withLock {
            if current?.identifier == identifier {
                current = nil
            }
        }
    }

    func take(identifier: String? = nil) -> Request? {
        lock.withLock {
            if let identifier, current?.identifier != identifier {
                return nil
            }
            defer { current = nil }
            return current?.request
        }
    }
}

nonisolated final class StepImportClient: @unchecked Sendable {
    static let serviceName = "com.local.stepviewer.StepLook.StepImportService"
    static let defaultMaximumResidentBytes: Int64 = 1_536 * 1_024 * 1_024
    private static let log = Logger(
        subsystem: "com.local.stepviewer.StepLook",
        category: "ImportClient"
    )
    private static let performanceSignposter = OSSignposter(
        subsystem: "com.local.stepviewer.StepLook",
        category: "ImportPerformance"
    )

    private struct ActiveRequest {
        let identifier: String
        let connection: NSXPCConnection
        let connectionTeardown: StepImportClientConnectionTeardown
    }

    private let requestSlot = StepImportClientRequestSlot<ActiveRequest>()

    var hasActiveRequest: Bool { requestSlot.hasCurrent }

    func importFile(
        at url: URL,
        maxSeconds: Double,
        maxTriangles: Int,
        relativeDeflection: Double,
        maxResidentBytes: Int64 = defaultMaximumResidentBytes,
        minimumDeflection: Double = 0.000_001,
        maximumDeflection: Double = .greatestFiniteMagnitude,
        startingSimplificationLevel: Int = 0
    ) async throws -> StepImportResult {
        try Task.checkCancellation()
        let signpostState = Self.performanceSignposter.beginInterval(
            "STEP import request"
        )
        defer {
            Self.performanceSignposter.endInterval(
                "STEP import request",
                signpostState
            )
        }
        // Finder's scoped access stays active while XPC duplicates this
        // descriptor. The sandboxed service copies it into service-owned
        // temporary storage before OpenCascade reads a normal seekable path.
        let sourceFile = try FileHandle(forReadingFrom: url)
        defer { try? sourceFile.close() }
        let requestIdentifier = UUID().uuidString

        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let gate = ImportReplyGate(continuation: continuation)
                    let connection = NSXPCConnection(serviceName: Self.serviceName)
                    let connectionReference = StepImportClientConnectionReference(
                        connection
                    ) { connection in
                        connection.invalidate()
                    }
                    let connectionTeardown = StepImportClientConnectionTeardown {
                        connectionReference.invalidate()
                    }
                    let activeRequest = ActiveRequest(
                        identifier: requestIdentifier,
                        connection: connection,
                        connectionTeardown: connectionTeardown
                    )
                    let clientTimeout = StepImportClientTimeout(
                        after: max(2, maxSeconds + 1.5)
                    ) { [weak self] in
                        gate.finish(.failure(NSError(
                            domain: "com.local.stepviewer.import",
                            code: 6,
                            userInfo: [NSLocalizedDescriptionKey: "Preview took too long. Open the file in LookSTEP to continue."]
                        )))
                        self?.clearCurrentRequest(identifier: requestIdentifier)
                        Self.requestCancellation(activeRequest)
                    }
                    connection.remoteObjectInterface = NSXPCInterface(with: StepImportServiceProtocol.self)
                    connection.interruptionHandler = { [weak self] in
                        clientTimeout.cancel()
                        self?.clearCurrentRequest(identifier: requestIdentifier)
                        gate.finish(.failure(StepImportClientError.unavailable))
                        connectionTeardown.invalidate()
                    }
                    connection.invalidationHandler = { [weak self] in
                        clientTimeout.cancel()
                        self?.clearCurrentRequest(identifier: requestIdentifier)
                        gate.finish(.failure(StepImportClientError.unavailable))
                        connectionTeardown.connectionDidInvalidate()
                    }
                    // Publish request ownership before resume: interruption or
                    // invalidation handlers may run as soon as XPC starts.
                    if let replaced = requestSlot.install(
                        identifier: requestIdentifier,
                        request: activeRequest
                    ) {
                        Self.requestCancellation(replaced)
                    }
                    connection.resume()
                    if Task.isCancelled {
                        cancel(requestIdentifier: requestIdentifier)
                    }
                    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
                        clientTimeout.cancel()
                        self?.clearCurrentRequest(identifier: requestIdentifier)
                        gate.finish(.failure(error))
                        connectionTeardown.invalidate()
                    }) as? StepImportServiceProtocol else {
                        clientTimeout.cancel()
                        clearCurrentRequest(identifier: requestIdentifier)
                        gate.finish(.failure(StepImportClientError.unavailable))
                        connectionTeardown.invalidate()
                        return
                    }

                    proxy.importSTEP(
                        requestIdentifier: requestIdentifier,
                        sourceFile: sourceFile,
                        sourceExtension: url.pathExtension,
                        maxSeconds: maxSeconds,
                        maxTriangles: maxTriangles,
                        maxResidentBytes: maxResidentBytes,
                        relativeDeflection: relativeDeflection,
                        minimumDeflection: minimumDeflection,
                        maximumDeflection: maximumDeflection,
                        startingSimplificationLevel: startingSimplificationLevel
                    ) { [weak self] data, rawMetrics, error in
                        clientTimeout.cancel()
                        self?.clearCurrentRequest(identifier: requestIdentifier)
                        if let error {
                            gate.finish(.failure(error))
                        } else if let data {
                            let metrics = (rawMetrics as? [String: Any] ?? [:])
                                .mapValues { String(describing: $0) }
                            gate.finish(.success(StepImportResult(
                                archive: data,
                                metrics: metrics
                            )))
                        } else {
                            gate.finish(.failure(StepImportClientError.invalidReply))
                        }
                        connectionTeardown.invalidate()
                    }
                }
            } onCancel: {
                cancel(requestIdentifier: requestIdentifier)
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    func cancel() {
        let request = requestSlot.take()
        if let request {
            Self.requestCancellation(request)
        }
    }

    func cancelAndWait() async -> Bool {
        let request = requestSlot.take()
        guard let request else { return false }
        return await withCheckedContinuation { continuation in
            Self.requestCancellation(request) { acknowledged in
                continuation.resume(returning: acknowledged)
            }
        }
    }

    private func clearCurrentRequest(identifier: String) {
        requestSlot.clear(identifier: identifier)
    }

    private func cancel(requestIdentifier: String) {
        if let request = requestSlot.take(identifier: requestIdentifier) {
            Self.requestCancellation(request)
        }
    }

    private static func requestCancellation(
        _ request: ActiveRequest,
        completion: @escaping @Sendable (Bool) -> Void = { _ in }
    ) {
        let replyGate = CancellationReplyGate(completion: completion)
        let fallback = StepImportClientTimeout(after: 0.5) {
            replyGate.finish(false)
            request.connectionTeardown.invalidate()
        }
        guard let proxy = request.connection.remoteObjectProxyWithErrorHandler({ _ in
            fallback.cancel()
            replyGate.finish(false)
            request.connectionTeardown.invalidate()
        }) as? StepImportServiceProtocol else {
            replyGate.finish(false)
            request.connectionTeardown.invalidate()
            return
        }
        proxy.cancelImport(requestIdentifier: request.identifier) { acknowledged in
            log.info("cancel_reply acknowledged=\(acknowledged)")
            fallback.cancel()
            replyGate.finish(acknowledged)
            request.connectionTeardown.invalidate()
        }
    }
}

private nonisolated final class CancellationReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (Bool) -> Void)?

    init(completion: @escaping @Sendable (Bool) -> Void) {
        self.completion = completion
    }

    func finish(_ acknowledged: Bool) {
        let pending = lock.withLock { () -> (@Sendable (Bool) -> Void)? in
            defer { completion = nil }
            return completion
        }
        pending?(acknowledged)
    }
}

private nonisolated final class ImportReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<StepImportResult, Error>?

    init(continuation: CheckedContinuation<StepImportResult, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<StepImportResult, Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<StepImportResult, Error>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }
}

private nonisolated extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
