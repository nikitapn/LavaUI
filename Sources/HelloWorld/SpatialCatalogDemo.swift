import LavaUI

/// Small executable example for the first Scene3D vertical slice. It is kept
/// separate from DemoExample so applications can copy the complete pattern.
struct SpatialCatalogDemo: View {
    private let posters: [UIImage]
    @State private var hovered: Int?
    @State private var selected: Int?

    init(_ posters: [UIImage]) {
        self.posters = posters
    }

    var body: some View {

        Scene3D(height: .pt(320), flexGrow: 1) {
            AmbientLight3D(intensity: 0.28)
            DirectionalLight3D(direction: [-0.35, -0.6, -1], intensity: 1.05)
            ForEach3D(Array(posters.enumerated()), id: \.offset) { index, poster in
                Box3D(
                    id: index, width: 1.45, height: 1.45, depth: 0.08,
                    color: selected == index ? .selected : DemoPalette.color(at: index)
                )
                .material3D(.albumCover(front: poster))
                .shadow3D(radius: 15, offsetX: 7, offsetY: 11, opacity: 0.7)
                .position([Float(index - 3) * 1.6, 0, 0])
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
