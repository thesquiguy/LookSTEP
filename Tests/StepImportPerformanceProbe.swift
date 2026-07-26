import Darwin
import Foundation

@main
struct StepImportPerformanceProbe {
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4,
              let simplificationLevel = Int(arguments[3]),
              simplificationLevel >= 0 else {
            throw ProbeError(
                "usage: StepImportPerformanceProbe PRIVACY_SAFE_ID SOURCE_PATH SIMPLIFICATION_LEVEL"
            )
        }

        let fixtureID = arguments[1]
        guard !fixtureID.isEmpty, !fixtureID.contains("/") else {
            throw ProbeError("the privacy-safe ID must be nonempty and contain no slash")
        }
        let sourceURL = URL(fileURLWithPath: arguments[2])
        let budget = StepPreviewImportBudget(for: sourceURL)
        let started = ProcessInfo.processInfo.systemUptime
        let result = try await StepImportClient().importFile(
            at: sourceURL,
            maxSeconds: 120,
            maxTriangles: budget.maximumTriangles,
            relativeDeflection: budget.relativeDeflection,
            minimumDeflection: budget.minimumDeflection,
            maximumDeflection: budget.maximumDeflection,
            startingSimplificationLevel: simplificationLevel
        )

        var record: [String: Any] = result.metrics
        record["fixture_id"] = fixtureID
        record["source_class"] = budget.sourceClass.rawValue
        record["requested_simplification_level"] = simplificationLevel
        record["client_seconds"] =
            ProcessInfo.processInfo.systemUptime - started
        let data = try JSONSerialization.data(
            withJSONObject: record,
            options: [.sortedKeys]
        )
        guard let line = String(data: data, encoding: .utf8) else {
            throw ProbeError("could not encode the performance record")
        }
        print(line)
    }
}

private struct ProbeError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
