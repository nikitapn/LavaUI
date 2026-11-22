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

Each installed extension is a directory containing an `extension.json` manifest and its shared library. LavaEditor reads manifests at startup and on reload. The manifest declares a schema version, stable extension ID, library filename and commands. Each command has its own extension-local ID, menu title and contribution kind. Version 1 supports `selectionEdit`. Optional `languages` matches the editor’s language IDs and `fileExtensions` matches filename suffixes without a leading dot, case-insensitively. Either selector may match. Omit both for all documents, including untitled buffers. The `plain` language includes untitled buffers and unrecognized file formats.

The host loads the library when a command is invoked. All libraries export the same activation symbol and receive the selected command ID. A library can dispatch as many commands as its manifest declares. Rebuild and install the manifest when migrating a library from the earlier single-command prototype.

The wire contract lives in `idl/editor_extension.npidl`. Export `lava_editor_activate_v1` taking a command ID C string, a reference C string and a UInt64 invocation ID, returning Int32. Pass the reference to `runEditorCommand` to obtain a generated Swift proxy. `readSelection` returns the document ID, revision, UTF-8 byte range and selected text. `proposeEdits` accepts one batch of ordered, nonoverlapping UTF-8 byte ranges within that selection. Each edit carries its own replacement text. A zero-width range inserts text, and an empty replacement deletes the range. The editor rejects the entire batch if any range splits a UTF-8 scalar or the resulting selection exceeds 8 MiB.

The editor applies the proposal as one undo operation after the host exits successfully and the selection is still current. A crash, a five-second timeout, a stale selection or an absent proposal leaves the buffer alone. The headless host runs under the user's filesystem and network permissions.

LavaEditor configures its NPRPC runtime before opening its window. Each accepted connection gets a 12 MiB ring in each direction and a 9 MiB message ceiling. Up to 8 MiB of selection or replacement text travels inline, leaving room for RPC headers. The child adopts these values from the ring headers. A fresh host runs each invocation, so the extension connection occupies those rings only while connected.
