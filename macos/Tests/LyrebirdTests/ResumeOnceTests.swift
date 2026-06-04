import XCTest

@testable import Lyrebird

/// Coverage for `ResumeOnce`, the one-shot continuation guard that makes the
/// Dock-badge observer's `withTaskCancellationHandler` safe.
///
/// The observer suspends on a `CheckedContinuation` that can be resumed by two
/// racers: the `withObservationTracking` `onChange` (main actor) and the
/// `withTaskCancellationHandler` `onCancel` (any thread). A bare
/// `CheckedContinuation` *traps* on a second resume and *warns/leaks* if never
/// resumed, so these tests lean on a real `withCheckedContinuation` to assert
/// the "resume exactly once, never park" contract end-to-end: if the guard
/// double-resumed, the test would crash; if it failed to resume, the test
/// would hang and time out.
final class ResumeOnceTests: XCTestCase {

    /// The common path: install the continuation, then a single `resume()`
    /// (e.g. an `onChange`) wakes the awaiter exactly once.
    func testStoreThenResumeWakesAwaiterOnce() async {
        let box = ResumeOnce()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            box.store(continuation)
            box.resume()
        }
        // Reaching here means the continuation resumed. A second resume must be
        // an inert no-op rather than a fatal double-resume of the (now consumed)
        // continuation.
        box.resume()
        box.resume()
    }

    /// Cancellation can fire *before* the continuation is installed (the
    /// `onCancel` racing ahead of `withCheckedContinuation`'s body). The late
    /// `store` must resume immediately so the task never parks forever.
    func testResumeBeforeStoreResumesLateContinuation() async {
        let box = ResumeOnce()
        // Simulate onCancel landing first.
        box.resume()
        // The body installs its continuation afterwards; it must not hang.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            box.store(continuation)
        }
    }

    /// Many concurrent `resume()` callers plus the `store` must still resume the
    /// continuation exactly once — no trap, no hang. Models the worst-case
    /// onChange/onCancel collision across threads.
    func testConcurrentResumeAndStoreResumeExactlyOnce() async {
        let box = ResumeOnce()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            box.store(continuation)
            DispatchQueue.concurrentPerform(iterations: 64) { _ in
                box.resume()
            }
        }
        // Survived the storm without a double-resume trap; further resumes inert.
        box.resume()
    }

    /// A `resume()` with no continuation ever stored (e.g. cancellation before
    /// the loop ever suspends) must be a harmless no-op.
    func testResumeWithoutStoreIsNoOp() {
        let box = ResumeOnce()
        box.resume()
        box.resume()
    }
}
