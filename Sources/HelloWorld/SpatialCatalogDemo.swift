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
        let layout = CatalogLayout3D.focusedShelf()
        let minimumDistance = layout.recommendedMinimumCameraDistance(
            itemCount: posters.count, itemWidth: 1.45, itemHeight: 1.45
        )

        Scene3D(
            height: .pt(320), flexGrow: 1,
            cameraControls: .orbit(
                minimumDistance: minimumDistance,
                maximumDistance: minimumDistance * 1.8
            )
        ) {
            AmbientLight3D(intensity: 0.28)
            DirectionalLight3D(direction: [-0.35, -0.6, -1], intensity: 1.05)
            ForEach3D(Array(posters.enumerated()), id: \.offset) { index, poster in
                Box3D(
                    id: index, width: 1.45, height: 1.45, depth: 0.08,
                    color: selected == index ? .selected : DemoPalette.color(at: index)
                )
                .material3D(.albumCover(front: poster))
                .shadow3D(radius: 15, offsetX: 7, offsetY: 11, opacity: 0.7)
                .reflection3D(
                    planeY: -0.73, opacity: 0.28,
                    fadeDistance: 1.5, blurRadius: 1.25
                )
                .catalog3D(
                    index: index, itemCount: posters.count,
                    focusedIndex: hovered, layout: layout
                )
                .animation3D(.spring(response: 0.3, dampingFraction: 0.7))
                .onHover3D { inside in hovered = inside ? index : nil }
                .onTap3D { selected = index }
            }
        }
        .background(Environment.current.theme.canvas)
        .cornerRadius(8)
    }
}
