import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Lightweight agent control plane: newline-delimited JSON over TCP.
//
// Enable with LAVA_AGENT_PORT=9876 (or any port > 0). Bind is 127.0.0.1 only.
// Handlers run on the UI thread via `poll()` from the frame loop — no worker
// threads touch Yoga / Vulkan.
//
// A background select() watcher calls `wakeMainLoop` when the listen/client
// socket becomes readable so `pumpEvents` unblocks immediately (via
// glfwPostEmptyEvent) instead of waiting for a mouse move or timeout.

/// Callbacks the host app provides so the server stays UI-framework-agnostic.
public struct AgentHost {
    public var framebufferSize: () -> (w: Float, h: Float)
    /// Force layout+present; should also drain any injected input first.
    public var settle: () -> Void
    public var layoutTreeJSON: (_ maxDepth: Int) -> String
    public var hitLabel: (_ x: Float, _ y: Float) -> String?
    /// Resolve a frame by sid/agentId, label, process id, or first `find` hit.
    public var resolveFrame: (
        _ sid: String?, _ label: String?, _ id: UInt64?, _ query: String?
    ) -> (label: String, sid: String, x: Float, y: Float, w: Float, h: Float)?
    public var find: (_ query: String, _ limit: Int) -> [[String: Any]]
    public var injectMove: (_ x: Float, _ y: Float) -> Void
    public var injectClick: (_ x: Float, _ y: Float, _ button: Int32) -> Void
    public var injectKey: (_ key: Int32, _ action: Int32, _ mods: Int32) -> Void
    public var injectText: (_ text: String) -> Void
    /// Capture pixels only (caller settles when needed).
    public var screenshotBase64: (_ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32) -> String?

    public init(
        framebufferSize: @escaping () -> (w: Float, h: Float),
        settle: @escaping () -> Void,
        layoutTreeJSON: @escaping (_ maxDepth: Int) -> String,
        hitLabel: @escaping (_ x: Float, _ y: Float) -> String?,
        resolveFrame: @escaping (
            _ sid: String?, _ label: String?, _ id: UInt64?, _ query: String?
        ) -> (label: String, sid: String, x: Float, y: Float, w: Float, h: Float)?,
        find: @escaping (_ query: String, _ limit: Int) -> [[String: Any]],
        injectMove: @escaping (_ x: Float, _ y: Float) -> Void,
        injectClick: @escaping (_ x: Float, _ y: Float, _ button: Int32) -> Void,
        injectKey: @escaping (_ key: Int32, _ action: Int32, _ mods: Int32) -> Void,
        injectText: @escaping (_ text: String) -> Void,
        screenshotBase64: @escaping (_ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32) -> String?
    ) {
        self.framebufferSize = framebufferSize
        self.settle = settle
        self.layoutTreeJSON = layoutTreeJSON
        self.hitLabel = hitLabel
        self.resolveFrame = resolveFrame
        self.find = find
        self.injectMove = injectMove
        self.injectClick = injectClick
        self.injectKey = injectKey
        self.injectText = injectText
        self.screenshotBase64 = screenshotBase64
    }
}

public final class AgentServer: @unchecked Sendable {
    private let host: AgentHost
    private var listenFd: Int32 = -1
    private var clientFd: Int32 = -1
    private var inBuf = Data()
    public private(set) var port: UInt16 = 0

    /// Thread-safe: called from the poll watcher to unblock `pumpEvents`.
    private let wakeMainLoop: @Sendable () -> Void
    private let fdLock = NSLock()
    private var stopWatcher = false
    private var watcherThread: Thread?

    public init?(
        host: AgentHost,
        port: UInt16,
        wakeMainLoop: @escaping @Sendable () -> Void
    ) {
        self.host = host
        self.wakeMainLoop = wakeMainLoop
        guard port > 0 else { return nil }
        guard Self.bindListen(port: port, fd: &listenFd) else {
            FileHandle.standardError.write(
                Data("AgentServer: failed to bind 127.0.0.1:\(port)\n".utf8)
            )
            return nil
        }
        self.port = port
        FileHandle.standardError.write(
            Data("AgentServer: listening on 127.0.0.1:\(port)\n".utf8)
        )
        startWatcher()
    }

    deinit { close() }

    public func close() {
        stopWatcher = true
        // Unblock select so the watcher can exit.
        wakeMainLoop()
        watcherThread?.cancel()
        watcherThread = nil

        fdLock.lock()
        if clientFd >= 0 {
            _ = sysClose(clientFd)
            clientFd = -1
        }
        if listenFd >= 0 {
            _ = sysClose(listenFd)
            listenFd = -1
        }
        fdLock.unlock()
    }

    /// Non-blocking: accept clients and process complete request lines.
    /// Call on the UI thread after `pumpEvents` returns.
    public func poll() {
        acceptIfNeeded()
        guard clientFd >= 0 else { return }
        readAvailable()
        while let line = popLine() {
            let response = handleLine(line)
            writeAll(response + "\n")
        }
    }

    // MARK: - wake watcher

    private func startWatcher() {
        let thread = Thread { [weak self] in
            self?.watcherLoop()
        }
        thread.name = "LavaUI.AgentWatcher"
        thread.qualityOfService = .userInteractive
        watcherThread = thread
        thread.start()
    }

    private func watcherLoop() {
        while !stopWatcher {
            fdLock.lock()
            let listen = listenFd
            let client = clientFd
            fdLock.unlock()

            if listen < 0 { break }

            // poll(2) — avoids fd_set bit-twiddling portability issues.
            var pfds: [pollfd] = [
                pollfd(fd: listen, events: Int16(POLLIN), revents: 0),
            ]
            if client >= 0 {
                pfds.append(pollfd(fd: client, events: Int16(POLLIN), revents: 0))
            }
            let n = pfds.withUnsafeMutableBufferPointer { buf in
                #if canImport(Glibc)
                Glibc.poll(buf.baseAddress, nfds_t(buf.count), 200)
                #else
                Darwin.poll(buf.baseAddress, nfds_t(buf.count), 200)
                #endif
            }
            if stopWatcher { break }
            if n > 0 {
                // Accept pending or request bytes ready — unblock pumpEvents.
                wakeMainLoop()
            }
        }
    }

    // MARK: - sockets

    private static func bindListen(port: UInt16, fd: inout Int32) -> Bool {
        #if canImport(Glibc)
        let stream = Int32(SOCK_STREAM.rawValue)
        #else
        let stream = SOCK_STREAM
        #endif
        let s = socket(AF_INET, stream, 0)
        guard s >= 0 else { return false }
        var yes: Int32 = 1
        _ = setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        setNonBlocking(s)

        var addr = sockaddr_in()
        memset(&addr, 0, MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindOk: Bool = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(s, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard bindOk, listen(s, 4) == 0 else {
            _ = sysClose(s)
            return false
        }
        fd = s
        return true
    }

    private static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
    }

    private func acceptIfNeeded() {
        guard listenFd >= 0, clientFd < 0 else { return }
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let c: Int32 = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                accept(listenFd, sa, &len)
            }
        }
        if c >= 0 {
            Self.setNonBlocking(c)
            fdLock.lock()
            clientFd = c
            fdLock.unlock()
            inBuf.removeAll(keepingCapacity: true)
            FileHandle.standardError.write(Data("AgentServer: client connected\n".utf8))
        }
    }

    private func readAvailable() {
        var tmp = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = recv(clientFd, &tmp, tmp.count, 0)
            if n > 0 {
                inBuf.append(contentsOf: tmp.prefix(Int(n)))
            } else if n == 0 {
                fdLock.lock()
                _ = sysClose(clientFd)
                clientFd = -1
                fdLock.unlock()
                inBuf.removeAll()
                FileHandle.standardError.write(Data("AgentServer: client disconnected\n".utf8))
                return
            } else {
                return
            }
        }
    }

    private func popLine() -> String? {
        guard let nl = inBuf.firstIndex(of: 0x0A) else { return nil }
        var slice = inBuf.subdata(in: inBuf.startIndex..<nl)
        inBuf.removeSubrange(inBuf.startIndex...nl)
        if slice.last == 0x0D { slice.removeLast() }
        return String(data: slice, encoding: .utf8)
    }

    private func writeAll(_ s: String) {
        guard clientFd >= 0 else { return }
        let data = Array(s.utf8)
        var offset = 0
        while offset < data.count {
            let remaining = data.count - offset
            let n: Int = data.withUnsafeBytes { buf in
                guard let base = buf.baseAddress else { return -1 }
                return send(clientFd, base.advanced(by: offset), remaining, 0)
            }
            if n > 0 {
                offset += n
            } else {
                fdLock.lock()
                _ = sysClose(clientFd)
                clientFd = -1
                fdLock.unlock()
                break
            }
        }
    }

    // MARK: - protocol

    private func handleLine(_ line: String) -> String {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return #"{"id":null,"ok":false,"error":"invalid_json"}"#
        }
        let id = obj["id"] ?? NSNull()
        let cmd = (obj["cmd"] as? String) ?? ""
        do {
            let result = try dispatch(cmd: cmd, params: obj)
            return encodeResponse(id: id, ok: true, result: result, error: nil)
        } catch {
            return encodeResponse(id: id, ok: false, result: nil, error: error.localizedDescription)
        }
    }

    private enum AgentError: LocalizedError {
        case unknownCmd(String)
        case badParams(String)
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .unknownCmd(let c): return "unknown_cmd:\(c)"
            case .badParams(let m): return m
            case .failed(let m): return m
            }
        }
    }

    private func dispatch(cmd: String, params: [String: Any]) throws -> Any {
        switch cmd {
        case "ping":
            return ["pong": true]

        case "fb_size":
            let fb = host.framebufferSize()
            return ["w": fb.w, "h": fb.h]

        case "settle":
            host.settle()
            return ["settled": true]

        case "layout_tree":
            let depth = intParam(params, "max_depth", default: 12)
            let json = host.layoutTreeJSON(depth)
            if let data = json.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) {
                return obj
            }
            return ["raw": json]

        case "hit_test":
            let x = floatParam(params, "x")
            let y = floatParam(params, "y")
            let label = host.hitLabel(x, y)
            return ["label": label as Any, "x": x, "y": y]

        case "frame_of":
            let sid = params["sid"] as? String
            let label = params["label"] as? String
            let id = u64Param(params, "id")
            let query = params["query"] as? String
            guard sid != nil || label != nil || id != nil || (query != nil && !(query!).isEmpty) else {
                throw AgentError.badParams("sid, label, id, or query required")
            }
            if let f = host.resolveFrame(sid, label, id, query) {
                return [
                    "sid": f.sid, "label": f.label,
                    "x": f.x, "y": f.y, "w": f.w, "h": f.h,
                ]
            }
            throw AgentError.failed("not_found")

        case "find":
            guard let query = params["query"] as? String, !query.isEmpty else {
                throw AgentError.badParams("query required")
            }
            let limit = intParam(params, "limit", default: 32)
            return ["matches": host.find(query, limit)]

        case "move":
            let x = floatParam(params, "x")
            let y = floatParam(params, "y")
            host.injectMove(x, y)
            return ["x": x, "y": y]

        case "click":
            // Prefer node targeting when sid/label/id/query given.
            if let f = resolveOptionalFrame(params) {
                let cx = f.x + f.w * 0.5
                let cy = f.y + f.h * 0.5
                let button = Int32(intParam(params, "button", default: 0))
                host.injectClick(cx, cy, button)
                host.settle()
                return [
                    "x": cx, "y": cy, "button": button,
                    "target": [
                        "sid": f.sid, "label": f.label,
                        "x": f.x, "y": f.y, "w": f.w, "h": f.h,
                    ],
                ]
            }
            let x = floatParam(params, "x")
            let y = floatParam(params, "y")
            let button = Int32(intParam(params, "button", default: 0))
            host.injectClick(x, y, button)
            host.settle()
            return ["x": x, "y": y, "button": button]

        case "key":
            let key = Int32(intParam(params, "key", default: -1))
            if key < 0 { throw AgentError.badParams("key required (GLFW key code)") }
            let action = Int32(intParam(params, "action", default: 1))
            let mods = Int32(intParam(params, "mods", default: 0))
            // Press then release unless action is explicitly release-only.
            if action == 0 {
                host.injectKey(key, 0, mods)
            } else {
                host.injectKey(key, action, mods)
                if action == 1 { host.injectKey(key, 0, mods) }
            }
            host.settle()
            return ["key": key, "action": action, "mods": mods]

        case "type_text":
            guard let text = params["text"] as? String else {
                throw AgentError.badParams("text required")
            }
            host.injectText(text)
            host.settle()
            return ["chars": text.count]

        case "screenshot":
            host.settle()
            let x = Int32(intParam(params, "x", default: 0))
            let y = Int32(intParam(params, "y", default: 0))
            let w = Int32(intParam(params, "w", default: 0))
            let h = Int32(intParam(params, "h", default: 0))
            guard let b64 = host.screenshotBase64(x, y, w, h) else {
                throw AgentError.failed("capture_failed")
            }
            let fb = host.framebufferSize()
            return [
                "x": x, "y": y,
                "w": w <= 0 ? Int(fb.w) : Int(w),
                "h": h <= 0 ? Int(fb.h) : Int(h),
                "png_base64": b64,
            ]

        case "screenshot_node":
            // Settle first so layout matches what we paint.
            host.settle()
            guard let f = resolveOptionalFrame(params) else {
                throw AgentError.badParams("sid, label, id, or query required")
            }
            let pad = floatParam(params, "pad")
            let x = Int32(floor(f.x - pad))
            let y = Int32(floor(f.y - pad))
            let w = Int32(ceil(f.w + pad * 2))
            let h = Int32(ceil(f.h + pad * 2))
            guard let b64 = host.screenshotBase64(x, y, w, h) else {
                throw AgentError.failed("capture_failed")
            }
            return [
                "sid": f.sid,
                "label": f.label,
                "x": x, "y": y, "w": w, "h": h,
                "frame": ["x": f.x, "y": f.y, "w": f.w, "h": f.h],
                "png_base64": b64,
            ]

        default:
            throw AgentError.unknownCmd(cmd)
        }
    }

    private func resolveOptionalFrame(_ params: [String: Any])
        -> (label: String, sid: String, x: Float, y: Float, w: Float, h: Float)?
    {
        let sid = params["sid"] as? String
        let label = params["label"] as? String
        let id = u64Param(params, "id")
        let query = params["query"] as? String
        if (sid == nil || sid!.isEmpty)
            && label == nil && id == nil
            && (query == nil || query!.isEmpty)
        {
            return nil
        }
        return host.resolveFrame(sid, label, id, query)
    }

    private func floatParam(_ p: [String: Any], _ key: String) -> Float {
        if let n = p[key] as? NSNumber { return n.floatValue }
        if let d = p[key] as? Double { return Float(d) }
        if let i = p[key] as? Int { return Float(i) }
        if let s = p[key] as? String, let d = Double(s) { return Float(d) }
        return 0
    }

    private func intParam(_ p: [String: Any], _ key: String, default def: Int) -> Int {
        if let n = p[key] as? NSNumber { return n.intValue }
        if let i = p[key] as? Int { return i }
        if let d = p[key] as? Double { return Int(d) }
        if let s = p[key] as? String, let i = Int(s) { return i }
        return def
    }

    private func u64Param(_ p: [String: Any], _ key: String) -> UInt64? {
        if let n = p[key] as? NSNumber { return n.uint64Value }
        if let i = p[key] as? UInt64 { return i }
        if let i = p[key] as? Int, i >= 0 { return UInt64(i) }
        if let s = p[key] as? String, let i = UInt64(s) { return i }
        return nil
    }

    private func encodeResponse(id: Any, ok: Bool, result: Any?, error: String?) -> String {
        var dict: [String: Any] = ["id": id, "ok": ok]
        if ok {
            dict["result"] = result ?? NSNull()
        } else {
            dict["error"] = error ?? "error"
        }
        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let s = String(data: data, encoding: .utf8)
        else {
            return #"{"id":null,"ok":false,"error":"encode_failed"}"#
        }
        return s
    }
}

#if canImport(Glibc)
private func sysClose(_ fd: Int32) -> Int32 { close(fd) }
#else
private func sysClose(_ fd: Int32) -> Int32 { Darwin.close(fd) }
#endif
