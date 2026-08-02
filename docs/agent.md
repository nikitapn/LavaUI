# LavaUI agent control plane

An optional localhost TCP server lets an external agent (or CLI / MCP wrapper)
inspect layout, capture screenshots, and inject input without OS-level
accessibility hooks.

## Enable

```bash
export LAVA_AGENT_PORT=9876          # any port > 0; unset = off
export CANVAS_VK_VALIDATION=1        # optional Vulkan validation layers
# Optional override for engine shaders (default: CanvasResources SPM bundle):
# export CANVAS_ASSETS_ROOT=...

swift run HelloWorld
# stderr: AgentServer: listening on 127.0.0.1:9876
```

Coordinates are **layout / framebuffer pixels** (top-left origin), matching
Yoga and hit-testing. With the demo’s menu height of 0 they are also window
pixels.

Captured drags use independent button phases with any number of moves between
them:

```bash
python3 tools/lava_agent_cli.py pointer_down --x 300 --y 450
python3 tools/lava_agent_cli.py move --x 600 --y 450
python3 tools/lava_agent_cli.py move --x 900 --y 450
python3 tools/lava_agent_cli.py pointer_up --x 900 --y 450
```

`pointer_down` and `pointer_up` also accept `--sid`, `--label`, `--id`, or
`--query` and use the resolved node center, like `click`. The MCP server exposes
the same two operations.

## Stable ids (`sid`)

Process-local `NodeID` (`id` in the tree) changes every launch. Agents could
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

## Per-widget paint profiling

```bash
export LAVAUI_PROFILE=1   # in addition to the env above
swift run HelloWorld
```

With this set, the `profile` command (also `tools/lava_agent_cli.py profile`)
settles a frame and returns the most recent frame's paint cost per widget —
`[{"label", "ms", "count"}]`, worst first, `label` being a view's `.agentId`
if it has one, else its structural kind (`"Canvas"`, `"EditorView"`, …).
Timed per widget's whole paint, not per draw primitive, so it points at
*which* widget is expensive without the timing calls themselves swamping the
cost they're measuring. `LAVAUI_DEBUG` (off by default) also prints the top 5
each frame on stdout when this is set, prefixed `  top:`.
