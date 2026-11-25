# LavaEditor settings

Edit **Open User Settings** or **Open Folder Settings** from the Editor menu. Both
open ordinary tabs. The user file is `$XDG_CONFIG_HOME/LavaEditor/editor.json`
(`~/.config/LavaEditor/editor.json` by default). The folder file is
`.lava/settings.json` under the open project's root. In a workspace, use its
project root, or the directory containing the workspace file if it has no project
root. LavaEditor creates a missing file when you open it from the menu.

On the first launch after upgrading, LavaEditor copies any legacy View
preferences into a missing user file and records the migration in app state.

LavaEditor starts with built-in defaults, applies the user file, then applies the
folder file. Objects merge key by key and arrays replace earlier arrays. Changes
load automatically after a save. Files can contain `//` line comments and
trailing commas.

The notice bar displays errors and warnings with the file, line, and column.
A file with invalid syntax keeps its last successfully parsed values. Invalid
setting values use their built-in defaults.

The View menu toggles write to the user file. When the folder supplies the same
setting, the notice bar explains that the folder value still applies. **Toggling
rewrites the user file** as sorted, indented JSON. It preserves other keys and
values and removes comments and trailing commas.

## Editor preferences

| Key under `editor` | Type | Default |
| --- | --- | --- |
| `fontFamily` | String | `Noto Sans Mono` |
| `fontSize` | Number in pixels, 1–256 | `14` |
| `lineHeight` | Positive font-size multiple up to 10 | `1.5` |
| `wordWrap` | Boolean | `false` |
| `lineNumbers` | Boolean | `true` |
| `highlightChangedLines` | Boolean | `true` |
| `tabSize` | Integer from 1 to 32 | `4` |
| `insertSpaces` | Boolean | `true` |
| `detectIndentation` | Boolean | `true` |
| `languages` | Object keyed by language ID | `{}` |

Font settings apply to the document. If fontconfig can't locate the requested
family, LavaEditor tries the default family, then bundled Figtree.

`tabSize` sets the width of a tab and the number of spaces in one indentation
level. `insertSpaces` controls what Tab inserts and the level Enter adds after
an opening brace or colon. The whitespace Enter carries over from the line
above is kept exactly as it is, so a tab-indented line continues with a tab
whatever `insertSpaces` says.

With `detectIndentation`, a file's own indentation outranks both settings:
when it is read, whichever of tabs or spaces more of its lines begin with
wins, and for spaces the most common step between indented lines becomes the
level width. A tab-indented file keeps the configured `tabSize` for display,
since the bytes say nothing about how wide a tab is. A file with no indented
lines yet uses the settings. Makefiles (`Makefile`, `GNUmakefile`, `*.mk`)
always insert tabs, since make requires them.

Use `editor.languages` in either settings file to override either field for
one language. A folder value replaces the user value for the same language
and field. A field omitted by both layers inherits the general `editor`
setting. Use `c` for C and `cpp` for C++ and shared `.h` headers.

```json
{
  "editor": {
    "languages": {
      "swift": { "tabSize": 4, "insertSpaces": true },
      "cpp": { "tabSize": 2, "insertSpaces": true },
      "c": { "tabSize": 4, "insertSpaces": false }
    }
  }
}
```

## Language servers

`lsp.servers` maps a server name to `command` (an array containing the executable
and its arguments), `languages` and `rootMarkers` (arrays of strings), `enabled`
(Boolean), and optional `initializationOptions` and `settings` (JSON values).
Both built-ins start enabled, with optional JSON fields unset. A new user server
defaults to enabled with empty language and root-marker lists, and needs a command.

| Server | Command | Languages | Root markers |
| --- | --- | --- | --- |
| `sourcekit-lsp` | `["sourcekit-lsp"]` | `swift` | `Package.swift`, `.git` |
| `clangd` | `["clangd"]` | `c`, `cpp`, `objective-c` | `compile_commands.json`, `compile_flags.txt`, `.git` |

Define commands and new servers in the user file. A folder can change
`enabled`, `initializationOptions`, and `settings` for a server defined by the
defaults or user file. Other folder server fields are ignored with a warning.
Language-server support here consists of loading and validating the settings.
