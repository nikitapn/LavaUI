#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
src=Tests/ExtensionHostIntegration
cc -Wall -Wextra -Werror -fPIC -shared "$src/fixture.c" -o "$tmp/extension.so"
cc -Wall -Wextra -Werror -fPIC -shared -DLEGACY "$src/fixture.c" -o "$tmp/legacy.so"
cc -Wall -Wextra -Werror -I Sources/CExtensionHost/include "$src/main.c" Sources/CExtensionHost/extension_host.c -ldl -o "$tmp/driver"
if [ "${1:-}" = "--swift-test" ]; then
    export TEST_SWIFT_PACKAGE="$tmp/package" TEST_CLI_PID="$tmp/cli" TEST_CASE_PID="$tmp/test"
    mkdir -p "$TEST_SWIFT_PACKAGE/Tests/WaitTests"
    cat > "$TEST_SWIFT_PACKAGE/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Wait", targets: [.testTarget(name: "WaitTests")])
SWIFT
    cat > "$TEST_SWIFT_PACKAGE/Tests/WaitTests/WaitTests.swift" <<'SWIFT'
import Foundation
import XCTest

final class WaitTests: XCTestCase {
    func testWait() throws {
        let process = ProcessInfo.processInfo
        let path = try XCTUnwrap(process.environment["TEST_CASE_PID"])
        try String(process.processIdentifier).write(toFile: path, atomically: true, encoding: .utf8)
        Thread.sleep(forTimeInterval: 60)
    }
}
SWIFT
    swift build --build-system native --package-path "$TEST_SWIFT_PACKAGE" --build-tests
fi
"$tmp/driver" "$tmp/extension.so" "$tmp/legacy.so" "$tmp/children"
