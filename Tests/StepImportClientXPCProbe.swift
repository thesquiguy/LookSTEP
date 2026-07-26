import Darwin
import Foundation

@main
struct StepImportClientXPCProbe {
    static func main() async {
        do {
            try await run()
            print("Step import client XPC cancellation probe passed")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StepImportClientXPCProbe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cancellableURL = root.appendingPathComponent("cancellable.step")
        FileManager.default.createFile(atPath: cancellableURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: cancellableURL)
        try handle.truncate(atOffset: 32 * 1_024 * 1_024)
        try handle.close()

        let client = StepImportClient()
        let importTask = Task {
            try await client.importFile(
                at: cancellableURL,
                maxSeconds: 20,
                maxTriangles: 750_000,
                relativeDeflection: 0.0035
            )
        }

        for _ in 0..<500 where !client.hasActiveRequest {
            try await Task.sleep(for: .milliseconds(1))
        }
        try expect(client.hasActiveRequest, "request never became cancellable")

        let acknowledged = await client.cancelAndWait()
        try expect(acknowledged, "service did not acknowledge cancellation")
        try expect(!client.hasActiveRequest, "client retained the cancelled request")

        let returnedGeometry: Bool
        do {
            _ = try await importTask.value
            returnedGeometry = true
        } catch {
            // The acknowledgement is the teardown contract. The in-flight
            // import may observe cancellation or connection invalidation.
            returnedGeometry = false
        }
        try expect(!returnedGeometry, "cancelled import unexpectedly returned geometry")

        // A before-start cancellation may recycle the helper. Verify that a
        // fresh client can reconnect after teardown rather than relying on
        // process state from the cancelled request.
        try await Task.sleep(for: .milliseconds(1_250))
        let invalidURL = root.appendingPathComponent("invalid.step")
        try Data("not a STEP file".utf8).write(to: invalidURL, options: .atomic)
        do {
            _ = try await StepImportClient().importFile(
                at: invalidURL,
                maxSeconds: 10,
                maxTriangles: 1,
                relativeDeflection: 0.0035
            )
            throw ProbeError("invalid source unexpectedly imported after service restart")
        } catch let error as ProbeError {
            throw error
        } catch {
            let nsError = error as NSError
            try expect(
                nsError.domain == "com.local.stepviewer.import" && nsError.code == 1,
                "service restart returned \(nsError.domain):\(nsError.code), expected import read error"
            )
        }
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ProbeError(message) }
    }
}

private struct ProbeError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
