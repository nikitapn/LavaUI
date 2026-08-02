import LavaUI

/// Small executable example for the first Scene3D vertical slice. It is kept
/// separate from DemoExample so applications can copy the complete pattern.
struct SpatialCatalogDemo: View {
    @State private var hovered: Int?
    @State private var selected: Int?

    var body: some View {
        Scene3D(height: .pt(320), flexGrow: 1) {
            ForEach3D(Array(0..<5), id: \.self) { index in
                Box3D(
                    id: index, width: 1.25, height: 1.25, depth: 0.08,
                    color: selected == index ? .selected : DemoPalette.color(at: index)
                )
                .position([Float(index - 2) * 1.4, 0, 0])
                .rotation3D(
                    angle: .degrees(hovered == index ? 12 : 0), axis: [0, 1, 0]
                )
                .offset3D(z: hovered == index ? 0.45 : 0)
                .scale3D(hovered == index ? 1.12 : 1)
                .animation3D(.smooth(duration: 0.24))
                .onHover3D { inside in hovered = inside ? index : nil }
                .onTap3D { selected = index }
            }
        }
        .background(Environment.current.theme.canvas)
        .cornerRadius(8)
        .clipped()
    }
}
