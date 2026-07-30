# LavaUI agent control plane

An optional localhost TCP server lets an external agent (or CLI / MCP wrapper)
inspect layout, capture screenshots, and inject input without OS-level
accessibility hooks. Handlers run on the **UI thread**; Yoga and Vulkan are
never touched from the watcher thread.

## Enable

```bash
export CANVAS_ASSETS_ROOT=$PWD/canvas/.build.Debug
export LAVA_AGENT_PORT=9876          # any port > 0; unset = off
export LD_LIBRARY_PATH=$PWD/canvas/.build.Debug
export CANVAS_VK_VALIDATION=1        # optional Vulkan validation layers

swift run HelloWorld
# stderr: AgentServer: listening on 127.0.0.1:9876
```

Bind is **127.0.0.1 only**.

When idle, the frame loop still blocks in `glfwWaitEvents` (zero CPU). A
background `poll()` on the listen/client sockets calls `glfwPostEmptyEvent` so
agent requests wake the loop immediately — no mouse move required.

## Protocol

Newline-delimited JSON over TCP.

**Request**

```json
{"id":1,"cmd":"layout_tree","max_depth":12}
```

**Response**

```json
{"id":1,"ok":true,"result":{...}}
{"id":1,"ok":false,"error":"…"}
```

Coordinates are **layout / framebuffer pixels** (top-left origin), matching
Yoga and hit-testing. With the demo’s menu height of 0 they are also window
pixels.

## Commands

| `cmd` | Purpose |
|-------|---------|
| `ping` | Health check |
| `fb_size` | Framebuffer width/height |
| `settle` | Drain injected input, re-layout/redraw, present |
| `layout_tree` | Nested Yoga tree (`max_depth`) |
| `find` | Substring match on `sid` / label / text (`query`, `limit`) |
| `frame_of` | One frame by `sid`, `label`, `id`, or `query` |
| `hit_test` | Label under `x`,`y` |
| `move` | Pointer move |
| `click` | Click at `x`,`y` **or** center of `sid`/`label`/`id`/`query` |
| `scroll` | Wheel/trackpad `dx`,`dy`; moves to `x`,`y` or center of `sid`/`label`/`id`/`query` first if given, else uses the last pointer position |
| `key` | GLFW key (`key`, `action` 0/1/2, `mods`); press+release by default |
| `type_text` | UTF-8 string → character events (focused field path) |
| `screenshot` | PNG base64; optional region `x,y,w,h` (`w`/`h` ≤ 0 = full); optional `max_side` |
| `screenshot_node` | Crop around a node (`sid` / … + optional `pad`, `max_side`) |

`click`, `scroll`, `key`, `type_text`, and screenshot commands call **settle**
so the response reflects the post-action frame.

## Stable ids (`sid`)

Process-local `NodeID` (`id` in the tree) changes every launch. Agents should
use **`sid`**:

1. **Explicit** — `.agentId("theme-toggle")` on a view (preferred).
2. **Structural path** — e.g. `0:VStack/0:HStack/3:Text`. ForEach rows use
   `k:<element-id>` so reordering does not rename other rows.

Layout nodes may also report `agent_id` (when tagged) and `path` (structural
path when an explicit id is set).

```swift
Text("[ Theme: Dark ]", onClick: { … })
  .agentId("theme-toggle")
```

```bash
python3 tools/lava_agent_cli.py click --sid theme-toggle
python3 tools/lava_agent_cli.py screenshot_node --sid theme-toggle -o t.png
```

Demo tags: `theme-toggle`, `sidebar-toggle`, `inspector-toggle`.

## Screenshots

- Prefer **region** or **`screenshot_node`** over full-frame (cheaper for VLM/token budgets).
- **`max_side`** (optional, pixels): if the longer side of the crop exceeds this,
  the image is **box-downsampled** so `max(w,h) ≤ max_side`. Use e.g. `512` for a
  cheap full-window overview; omit or `0` for 1:1 pixels. Response includes
  `src_w`/`src_h` (pre-scale) and `w`/`h` (encoded size).
- After each present, the host capture cache is invalidated. Within one settled
  frame, multiple crops share a **single GPU readback** (downsample is CPU-only
  on that cache).
- Windowed mode uses a one-shot resolve → staging copy (not the present path).

```bash
# Full window, long side 512px
python3 tools/lava_agent_cli.py screenshot --max-side 512 -o overview.png

# Node crop at full res
python3 tools/lava_agent_cli.py screenshot_node --sid theme-toggle -o t.png
```

## Tools

```bash
# CLI (talks TCP → app directly)
python3 tools/lava_agent_cli.py ping
python3 tools/lava_agent_cli.py layout_tree --max-depth 4
python3 tools/lava_agent_cli.py find --query Theme
python3 tools/lava_agent_cli.py screenshot --w 200 --h 100 -o crop.png
python3 tools/lava_agent_cli.py click --sid theme-toggle
python3 tools/lava_agent_cli.py scroll --sid content-list --dy -20
```

## Wire to Grok Build / Claude Code

Architecture (two processes):

```
Grok Build or Claude Code
    │  MCP stdio (newline-delimited JSON-RPC)
    ▼
python3 tools/lava_agent_mcp.py     ← spawned by the IDE/agent
    │  TCP localhost:9876
    ▼
HelloWorld  (LAVA_AGENT_PORT=9876)  ← you start this yourself
```

The app must be **running with the agent port** before MCP tools work. The MCP
process only forwards; it does not start the UI.

### 1. Start the demo with the agent port

```bash
export CANVAS_ASSETS_ROOT=$PWD/canvas/.build.Debug
export LD_LIBRARY_PATH=$PWD/canvas/.build.Debug
export LAVA_AGENT_PORT=9876
swift run HelloWorld
# stderr: AgentServer: listening on 127.0.0.1:9876
```

Sanity-check without an IDE:

```bash
python3 tools/lava_agent_cli.py ping
```

### 2. Grok Build

This repo already ships a project config:

```toml
# .grok/config.toml
[mcp_servers.lava-ui]
command = "python3"
args = ["tools/lava_agent_mcp.py"]
env = { LAVA_AGENT_HOST = "127.0.0.1", LAVA_AGENT_PORT = "9876" }
enabled = true
tool_timeout_sec = 120
```

From the **repo root**:

```bash
grok mcp list          # should show lava-ui (project)
grok mcp doctor lava-ui
# or open /mcps in the TUI and press r to refresh
```

Optional one-liner (user scope instead of project):

```bash
grok mcp add lava-ui \
  -e LAVA_AGENT_HOST=127.0.0.1 \
  -e LAVA_AGENT_PORT=9876 \
  -- python3 /absolute/path/to/HelloWorld/tools/lava_agent_mcp.py
```

Tools appear as `lava-ui__click`, `lava-ui__screenshot`, etc. Grok discovers
them via `search_tool` / `use_tool`.

### 3. Claude Code

Project file (also in repo):

```json
// .mcp.json
{
  "mcpServers": {
    "lava-ui": {
      "command": "python3",
      "args": ["tools/lava_agent_mcp.py"],
      "env": {
        "LAVA_AGENT_HOST": "127.0.0.1",
        "LAVA_AGENT_PORT": "9876"
      }
    }
  }
}
```

Or install for the user globally:

```bash
claude mcp add lava-ui -- \
  env LAVA_AGENT_HOST=127.0.0.1 LAVA_AGENT_PORT=9876 \
  python3 /absolute/path/to/HelloWorld/tools/lava_agent_mcp.py
```

(Exact `claude mcp` flags vary by version — `claude mcp add --help` if needed.)

Then restart Claude Code / open this project so it reloads MCP. Use `/mcp` to
confirm `lava-ui` is connected.

### 4. Typical agent prompt

> Start by calling `fb_size` and `layout_tree`. Prefer `find` / `click --sid`
> over coordinates. Use `screenshot` with `max_side: 512` for overviews and
> `screenshot_node` with a `sid` for small crops.

### Troubleshooting

| Symptom | Fix |
|---------|-----|
| MCP tools error / connection refused | App not running, or wrong `LAVA_AGENT_PORT` |
| Server starts but tools hang | Wait for `AgentServer: listening` on stderr; check firewall (should be localhost only) |
| Grok/Claude never lists tools | Run from repo root so `args` path resolves; `grok mcp doctor lava-ui` / Claude `/mcp` |
| Old framing errors | Use current `tools/lava_agent_mcp.py` — MCP stdio is newline-delimited JSON, **not** `Content-Length` (LSP-style) framing; an earlier version of this file used the latter by mistake, which hangs every client |

Env for the MCP process (not the app): `LAVA_AGENT_HOST`, `LAVA_AGENT_PORT`.

## Implementation map

| Piece | Where |
|-------|--------|
| TCP server + protocol | `Sources/LavaUI/AgentServer.swift` |
| Layout dump / find / sid | `Sources/LavaUI/AgentLayout.swift` |
| `.agentId` | `Sources/LavaUI/AgentId.swift` |
| Inject + capture APIs | `Sources/LavaUI/Editor.swift` → `canvas::Engine` |
| PNG / frame cache | `canvas/src/render/vulkan.cpp` |
| Wire into demo loop | `Sources/HelloWorld/HelloWorldApp.swift` |

## Design notes

- **Do not** put Vulkan or Yoga inside the MCP process; the app owns the control
  surface, MCP is a thin adapter.
- Prefer `layout_tree` / `find` / `hit_test` before pixels; use small screenshots
  for visual confirmation.
- Keyboard inject uses GLFW key codes (`KeyCode` in LavaUI, e.g. Escape = 256).
- Text input for focused fields uses `type_text`, not key codes alone.
