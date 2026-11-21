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
| `tabSize` | Positive integer | `4` |
| `insertSpaces` | Boolean | `true` |

Font settings apply to the document. If fontconfig can't locate the requested
family, LavaEditor tries the default family, then bundled Figtree. `tabSize` and
`insertSpaces` are available in the settings model for future use.

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
