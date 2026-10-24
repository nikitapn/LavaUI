import Foundation
import Glibc
import Testing
@testable import LavaShell

@Suite("Child process monitor")
struct ChildProcessMonitorTests {
    private func spawn(_ arguments: [String]) throws -> pid_t {
        let argv = arguments.map { strdup($0) } + [nil]
        defer { for pointer in argv { free(pointer) } }
        var pid: pid_t = 0
        let error = posix_spawnp(&pid, arguments[0], nil, nil, argv, environ)
        #expect(error == 0)
        return try #require(error == 0 ? pid : nil)
    }

    @Test("reaps launch bursts after idle without collecting unrelated children")
    func reapsOwnedChildren() throws {
        let unrelated = try spawn(["/bin/sh", "-c", "exit 23"])
        defer {
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(unrelated, &status, 0) }
            while result == -1 && errno == EINTR
            #expect(result == unrelated)
            #expect(status == 23 << 8)
        }

        // A second wave wakes a monitor that has already returned to idle.
        for _ in 0..<2 {
            var pids: [pid_t] = []
            for _ in 0..<32 {
                let pid = try spawn(["/bin/sleep", "0.02"])
                pids.append(pid)
                ChildProcessMonitor.shared.track(pid)
            }
            let deadline = Date().addingTimeInterval(5)
            var remaining = pids
            repeat {
                remaining = remaining.filter { kill($0, 0) == 0 || errno != ESRCH }
                if remaining.isEmpty { break }
                Thread.sleep(forTimeInterval: 0.01)
            } while Date() < deadline
            #expect(remaining.isEmpty, "Children still present: \(remaining)")
        }
    }
}
