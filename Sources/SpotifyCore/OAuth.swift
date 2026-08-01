import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#endif

/// Authorization-code + PKCE for user tokens (Player API / spotifyd control).
///
/// Client-credentials alone cannot hit `/me/player/*`. A user must grant
/// `user-modify-playback-state` (and friends) so we can target spotifyd as a
/// Connect device.
///
/// Redirect: `http://127.0.0.1:<port>/callback` — register the same URI in the
/// Spotify developer dashboard. Default port is 17321.
public final class SpotifyOAuth: @unchecked Sendable {
    public static let defaultRedirectPort: UInt16 = 17321
    public static let defaultScopes = [
        "user-read-playback-state",
        "user-modify-playback-state",
        "user-read-currently-playing",
    ].joined(separator: " ")

    public let clientId: String
    public let clientSecret: String?
    public let redirectURI: String
    public let scopes: String

    private let lock = NSLock()
    private var tokens: StoredTokens?
    private var pendingVerifier: String?

    public var isLoggedIn: Bool {
        lock.lock(); defer { lock.unlock() }
        return tokens?.refreshToken != nil || (tokens.map { $0.expiresAt > Date() } ?? false)
    }

    public var hasRefreshToken: Bool {
        lock.lock(); defer { lock.unlock() }
        return tokens?.refreshToken != nil
    }

    public init(
        clientId: String,
        clientSecret: String? = nil,
        redirectURI: String? = nil,
        scopes: String = SpotifyOAuth.defaultScopes
    ) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        if let redirectURI {
            self.redirectURI = redirectURI
        } else if let env = ProcessInfo.processInfo.environment["SPOTIFY_REDIRECT_URI"],
                  !env.isEmpty
        {
            self.redirectURI = env
        } else {
            self.redirectURI = "http://127.0.0.1:\(Self.defaultRedirectPort)/callback"
        }
        self.scopes = scopes
        self.tokens = TokenStore.load()
    }

    // MARK: - Access token

    /// Valid user access token, refreshing if needed.
    public func accessToken() throws -> String {
        lock.lock()
        if let t = tokens, t.expiresAt > Date().addingTimeInterval(30) {
            lock.unlock()
            return t.accessToken
        }
        let refresh = tokens?.refreshToken
        lock.unlock()

        guard let refresh else {
            throw SpotifyError("Not logged in — use Account → Log in to Spotify")
        }
        let fresh = try refreshAccessToken(refresh)
        lock.lock()
        tokens = fresh
        lock.unlock()
        TokenStore.save(fresh)
        return fresh.accessToken
    }

    public func logout() {
        lock.lock()
        tokens = nil
        pendingVerifier = nil
        lock.unlock()
        TokenStore.clear()
    }

    // MARK: - Login flow

    /// Opens the system browser and blocks until the user finishes (or timeout).
    /// Returns once tokens are stored.
    public func loginInteractive(timeoutSeconds: TimeInterval = 180) throws {
        let verifier = PKCE.randomVerifier()
        let challenge = PKCE.challenge(for: verifier)
        lock.lock()
        pendingVerifier = verifier
        lock.unlock()

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "show_dialog", value: "true"),
        ]
        guard let authURL = components.url else {
            throw SpotifyError("Bad authorize URL")
        }

        let port = Self.port(from: redirectURI) ?? Self.defaultRedirectPort
        let loginMsg =
            "LavaSpotify: opening browser for Spotify login…\n"
            + "  redirect \(redirectURI) (add this exact URI in the dashboard)\n"
        FileHandle.standardError.write(Data(loginMsg.utf8))
        openBrowser(authURL)

        let code = try LocalCallbackServer.waitForCode(
            port: port,
            path: "/callback",
            timeoutSeconds: timeoutSeconds
        )
        try finishLogin(code: code)
    }

    public func finishLogin(code: String) throws {
        lock.lock()
        let verifier = pendingVerifier
        pendingVerifier = nil
        lock.unlock()
        guard let verifier else {
            throw SpotifyError("Login session expired — try Log in again")
        }

        var body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientId,
            "code_verifier": verifier,
        ]
        if let secret = clientSecret, !secret.isEmpty {
            body["client_secret"] = secret
        }

        let token = try exchange(body: body)
        lock.lock()
        tokens = token
        lock.unlock()
        TokenStore.save(token)
        FileHandle.standardError.write(Data("LavaSpotify: logged in (user token stored)\n".utf8))
    }

    // MARK: - Token exchange

    private func refreshAccessToken(_ refresh: String) throws -> StoredTokens {
        var body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": clientId,
        ]
        if let secret = clientSecret, !secret.isEmpty {
            body["client_secret"] = secret
        }
        let next = try exchange(body: body)
        // Spotify may omit refresh_token on refresh — keep the old one.
        if next.refreshToken == nil {
            return StoredTokens(
                accessToken: next.accessToken,
                refreshToken: refresh,
                expiresAt: next.expiresAt
            )
        }
        return next
    }

    private func exchange(body: [String: String]) throws -> StoredTokens {
        guard let url = URL(string: "https://accounts.spotify.com/api/token") else {
            throw SpotifyError("Bad token URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = Data(formEncode(body).utf8)
        if let secret = clientSecret, !secret.isEmpty {
            // Confidential clients may also send Basic auth.
            let basic = Data("\(clientId):\(secret)".utf8).base64EncodedString()
            request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        }

        let (data, status) = try HTTP.data(for: request)
        guard (200...299).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SpotifyError("OAuth token HTTP \(status): \(body.prefix(200))")
        }
        let decoded = try JSONDecoder().decode(TokenJSON.self, from: data)
        return StoredTokens(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token,
            expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in))
        )
    }

    private static func port(from redirectURI: String) -> UInt16? {
        guard let url = URL(string: redirectURI), let port = url.port else { return nil }
        return UInt16(port)
    }

    private func openBrowser(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
        process.arguments = [url.absoluteString]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private func formEncode(_ fields: [String: String]) -> String {
        fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }
}

// MARK: - Token persistence

struct StoredTokens: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
}

enum TokenStore {
    private static var fileURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".config/LavaSpotify", isDirectory: true)
            .appendingPathComponent("tokens.json")
    }

    static func load() -> StoredTokens? {
        let url = fileURL
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StoredTokens.self, from: data)
    }

    static func save(_ tokens: StoredTokens) {
        let url = fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(tokens) else { return }
        try? data.write(to: url, options: .atomic)
        // User tokens are credentials — keep them private.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

private struct TokenJSON: Decodable {
    var access_token: String
    var expires_in: Int
    var refresh_token: String?
}

// MARK: - PKCE

enum PKCE {
    static func randomVerifier(length: Int = 64) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        var out = ""
        out.reserveCapacity(length)
        for _ in 0..<length {
            out.append(alphabet[Int.random(in: 0..<alphabet.count)])
        }
        return out
    }

    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(Data(verifier.utf8))
        return base64URL(digest)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Minimal SHA-256 (avoid CryptoKit on Linux toolchains)

enum SHA256 {
    static func hash(_ message: Data) -> Data {
        var h0: UInt32 = 0x6a09e667
        var h1: UInt32 = 0xbb67ae85
        var h2: UInt32 = 0x3c6ef372
        var h3: UInt32 = 0xa54ff53a
        var h4: UInt32 = 0x510e527f
        var h5: UInt32 = 0x9b05688c
        var h6: UInt32 = 0x1f83d9ab
        var h7: UInt32 = 0x5be0cd19

        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ]

        var msg = [UInt8](message)
        let bitLen = UInt64(msg.count) * 8
        msg.append(0x80)
        while (msg.count % 64) != 56 { msg.append(0) }
        for shift in [56, 48, 40, 32, 24, 16, 8, 0] {
            msg.append(UInt8((bitLen >> shift) & 0xff))
        }

        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
            (x >> n) | (x << (32 - n))
        }

        for chunkStart in stride(from: 0, to: msg.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let j = chunkStart + i * 4
                w[i] = (UInt32(msg[j]) << 24) | (UInt32(msg[j + 1]) << 16)
                    | (UInt32(msg[j + 2]) << 8) | UInt32(msg[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }

            var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7
            for i in 0..<64 {
                let S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = h &+ S1 &+ ch &+ k[i] &+ w[i]
                let S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = S0 &+ maj
                h = g; g = f; f = e; e = d &+ t1
                d = c; c = b; b = a; a = t1 &+ t2
            }
            h0 &+= a; h1 &+= b; h2 &+= c; h3 &+= d
            h4 &+= e; h5 &+= f; h6 &+= g; h7 &+= h
        }

        var out = Data()
        for word in [h0, h1, h2, h3, h4, h5, h6, h7] {
            out.append(UInt8((word >> 24) & 0xff))
            out.append(UInt8((word >> 16) & 0xff))
            out.append(UInt8((word >> 8) & 0xff))
            out.append(UInt8(word & 0xff))
        }
        return out
    }
}

// MARK: - Local loopback HTTP for OAuth redirect

enum LocalCallbackServer {
    /// Blocks until Spotify redirects with `?code=` or times out.
    static func waitForCode(
        port: UInt16,
        path: String,
        timeoutSeconds: TimeInterval
    ) throws -> String {
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { throw SpotifyError("socket() failed") }
        defer { close(fd) }

        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindOK = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOK == 0 else {
            throw SpotifyError("bind 127.0.0.1:\(port) failed — is another LavaSpotify login open?")
        }
        guard listen(fd, 1) == 0 else { throw SpotifyError("listen() failed") }

        // Non-blocking accept loop with deadline.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            var clientAddr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(fd, $0, &len)
                }
            }
            if client < 0 {
                usleep(50_000)
                continue
            }
            defer { close(client) }

            var buffer = [UInt8](repeating: 0, count: 8192)
            let n = read(client, &buffer, buffer.count)
            guard n > 0 else { continue }
            let request = String(bytes: buffer[0..<n], encoding: .utf8) ?? ""
            guard let code = parseCode(fromHTTPRequest: request, expectedPath: path) else {
                let html = httpResponse(
                    400,
                    body: "<html><body>Missing code — try again from LavaSpotify.</body></html>"
                )
                _ = html.withCString { write(client, $0, strlen($0)) }
                continue
            }
            let html = httpResponse(
                200,
                body: """
                <html><body style="font-family:sans-serif;background:#121212;color:#fff;padding:2rem">
                <h2>LavaSpotify</h2>
                <p>Logged in. You can close this tab and return to the app.</p>
                </body></html>
                """
            )
            _ = html.withCString { write(client, $0, strlen($0)) }
            return code
        }
        throw SpotifyError("Login timed out after \(Int(timeoutSeconds))s")
        #else
        throw SpotifyError("OAuth loopback requires Linux")
        #endif
    }

    private static func parseCode(fromHTTPRequest request: String, expectedPath: String) -> String? {
        // GET /callback?code=...&state=... HTTP/1.1
        let first = request.split(separator: "\r\n", maxSplits: 1).first
            ?? request.split(separator: "\n", maxSplits: 1).first
        guard let first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let target = String(parts[1])
        guard let url = URL(string: "http://127.0.0.1\(target)") else { return nil }
        guard url.path == expectedPath || url.path.hasSuffix(expectedPath) else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "code" })?
            .value
    }

    private static func httpResponse(_ status: Int, body: String) -> String {
        let reason = status == 200 ? "OK" : "Bad Request"
        return """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
    }
}
