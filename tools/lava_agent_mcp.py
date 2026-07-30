#!/usr/bin/env python3
"""Minimal MCP stdio server forwarding tools to the LavaUI agent TCP port.

Requires the app running with LAVA_AGENT_PORT set (default 9876).
"""

from __future__ import annotations

import json
import os
import socket
import sys
from typing import Any


HOST = os.environ.get("LAVA_AGENT_HOST", "127.0.0.1")
PORT = int(os.environ.get("LAVA_AGENT_PORT", "9876"))


def agent_call(cmd: str, params: dict[str, Any] | None = None, timeout: float = 60.0) -> dict:
    payload = {"id": 1, "cmd": cmd}
    if params:
        payload.update(params)
    line = json.dumps(payload, separators=(",", ":")) + "\n"
    with socket.create_connection((HOST, PORT), timeout=timeout) as sock:
        sock.sendall(line.encode("utf-8"))
        buf = b""
        while b"\n" not in buf:
            chunk = sock.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
    if not buf:
        raise RuntimeError("empty response from LavaUI agent")
    return json.loads(buf.decode("utf-8"))


def tool_result(text: str, is_error: bool = False) -> dict:
    return {"content": [{"type": "text", "text": text}], "isError": is_error}


def image_result(meta: dict, b64: str) -> dict:
    return {
        "content": [
            {"type": "text", "text": json.dumps(meta, indent=2)},
            {"type": "image", "data": b64, "mimeType": "image/png"},
        ]
    }


def handle_tool(name: str, arguments: dict[str, Any]) -> dict:
    try:
        if name == "ping":
            r = agent_call("ping")
        elif name == "fb_size":
            r = agent_call("fb_size")
        elif name == "settle":
            r = agent_call("settle")
        elif name == "layout_tree":
            r = agent_call("layout_tree", {"max_depth": int(arguments.get("max_depth", 12))})
        elif name == "hit_test":
            r = agent_call("hit_test", {"x": float(arguments["x"]), "y": float(arguments["y"])})
        elif name == "frame_of":
            p: dict[str, Any] = {}
            if "sid" in arguments:
                p["sid"] = str(arguments["sid"])
            if "label" in arguments:
                p["label"] = str(arguments["label"])
            if "id" in arguments:
                p["id"] = int(arguments["id"])
            if "query" in arguments:
                p["query"] = str(arguments["query"])
            r = agent_call("frame_of", p)
        elif name == "find":
            r = agent_call(
                "find",
                {"query": str(arguments["query"]), "limit": int(arguments.get("limit", 32))},
            )
        elif name == "move":
            r = agent_call("move", {"x": float(arguments["x"]), "y": float(arguments["y"])})
        elif name == "click":
            p = {"button": int(arguments.get("button", 0))}
            for k in ("x", "y"):
                if k in arguments:
                    p[k] = float(arguments[k])
            for k in ("sid", "label", "query"):
                if k in arguments:
                    p[k] = str(arguments[k])
            if "id" in arguments:
                p["id"] = int(arguments["id"])
            r = agent_call("click", p)
        elif name == "key":
            r = agent_call(
                "key",
                {
                    "key": int(arguments["key"]),
                    "action": int(arguments.get("action", 1)),
                    "mods": int(arguments.get("mods", 0)),
                },
            )
        elif name == "type_text":
            r = agent_call("type_text", {"text": str(arguments["text"])})
        elif name in ("screenshot", "screenshot_node"):
            if name == "screenshot":
                r = agent_call(
                    "screenshot",
                    {
                        "x": int(arguments.get("x", 0)),
                        "y": int(arguments.get("y", 0)),
                        "w": int(arguments.get("w", 0)),
                        "h": int(arguments.get("h", 0)),
                    },
                )
            else:
                p = {"pad": float(arguments.get("pad", 2))}
                for k in ("sid", "label", "query"):
                    if k in arguments:
                        p[k] = str(arguments[k])
                if "id" in arguments:
                    p["id"] = int(arguments["id"])
                r = agent_call("screenshot_node", p)
            if r.get("ok") and isinstance(r.get("result"), dict):
                b64 = r["result"].get("png_base64")
                if b64:
                    meta = {k: v for k, v in r["result"].items() if k != "png_base64"}
                    return image_result(meta, b64)
        else:
            return tool_result(f"unknown tool: {name}", is_error=True)

        if not r.get("ok"):
            return tool_result(json.dumps(r), is_error=True)
        return tool_result(json.dumps(r.get("result"), indent=2))
    except Exception as ex:  # noqa: BLE001
        return tool_result(f"{type(ex).__name__}: {ex}", is_error=True)


TOOLS = [
    {"name": "ping", "description": "Health check.", "inputSchema": {"type": "object", "properties": {}}},
    {"name": "fb_size", "description": "Framebuffer size.", "inputSchema": {"type": "object", "properties": {}}},
    {"name": "settle", "description": "Drain input + re-layout + present.", "inputSchema": {"type": "object", "properties": {}}},
    {
        "name": "layout_tree",
        "description": "Yoga layout tree (id, label, frames, interactive, text).",
        "inputSchema": {"type": "object", "properties": {"max_depth": {"type": "integer", "default": 12}}},
    },
    {
        "name": "find",
        "description": "Substring search over labels/text; returns matching frames.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string"},
                "limit": {"type": "integer", "default": 32},
            },
            "required": ["query"],
        },
    },
    {
        "name": "frame_of",
        "description": "Resolve one frame by sid (stable), label, process id, or query.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "sid": {"type": "string", "description": "Stable agent id or structural path"},
                "label": {"type": "string"},
                "id": {"type": "integer"},
                "query": {"type": "string"},
            },
        },
    },
    {
        "name": "hit_test",
        "description": "Label under a layout-pixel point.",
        "inputSchema": {
            "type": "object",
            "properties": {"x": {"type": "number"}, "y": {"type": "number"}},
            "required": ["x", "y"],
        },
    },
    {
        "name": "move",
        "description": "Pointer move (layout pixels).",
        "inputSchema": {
            "type": "object",
            "properties": {"x": {"type": "number"}, "y": {"type": "number"}},
            "required": ["x", "y"],
        },
    },
    {
        "name": "click",
        "description": "Click at x/y or center of sid/label/id/query target, then settle.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "x": {"type": "number"},
                "y": {"type": "number"},
                "sid": {"type": "string"},
                "label": {"type": "string"},
                "id": {"type": "integer"},
                "query": {"type": "string"},
                "button": {"type": "integer", "default": 0},
            },
        },
    },
    {
        "name": "key",
        "description": "Inject GLFW key (press+release by default). Escape=256 Enter=257.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "key": {"type": "integer"},
                "action": {"type": "integer", "default": 1},
                "mods": {"type": "integer", "default": 0},
            },
            "required": ["key"],
        },
    },
    {
        "name": "type_text",
        "description": "Type UTF-8 text into the focused field.",
        "inputSchema": {
            "type": "object",
            "properties": {"text": {"type": "string"}},
            "required": ["text"],
        },
    },
    {
        "name": "screenshot",
        "description": "PNG capture; optional region x,y,w,h (0 w/h = full). Prefer small regions.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "x": {"type": "integer", "default": 0},
                "y": {"type": "integer", "default": 0},
                "w": {"type": "integer", "default": 0},
                "h": {"type": "integer", "default": 0},
            },
        },
    },
    {
        "name": "screenshot_node",
        "description": "PNG crop of a node by sid, label, id, or query (+ optional pad).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "sid": {"type": "string"},
                "label": {"type": "string"},
                "id": {"type": "integer"},
                "query": {"type": "string"},
                "pad": {"type": "number", "default": 2},
            },
        },
    },
]


def send(msg: dict) -> None:
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def main() -> None:
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            msg = json.loads(raw)
        except json.JSONDecodeError:
            continue

        mid = msg.get("id")
        method = msg.get("method")
        params = msg.get("params") or {}

        if method == "initialize":
            send(
                {
                    "jsonrpc": "2.0",
                    "id": mid,
                    "result": {
                        "protocolVersion": "2024-11-05",
                        "capabilities": {"tools": {}},
                        "serverInfo": {"name": "lava-ui-agent", "version": "0.2.0"},
                    },
                }
            )
        elif method == "notifications/initialized":
            pass
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": mid, "result": {"tools": TOOLS}})
        elif method == "tools/call":
            name = params.get("name", "")
            args = params.get("arguments") or {}
            result = handle_tool(name, args)
            send({"jsonrpc": "2.0", "id": mid, "result": result})
        elif method == "ping":
            send({"jsonrpc": "2.0", "id": mid, "result": {}})
        else:
            if mid is not None:
                send(
                    {
                        "jsonrpc": "2.0",
                        "id": mid,
                        "error": {"code": -32601, "message": f"Method not found: {method}"},
                    }
                )


if __name__ == "__main__":
    main()
