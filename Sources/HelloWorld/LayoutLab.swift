import LavaUI

/// Visual counterpart of `LayoutCatalogTests`.
///
/// DemoExample's widget playground is a kitchen sink; this is the page for
/// "what size did Yoga actually give that box?". Each specimen is bordered
/// so a width-without-height image that kept its native pixels is obvious
/// without reading `layout_tree`.
struct LayoutLab: View {
    /// A loaded bitmap, used for the Image cases. Synthetic textures have
    /// no GPU id, so the running demo needs a real poster or brand mark.
    var sample: UIImage?

    var body: some View {
        let theme = Environment.current.theme
        return VStack(flexGrow: 1, padding: 8, alignment: .start, spacing: 10) {
            Text("Layout lab", color: .accent)
            Text(
                "Specimens from LayoutCatalogTests. The border is the layout box.",
                color: .secondary
            )
            imageSection(theme: theme)
            stackSection(theme: theme)
            flexSection(theme: theme)
            percentSection(theme: theme)
        }
    }

    // MARK: - Image

    @ViewBuilder
    private func imageSection(theme: Theme) -> some View {
        Text("Image", color: .accent)
        if let sample {
            let nativeW = sample.pixelWidth
            let nativeH = sample.pixelHeight
            let scaledH = 120 * nativeH / nativeW
            caption(
                "native \(Int(nativeW))×\(Int(nativeH))  ·  width 120, height auto → "
                    + "120×\(Int(scaledH.rounded()))"
            )
            specimen(theme: theme, id: "layout-lab-image-width-only") {
                Image(sample, width: .pt(120), contentMode: .fit)
            }
            caption("height 60, width auto")
            specimen(theme: theme, id: "layout-lab-image-height-only") {
                Image(sample, height: .pt(60), contentMode: .fit)
            }
            caption("both auto — intrinsic pixels")
            specimen(theme: theme, id: "layout-lab-image-native") {
                Image(sample, contentMode: .fit)
            }
            caption("80×80 box, contentMode .fit")
            specimen(theme: theme, id: "layout-lab-image-fit") {
                Image(sample, width: .pt(80), height: .pt(80), contentMode: .fit)
            }
            caption("80×80 box, contentMode .fill")
            specimen(theme: theme, id: "layout-lab-image-fill") {
                Image(sample, width: .pt(80), height: .pt(80), contentMode: .fill)
                    .clipped()
            }
            caption(".frame(width: 120) on an intrinsic image")
            specimen(theme: theme, id: "layout-lab-image-frame-width") {
                Image(sample, contentMode: .fit)
                    .frame(width: .pt(120))
            }
            caption(".frame(width: 80, height: 80) — square box, bitmap letterboxed")
            specimen(theme: theme, id: "layout-lab-image-frame-both") {
                Image(sample, contentMode: .fit)
                    .frame(width: .pt(80), height: .pt(80))
            }
            caption("stretch in a 200pt column, height from aspect")
            specimen(theme: theme, id: "layout-lab-image-column") {
                VStack(width: .pt(200), alignment: .stretch, spacing: 0) {
                    Image(sample, contentMode: .fit)
                }
            }
        } else {
            Text("No sample bitmap loaded — Image cases skipped.", color: .dim)
        }
    }

    // MARK: - Stacks

    @ViewBuilder
    private func stackSection(theme: Theme) -> some View {
        Text("Stacks", color: .accent)
        caption("HStack spacing 8")
        specimen(theme: theme, id: "layout-lab-hstack-spacing") {
            HStack(spacing: 8) {
                swatch("A", theme: theme, w: 28, h: 28)
                swatch("B", theme: theme, w: 28, h: 28)
                swatch("C", theme: theme, w: 28, h: 28)
            }
        }
        caption("HStack alignment .center — short box should sit mid-tall")
        specimen(theme: theme, id: "layout-lab-hstack-center") {
            HStack(alignment: .center, spacing: 4) {
                swatch("tall", theme: theme, w: 24, h: 48)
                swatch("short", theme: theme, w: 24, h: 16)
            }
        }
        caption("HStack alignment .start")
        specimen(theme: theme, id: "layout-lab-hstack-start") {
            HStack(alignment: .start, spacing: 4) {
                swatch("tall", theme: theme, w: 24, h: 48)
                swatch("short", theme: theme, w: 24, h: 16)
            }
        }
        caption("Nested: VStack of a bar and an HStack")
        specimen(theme: theme, id: "layout-lab-nested") {
            VStack(alignment: .start, spacing: 4) {
                swatch("top", theme: theme, w: 80, h: 16)
                HStack(spacing: 4) {
                    swatch("L", theme: theme, w: 24, h: 24)
                    swatch("R", theme: theme, w: 24, h: 24)
                }
            }
        }
    }

    // MARK: - Flex

    @ViewBuilder
    private func flexSection(theme: Theme) -> some View {
        Text("Flex", color: .accent)
        caption("Two flexGrow: 1 in a 300pt row — equal share")
        specimen(theme: theme, id: "layout-lab-flex-equal") {
            HStack(width: .pt(300), height: .pt(28), spacing: 0) {
                growChip("1", theme: theme)
                growChip("1", theme: theme)
            }
        }
        caption("flexGrow 2 and 1")
        specimen(theme: theme, id: "layout-lab-flex-2-1") {
            HStack(width: .pt(300), height: .pt(28), spacing: 0) {
                growChip("2", theme: theme, grow: 2)
                growChip("1", theme: theme, grow: 1)
            }
        }
        caption("Spacer between two 50pt chips in a 300pt row")
        specimen(theme: theme, id: "layout-lab-spacer") {
            HStack(width: .pt(300), height: .pt(28), spacing: 0) {
                swatch("L", theme: theme, w: 50, h: 28)
                Spacer()
                swatch("R", theme: theme, w: 50, h: 28)
            }
        }
    }

    // MARK: - Percent

    @ViewBuilder
    private func percentSection(theme: Theme) -> some View {
        Text("Percent / min", color: .accent)
        caption("width 50% of a 400pt column")
        specimen(theme: theme, id: "layout-lab-percent") {
            VStack(width: .pt(400), alignment: .start, spacing: 0) {
                swatch("50%", theme: theme, w: 0, h: 24, width: .pct(50))
            }
        }
        caption("minWidth 80 inside a 60pt row — must not shrink past 80")
        specimen(theme: theme, id: "layout-lab-min-width") {
            HStack(width: .pt(60), height: .pt(24), spacing: 0) {
                Canvas(
                    label: "min-w",
                    width: .pt(200),
                    height: .pt(24),
                    flexGrow: 1,
                    minWidth: 80,
                    paint: { list, frame in
                        list.rect(
                            x: frame.x, y: frame.y, w: frame.w, h: frame.h,
                            color: theme.hover
                        )
                    }
                )
            }
        }
    }

    // MARK: - Chrome

    private func caption(_ text: String) -> some View {
        Text(text, color: .dim)
    }

    private func specimen<Content: View>(
        theme: Theme, id: String, @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .border(theme.border)
            .padding(6)
            .background(theme.inset)
            .cornerRadius(4)
            .agentId(id)
    }

    private func swatch(
        _ title: String, theme: Theme, w: Float, h: Float,
        width: LavaUI.Dimension? = nil
    ) -> some View {
        Canvas(
            label: title,
            width: width ?? .pt(w),
            height: .pt(h),
            paint: { list, frame in
                list.rect(
                    x: frame.x, y: frame.y, w: frame.w, h: frame.h,
                    color: theme.hover
                )
                list.text(
                    title,
                    x: frame.x + 4, y: frame.y + 4,
                    w: max(8, frame.w - 8), h: max(8, frame.h - 8),
                    color: theme.textPrimary,
                    font: FontStore.default
                )
            }
        )
    }

    private func growChip(
        _ title: String, theme: Theme, grow: Float = 1
    ) -> some View {
        Canvas(
            label: title,
            width: .auto,
            height: .pt(28),
            flexGrow: grow,
            paint: { list, frame in
                list.rect(
                    x: frame.x, y: frame.y, w: frame.w, h: frame.h,
                    color: theme.hover
                )
                list.text(
                    title,
                    x: frame.x + 6, y: frame.y + 6,
                    w: max(8, frame.w - 12), h: 16,
                    color: theme.textPrimary,
                    font: FontStore.default
                )
            }
        )
    }
}
