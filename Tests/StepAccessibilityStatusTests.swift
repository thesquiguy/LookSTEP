import Darwin
import Foundation

@main
struct StepAccessibilityStatusTests {
    static func main() {
        let empty = StepAccessibilityStatus.empty(
            detail: "Drop a .step or .stp file here, or choose one."
        )
        expect(empty.identifier == "lookstep.status.empty",
               "empty status identifier changed")
        expect(empty.label == "No STEP model open",
               "empty status label changed")
        expect(empty.value.contains(".step"),
               "empty status lost its file-opening guidance")

        let loading = StepAccessibilityStatus.loading(
            phase: "Preparing model…",
            fileName: "gear.step"
        )
        expect(loading.identifier == "lookstep.status.loading",
               "loading status identifier changed")
        expect(loading.label == "Opening STEP model",
               "loading status label changed")
        expect(loading.value == "Preparing model…, gear.step",
               "loading status lost its phase or file name")

        let failure = StepAccessibilityStatus.failure(
            title: "Can’t open this STEP file",
            message: "The file is damaged."
        )
        expect(failure.identifier == "lookstep.status.failure",
               "failure status identifier changed")
        expect(failure.label == "Can’t open this STEP file",
               "failure status title changed")
        expect(failure.value == "The file is damaged.",
               "failure status lost its actionable detail")

        print("LookSTEP accessibility status tests passed")
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
