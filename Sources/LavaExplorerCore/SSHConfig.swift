import Foundation

/// What `~/.ssh/config` says about one host — the part of it an SFTP
/// connection needs.
///
/// A machine already set up for `ssh vps` should open as `sftp://vps` with
/// nothing else to say: the key it uses, the user and the real address are
/// all in that file, and a server with password logins switched off has no
/// other way in. The rules are OpenSSH's (`ssh_config(5)`): blocks apply when
/// one of their `Host` patterns matches and none of their `!` patterns does,
/// the *first* value given for a keyword wins, and `IdentityFile` adds up.
public struct SSHHostConfig: Equatable, Sendable {
    public var hostName: String?
    public var user: String?
    public var port: Int?
    /// In the order to try them, `~` expanded.
    public var identityFiles: [String] = []
    /// Only the files above: no keys from the agent.
    public var identitiesOnly = false

    public init() {}
}

public enum SSHConfig {
    /// `host`'s settings from `text`, `~` expanded against `home`.
    ///
    /// `Match` blocks are skipped whole, rather than half understood. An
    /// `Include` is read — relative to `~/.ssh` as OpenSSH reads it, globs
    /// included — through `read`, so a test can hand it files.
    public static func resolve(
        host: String, in text: String, home: String,
        read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) },
        depth: Int = 0
    ) -> SSHHostConfig {
        var config = SSHHostConfig()
        var seenFirst = Set<String>()
        apply(host: host, text: text, home: home, read: read, depth: depth,
              into: &config, seen: &seenFirst)
        return config
    }

    private static func apply(
        host: String, text: String, home: String, read: (String) -> String?,
        depth: Int, into config: inout SSHHostConfig, seen: inout Set<String>
    ) {
        // Before the first `Host`, everything applies.
        var active = true
        for raw in text.split(whereSeparator: \.isNewline) {
            guard let (key, values) = line(String(raw)) else { continue }
            switch key {
            case "host":
                active = matches(host, patterns: values)
                continue
            case "match":
                active = false
                continue
            default:
                break
            }
            guard active, let value = values.first else { continue }
            switch key {
            case "include" where depth < 8:
                for pattern in values {
                    for path in expandInclude(pattern, home: home) {
                        guard let included = read(path) else { continue }
                        apply(host: host, text: included, home: home, read: read,
                              depth: depth + 1, into: &config, seen: &seen)
                    }
                }
            case "identityfile":
                let path = expand(value, home: home, host: host)
                if path.lowercased() != "none", !config.identityFiles.contains(path) {
                    config.identityFiles.append(path)
                }
            default:
                guard seen.insert(key).inserted else { continue }
                switch key {
                case "hostname": config.hostName = value.replacingOccurrences(of: "%h", with: host)
                case "user": config.user = value
                case "port": config.port = Int(value)
                case "identitiesonly": config.identitiesOnly = value.lowercased() == "yes"
                default: break
                }
            }
        }
    }

    /// `Keyword value…` or `Keyword=value`, comments and quotes handled.
    static func line(_ raw: String) -> (String, [String])? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        var words: [String] = []
        var current = ""
        var quoted = false
        var keyEnded = false
        for ch in trimmed {
            if ch == "\"" { quoted.toggle(); continue }
            let separator = !quoted && (ch == " " || ch == "\t" || (ch == "=" && !keyEnded))
            if separator {
                if !current.isEmpty { words.append(current); current = ""; keyEnded = true }
                continue
            }
            if ch == "#", !quoted, current.isEmpty { break }
            current.append(ch)
        }
        if !current.isEmpty { words.append(current) }
        guard let key = words.first else { return nil }
        return (key.lowercased(), Array(words.dropFirst()))
    }

    /// One `Host` line: a match on any pattern, and on no negated one.
    static func matches(_ host: String, patterns: [String]) -> Bool {
        var matched = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if glob(String(pattern.dropFirst()), host) { return false }
            } else if glob(pattern, host) {
                matched = true
            }
        }
        return matched
    }

    /// `*` and `?`, case-blind, as OpenSSH matches host names.
    static func glob(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern.lowercased())
        let t = Array(text.lowercased())
        var pi = 0, ti = 0
        var star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1; ti += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi; mark = ti; pi += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    static func expand(_ path: String, home: String, host: String) -> String {
        var out = path
            .replacingOccurrences(of: "%d", with: home)
            .replacingOccurrences(of: "%h", with: host)
        if out == "~" { out = home } else if out.hasPrefix("~/") { out = home + out.dropFirst() }
        return out
    }

    static func expandInclude(_ pattern: String, home: String) -> [String] {
        var path = expand(pattern, home: home, host: "")
        if !path.hasPrefix("/") { path = home + "/.ssh/" + path }
        guard path.contains("*") || path.contains("?") else { return [path] }
        let folder = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.filter { glob(name, $0) }.sorted().map { folder + "/" + $0 }
    }

    /// The keys `ssh` tries when nothing names one, in its order, that exist.
    public static func defaultIdentities(
        home: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [String] {
        ["id_rsa", "id_ecdsa", "id_ecdsa_sk", "id_ed25519", "id_ed25519_sk", "id_dsa"]
            .map { home + "/.ssh/" + $0 }
            .filter(exists)
    }
}
