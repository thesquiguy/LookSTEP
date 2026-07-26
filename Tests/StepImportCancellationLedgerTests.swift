import Darwin
import Foundation

@main
struct StepImportCancellationLedgerTests {
    static func main() {
        var repeated = StepImportCancellationLedger()
        for _ in 0..<10_000 {
            repeated.record("same-request", now: 10)
        }
        expect(repeated.count == 1, "duplicate cancellation IDs grew ledger state")

        var churned = StepImportCancellationLedger()
        for index in 0..<10_000 {
            churned.record("request-\(index)", now: 10)
            expect(
                churned.count <= StepImportCancellationLedger.maximumCount,
                "unique cancellation churn exceeded the production cap"
            )
        }
        expect(
            !churned.contains("request-0") && churned.contains("request-9999"),
            "bounded ledger did not evict old state while retaining current cancellation"
        )
        expect(
            churned.consume("request-9999", now: 11),
            "current cancellation could not be consumed"
        )
        expect(
            !churned.consume("request-9999", now: 11),
            "one cancellation was consumed more than once"
        )

        var expiring = StepImportCancellationLedger()
        expiring.record("expiring", now: 20)
        expect(
            !expiring.consume(
                "expiring",
                now: 20 + StepImportCancellationLedger.retentionSeconds
            ),
            "expired cancellation incorrectly applied to a later request"
        )
        expect(expiring.count == 0, "expired cancellation state was retained")

        print("Step import cancellation-ledger tests passed")
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
