import Foundation
import XCTest

@testable import LavaUI

/// Two processes of one app share one `settings.json` — two explorer windows,
/// one per workspace profile. A write used to put back every key as this
/// process had loaded it at start-up, undoing what the other had saved since.
/// "The other process" here is the test writing the file behind the cache's
/// back, which is all another process ever does.
final class AppSettingsTests: XCTestCase {
    private var root = ""
    private var savedXDG: String?
    private var file: URL { AppSettings.fileURL }

    override func setUpWithError() throws {
        root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("lava-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        savedXDG = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        setenv("XDG_CONFIG_HOME", root, 1)
        AppSettings.configure(appName: "SettingsTest-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let savedXDG { setenv("XDG_CONFIG_HOME", savedXDG, 1) } else { unsetenv("XDG_CONFIG_HOME") }
        AppSettings.configure(appName: "LavaUI")
        try? FileManager.default.removeItem(atPath: root)
    }

    /// What another process would leave on disk: the file, rewritten whole.
    private func otherProcessWrites(_ json: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: file, options: .atomic)
    }

    private func onDisk() throws -> [String: Any] {
        let data = try Data(contentsOf: file)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAWriteKeepsWhatAnotherProcessSavedSince() throws {
        AppSettings.set("mine", forKey: "a")
        // Another window saves its own key after this one loaded.
        var disk = try onDisk()
        disk["b"] = "theirs"
        try otherProcessWrites(disk)

        AppSettings.set("mine again", forKey: "a")

        let after = try onDisk()
        XCTAssertEqual(after["a"] as? String, "mine again")
        XCTAssertEqual(after["b"] as? String, "theirs", "the other process's key survives")
    }

    func testRemoveKeepsWhatAnotherProcessSavedSince() throws {
        AppSettings.set(1, forKey: "gone")
        var disk = try onDisk()
        disk["b"] = "theirs"
        try otherProcessWrites(disk)

        AppSettings.remove("gone")

        let after = try onDisk()
        XCTAssertNil(after["gone"])
        XCTAssertEqual(after["b"] as? String, "theirs")
    }

    func testUpdateSeesTheValueAsItIsOnDisk() throws {
        AppSettings.set(["home": 1], forKey: "counts")
        // The other window adds its entry to the same key.
        try otherProcessWrites(["counts": ["home": 1, "work": 5]])

        AppSettings.update([String: Int].self, forKey: "counts") { current in
            var counts = current ?? [:]
            counts["home", default: 0] += 1
            return counts
        }

        XCTAssertEqual(
            AppSettings.value(forKey: "counts", as: [String: Int].self),
            ["home": 2, "work": 5]
        )
        XCTAssertEqual(try onDisk()["counts"] as? [String: Int], ["home": 2, "work": 5])
    }

    func testUpdateStartsFromNilWhenTheKeyIsMissing() throws {
        AppSettings.update([String].self, forKey: "list") { current in
            XCTAssertNil(current)
            return ["first"]
        }
        XCTAssertEqual(AppSettings.value(forKey: "list", as: [String].self), ["first"])
    }

    func testReloadSeesWhatAnotherProcessSaved() throws {
        AppSettings.set("before", forKey: "shared")
        try otherProcessWrites(["shared": "after"])
        // Reads are served from what this process loaded...
        XCTAssertEqual(AppSettings.string(forKey: "shared"), "before")
        AppSettings.reload()
        // ...until it looks again.
        XCTAssertEqual(AppSettings.string(forKey: "shared"), "after")
    }
}
