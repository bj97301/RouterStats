import Cocoa
import Security

// MARK: settings (non-secret values live in UserDefaults; the password lives in the Keychain)
struct Config {
    static let keychainService = "RouterStats"

    var address: String      // "192.168.1.1", "router.asus.com" or "https://192.168.1.1:8443"
    var username: String
    var pingTarget: String

    static var current: Config? {
        let d = UserDefaults.standard
        guard let a = d.string(forKey: "routerAddress"), let u = d.string(forKey: "routerUsername") else { return nil }
        return Config(address: a, username: u, pingTarget: d.string(forKey: "pingTarget") ?? "8.8.8.8")
    }

    func save() {
        let d = UserDefaults.standard
        d.set(address, forKey: "routerAddress"); d.set(username, forKey: "routerUsername"); d.set(pingTarget, forKey: "pingTarget")
    }

    var baseURL: URL? {
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: a.contains("://") ? a : "http://" + a)
    }

    var keychainAccount: String { "\(username)@\(baseURL?.host ?? address)" }
}

enum Keychain {
    static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Config.keychainService,
         kSecAttrAccount as String: account]
    }

    static func read(_ account: String) -> String? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    static func write(_ password: String, account: String) -> Bool {
        let data = Data(password.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(base(account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base(account)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "RouterStats router login"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    static func delete(_ account: String) { SecItemDelete(base(account) as CFDictionary) }
}

/// The Mac's default gateway, which is usually the router.
func defaultGateway() -> String? {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/sbin/route")
    p.arguments = ["-n", "get", "default"]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
    guard (try? p.run()) != nil else { return nil }
    p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return out.split(separator: "\n").first { $0.contains("gateway:") }?
        .split(separator: ":").last?.trimmingCharacters(in: .whitespaces)
}

// MARK: router API client
enum RouterError: LocalizedError {
    case badAddress, badLogin, lockedOut, unexpected(String)
    var errorDescription: String? {
        switch self {
        case .badAddress: return "That router address isn't valid."
        case .badLogin: return "The router rejected that username or password."
        case .lockedOut: return "The router has temporarily locked logins after too many failed attempts. Wait a few minutes and try again."
        case .unexpected(let s): return s
        }
    }
}

/// Talks to an ASUS router's web API (login.cgi + appGet.cgi), the same endpoints the ASUS app uses.
final class RouterClient: NSObject, URLSessionDelegate {
    let config: Config
    private var password: String
    private var token: String?
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    static let userAgent = "asusrouter-Android-DUTUtil-1.0.0.245"   // the API only answers app-style clients

    init(config: Config, password: String) { self.config = config; self.password = password }

    // Routers use self-signed certificates on HTTPS; trust them only for the configured router host.
    func urlSession(_ s: URLSession, didReceive ch: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if ch.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           ch.protectionSpace.host == config.baseURL?.host, let trust = ch.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else { completionHandler(.performDefaultHandling, nil) }
    }

    private func post(_ path: String, _ body: String, cookie: String?) async throws -> [String: Any] {
        guard let base = config.baseURL else { throw RouterError.badAddress }
        var r = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 5)
        r.httpMethod = "POST"; r.httpBody = body.data(using: .utf8)
        r.setValue(RouterClient.userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if let c = cookie { r.setValue("asus_token=\(c)", forHTTPHeaderField: "Cookie") }
        let (d, _) = try await session.data(for: r)
        guard let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw RouterError.unexpected("The router at \(config.address) didn't answer like an ASUS router.")
        }
        return obj
    }

    func login() async throws {
        let auth = Data("\(config.username):\(password)".utf8).base64EncodedString()
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let r = try await post("login.cgi", "login_authorization=\(auth)", cookie: nil)
        if let t = r["asus_token"] as? String { token = t; return }
        switch r["error_status"] as? String ?? "\(r["error_status"] ?? "")" {
        case "7", "10": throw RouterError.lockedOut
        default: throw RouterError.badLogin
        }
    }

    /// Fetch appGet hooks. The router needs the ";" between hooks sent as %3B, or it only answers the first one.
    func get(_ hooks: [String]) async throws -> [String: Any] {
        let body = "hook=" + hooks.joined(separator: "%3B") + "%3B"
        if let t = token, let d = try? await post("appGet.cgi", body, cookie: t), d[firstKey(hooks[0])] != nil { return d }
        try await login()
        return try await post("appGet.cgi", body, cookie: token)
    }

    private func firstKey(_ hook: String) -> String { String(hook.prefix { $0 != "(" }) }
}
