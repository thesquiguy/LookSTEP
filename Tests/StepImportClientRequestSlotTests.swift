import Darwin
import Foundation

@main
struct StepImportClientRequestSlotTests {
    static func main() {
        let slot = StepImportClientRequestSlot<String>()

        expect(!slot.hasCurrent, "new request slot was not empty")
        expect(
            slot.install(identifier: "old", request: "old-request") == nil,
            "first install unexpectedly replaced a request"
        )
        expect(slot.hasCurrent, "installed request was not visible")

        expect(
            slot.install(identifier: "new", request: "new-request") == "old-request",
            "replacement did not return the superseded request for cancellation"
        )
        expect(
            slot.take(identifier: "old") == nil,
            "stale cancellation removed the newer request"
        )
        expect(slot.hasCurrent, "stale cancellation emptied the request slot")

        slot.clear(identifier: "old")
        expect(slot.hasCurrent, "stale completion cleared the newer request")
        expect(
            slot.take(identifier: "new") == "new-request",
            "current cancellation did not take its matching request"
        )
        expect(!slot.hasCurrent, "taking the current request did not empty the slot")

        verifyProductionConnectionOwnership()

        print("Step import client request-slot tests passed")
    }

    private static func verifyProductionConnectionOwnership() {
        let retained = makeConnectionOwnershipFixture()

        expect(
            retained.weakProbe.value != nil,
            "production teardown did not retain its XPC connection until invalidation"
        )
        retained.teardown.invalidate()
        expect(
            retained.counter.value == 1,
            "production teardown did not invoke connection invalidation exactly once"
        )
        expect(
            retained.weakProbe.value == nil,
            "production teardown retained its XPC connection after invalidation"
        )
        retained.teardown.invalidate()
        expect(
            retained.counter.value == 1,
            "repeated production teardown invalidated the connection more than once"
        )

        let externallyInvalidated = makeConnectionOwnershipFixture()

        expect(
            externallyInvalidated.weakProbe.value != nil,
            "external-invalidation wiring did not retain its XPC connection"
        )
        externallyInvalidated.teardown.connectionDidInvalidate()
        expect(
            externallyInvalidated.counter.value == 0,
            "external invalidation redundantly invoked connection invalidation"
        )
        expect(
            externallyInvalidated.weakProbe.value == nil,
            "external invalidation did not release its XPC connection"
        )
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

private final class TestConnectionProbe {}

private final class WeakTestConnectionProbe {
    weak var value: TestConnectionProbe?

    init(_ value: TestConnectionProbe) {
        self.value = value
    }
}

private final class TestConnectionInvalidationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private func makeConnectionOwnershipFixture() -> (
    teardown: StepImportClientConnectionTeardown,
    weakProbe: WeakTestConnectionProbe,
    counter: TestConnectionInvalidationCounter
) {
    let probe = TestConnectionProbe()
    let weakProbe = WeakTestConnectionProbe(probe)
    let counter = TestConnectionInvalidationCounter()
    let reference = StepImportClientConnectionReference(probe) { _ in
        counter.increment()
    }
    let teardown = StepImportClientConnectionTeardown {
        reference.invalidate()
    }
    return (teardown, weakProbe, counter)
}
