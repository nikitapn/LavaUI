#!/usr/bin/env python3
"""Tiny CLI client for the LavaUI agent TCP protocol.

  LAVA_AGENT_PORT=9876 ./HelloWorld &
  python3 tools/lava_agent_cli.py ping
  python3 tools/lava_agent_cli.py find --query Theme
  python3 tools/lava_agent_cli.py screenshot_node --query Theme -o theme.png
  python3 tools/lava_agent_cli.py click --query Theme
  python3 tools/lava_agent_cli.py type_text --text hello
  python3 tools/lava_agent_cli.py key --key 256   # Escape
  LAVAUI_PROFILE=1 ./HelloWorld &  python3 tools/lava_agent_cli.py profile
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import socket
import sys


def request(host: str, port: int, payload: dict, timeout: float = 60.0) -> dict:
    line = json.dumps(payload, separators=(",", ":")) + "\n"
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.sendall(line.encode("utf-8"))
        buf = b""
        while b"\n" not in buf:
            chunk = sock.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
    text = buf.decode("utf-8", errors="replace").strip()
    if not text:
        raise RuntimeError("empty response from agent")
    return json.loads(text)


def main() -> int:
    p = argparse.ArgumentParser(description="LavaUI agent CLI")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=int(os.environ.get("LAVA_AGENT_PORT", "9876")))
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("ping")
    sub.add_parser("fb_size")
    sub.add_parser("settle")
    sub.add_parser("profile", help="per-widget paint cost (needs LAVAUI_PROFILE=1)")
    lt = sub.add_parser("layout_tree")
    lt.add_argument("--max-depth", type=int, default=12)
    ht = sub.add_parser("hit_test")
    ht.add_argument("--x", type=float, required=True)
    ht.add_argument("--y", type=float, required=True)
    fo = sub.add_parser("frame_of")
    fo.add_argument("--sid", help="stable agent id or structural path")
    fo.add_argument("--label")
    fo.add_argument("--id", type=int, help="process-local NodeID (unstable)")
    fo.add_argument("--query")
    fi = sub.add_parser("find")
    fi.add_argument("--query", required=True)
    fi.add_argument("--limit", type=int, default=32)
    mv = sub.add_parser("move")
    mv.add_argument("--x", type=float, required=True)
    mv.add_argument("--y", type=float, required=True)
    cl = sub.add_parser("click")
    cl.add_argument("--x", type=float)
    cl.add_argument("--y", type=float)
    cl.add_argument("--sid", help="stable agent id (preferred)")
    cl.add_argument("--label")
    cl.add_argument("--id", type=int)
    cl.add_argument("--query")
    cl.add_argument("--button", type=int, default=0)
    for phase in ("pointer_down", "pointer_up"):
        pp = sub.add_parser(phase)
        pp.add_argument("--x", type=float)
        pp.add_argument("--y", type=float)
        pp.add_argument("--sid", help="stable agent id (preferred)")
        pp.add_argument("--label")
        pp.add_argument("--id", type=int)
        pp.add_argument("--query")
        pp.add_argument("--button", type=int, default=0)
    sr = sub.add_parser("scroll")
    sr.add_argument("--dx", type=float, default=0.0)
    sr.add_argument("--dy", type=float, required=True)
    sr.add_argument("--x", type=float)
    sr.add_argument("--y", type=float)
    sr.add_argument("--sid", help="stable agent id (preferred)")
    sr.add_argument("--label")
    sr.add_argument("--id", type=int)
    sr.add_argument("--query")
    ky = sub.add_parser("key")
    ky.add_argument("--key", type=int, required=True, help="GLFW key code")
    ky.add_argument("--action", type=int, default=1, help="0=release 1=press 2=repeat")
    ky.add_argument("--mods", type=int, default=0)
    tt = sub.add_parser("type_text")
    tt.add_argument("--text", required=True)
    sc = sub.add_parser("screenshot")
    sc.add_argument("--x", type=int, default=0)
    sc.add_argument("--y", type=int, default=0)
    sc.add_argument("--w", type=int, default=0)
    sc.add_argument("--h", type=int, default=0)
    sc.add_argument(
        "--max-side",
        type=int,
        default=0,
        help="box-downsample so longer side ≤ this (0 = full res)",
    )
    sc.add_argument("-o", "--output", help="write PNG to path")
    sn = sub.add_parser("screenshot_node")
    sn.add_argument("--sid", help="stable agent id or structural path")
    sn.add_argument("--label")
    sn.add_argument("--id", type=int)
    sn.add_argument("--query")
    sn.add_argument("--pad", type=float, default=2.0)
    sn.add_argument(
        "--max-side",
        type=int,
        default=0,
        help="box-downsample so longer side ≤ this (0 = full res)",
    )
    sn.add_argument("-o", "--output", help="write PNG to path")

    args = p.parse_args()
    payload: dict = {"id": 1, "cmd": args.cmd}

    if args.cmd == "layout_tree":
        payload["max_depth"] = args.max_depth
    elif args.cmd == "hit_test":
        payload["x"] = args.x
        payload["y"] = args.y
    elif args.cmd == "frame_of":
        if args.sid:
            payload["sid"] = args.sid
        if args.label:
            payload["label"] = args.label
        if args.id is not None:
            payload["id"] = args.id
        if args.query:
            payload["query"] = args.query
    elif args.cmd == "find":
        payload["query"] = args.query
        payload["limit"] = args.limit
    elif args.cmd == "move":
        payload["x"] = args.x
        payload["y"] = args.y
    elif args.cmd in ("click", "pointer_down", "pointer_up"):
        if args.sid:
            payload["sid"] = args.sid
        if args.label:
            payload["label"] = args.label
        if args.id is not None:
            payload["id"] = args.id
        if args.query:
            payload["query"] = args.query
        if args.x is not None:
            payload["x"] = args.x
        if args.y is not None:
            payload["y"] = args.y
        payload["button"] = args.button
    elif args.cmd == "scroll":
        if args.sid:
            payload["sid"] = args.sid
        if args.label:
            payload["label"] = args.label
        if args.id is not None:
            payload["id"] = args.id
        if args.query:
            payload["query"] = args.query
        if args.x is not None:
            payload["x"] = args.x
        if args.y is not None:
            payload["y"] = args.y
        payload["dx"] = args.dx
        payload["dy"] = args.dy
    elif args.cmd == "key":
        payload["key"] = args.key
        payload["action"] = args.action
        payload["mods"] = args.mods
    elif args.cmd == "type_text":
        payload["text"] = args.text
    elif args.cmd == "screenshot":
        payload.update(x=args.x, y=args.y, w=args.w, h=args.h)
        if args.max_side:
            payload["max_side"] = args.max_side
    elif args.cmd == "screenshot_node":
        if args.sid:
            payload["sid"] = args.sid
        if args.label:
            payload["label"] = args.label
        if args.id is not None:
            payload["id"] = args.id
        if args.query:
            payload["query"] = args.query
        payload["pad"] = args.pad
        if args.max_side:
            payload["max_side"] = args.max_side

    resp = request(args.host, args.port, payload)
    if not resp.get("ok"):
        print(json.dumps(resp, indent=2), file=sys.stderr)
        return 1

    result = resp.get("result")
    if args.cmd in ("screenshot", "screenshot_node") and isinstance(result, dict):
        b64 = result.get("png_base64")
        out = getattr(args, "output", None)
        if out and b64:
            with open(out, "wb") as f:
                f.write(base64.b64decode(b64))
            slim = {k: v for k, v in result.items() if k != "png_base64"}
            slim["saved"] = out
            print(json.dumps({"id": resp.get("id"), "ok": True, "result": slim}, indent=2))
            return 0

    print(json.dumps(resp, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
