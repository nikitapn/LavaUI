#if canImport(CxxCanvas)
import Foundation
import LavaMenu

/// Which code path owns the menubar. Phase 2 is always Vulkan; phase 3 may
/// choose DBusMenu when a global-menu registrar is available.
public enum MenuBackendKind: Equatable, Sendable {
    /// In-window strip + overlays drawn by LavaUI.
    case vulkan
}

/// App-level menubar owner: retains `MenuController` and the active backend.
///
/// Phase 2 always uses the Vulkan host. Call `update` when rebuilding the
/// declarative menu; the view chrome reads `controller.model`.
public final class MenuHost {
    public let controller = MenuController()
    public private(set) var backend: MenuBackendKind = .vulkan

    public init() {}

    /// Rebuild IR from a menubar description. Returns whether the model changed.
    @discardableResult
    public func update(_ bar: MenuBar) -> Bool {
        controller.update(bar)
    }

    @discardableResult
    public func update(@MenuBarBuilder _ content: () -> [Menu]) -> Bool {
        controller.update(content)
    }

    @discardableResult
    public func activate(_ id: MenuID) -> Bool {
        guard let item = controller.model.item(id: id) else {
            return controller.activate(id)
        }
        guard item.isEnabled else { return false }
        return controller.activate(id)
    }

    @discardableResult
    public func activate(
        matchingKey key: Int32,
        mods: Int32
    ) -> Bool {
        controller.activate(matchingKey: key, mods: mods)
    }

    public var model: MenuModel { controller.model }

    public var isEmpty: Bool { model.menus.isEmpty }

    /// Default strip height in layout pixels. Sized for the default UI face
    /// (~16px) plus title padding without overflowing into the content area.
    public static let barHeight: Float = 30
}

#endif
