# Swift selection commands for LavaEditor

Build the editor and example with the same Swift toolchain and the NPRPC Swift binding that exposes `shmChannelSizes(ringBytes:maxMessageBytes:)`. From the worktree root:

```sh
scripts/gen_stubs.sh
swift build --product FormatJSON
extensions="${XDG_DATA_HOME:-$HOME/.local/share}/lavaeditor/extensions/json-tools"
mkdir -p "$extensions"
cp Examples/EditorExtensions/extension.json "$(swift build --show-bin-path)/libFormatJSON.so" "$extensions/"
swift run LavaEditor
```

Open a .json file, select some JSON, and choose **Extensions → Format JSON** or **Compact JSON**. Undo restores the original text. **Reload Extensions** rescans for added or removed libraries. Replacing a library takes effect on its next invocation.

Each installed extension is a directory containing an `extension.json` manifest and its shared library. LavaEditor reads manifests at startup and on reload. The manifest declares a schema version, stable extension ID, library filename and commands. Each command has its own extension-local ID, menu title and contribution kind. Version 1 supports read-only `markdownPreview` providers, explicit `selectionEdit` commands and automatic `documentActions` providers. The [Swift test extension](../SwiftTestExtension/README.md) uses the latter to publish clickable gutter buttons and inline hints. Optional `languages` matches the editor’s language IDs and `fileExtensions` matches filename suffixes without a leading dot, case-insensitively. Either selector may match. Omit both for all documents, including untitled buffers. The `plain` language includes untitled buffers and unrecognized file formats.

Right-click a JSON tab and choose **Open Preview · Formatted JSON** to see a formatted copy, including unsaved edits. The example's `preview` command uses `runMarkdownPreviewProvider`, calls `readDocument(invocation:)` for the path and current text, then submits one string with `setMarkdown(invocation:markdown:)`. Input and output each have an 8 MiB limit. The editor renders the result with its Markdown view. A Markdown file also has a built-in preview.

The host loads the library on demand. The SDK advertises reusable discovery through the exported marker `lava_editor_reusable_host_v1`. Older libraries keep their one-invocation lifetime. All libraries export the same activation symbol and receive the selected command ID. A library can dispatch as many commands as its manifest declares. Rebuild and install the manifest when migrating a library from the earlier single-command prototype.

The wire contract lives in `idl/editor_extension.npidl`. Export `lava_editor_activate_v1` taking a command ID C string, a reference C string and a UInt64 invocation ID, returning Int32. Pass the reference to `runEditorCommand` to obtain a generated Swift proxy. `readSelection` returns the document ID, revision, UTF-8 byte range and selected text. `proposeEdits` accepts one batch of ordered, nonoverlapping UTF-8 byte ranges within that selection. Each edit carries its own replacement text. A zero-width range inserts text, and an empty replacement deletes the range. The editor rejects the entire batch if any range splits a UTF-8 scalar or the resulting selection exceeds 8 MiB.

The editor applies the proposal as one undo operation after the host exits successfully and the selection is still current. A crash, a five-second timeout, a stale selection or an absent proposal leaves the buffer alone. The headless host runs under the user's filesystem and network permissions.

LavaEditor configures its NPRPC runtime before opening its window. Each accepted connection gets a 12 MiB ring in each direction and a 9 MiB message ceiling. Up to 8 MiB of selection or replacement text travels inline, leaving room for RPC headers. The child adopts these values from the ring headers. Format commands use a fresh worker per invocation. Discovery workers keep their connection between requests. Invocation IDs are random 64-bit tokens delivered over a private socket.

### Embedded surfaces

Choose **Open Preview · JSON Overview** to open the example drawn by the extension. Nested objects and arrays appear expanded, with indented children and JSON values. Click the order control or press Space to reverse object-key order at every level. Arrays keep their original indices. Scroll or use the arrow keys to browse the tree.

A command advertising `embeddedSurface` uses `runEmbeddedSurfaceProvider` to read a viewport and a batch of input events. It can request the source buffer separately. Each invocation returns one complete frame and up to 64 KiB of state for its next call. The editor keeps one request in flight per preview, coalesces pointer motion, and gives editor shortcuts priority over focused surface keys. Event coordinates are local logical pixels. Each event names the viewport and painted frame it targeted. A provider should use those IDs if its hit regions change between frames. Resizing or changing the font replaces the viewport. A late reply can advance interaction state, while only frames matching the new viewport can be displayed. A changed document starts a fresh preview state.

Use a headless `Editor.openClient()` and `DrawList.captureEmbedded` with a paint closure or a LavaUI view. V1 accepts rectangles, rounded rectangles, balanced clips, shaped text and image quads in the native little-endian draw-list layout. The editor validates command and glyph ranges and draws inside the tab clip. Font slot zero maps to the viewport face. The descriptor includes its SHA-256, local path, face index, raster flags and 26.6 pixel size. The example verifies the digest of the loaded face before shaping. Focus events carry 1 on entry and 0 on exit. Cancel ends gestures when a tab is hidden or its viewport is replaced. Image quads refer to frame-local IDs declared with tightly packed RGBA8 pixels. Each frame allows up to 32,768 commands, 65,536 glyphs and 4 MiB of image bytes. Local transport uses the existing supervised NPRPC shared-memory worker. A remote transport would also need a font resolver for the advertised digest.
