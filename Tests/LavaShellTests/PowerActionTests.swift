import Foundation
import Testing
@testable import LavaShell

@Suite("Power actions")
struct PowerActionTests {
    private func withCommand(_ script: String, _ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lava-power-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("systemctl")
        try ("#!/bin/sh\n" + script).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try body(executable)
    }

    @Test("every action preserves inhibitors and disables terminal prompts")
    func arguments() throws {
        for action in PowerAction.allCases {
            try withCommand("""
                test "$#" = 3 && test "$1" = '--no-ask-password' &&
                test "$2" = '--check-inhibitors=yes' && test "$3" = '\(action.rawValue)'
                """) { executable in
                #expect(action.perform(executable: executable) == nil)
            }
        }
    }

    @Test("system errors are returned for the dialog")
    func failure() throws {
        try withCommand("echo 'Not enough swap space for hibernation' >&2\nexit 1\n") { executable in
            #expect(PowerAction.hibernate.perform(executable: executable)
                == "Not enough swap space for hibernation")
        }
        try withCommand("exit 1\n") { executable in
            #expect(PowerAction.sleep.perform(executable: executable)
                == "The system refused the request.")
        }
        #expect(PowerAction.powerOff.perform(
            executable: URL(fileURLWithPath: "/nonexistent/lava-test-systemctl")) != nil)
    }

    @Test("large inhibitor reports are drained before waiting")
    func largeReport() throws {
        try withCommand("head -c 131072 /dev/zero | tr '\\000' x\nexit 1\n") { executable in
            #expect(PowerAction.powerOff.perform(executable: executable)?.count == 131072)
        }
    }
}
