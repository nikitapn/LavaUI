# Run individual Swift tests in LavaEditor

Build and install the extension from the LavaUI checkout using the same Swift toolchain as LavaEditor. The extension uses the Linux toolchain’s SwiftParser and SwiftSyntax libraries.

```sh
scripts/gen_stubs.sh
swift build --product SwiftTestExtension
dest="${XDG_DATA_HOME:-$HOME/.local/share}/lavaeditor/extensions/swift-tests"
mkdir -p "$dest"
cp Examples/SwiftTestExtension/extension.json "$(swift build --show-bin-path)/libSwiftTestExtension.so" "$dest/"
swift run LavaEditor
```

If the editor is already running, choose **Extensions → Reload Extensions**. Open a Swift file inside a SwiftPM package. Each discovered `@Test` function and conventional `test…` method in a directly declared `XCTestCase` subclass has a green gutter button and a clickable **Run** hint above the declaration. Save changes before running. Parameterized tests run all arguments of the selected function. The notice area reports the result and a diagnostic on failure.

Discovery parses the active buffer in a helper process after typing pauses. The document snapshot is limited to 8 MiB. Clicking a test resolves the owning test target from SwiftPM’s package description, builds and lists tests, then runs the exact discovered test with `swift test --skip-build --filter`. This supports nested Swift Testing suites and top-level functions. Debugging and coverage are outside the initial runner.

## Document-action extension API

Declare a `documentActions` command in the manifest. The host passes the usual activation arguments. Use `runDocumentActionProvider` to get the generated IDL proxy. Read the current document with `readDocument`. An empty action ID requests discovery. Return the complete current set with `setLineActions`, including an empty list to clear earlier contributions. Each action supplies a zero-based logical line, an extension-defined ID, a gutter play flag and optional hint text. The first play action on a line owns the gutter button. Hints on the same line appear side by side.

A click starts a new invocation with the chosen action ID. Use `reportResult` to return its message. The editor owns drawing and hit testing, rejects stale document contributions and keeps hint rows outside the text buffer and undo history.
