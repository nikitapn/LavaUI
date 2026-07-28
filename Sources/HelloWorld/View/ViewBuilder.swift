// Phase 1 — @ViewBuilder with parameter packs (Phase 0a proved packs work).

@resultBuilder
public enum ViewBuilder {
    public static func buildExpression<Content: View>(_ content: Content) -> Content {
        content
    }

    public static func buildBlock() -> EmptyView {
        EmptyView()
    }

    public static func buildBlock<Content: View>(_ content: Content) -> Content {
        content
    }

    public static func buildBlock<each Content: View>(
        _ content: repeat each Content
    ) -> TupleView<repeat each Content> {
        TupleView(content: (repeat each content))
    }

    public static func buildOptional<Content: View>(
        _ content: Content?
    ) -> OptionalView<Content> {
        OptionalView(content)
    }

    public static func buildEither<TrueContent: View, FalseContent: View>(
        first: TrueContent
    ) -> EitherView<TrueContent, FalseContent> {
        EitherView(first: first)
    }

    public static func buildEither<TrueContent: View, FalseContent: View>(
        second: FalseContent
    ) -> EitherView<TrueContent, FalseContent> {
        EitherView(second: second)
    }

    /// `for … in` loops in a builder.
    public static func buildArray<Content: View>(
        _ views: [Content]
    ) -> ArrayView<Content> {
        ArrayView(views: views)
    }

    public static func buildLimitedAvailability<Content: View>(
        _ content: Content
    ) -> Content {
        content
    }
}
