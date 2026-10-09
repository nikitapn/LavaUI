import CxxCanvas
import Foundation

/// Runs GLib's work on the frame loop when there is some, and not otherwise.
///
/// D-Bus — the global menu, the tray, notifications — is GLib, and GLib only
/// gets anything done when its main context is iterated. The frame loop owns
/// everything that work touches, so it is the one that iterates; the question
/// is how it learns there is something to iterate for. It used to guess: an
/// app exporting a global menu capped its idle wait at 20 ms, and the panel
/// iterated from a 50 ms timer, so an idle desktop woke seventy times a second
/// to find nothing nearly every time.
///
/// Instead one thread per process sleeps on GLib's own file descriptors
/// (`canvas::waitForGLibEvents`), and when they say something arrived it hops
/// to the frame loop, which runs every registered pump, and waits for that to
/// finish before sleeping again. The hand-off is strict on purpose: the waiter
/// holds the GLib context while it sleeps, so the pumps are the only place the
/// context can be iterated, and they run while the waiter has let go of it.
///
/// A pump returns how long until it next needs a turn on its own account — a
/// toast's expiry is a clock GLib knows nothing about — or nil.
public enum GLibPump {
    /// Work for the frame loop. Returns milliseconds until it next has to run
    /// even if nothing arrives, or nil.
    public typealias Pump = () -> Int64?

    nonisolated(unsafe) private static var pumps: [Pump] = []
    nonisolated(unsafe) private static var started = false
    /// Written by the frame loop inside the hop, read by the waiter after the
    /// semaphore says the hop is done — the semaphore is the synchronisation.
    nonisolated(unsafe) private static var nextDeadline: Int64 = -1

    /// Registers a pump and starts the waiter if it is not running. Frame-loop
    /// thread only, and only once whatever needed to iterate GLib by hand at
    /// start-up has finished: from here on the waiter holds the context.
    public static func add(_ pump: @escaping Pump) {
        pumps.append(pump)
        guard !started else { return }
        started = true

        let turnDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var busy = 0
            while true {
                let immediate = canvas.Engine.waitForGLibEvents(nextDeadline)
                // A source that is always ready would otherwise turn this into
                // a spin. Never seen in practice; bounded anyway, at the rate
                // the old timers ran at.
                busy = immediate ? busy + 1 : 0
                if busy > 3 { Thread.sleep(forTimeInterval: 0.02) }
                MainQueue.async {
                    var next: Int64 = -1
                    for pump in pumps {
                        if let ms = pump(), ms >= 0 {
                            next = next < 0 ? ms : min(next, ms)
                        }
                    }
                    nextDeadline = next
                    turnDone.signal()
                }
                turnDone.wait()
            }
        }
    }
}
