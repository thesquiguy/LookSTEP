import Foundation

/// On-demand redraw bookkeeping for the interactive viewport.
///
/// The viewport is a paused `MTKView`: it presents a frame only when a state
/// change asks for one. A single frame is enough for a camera change, but a
/// newly published scene is given a short settle burst so RealityKit has a
/// chance to make every resource resident before the view goes quiet again.
///
/// The scheduler stops permanently on a render failure. Nothing should keep
/// asking a broken renderer to draw, and `reset()` — called when a new model
/// load begins — is the only way back.
nonisolated struct StepRedrawScheduler: Sendable, Equatable {
    private(set) var pendingFrames = 0
    private(set) var isStopped = false

    /// True when at least one requested frame has not been presented yet.
    var wantsRedraw: Bool {
        !isStopped && pendingFrames > 0
    }

    /// Asks for `frames` presentations. Requests coalesce rather than
    /// accumulate: two overlapping single-frame requests are still one frame,
    /// and a burst request never shortens an outstanding longer burst.
    mutating func request(frames: Int = 1) {
        guard !isStopped else { return }
        pendingFrames = max(pendingFrames, max(1, frames))
    }

    /// Records that one requested frame is being presented. Returns `true` when
    /// another frame is still owed and the view must be marked dirty again.
    mutating func consumeFrame() -> Bool {
        guard !isStopped else { return false }
        pendingFrames = max(0, pendingFrames - 1)
        return pendingFrames > 0
    }

    /// Stops all further drawing after an unrecoverable render failure.
    mutating func stop() {
        pendingFrames = 0
        isStopped = true
    }

    /// Returns the scheduler to its initial state for a new model load.
    mutating func reset() {
        pendingFrames = 0
        isStopped = false
    }
}

/// Chooses the viewport's frame cadence from the display it is actually on.
///
/// Interaction stays at 60 Hz on a standard display and rises to the panel's
/// native rate on ProMotion, instead of being pinned to a hardcoded 60.
nonisolated enum StepDisplayRefreshPolicy {
    /// Used before the view has a window, and whenever the screen reports a
    /// rate that cannot be trusted.
    static let fallbackFramesPerSecond = 60
    static let minimumFramesPerSecond = 30
    static let maximumFramesPerSecond = 240

    static func preferredFramesPerSecond(screenMaximum: Int?) -> Int {
        guard let screenMaximum, screenMaximum > 0 else {
            return fallbackFramesPerSecond
        }
        return min(maximumFramesPerSecond, max(minimumFramesPerSecond, screenMaximum))
    }
}
