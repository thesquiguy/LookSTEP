import Testing
@testable import LookSTEP

struct StepRedrawSchedulerTests {
    @Test func anIdleSchedulerAsksForNothing() {
        let scheduler = StepRedrawScheduler()
        #expect(scheduler.wantsRedraw == false)
        #expect(scheduler.pendingFrames == 0)
        #expect(scheduler.isStopped == false)
    }

    @Test func oneRequestPresentsExactlyOneFrame() {
        var scheduler = StepRedrawScheduler()
        scheduler.request()
        #expect(scheduler.wantsRedraw)
        let owesAnother = scheduler.consumeFrame()
        #expect(owesAnother == false)
        #expect(scheduler.wantsRedraw == false)
    }

    @Test func overlappingRequestsCoalesceInsteadOfAccumulating() {
        var scheduler = StepRedrawScheduler()
        scheduler.request()
        scheduler.request()
        scheduler.request()
        #expect(scheduler.pendingFrames == 1)
        let owesAnother = scheduler.consumeFrame()
        #expect(owesAnother == false)
    }

    @Test func aBurstPresentsEveryRequestedFrame() {
        var scheduler = StepRedrawScheduler()
        scheduler.request(frames: 3)
        let first = scheduler.consumeFrame()
        let second = scheduler.consumeFrame()
        let third = scheduler.consumeFrame()
        #expect(first)
        #expect(second)
        #expect(third == false)
        #expect(scheduler.wantsRedraw == false)
    }

    @Test func aSingleRequestNeverShortensAnOutstandingBurst() {
        var scheduler = StepRedrawScheduler()
        scheduler.request(frames: 3)
        scheduler.request()
        #expect(scheduler.pendingFrames == 3)
    }

    @Test func nonPositiveRequestsStillPresentOneFrame() {
        var scheduler = StepRedrawScheduler()
        scheduler.request(frames: 0)
        #expect(scheduler.pendingFrames == 1)
        scheduler.reset()
        scheduler.request(frames: -4)
        #expect(scheduler.pendingFrames == 1)
    }

    @Test func aStoppedSchedulerRefusesEveryFurtherFrame() {
        var scheduler = StepRedrawScheduler()
        scheduler.request(frames: 5)
        scheduler.stop()
        #expect(scheduler.wantsRedraw == false)
        #expect(scheduler.pendingFrames == 0)
        scheduler.request(frames: 5)
        #expect(scheduler.wantsRedraw == false)
        let owesAnother = scheduler.consumeFrame()
        #expect(owesAnother == false)
    }

    @Test func resetRecoversFromAFailureForTheNextLoad() {
        var scheduler = StepRedrawScheduler()
        scheduler.stop()
        scheduler.reset()
        #expect(scheduler.isStopped == false)
        scheduler.request()
        #expect(scheduler.wantsRedraw)
    }

    @Test func consumingAnUnrequestedFrameStaysIdle() {
        var scheduler = StepRedrawScheduler()
        let owesAnother = scheduler.consumeFrame()
        #expect(owesAnother == false)
        #expect(scheduler.pendingFrames == 0)
    }
}

struct StepDisplayRefreshPolicyTests {
    @Test func anUnknownScreenFallsBackToSixtyHertz() {
        #expect(StepDisplayRefreshPolicy.preferredFramesPerSecond(screenMaximum: nil) == 60)
        #expect(StepDisplayRefreshPolicy.preferredFramesPerSecond(screenMaximum: 0) == 60)
        #expect(StepDisplayRefreshPolicy.preferredFramesPerSecond(screenMaximum: -1) == 60)
    }

    @Test func aProMotionDisplayGetsItsNativeRate() {
        #expect(StepDisplayRefreshPolicy.preferredFramesPerSecond(screenMaximum: 120) == 120)
        #expect(StepDisplayRefreshPolicy.preferredFramesPerSecond(screenMaximum: 60) == 60)
    }

    @Test func implausibleRatesAreClamped() {
        #expect(StepDisplayRefreshPolicy.preferredFramesPerSecond(screenMaximum: 1) == 30)
        #expect(StepDisplayRefreshPolicy.preferredFramesPerSecond(screenMaximum: 1_000) == 240)
    }
}
