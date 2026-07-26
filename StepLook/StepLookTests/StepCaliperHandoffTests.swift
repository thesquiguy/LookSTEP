import Foundation
import Testing
@testable import LookSTEP

@Suite("Caliper handoff configuration")
struct StepCaliperHandoffTests {
    @Test("A real reverse-DNS identifier is accepted")
    func aRealIdentifierIsAccepted() {
        #expect(StepCaliperHandoff.isValidBundleIdentifier("com.local.stepviewer.Caliper"))
        #expect(StepCaliperHandoff.isValidBundleIdentifier("com.example.App-Name"))
    }

    @Test("An unsubstituted build setting never becomes an identifier")
    func anUnsubstitutedBuildSettingIsRejected() {
        // The whole feature must degrade to absent rather than to a broken
        // action when the build setting is missing.
        #expect(!StepCaliperHandoff.isValidBundleIdentifier("$(STEPLOOK_CALIPER_BUNDLE_IDENTIFIER)"))
        #expect(StepCaliperHandoff(bundleIdentifier: "$(STEPLOOK_CALIPER_BUNDLE_IDENTIFIER)") == nil)
    }

    @Test("Malformed identifiers are rejected")
    func malformedIdentifiersAreRejected() {
        #expect(!StepCaliperHandoff.isValidBundleIdentifier(""))
        #expect(!StepCaliperHandoff.isValidBundleIdentifier("Caliper"))
        #expect(!StepCaliperHandoff.isValidBundleIdentifier("com..Caliper"))
        #expect(!StepCaliperHandoff.isValidBundleIdentifier("com.local.Cal iper"))
        #expect(!StepCaliperHandoff.isValidBundleIdentifier("com.local.Caliper;rm"))
    }

    @Test("A missing Info.plist key yields no handoff")
    func aMissingKeyYieldsNoHandoff() {
        #expect(StepCaliperHandoff.configured(bundle: Bundle(for: EmptyMarker.self)) == nil)
    }
}

private final class EmptyMarker {}

@Suite("Failure advice adapts to whether Caliper is installed")
struct StepPreviewAdviceTests {
    @Test("With Caliper installed the message names it and offers the action")
    func withCaliperInstalledTheMessageNamesIt() {
        let advice = StepPreviewAdvice.make(
            base: "Too complex.",
            caliperClause: "Open it in Caliper for exact geometry.",
            fallbackClause: "Try a smaller file.",
            caliperInstalled: true
        )
        #expect(advice.offersCaliper)
        #expect(advice.message == "Too complex. Open it in Caliper for exact geometry.")
    }

    @Test("Without Caliper the message never names it")
    func withoutCaliperTheMessageNeverNamesIt() {
        let advice = StepPreviewAdvice.make(
            base: "Too complex.",
            caliperClause: "Open it in Caliper for exact geometry.",
            fallbackClause: "Try a smaller file.",
            caliperInstalled: false
        )
        #expect(!advice.offersCaliper)
        #expect(!advice.message.contains("Caliper"))
        #expect(advice.message == "Too complex. Try a smaller file.")
    }

    @Test("With no fallback the base sentence stands alone")
    func withNoFallbackTheBaseStandsAlone() {
        let advice = StepPreviewAdvice.make(
            base: "Too complex.",
            caliperClause: "Open it in Caliper for exact geometry.",
            fallbackClause: nil,
            caliperInstalled: false
        )
        #expect(advice.message == "Too complex.")
        #expect(!advice.offersCaliper)
    }

    @Test("Budget refusals never name Caliper when it is absent")
    func budgetRefusalsNeverNameAnAbsentCaliper() {
        for error: StepPreviewImportBudgetError in [
            .compatibleCacheRequired,
            .predictedCostExceedsBudget(predictedSeconds: 41, budgetSeconds: 13.5),
        ] {
            let absent = StepPreviewErrorMessage.advice(for: error, caliperInstalled: false)
            #expect(!absent.message.contains("Caliper"))
            #expect(!absent.offersCaliper)

            let present = StepPreviewErrorMessage.advice(for: error, caliperInstalled: true)
            #expect(present.message.contains("Caliper"))
            #expect(present.offersCaliper)
        }
    }

    @Test("The logged description never promises Caliper")
    func theLoggedDescriptionNeverPromisesCaliper() {
        // errorDescription reaches logs and NSError bridging, where the
        // machine's installation state is unknown.
        for error: StepPreviewImportBudgetError in [
            .compatibleCacheRequired,
            .predictedCostExceedsBudget(predictedSeconds: 41, budgetSeconds: 13.5),
        ] {
            #expect(error.errorDescription?.contains("Caliper") == false)
        }
    }

    @Test("Failures Caliper cannot help with do not offer it")
    func failuresCaliperCannotHelpWithDoNotOfferIt() {
        // A damaged file and one with no usable geometry fail identically in
        // Caliper, so sending the user there would only waste a cold import.
        for code in [1, 2, 3, 5] {
            let error = NSError(domain: "com.local.stepviewer.import", code: code)
            let advice = StepPreviewErrorMessage.advice(for: error, caliperInstalled: true)
            #expect(!advice.offersCaliper)
            #expect(!advice.message.contains("Caliper"))
        }
    }

    @Test("Complexity and timeout failures do offer Caliper")
    func complexityAndTimeoutFailuresOfferCaliper() {
        for code in [4, 6] {
            let error = NSError(domain: "com.local.stepviewer.import", code: code)
            let advice = StepPreviewErrorMessage.advice(for: error, caliperInstalled: true)
            #expect(advice.offersCaliper)
            #expect(advice.message.contains("Caliper"))
        }
    }

    @Test("The simplified badge only points at an installed Caliper")
    func theSimplifiedBadgeOnlyPointsAtAnInstalledCaliper() {
        let absent = StepSimplifiedPreviewNotice(caliperInstalled: false)
        #expect(!absent.detail.contains("Caliper"))
        #expect(!absent.offersCaliper)
        #expect(absent.detail == StepSimplifiedPreviewNotice.base)

        let present = StepSimplifiedPreviewNotice(caliperInstalled: true)
        #expect(present.detail.contains("Caliper"))
        #expect(present.offersCaliper)
        #expect(present.accessibilityLabel.contains(present.summary))
    }
}
