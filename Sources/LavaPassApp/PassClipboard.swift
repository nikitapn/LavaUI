import Foundation
import LavaUI

/// A lease on only the password we copied. Never clear a later clipboard value.
/// Exit cleanup also runs for client-mode close, which can exit from its watchdog.
enum PassClipboard {
    private static let mutex = NSLock()
    nonisolated(unsafe) private static var value: String?
    nonisolated(unsafe) private static var generation = 0

    static func copy(_ secret: String) {
        mutex.lock()
        generation += 1
        let token = generation
        value = secret
        ClipboardBridge.write(secret)
        mutex.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) {
            MainQueue.async { clear(ifGeneration: token) }
        }
    }
    static func clear() { clear(ifGeneration: nil) }
    private static func clear(ifGeneration token: Int?) {
        mutex.lock()
        defer { mutex.unlock() }
        if let token, token != generation { return }
        if let value, ClipboardBridge.read() == value { ClipboardBridge.write("") }
        value = nil
        generation += 1
    }
}
