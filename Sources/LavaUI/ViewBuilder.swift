// @ViewBuilder — no buildArray (index identity trap). Use ForEach(_:id:).

/// Builds a view from the statements of a closure: several views become a
/// `TupleView`, `if` becomes an `OptionalView` and `if`/`else` an `EitherView`.
///
/// There is no `for` loop support, on purpose: children built by a loop could
/// only be identified by position, which gives a row's state to whatever row
/// moves into its place. Use `ForEach` with an id.
@resultBuilder
public enum ViewBuilder {
    /// Passes a single view through unchanged.
    public static func buildExpression<Content: View>(_ content: Content) -> Content {
        content
    }

    /// An empty block: shows nothing.
    public static func buildBlock() -> EmptyView {
        EmptyView()
    }

    /// A block with one view: that view, unwrapped.
    public static func buildBlock<Content: View>(_ content: Content) -> Content {
        content
    }

    /// A block with several views: them, as siblings in order.
    public static func buildBlock<each Content: View>(
        _ content: repeat each Content
    ) -> TupleView<repeat each Content> {
        TupleView(content: (repeat each content))
    }

    /// An `if` without an `else`.
    public static func buildOptional<Content: View>(
        _ content: Content?
    ) -> OptionalView<Content> {
        OptionalView(content)
    }

    /// The `if` branch of an `if`/`else`.
    public static func buildEither<TrueContent: View, FalseContent: View>(
        first: TrueContent
    ) -> EitherView<TrueContent, FalseContent> {
        EitherView(first: first)
    }

    /// The `else` branch of an `if`/`else`.
    public static func buildEither<TrueContent: View, FalseContent: View>(
        second: FalseContent
    ) -> EitherView<TrueContent, FalseContent> {
        EitherView(second: second)
    }

    /// An `if #available` block: the view unchanged.
    public static func buildLimitedAvailability<Content: View>(
        _ content: Content
    ) -> Content {
        content
    }
}
