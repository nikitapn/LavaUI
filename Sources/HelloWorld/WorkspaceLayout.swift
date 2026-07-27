#if canImport(CxxCanvas)

/// Panel roles for the Yoga workspace (must match shell::PanelKind).
public enum WorkspacePanel: Int32, Sendable {
    case projectTree = 0
    case diagram = 1
    case properties = 2
    case log = 3
}

/// Declarative chrome layout — SwiftUI-inspired, not SwiftUI.
///
/// Describes how the ImGui shell is partitioned; C++/Yoga turns this into
/// pixel rects each frame. The diagram panel is always the flex-grow center
/// in the standard three-column layout.
public struct WorkspaceLayout: Sendable {
    public var left: WorkspacePanel
    public var center: WorkspacePanel
    public var right: WorkspacePanel
    public var leftWidth: Float
    public var rightWidth: Float

    public init(
        left: WorkspacePanel = .projectTree,
        center: WorkspacePanel = .diagram,
        right: WorkspacePanel = .properties,
        leftWidth: Float = 220,
        rightWidth: Float = 260
    ) {
        self.left = left
        self.center = center
        self.right = right
        self.leftWidth = leftWidth
        self.rightWidth = rightWidth
    }

    /// Standard FBD editor: tree | diagram | properties.
    public static var standard: WorkspaceLayout { WorkspaceLayout() }

    /// Wider tree, narrower properties.
    public static var wideTree: WorkspaceLayout {
        WorkspaceLayout(leftWidth: 280, rightWidth: 220)
    }
}

#endif
