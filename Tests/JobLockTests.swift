import Foundation
import Darwin

func requireLock(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw driverError("Test failed: " + message) }
}
@main struct JobLockTests {
    static func main() throws {
        var events: [String] = []
        var clock: TimeInterval = 0
        var attempts = 0
        let descriptor = try acquireJobLock(check: { events.append("cancel-check") }, attempt: {
            attempts += 1
            events.append(attempts == 1 ? "busy" : "acquired")
            return attempts == 1 ? (Int32(AVANSIA_LOCK_BUSY), "busy") : (123, "")
        }, now: { clock }, pause: { delay in clock += delay; events.append("wait") })
        events.append("core-may-start")
        try requireLock(descriptor == 123 && attempts == 2 && clock == 0.25, "Busy-to-free acquisition succeeds without printing retry")
        try requireLock(events == ["cancel-check", "busy", "wait", "cancel-check", "acquired", "core-may-start"], "Cancellation precedes every attempt and Core begins only after acquisition")
        attempts = 0; clock = 0
        do {
            _ = try acquireJobLock(check: {}, attempt: { attempts += 1; return (-1, "Invalid printer lock file") }, now: { clock }, pause: { clock += $0 })
            throw driverError("Hard error unexpectedly succeeded")
        } catch { try requireLock(error.localizedDescription == "Invalid printer lock file", "Hard errors retain their diagnostic") }
        try requireLock(attempts == 1 && clock == 0, "Hard lock errors are never retried")
        attempts = 0; clock = 0
        do {
            _ = try acquireJobLock(check: {}, attempt: { attempts += 1; return (Int32(AVANSIA_LOCK_BUSY), "busy") }, now: { clock }, pause: { clock += $0 })
            throw driverError("Timeout unexpectedly succeeded")
        } catch { try requireLock(error.localizedDescription.contains("25 seconds"), "Contention timeout is explicit") }
        try requireLock(clock == 25 && attempts == 100, "Contention deadline prevents attempts at or after 25 seconds")
        attempts = 0; clock = 0
        do {
            _ = try acquireJobLock(check: { if attempts > 0 { throw JobCancelled() } }, attempt: { attempts += 1; return (Int32(AVANSIA_LOCK_BUSY), "busy") }, now: { clock }, pause: { clock += $0 })
            throw driverError("Canceled wait unexpectedly succeeded")
        } catch is JobCancelled {}
        try requireLock(attempts == 1 && clock == 0.25, "Cancellation during contention prevents the next acquisition attempt")
        setenv("IPP_JOB_URI", "ipp://localhost:18631/ipp/print/123", 1)
        setenv("CONTENT_TYPE", "application/pdf", 1)
        for mode: Int32 in [1, 2, 3, 4] {
            job_lock_test_reset(mode)
            var failed = false
            do { try runJob() } catch { failed = true }
            try requireLock(failed && job_lock_test_attempts() == 1, "Actual job stops on hard error, cancellation, unavailable IPP state, or signal while waiting")
            try requireLock(job_lock_test_core_calls() == 0, "Actual job invokes no Core command or card submission before acquiring its lock")
        }
        print("PASS: Job lock busy/free ordering, hard-error no retry, 25-second deadline, waiting cancellation, actual job URI/signal checks, and zero Core calls before acquisition")
    }
}
