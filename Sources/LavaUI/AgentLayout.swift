#if canImport(CYoga)
import CYoga
import Foundation

// Layout / hit-test reporting for the agent socket (and MCP).
//
// Coordinates are layout pixels (same as Yoga and hit-testing), origin top-left
// of the content root. `originY` matches `emitTree` / hit-test menu offset.
//
// Stable ids (`sid`):
//   1. Explicit `.agentId("…")` on a node (preferred, stable across launches)
//   2. Structural path: `0:VStack/1:HStack/k:3/0:Text` (ForEach uses element keys)

extension LayoutHost {
    /// Nested layout tree suitable for JSONSerialization.
    public func agentLayoutTree(originY: Float = 0, maxDepth: Int = 16) -> [String: Any] {
        guard let root = rootNode else {
            return [
                "width": lastLayoutWidth,
                "height": lastLayoutHeight,
                "nodes": [] as [Any],
            ]
        }
        let nodes = agentWalk(
            root,
            originX: 0,
            originY: originY,
            path: "",
            indexInParent: 0,
            depth: 0,
            maxDepth: maxDepth
        )
        return [
            "width": lastLayoutWidth,
            "height": lastLayoutHeight,
            "nodes": nodes,
        ]
    }

    /// JSON string of `agentLayoutTree`.
    public func agentLayoutTreeJSON(originY: Float = 0, maxDepth: Int = 16) -> String {
        let obj = agentLayoutTree(originY: originY, maxDepth: maxDepth)
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8)
        else {
            return #"{"error":"encode_failed"}"#
        }
        return s
    }

    /// Topmost layout label under a point (debug helper for agents).
    public func agentHitLabel(x: Float, y: Float, originY: Float = 0) -> String? {
        if let id = hitTestHover(x: x, y: y, originY: originY) {
            return "id:\(id.raw)"
        }
        for f in lastLayoutFrames.reversed() {
            let fx = f.x
            let fy = f.y + originY
            if x >= fx, y >= fy, x < fx + f.w, y < fy + f.h {
                return f.label
            }
        }
        return nil
    }

    /// Frame of the first node whose label equals `label` (committed layout).
    public func agentFrame(label: String, originY: Float = 0) -> LayoutFrame? {
        guard let f = lastLayoutFrames.first(where: { $0.label == label }) else {
            return nil
        }
        return LayoutFrame(label: f.label, x: f.x, y: f.y + originY, w: f.w, h: f.h)
    }

    /// Frame by process-local NodeID (not stable across launches).
    public func agentFrame(id: UInt64, originY: Float = 0) -> LayoutFrame? {
        guard let root = rootNode else { return nil }
        return agentFrameWalk(
            root, match: .nodeId(id), originX: 0, originY: originY, path: "", indexInParent: 0
        )?.frame
    }

    /// Frame by stable agent id or structural path (`sid` from layout_tree).
    public func agentFrame(sid: String, originY: Float = 0) -> LayoutFrame? {
        guard let root = rootNode, !sid.isEmpty else { return nil }
        return agentFrameWalk(
            root, match: .sid(sid), originX: 0, originY: originY, path: "", indexInParent: 0
        )?.frame
    }

    /// Find nodes by substring match on sid/label/text. Returns flat list
    /// of `{sid,id,label,type,text?,x,y,w,h,interactive}` (max `limit`).
    public func agentFind(
        query: String,
        originY: Float = 0,
        limit: Int = 32
    ) -> [[String: Any]] {
        guard let root = rootNode, !query.isEmpty else { return [] }
        var out: [[String: Any]] = []
        agentFindWalk(
            root,
            query: query.lowercased(),
            originX: 0,
            originY: originY,
            path: "",
            indexInParent: 0,
            into: &out,
            limit: limit
        )
        return out
    }

    // MARK: - path helpers

    private static func pathSegment(_ node: any AnyViewNode, index: Int) -> String {
        if let sk = node.structuralKey, !sk.isEmpty {
            return sk.replacingOccurrences(of: "/", with: "_")
        }
        // First token of label: "Text \"…\"" → Text, "HStack" → HStack
        var token = node.label
        if let space = token.firstIndex(of: " ") {
            token = String(token[..<space])
        }
        token = token.replacingOccurrences(of: "/", with: "_")
        if token.isEmpty { token = "node" }
        return "\(index):\(token)"
    }

    private static func joinPath(_ parent: String, _ seg: String) -> String {
        parent.isEmpty ? seg : parent + "/" + seg
    }

    private static func resolvedSid(agentId: String?, path: String) -> String {
        if let agentId, !agentId.isEmpty { return agentId }
        return path
    }

    private enum FrameMatch {
        case nodeId(UInt64)
        case sid(String)
    }

    private struct Hit {
        var frame: LayoutFrame
        var sid: String
    }

    private func agentFrameWalk(
        _ node: any AnyViewNode,
        match: FrameMatch,
        originX: Float,
        originY: Float,
        path: String,
        indexInParent: Int
    ) -> Hit? {
        if node.yoga == nil {
            for (i, child) in node.childNodes.enumerated() {
                if let h = agentFrameWalk(
                    child, match: match, originX: originX, originY: originY,
                    path: path, indexInParent: i
                ) {
                    return h
                }
            }
            return nil
        }
        guard let yoga = node.yoga else { return nil }
        let seg = Self.pathSegment(node, index: indexInParent)
        let myPath = Self.joinPath(path, seg)
        let sid = Self.resolvedSid(agentId: node.agentId, path: myPath)
        let x = originX + YGNodeLayoutGetLeft(yoga)
        let y = originY + YGNodeLayoutGetTop(yoga)
        let w = YGNodeLayoutGetWidth(yoga)
        let h = YGNodeLayoutGetHeight(yoga)

        let matched: Bool
        switch match {
        case .nodeId(let id): matched = node.id.raw == id
        // Accept explicit agentId, resolved sid, or raw structural path.
        case .sid(let s): matched = sid == s || node.agentId == s || myPath == s
        }
        if matched {
            return Hit(
                frame: LayoutFrame(label: node.label, x: x, y: y, w: w, h: h),
                sid: sid
            )
        }

        let shift: (x: Float, y: Float)
        if let box = node as? YogaBoxNode {
            shift = box.childOffset
        } else {
            shift = (0, 0)
        }
        for (i, child) in node.childNodes.enumerated() {
            if let h = agentFrameWalk(
                child, match: match,
                originX: x - shift.x, originY: y - shift.y,
                path: myPath, indexInParent: i
            ) {
                return h
            }
        }
        return nil
    }

    private func agentFindWalk(
        _ node: any AnyViewNode,
        query: String,
        originX: Float,
        originY: Float,
        path: String,
        indexInParent: Int,
        into out: inout [[String: Any]],
        limit: Int
    ) {
        if out.count >= limit { return }
        if node.yoga == nil {
            for (i, child) in node.childNodes.enumerated() {
                agentFindWalk(
                    child, query: query, originX: originX, originY: originY,
                    path: path, indexInParent: i, into: &out, limit: limit
                )
            }
            return
        }
        guard let yoga = node.yoga else { return }
        let seg = Self.pathSegment(node, index: indexInParent)
        let myPath = Self.joinPath(path, seg)
        let sid = Self.resolvedSid(agentId: node.agentId, path: myPath)
        let x = originX + YGNodeLayoutGetLeft(yoga)
        let y = originY + YGNodeLayoutGetTop(yoga)
        let w = YGNodeLayoutGetWidth(yoga)
        let h = YGNodeLayoutGetHeight(yoga)

        var text = ""
        var type = node.label
        var interactive = false
        if let leaf = node as? LeafNode {
            text = leaf.text
            type = String(describing: leaf.kind)
            interactive =
                leaf.onClick != nil || leaf.onClickLocal != nil
                || leaf.kind == .button || leaf.kind == .toggle
                || leaf.kind == .slider || leaf.kind == .textField
                || leaf.kind == .editor
        }
        let hay = (sid + " " + node.label + " " + text).lowercased()
        if hay.contains(query) {
            var entry: [String: Any] = [
                "sid": sid,
                "id": node.id.raw,
                "label": node.label,
                "type": type,
                "x": x, "y": y, "w": w, "h": h,
                "interactive": interactive,
            ]
            if let aid = node.agentId { entry["agent_id"] = aid }
            if sid != myPath { entry["path"] = myPath }
            if !text.isEmpty {
                entry["text"] = text.count > 80 ? String(text.prefix(80)) + "…" : text
            }
            out.append(entry)
        }
        if out.count >= limit { return }

        let shift: (x: Float, y: Float)
        if let box = node as? YogaBoxNode {
            shift = box.childOffset
        } else {
            shift = (0, 0)
        }
        for (i, child) in node.childNodes.enumerated() {
            agentFindWalk(
                child, query: query,
                originX: x - shift.x, originY: y - shift.y,
                path: myPath, indexInParent: i,
                into: &out, limit: limit
            )
        }
    }

    private func agentWalk(
        _ node: any AnyViewNode,
        originX: Float,
        originY: Float,
        path: String,
        indexInParent: Int,
        depth: Int,
        maxDepth: Int
    ) -> [[String: Any]] {
        // Fragments: splice children into parent list (path continues with their indices).
        if node.yoga == nil {
            return node.childNodes.enumerated().flatMap { i, child in
                agentWalk(
                    child,
                    originX: originX,
                    originY: originY,
                    path: path,
                    indexInParent: i,
                    depth: depth,
                    maxDepth: maxDepth
                )
            }
        }

        guard let yoga = node.yoga else { return [] }
        let seg = Self.pathSegment(node, index: indexInParent)
        let myPath = Self.joinPath(path, seg)
        let sid = Self.resolvedSid(agentId: node.agentId, path: myPath)
        let x = originX + YGNodeLayoutGetLeft(yoga)
        let y = originY + YGNodeLayoutGetTop(yoga)
        let w = YGNodeLayoutGetWidth(yoga)
        let h = YGNodeLayoutGetHeight(yoga)

        var entry: [String: Any] = [
            "sid": sid,
            "id": node.id.raw,
            "label": node.label,
            "x": x,
            "y": y,
            "w": w,
            "h": h,
        ]
        if let aid = node.agentId {
            entry["agent_id"] = aid
            entry["path"] = myPath  // structural path for debugging
        }

        if let leaf = node as? LeafNode {
            entry["type"] = String(describing: leaf.kind)
            if !leaf.text.isEmpty {
                let t = leaf.text
                entry["text"] = t.count > 80 ? String(t.prefix(80)) + "…" : t
            }
            let interactive =
                leaf.onClick != nil
                || leaf.onClickLocal != nil
                || leaf.kind == .button
                || leaf.kind == .toggle
                || leaf.kind == .slider
                || leaf.kind == .textField
                || leaf.kind == .editor
            entry["interactive"] = interactive
        } else {
            entry["type"] = node.label
            entry["interactive"] = false
        }

        if depth < maxDepth {
            let shift: (x: Float, y: Float)
            if let box = node as? YogaBoxNode {
                shift = box.childOffset
            } else {
                shift = (0, 0)
            }
            let kids = node.childNodes.enumerated().flatMap { i, child in
                agentWalk(
                    child,
                    originX: x - shift.x,
                    originY: y - shift.y,
                    path: myPath,
                    indexInParent: i,
                    depth: depth + 1,
                    maxDepth: maxDepth
                )
            }
            if !kids.isEmpty {
                entry["children"] = kids
            }
        }

        return [entry]
    }
}
#endif
