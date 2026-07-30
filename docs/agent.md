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
| `key` | GLFW key (`key`, `action` 0/1/2, `mods`); press+release by default |
| `type_text` | UTF-8 string → character events (focused field path) |
| `screenshot` | PNG base64; optional region `x,y,w,h` (`w`/`h` ≤ 0 = full) |
| `screenshot_node` | Crop around a node (`sid` / … + optional `pad`) |

`click`, `key`, `type_text`, and screenshot commands call **settle** so the
response reflects the post-action frame.

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
- After each present, the host capture cache is invalidated. Within one settled
  frame, multiple crops share a **single GPU readback**.
- Windowed mode uses a one-shot resolve → staging copy (not the present path).

## Tools

```bash
# CLI
python3 tools/lava_agent_cli.py ping
python3 tools/lava_agent_cli.py layout_tree --max-depth 4
python3 tools/lava_agent_cli.py find --query Theme
python3 tools/lava_agent_cli.py screenshot --w 200 --h 100 -o crop.png
python3 tools/lava_agent_cli.py click --sid theme-toggle

# MCP (stdio JSON-RPC → same TCP port)
python3 tools/lava_agent_mcp.py
# env: LAVA_AGENT_HOST, LAVA_AGENT_PORT
```

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
