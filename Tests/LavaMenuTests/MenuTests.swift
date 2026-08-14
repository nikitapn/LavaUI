import XCTest
@testable import LavaMenu

/// GLFW letter keys (same as LavaUI `KeyCode`).
private enum K {
    static let n: Int32 = 78
    static let o: Int32 = 79
    static let s: Int32 = 83
}

final class MenuTests: XCTestCase {
    func testResolveBasicStructureAndAutoIds() {
        let bar = MenuBar {
            Menu("File") {
                MenuItem("Open…") {}
                MenuItem("Save") {}
                MenuSeparator()
                MenuItem("Quit") {}
            }
            Menu("Edit") {
                MenuItem("Copy") {}
            }
        }

        let (model, actions) = bar.resolve()
        XCTAssertEqual(model.menus.count, 2)
        XCTAssertEqual(model.menus[0].title, "File")
        XCTAssertEqual(model.menus[0].id.raw, "file")
        XCTAssertEqual(model.menus[1].title, "Edit")
        XCTAssertEqual(model.menus[1].id.raw, "edit")

        let fileItems = model.menus[0].items
        XCTAssertEqual(fileItems.count, 4)
        guard case .item(let open) = fileItems[0] else {
            return XCTFail("expected item")
        }
        XCTAssertEqual(open.title, "Open…")
        XCTAssertEqual(open.id.raw, "file/open")
        guard case .separator = fileItems[2] else {
            return XCTFail("expected separator")
        }
        guard case .item(let quit) = fileItems[3] else {
            return XCTFail("expected quit")
        }
        XCTAssertEqual(quit.id.raw, "file/quit")

        XCTAssertEqual(actions.count, 4) // open, save, quit, copy — no separator
        XCTAssertTrue(actions.contains(MenuID("file/open")))
        XCTAssertTrue(actions.contains(MenuID("edit/copy")))
        XCTAssertFalse(actions.contains(MenuID("file")))
    }

    func testExplicitIdsAndDedup() {
        let bar = MenuBar {
            Menu("File", id: "file") {
                MenuItem("Save", id: "file.save") {}
                MenuItem("Save As…", id: "file.save") {} // clash → suffix
            }
        }
        let (model, actions) = bar.resolve()
        guard case .item(let a) = model.menus[0].items[0],
              case .item(let b) = model.menus[0].items[1]
        else {
            return XCTFail("expected two items")
        }
        XCTAssertEqual(a.id.raw, "file.save")
        XCTAssertEqual(b.id.raw, "file.save-2")
        XCTAssertEqual(actions.ids, [MenuID("file.save"), MenuID("file.save-2")])
    }

    func testSubmenuNestedInModel() {
        let bar = MenuBar {
            Menu("File") {
                Menu("Export") {
                    MenuItem("PNG") {}
                    MenuItem("SVG") {}
                }
                MenuItem("Close") {}
            }
        }
        let (model, _) = bar.resolve()
        XCTAssertEqual(model.menus[0].items.count, 2)
        guard case .submenu(let export) = model.menus[0].items[0] else {
            return XCTFail("expected submenu")
        }
        XCTAssertEqual(export.title, "Export")
        XCTAssertEqual(export.id.raw, "file/export")
        XCTAssertEqual(export.items.count, 2)
        guard case .item(let png) = export.items[0] else {
            return XCTFail("expected png")
        }
        XCTAssertEqual(png.id.raw, "file/export/png")
        XCTAssertEqual(model.allItems.map(\.title), ["PNG", "SVG", "Close"])
    }

    func testIfElseAndForEachInBuilder() {
        let showQuit = true
        let extras = ["A", "B"]
        let bar = MenuBar {
            Menu("File") {
                MenuItem("New") {}
                if showQuit {
                    MenuItem("Quit") {}
                }
                for name in extras {
                    MenuItem(name) {}
                }
            }
            if !showQuit {
                Menu("Hidden") {
                    MenuItem("Nope") {}
                }
            }
        }
        let (model, actions) = bar.resolve()
        XCTAssertEqual(model.menus.count, 1)
        XCTAssertEqual(model.menus[0].items.count, 4)
        XCTAssertEqual(actions.count, 4)
        XCTAssertNotNil(model.item(id: MenuID("file/quit")))
        XCTAssertNotNil(model.item(id: MenuID("file/a")))
        XCTAssertNotNil(model.item(id: MenuID("file/b")))
    }

    func testEquatableModelIgnoresActions() {
        var hits = 0
        let bar1 = MenuBar {
            Menu("File") {
                MenuItem("Open", id: "open", isEnabled: true) { hits += 1 }
            }
        }
        let bar2 = MenuBar {
            Menu("File") {
                MenuItem("Open", id: "open", isEnabled: true) { hits += 10 }
            }
        }
        let m1 = bar1.resolve().model
        let m2 = bar2.resolve().model
        XCTAssertEqual(m1, m2)

        let bar3 = MenuBar {
            Menu("File") {
                MenuItem("Open", id: "open", isEnabled: false) {}
            }
        }
        XCTAssertNotEqual(m1, bar3.resolve().model)
    }

    func testActivateAndControllerUpdate() {
        var log: [String] = []
        let controller = MenuController {
            Menu("File") {
                MenuItem("Open", id: "open") { log.append("open") }
                MenuItem("Save", id: "save", isEnabled: false) { log.append("save") }
            }
        }

        XCTAssertTrue(controller.activate("open"))
        XCTAssertEqual(log, ["open"])
        // Phase 1: activate does not enforce isEnabled — host UI should.
        XCTAssertTrue(controller.activate("save"))
        XCTAssertEqual(log, ["open", "save"])
        XCTAssertFalse(controller.activate("missing"))

        let changedSame = controller.update {
            Menu("File") {
                MenuItem("Open", id: "open") { log.append("open2") }
                MenuItem("Save", id: "save", isEnabled: false) { log.append("save2") }
            }
        }
        XCTAssertFalse(changedSame)
        XCTAssertTrue(controller.activate("open"))
        XCTAssertEqual(log.last, "open2")

        let changed = controller.update {
            Menu("File") {
                MenuItem("Open", id: "open") {}
                MenuItem("Save As…", id: "save-as") { log.append("save-as") }
            }
        }
        XCTAssertTrue(changed)
        XCTAssertEqual(controller.model.allItems.map(\.id.raw), ["open", "save-as"])
        XCTAssertTrue(controller.activate("save-as"))
        XCTAssertEqual(log.last, "save-as")
    }

    func testShortcutsResolveAndMatch() {
        let save = KeyShortcut(K.s, .primary)
        let saveAs = KeyShortcut(K.s, .primary, .shift)
        XCTAssertEqual(save.resolvedMods(), MenuKeyMods.control) // Linux primary
        XCTAssertEqual(saveAs.resolvedMods(), MenuKeyMods.control | MenuKeyMods.shift)
        XCTAssertTrue(save.matches(key: K.s, mods: MenuKeyMods.control))
        XCTAssertFalse(save.matches(key: K.s, mods: MenuKeyMods.control | MenuKeyMods.shift))
        XCTAssertTrue(saveAs.matches(key: K.s, mods: MenuKeyMods.control | MenuKeyMods.shift))

        var opened = false
        let bar = MenuBar {
            Menu("File") {
                MenuItem("Open", id: "open", shortcut: KeyShortcut(K.o, .primary)) {
                    opened = true
                }
                MenuItem("Disabled", id: "nope", shortcut: KeyShortcut(K.n, .primary), isEnabled: false) {}
            }
        }
        let controller = MenuController(bar)
        XCTAssertFalse(
            controller.activate(matchingKey: K.o, mods: 0)
        )
        XCTAssertTrue(
            controller.activate(matchingKey: K.o, mods: MenuKeyMods.control)
        )
        XCTAssertTrue(opened)
        // Disabled items are skipped by matchingKey.
        XCTAssertFalse(
            controller.activate(matchingKey: K.n, mods: MenuKeyMods.control)
        )
    }

    func testCheckedAndEnabledInModel() {
        let bar = MenuBar {
            Menu("View") {
                MenuItem("Sidebar", id: "sidebar", isChecked: true) {}
                MenuItem("Ghost", id: "ghost", isEnabled: false) {}
            }
        }
        let model = bar.resolve().model
        let sidebar = model.item(id: MenuID("sidebar"))
        XCTAssertEqual(sidebar?.isChecked, true)
        XCTAssertEqual(model.item(id: MenuID("ghost"))?.isEnabled, false)
    }

    func testTopLevelIconSurvivesResolve() {
        let icon = MenuIcon(size: 18, path: "/tmp/lava.svg")
        let bar = MenuBar {
            Menu("Lava", id: "desktop", icon: icon) {
                MenuItem("Settings…", id: "desktop.settings") {}
            }
            Menu("File") {
                MenuItem("Open") {}
            }
        }
        let model = bar.resolve().model
        XCTAssertEqual(model.menus[0].icon, icon)
        XCTAssertEqual(model.menus[0].title, "Lava")
        XCTAssertNil(model.menus[1].icon)
    }
}
