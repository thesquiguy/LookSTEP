import Foundation

@objc nonisolated protocol StepImportServiceProtocol {
    func importSTEP(
        sourceFile: FileHandle,
        sourceExtension: String,
        maxSeconds: Double,
        maxTriangles: Int,
        relativeDeflection: Double,
        minimumDeflection: Double,
        maximumDeflection: Double,
        with reply: @escaping (Data?, NSDictionary?, NSError?) -> Void
    )
    func cancelCurrentImport()
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

nonisolated enum StepPreviewErrorMessage {
    static func userMessage(for error: Error) -> String {
        if let clientError = error as? StepImportClientError {
            return clientError.errorDescription ?? generic
        }

        let nsError = error as NSError
        guard nsError.domain == "com.local.stepviewer.import" else { return generic }
        switch nsError.code {
        case 1:
            return "This file couldn’t be read. It may be damaged or use an unsupported STEP format."
        case 2, 3:
            return "This file doesn’t contain usable 3D geometry."
        case 4:
            return "This model is too complex for a Finder preview."
        case 5:
            return "The preview stopped unexpectedly. Try opening the file again."
        case 6:
            return "This model took too long to prepare. Try a smaller or simpler STEP file."
        default:
            return generic
        }
    }

    private static let generic = "This file couldn’t be opened. It may be damaged or unsupported."
}

nonisolated final class StepImportClient: @unchecked Sendable {
    static let serviceName = "com.local.stepviewer.StepLook.StepImportService"

    private let lock = NSLock()
    private var currentConnection: NSXPCConnection?

    func importFile(
        at url: URL,
        maxSeconds: Double,
        maxTriangles: Int,
        relativeDeflection: Double,
        minimumDeflection: Double = 0.000_001,
        maximumDeflection: Double = .greatestFiniteMagnitude
    ) async throws -> StepImportResult {
        // Finder's scoped access stays active while XPC duplicates this
        // descriptor. The sandboxed service copies it into service-owned
        // temporary storage before OpenCascade reads a normal seekable path.
        let sourceFile = try FileHandle(forReadingFrom: url)
        defer { try? sourceFile.close() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let gate = ImportReplyGate(continuation: continuation)
                let connection = NSXPCConnection(serviceName: Self.serviceName)
                let clientTimeout = DispatchWorkItem {
                    gate.finish(.failure(NSError(
                        domain: "com.local.stepviewer.import",
                        code: 6,
                        userInfo: [NSLocalizedDescriptionKey: "Preview took too long. Open the file in LookSTEP to continue."]
                    )))
                    connection.invalidate()
                }
                connection.remoteObjectInterface = NSXPCInterface(with: StepImportServiceProtocol.self)
                connection.interruptionHandler = {
                    clientTimeout.cancel()
                    gate.finish(.failure(StepImportClientError.unavailable))
                }
                connection.invalidationHandler = {
                    clientTimeout.cancel()
                    gate.finish(.failure(StepImportClientError.unavailable))
                }
                connection.resume()
                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: .now() + max(2, maxSeconds + 1.5),
                    execute: clientTimeout
                )

                lock.withLock { currentConnection = connection }
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    gate.finish(.failure(error))
                }) as? StepImportServiceProtocol else {
                    gate.finish(.failure(StepImportClientError.unavailable))
                    return
                }

                proxy.importSTEP(
                    sourceFile: sourceFile,
                    sourceExtension: url.pathExtension,
                    maxSeconds: maxSeconds,
                    maxTriangles: maxTriangles,
                    relativeDeflection: relativeDeflection,
                    minimumDeflection: minimumDeflection,
                    maximumDeflection: maximumDeflection
                ) { data, rawMetrics, error in
                    clientTimeout.cancel()
                    if let error {
                        gate.finish(.failure(error))
                    } else if let data {
                        let metrics = (rawMetrics as? [String: Any] ?? [:]).mapValues { String(describing: $0) }
                        gate.finish(.success(StepImportResult(archive: data, metrics: metrics)))
                    } else {
                        gate.finish(.failure(StepImportClientError.invalidReply))
                    }
                    connection.invalidate()
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        let connection = lock.withLock { () -> NSXPCConnection? in
            defer { currentConnection = nil }
            return currentConnection
        }
        if let proxy = connection?.remoteObjectProxy as? StepImportServiceProtocol {
            proxy.cancelCurrentImport()
        }
        connection?.invalidate()
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
