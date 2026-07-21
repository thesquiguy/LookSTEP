import Darwin
import Foundation

final class StepImportService: NSObject, StepImportServiceProtocol {
    private let stateLock = NSLock()
    private var activeSession: ImportSession?

    func importSTEP(
        sourceFile: FileHandle,
        sourceExtension: String,
        maxSeconds: Double,
        maxTriangles: Int,
        relativeDeflection: Double,
        minimumDeflection: Double,
        maximumDeflection: Double,
        with reply: @escaping (Data?, NSDictionary?, NSError?) -> Void
    ) {
        let session = ImportSession(reply: reply)
        stateLock.withLock {
            activeSession?.cancel(message: "A newer preview replaced this import.")
            activeSession = session
        }
        session.startWatchdog(after: max(1, maxSeconds))

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            autoreleasepool {
                let stagedURL = Self.temporarySTEPURL(sourceExtension: sourceExtension)
                defer {
                    try? sourceFile.close()
                    try? FileManager.default.removeItem(at: stagedURL)
                }
                do {
                    try Self.copy(sourceFile, to: stagedURL)
                    var metrics: NSDictionary?
                    let archive = try StepMeshImporter.importFile(
                        atPath: stagedURL.path,
                        maxTriangles: UInt(max(1, maxTriangles)),
                        relativeDeflection: max(0.0005, min(relativeDeflection, 0.02)),
                        minimumDeflection: max(0.000_001, minimumDeflection),
                        maximumDeflection: max(minimumDeflection, maximumDeflection),
                        metrics: &metrics
                    )

                    session.complete(data: archive as Data, metrics: metrics, error: nil)
                } catch {
                    session.complete(data: nil, metrics: nil, error: error as NSError)
                }
                self?.stateLock.withLock {
                    if self?.activeSession === session { self?.activeSession = nil }
                }
            }
        }
    }

    func cancelCurrentImport() {
        stateLock.withLock { activeSession?.cancel(message: "The import was cancelled.") }
    }

    fileprivate static func error(code: Int, message: String) -> NSError {
        NSError(domain: "com.local.stepviewer.import", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func temporarySTEPURL(sourceExtension: String) -> URL {
        let fileExtension = sourceExtension.lowercased() == "stp" ? "stp" : "step"
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("StepLook-Import-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
    }

    private static func copy(_ source: FileHandle, to destination: URL) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw error(code: 5, message: "The preview couldn’t prepare a private copy of this file.")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try source.seek(toOffset: 0)
        while let chunk = try source.read(upToCount: 1_048_576), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
    }
}

private final class ImportSession: @unchecked Sendable {
    typealias Reply = (Data?, NSDictionary?, NSError?) -> Void

    private let lock = NSLock()
    private let reply: Reply
    private var didReply = false
    private var didComplete = false
    private var watchdog: DispatchSourceTimer?
    private var forcedExit: DispatchWorkItem?

    init(reply: @escaping Reply) {
        self.reply = reply
    }

    func startWatchdog(after seconds: Double) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in
            self?.stop(message: "Preview took too long. Open the file in LookSTEP to continue.", code: 6)
        }
        lock.withLock { watchdog = timer }
        timer.resume()
    }

    func cancel(message: String) {
        stop(message: message, code: NSUserCancelledError)
    }

    func complete(data: Data?, metrics: NSDictionary?, error: NSError?) {
        let shouldReply = lock.withLock { () -> Bool in
            didComplete = true
            watchdog?.cancel()
            watchdog = nil
            forcedExit?.cancel()
            forcedExit = nil
            guard !didReply else { return false }
            didReply = true
            return true
        }
        if shouldReply { reply(data, metrics, error) }
    }

    private func stop(message: String, code: Int) {
        let action = lock.withLock { () -> DispatchWorkItem? in
            guard !didReply else { return nil }
            didReply = true
            watchdog?.cancel()
            watchdog = nil
            let action = DispatchWorkItem { _exit(124) }
            forcedExit = action
            return action
        }
        guard let action else { return }
        reply(nil, nil, StepImportService.error(code: code, message: message))
        // Give timeout replies enough time to cross the XPC boundary before the
        // watchdog tears down an importer that may still be blocked in OCCT.
        // User cancellation stays fast so closing Quick Look promptly cleans up.
        let forcedExitDelay: TimeInterval = code == NSUserCancelledError ? 1 : 3
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + forcedExitDelay,
            execute: action
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
