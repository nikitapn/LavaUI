import Foundation

/// A server: what a connection and a saved password are for.
public struct RemoteServer: Hashable, Sendable {
    public enum Scheme: String, Sendable, CaseIterable {
        case ftp
        /// Explicit FTPS — `AUTH TLS` on the ordinary port, which is what
        /// servers that offer TLS at all offer. Port 990 is the old implicit
        /// kind, and is spoken as such.
        case ftps
        case sftp
    }

    public var scheme: Scheme
    public var user: String?
    public var host: String
    /// Nil for the scheme's own port.
    public var port: Int?

    public init(scheme: Scheme, user: String? = nil, host: String, port: Int? = nil) {
        self.scheme = scheme
        self.user = user.flatMap { $0.isEmpty ? nil : $0 }
        self.host = host
        self.port = port == scheme.defaultPort ? nil : port
    }

    /// `alice@example.com`, or the host alone.
    public var title: String {
        let at = user.map { "\($0)@" } ?? ""
        let colon = port.map { ":\($0)" } ?? ""
        return at + host + colon
    }

    /// `scheme://user@host:port`, with nothing after it.
    public var prefix: String {
        var out = scheme.rawValue + "://"
        if let user { out += RemoteURL.escape(user, keeping: RemoteURL.userSafe) + "@" }
        out += host.contains(":") ? "[\(host)]" : host
        if let port { out += ":\(port)" }
        return out
    }
}

extension RemoteServer.Scheme {
    public var defaultPort: Int { self == .sftp ? 22 : 21 }
}

/// A folder or file on a server, as the explorer names it.
///
/// The explorer's paths are strings, and a remote one is this address:
/// `sftp://alice@host/home/alice/My Docs`. The path is kept decoded — it is
/// what the address bar and the tabs show — and is percent-encoded only on
/// its way to curl. A password is never part of it: one typed into the
/// address bar is taken out by `parse` and handed back separately, so it
/// cannot end up in a tab title, the history, or a drag.
public struct RemoteURL: Hashable, Sendable {
    public var server: RemoteServer
    /// Absolute and normalized: starts with "/", no trailing slash unless it
    /// is the root. SFTP's home is "/~", which curl understands as the login
    /// folder and which is where an address with no path lands.
    public var path: String

    public init(server: RemoteServer, path: String) {
        self.server = server
        self.path = Self.normalize(path)
    }

    /// Whether `path` is one of these at all — the test every local-only
    /// operation makes before it touches the disk.
    public static func isRemote(_ path: String) -> Bool {
        for scheme in RemoteServer.Scheme.allCases where path.hasPrefix(scheme.rawValue + "://") {
            return true
        }
        return false
    }

    /// The address and any password typed into it.
    public static func parse(_ text: String) -> (url: RemoteURL, password: String?)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sep = trimmed.range(of: "://"),
              let scheme = RemoteServer.Scheme(rawValue: trimmed[..<sep.lowerBound].lowercased())
        else { return nil }
        let rest = trimmed[sep.upperBound...]
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        var authority = Substring(rest[..<slash])
        let rawPath = rest[slash...]

        var user: String?
        var password: String?
        // The last "@": a user name can be an e-mail address.
        if let at = authority.lastIndex(of: "@") {
            let info = authority[..<at]
            authority = authority[authority.index(after: at)...]
            if let colon = info.firstIndex(of: ":") {
                user = unescape(String(info[..<colon]))
                password = unescape(String(info[info.index(after: colon)...]))
            } else {
                user = unescape(String(info))
            }
        }

        var host: String
        var port: Int?
        if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
            host = String(authority[authority.index(after: authority.startIndex)..<close])
            let after = authority[authority.index(after: close)...]
            if after.hasPrefix(":") { port = Int(after.dropFirst()) }
        } else if let colon = authority.lastIndex(of: ":") {
            host = String(authority[..<colon])
            port = Int(authority[authority.index(after: colon)...])
        } else {
            host = String(authority)
        }
        host = host.lowercased()
        guard !host.isEmpty else { return nil }

        let server = RemoteServer(scheme: scheme, user: user, host: host, port: port)
        // No path at all is "take me in": SFTP's login folder, an FTP
        // server's own starting place. A path of "/" is the root, asked for.
        let path = rawPath.isEmpty ? (scheme == .sftp ? "/~" : "/") : unescape(String(rawPath))
        return (RemoteURL(server: server, path: path), password.flatMap { $0.isEmpty ? nil : $0 })
    }

    public init?(_ text: String) {
        guard let parsed = Self.parse(text) else { return nil }
        self = parsed.url
    }

    /// The explorer's path for this — see the type's comment.
    public var string: String { server.prefix + path }

    public var isRoot: Bool { path == "/" }

    /// The last component, or the server for its root and its login folder
    /// — a tab called "~" says nothing about which server it is on.
    public var name: String {
        isRoot || path == "/~"
            ? server.title : String(path[path.index(after: path.lastIndex(of: "/")!)...])
    }

    public var parent: RemoteURL? {
        guard !isRoot else { return nil }
        let cut = path[..<path.lastIndex(of: "/")!]
        return RemoteURL(server: server, path: cut.isEmpty ? "/" : String(cut))
    }

    public func appending(_ name: String) -> RemoteURL {
        RemoteURL(server: server, path: isRoot ? "/" + name : path + "/" + name)
    }

    /// Whether `other` is this or somewhere below it.
    public func contains(_ other: RemoteURL) -> Bool {
        guard other.server == server else { return false }
        return isRoot || other.path == path || other.path.hasPrefix(path + "/")
    }

    /// What curl is handed: encoded, with no user (that goes separately, so
    /// it never has to survive URL escaping) and, for a folder, the trailing
    /// slash that tells curl to list rather than fetch.
    public func curlURL(directory: Bool) -> String {
        curlURL(directory: directory, host: server.host, port: server.port)
    }

    /// The same, at another host and port — where `~/.ssh/config` says the
    /// server really is.
    public func curlURL(directory: Bool, host: String, port: Int?) -> String {
        let scheme: String
        switch server.scheme {
        case .sftp: scheme = "sftp"
        case .ftp: scheme = "ftp"
        case .ftps: scheme = server.port == 990 ? "ftps" : "ftp"
        }
        var out = scheme + "://"
        out += host.contains(":") ? "[\(host)]" : host
        if let port, port != server.scheme.defaultPort || server.port != nil { out += ":\(port)" }
        out += Self.escape(path, keeping: Self.pathSafe)
        if directory, !out.hasSuffix("/") { out += "/" }
        return out
    }

    // MARK: - Pieces

    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    static let userSafe = CharacterSet.urlUserAllowed.subtracting(CharacterSet(charactersIn: ":@"))
    static let pathSafe = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: ";?#%"))

    static func escape(_ text: String, keeping safe: CharacterSet) -> String {
        text.addingPercentEncoding(withAllowedCharacters: safe) ?? text
    }

    static func unescape(_ text: String) -> String {
        text.removingPercentEncoding ?? text
    }
}
