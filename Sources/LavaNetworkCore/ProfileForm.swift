import Foundation

/// The Settings editor for one saved profile, as typed.
///
/// Fields are kept as the text in the boxes, not as parsed values, because a
/// half-typed address is a state the editor has to be able to hold — and
/// `problems` says what is wrong with it in words, here, where that is a
/// test, rather than as NetworkManager's refusal after the save.
public struct ProfileForm: Equatable, Sendable {
    public var name: String
    public var autoconnect: Bool
    /// "auto", "manual", "disabled", or whatever else the profile had.
    public var method: String
    /// Comma-separated "a.b.c.d/prefix"; a bare address is a /24.
    public var addresses: String
    public var gateway: String
    public var dns: String
    public var ignoreAutoDNS: Bool
    public var neverDefault: Bool

    public init(_ connection: NetConnection) {
        name = connection.id
        autoconnect = connection.autoconnect
        // No IPv4 setting at all reads as NetworkManager treats it.
        method = connection.ip4.method.isEmpty ? "auto" : connection.ip4.method
        addresses = connection.ip4.addresses.joined(separator: ", ")
        gateway = connection.ip4.gateway
        dns = connection.ip4.dns.joined(separator: ", ")
        ignoreAutoDNS = connection.ip4.ignoreAutoDNS
        neverDefault = connection.ip4.neverDefault
    }

    public enum Field: Hashable, Sendable { case name, addresses, gateway, dns }

    /// What would make NetworkManager refuse the save, by field.
    public var problems: [Field: String] {
        var out: [Field: String] = [:]
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            out[.name] = "A profile needs a name."
        }
        if method == "manual" {
            let list = Self.words(addresses)
            if list.isEmpty {
                out[.addresses] = "A manual address is needed, such as 192.168.1.20/24."
            } else if let bad = list.first(where: { IPv4.cidr($0) == nil }) {
                out[.addresses] = "“\(bad)” is not an address with a prefix (1–32)."
            }
            let gw = gateway.trimmingCharacters(in: .whitespaces)
            if !gw.isEmpty && !IPv4.isAddress(gw) {
                out[.gateway] = "“\(gw)” is not an IPv4 address."
            }
        }
        if method != "disabled", let bad = Self.words(dns).first(where: { !IPv4.isAddress($0) }) {
            out[.dns] = "“\(bad)” is not an IPv4 address."
        }
        return out
    }

    public var isValid: Bool { problems.isEmpty }

    /// Only what differs from `original`; nil when nothing does. IPv4 goes
    /// as a whole or not at all, since NetworkManager replaces the lists.
    public func edit(from original: ProfileForm) -> ProfileEdit? {
        var e = ProfileEdit()
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed != original.name { e.name = trimmed }
        if autoconnect != original.autoconnect { e.autoconnect = autoconnect }
        if method != original.method
            || Self.words(addresses) != Self.words(original.addresses)
            || gateway.trimmingCharacters(in: .whitespaces)
                != original.gateway.trimmingCharacters(in: .whitespaces)
            || Self.words(dns) != Self.words(original.dns)
            || ignoreAutoDNS != original.ignoreAutoDNS {
            e.ip4 = ProfileEdit.IPv4(
                method: method,
                addresses: method == "manual" ? Self.words(addresses) : [],
                gateway: method == "manual" ? gateway.trimmingCharacters(in: .whitespaces) : "",
                dns: method == "disabled" ? [] : Self.words(dns),
                ignoreAutoDNS: ignoreAutoDNS
            )
        }
        if neverDefault != original.neverDefault { e.neverDefault = neverDefault }
        return e == ProfileEdit() ? nil : e
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" || $0 == "\n" })
            .map(String.init)
    }
}

/// A change to send: nil means "leave it".
public struct ProfileEdit: Equatable, Sendable {
    public struct IPv4: Equatable, Sendable {
        public var method: String
        public var addresses: [String]
        public var gateway: String
        public var dns: [String]
        public var ignoreAutoDNS: Bool

        public init(method: String, addresses: [String], gateway: String, dns: [String],
                    ignoreAutoDNS: Bool) {
            self.method = method
            self.addresses = addresses
            self.gateway = gateway
            self.dns = dns
            self.ignoreAutoDNS = ignoreAutoDNS
        }
    }

    public var name: String?
    public var autoconnect: Bool?
    public var ip4: IPv4?
    public var neverDefault: Bool?

    public init(name: String? = nil, autoconnect: Bool? = nil, ip4: IPv4? = nil,
                neverDefault: Bool? = nil) {
        self.name = name
        self.autoconnect = autoconnect
        self.ip4 = ip4
        self.neverDefault = neverDefault
    }
}

public enum IPv4 {
    /// Four decimal octets, no leading zeros beyond a lone 0 — what
    /// NetworkManager's own parser takes.
    public static func isAddress(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII),
                  part.allSatisfy(\.isNumber), let value = Int(part), value <= 255
            else { return false }
            return part.count == 1 || part.first != "0"
        }
    }

    /// "a.b.c.d/p" → (a.b.c.d, p); a bare address is a /24, as the C side
    /// reads it.
    public static func cidr(_ text: String) -> (address: String, prefix: Int)? {
        let pieces = text.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count <= 2, isAddress(String(pieces[0])) else { return nil }
        guard pieces.count == 2 else { return (String(pieces[0]), 24) }
        guard let prefix = Int(pieces[1]), (1...32).contains(prefix) else { return nil }
        return (String(pieces[0]), prefix)
    }
}
