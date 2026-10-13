import Foundation
import Security

/// Where the UniFi Network controller is. The API key itself lives in the keychain.
struct UniFiConfig: Equatable, Sendable {
    var url: String
    var trustCertificate: Bool

    static let defaultURL = ""

    static func load() -> UniFiConfig {
        UniFiConfig(url: SpeedyShared.defaults.string(forKey: SpeedyShared.unifiURLKey) ?? defaultURL,
                    trustCertificate: SpeedyShared.bool(SpeedyShared.unifiTrustKey, default: false))
    }

    func save() {
        SpeedyShared.defaults.set(url, forKey: SpeedyShared.unifiURLKey)
        SpeedyShared.defaults.set(trustCertificate, forKey: SpeedyShared.unifiTrustKey)
    }

    /// "unifi.fm.net" or "https://unifi.fm.net/" become "https://unifi.fm.net".
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    var host: String { URL(string: url)?.host ?? (url.isEmpty ? "the controller" : url) }
}

/// Generic passwords in the login keychain, for the UniFi API key.
enum Keychain {
    static let service = "net.fm.speedybot"
    static let unifiKeyAccount = "unifi-api-key"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read(account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var q = query(account)
        q[kSecValueData as String] = data
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

struct UniFiSite: Sendable, Equatable {
    /// The internal name used in URLs ("default", "abc123") or the integration id.
    let name: String
    /// What the tech sees: "Howard Payne University".
    let desc: String
}

/// One client on a site, as far as the lookup needs it.
struct UniFiClientInfo: Sendable, Equatable {
    let ip: String
    let mac: String
    let name: String?
    let hostname: String?
    let wired: Bool
    let switchName: String?
    let switchMAC: String?
    let port: Int?
    let apName: String?
    let ssid: String?
    let network: String?

    var displayName: String? { name ?? hostname }

    /// "BRW-SW-JACKSON · Port 40" or "AP name · SSID" or nil when neither is known.
    var whereabouts: String? {
        var bits: [String] = []
        if wired {
            if let switchName { bits.append(switchName) } else if let switchMAC { bits.append("switch \(switchMAC)") }
            if let port { bits.append("Port \(port)") }
        } else {
            bits.append("Wi-Fi")
            if let apName { bits.append(apName) }
            if let ssid { bits.append(ssid) }
        }
        if let displayName { bits.append(displayName) }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }
}

struct UniFiLookup: Sendable, Equatable {
    /// The site the remote machine is on (by its address, or by the site's public IP).
    let site: UniFiSite?
    let siteByPublicIP: Bool
    let client: UniFiClientInfo?
    /// Every client of that site by address, so the pinged devices can be labelled too.
    let clientsByIP: [String: UniFiClientInfo]
    let note: String?

    /// "Howard Payne University · BRW-SW-JACKSON · Port 40 · FLC-JACKSON (Room PC)".
    var summary: String {
        var bits: [String] = []
        if let site { bits.append(site.desc + (siteByPublicIP ? " (by public IP)" : "")) }
        if let client, let w = client.whereabouts { bits.append(w) }
        if let network = client?.network { bits.append(network) }
        if let note { bits.append(note) }
        return bits.isEmpty ? "Not found" : bits.joined(separator: " · ")
    }
}

enum UniFiError: LocalizedError {
    case badURL
    case unauthorized
    case http(Int)
    case notJSON
    case noSites
    case network(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Enter the UniFi controller's address (like https://unifi.example.com) under Settings…."
        case .unauthorized: return "UniFi refused the API key (401). Create one under Settings › Control Plane › Integrations in UniFi Network and paste it here."
        case .http(let code): return "UniFi answered HTTP \(code)."
        case .notJSON: return "UniFi did not answer with data. Is this the controller's address, and are you allowed to reach it from here?"
        case .noSites: return "The API key works but can see no sites."
        case .network(let why): return "Could not reach the controller: \(why)"
        }
    }
}

/// Accepts the controller's own certificate when the tech has said to (self-signed controllers are common).
private final class TrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let host: String
    init(host: String) { self.host = host }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host.lowercased() == host.lowercased(),
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

/// Talks to a UniFi Network controller with an API key. Tries the classic endpoints first (they know which
/// switch port a client is on), behind the UniFi OS proxy or on a stand-alone controller; falls back to the
/// newer integration API, which names the site and the device but not the port.
actor UniFiClient {
    private enum Flavour { case classic(base: String), integration(base: String) }

    private let config: UniFiConfig
    private let apiKey: String
    private let session: URLSession
    private var flavour: Flavour?
    private var siteCache: [UniFiSite]?
    private var clientCache: [String: (at: Date, list: [UniFiClientInfo])] = [:]
    private var deviceNames: [String: [String: String]] = [:]   // site -> device mac/id -> name

    init(config: UniFiConfig, apiKey: String) {
        self.config = config
        self.apiKey = apiKey
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.httpAdditionalHeaders = ["X-API-KEY": apiKey, "Accept": "application/json"]
        session = config.trustCertificate
            ? URLSession(configuration: cfg, delegate: TrustDelegate(host: config.host), delegateQueue: nil)
            : URLSession(configuration: cfg)
    }

    // MARK: HTTP

    private func getJSON(_ path: String) async throws -> (status: Int, json: Any?) {
        guard !config.url.isEmpty, let url = URL(string: config.url + path), url.host != nil else { throw UniFiError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw UniFiError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data)
        return (status, json)
    }

    private func rows(_ json: Any?) -> [[String: Any]]? {
        guard let dict = json as? [String: Any], let data = dict["data"] as? [[String: Any]] else { return nil }
        return data
    }

    // MARK: sites

    func sites() async throws -> [UniFiSite] {
        if let siteCache { return siteCache }
        // UniFi OS console first, then a stand-alone Network application, then the integration API.
        var lastStatus = 0
        for base in ["/proxy/network", ""] {
            let r = try await getJSON(base + "/api/self/sites")
            lastStatus = r.status
            if r.status == 200, let data = rows(r.json) {
                flavour = .classic(base: base)
                let list = data.compactMap { d -> UniFiSite? in
                    guard let name = d["name"] as? String else { return nil }
                    return UniFiSite(name: name, desc: d["desc"] as? String ?? name)
                }
                guard !list.isEmpty else { throw UniFiError.noSites }
                siteCache = list
                return list
            }
            if r.status == 401 || r.status == 403 { break }
        }
        for base in ["/proxy/network/integration/v1", "/integration/v1"] {
            let r = try await getJSON(base + "/sites?limit=200")
            if r.status == 200, let data = rows(r.json) {
                flavour = .integration(base: base)
                let list = data.compactMap { d -> UniFiSite? in
                    guard let id = d["id"] as? String else { return nil }
                    return UniFiSite(name: id, desc: d["name"] as? String ?? d["internalReference"] as? String ?? id)
                }
                guard !list.isEmpty else { throw UniFiError.noSites }
                siteCache = list
                return list
            }
            if r.status == 401 || r.status == 403 { lastStatus = r.status }
        }
        if lastStatus == 401 || lastStatus == 403 { throw UniFiError.unauthorized }
        if lastStatus == 200 || lastStatus == 404 || lastStatus == 0 { throw UniFiError.notJSON }
        throw UniFiError.http(lastStatus)
    }

    // MARK: clients

    func clients(of site: UniFiSite) async throws -> [UniFiClientInfo] {
        if let cached = clientCache[site.name], Date().timeIntervalSince(cached.at) < 90 { return cached.list }
        guard let flavour else { _ = try await sites(); return try await clients(of: site) }
        let list: [UniFiClientInfo]
        switch flavour {
        case .classic(let base):
            let r = try await getJSON("\(base)/api/s/\(site.name)/stat/sta")
            guard r.status == 200, let data = rows(r.json) else { throw r.status == 401 ? UniFiError.unauthorized : UniFiError.http(r.status) }
            let names = try await classicDeviceNames(base: base, site: site)
            list = data.compactMap { d -> UniFiClientInfo? in
                guard let ip = d["ip"] as? String, let mac = d["mac"] as? String else { return nil }
                let wired = (d["is_wired"] as? Bool) ?? ((d["sw_port"] as? Int) != nil)
                let swMAC = d["sw_mac"] as? String
                let apMAC = d["ap_mac"] as? String
                return UniFiClientInfo(
                    ip: ip, mac: mac, name: d["name"] as? String, hostname: d["hostname"] as? String, wired: wired,
                    switchName: d["last_uplink_name"] as? String ?? swMAC.flatMap { names[$0.lowercased()] },
                    switchMAC: swMAC, port: d["sw_port"] as? Int,
                    apName: apMAC.flatMap { names[$0.lowercased()] }, ssid: d["essid"] as? String,
                    network: d["network"] as? String)
            }
        case .integration(let base):
            var all: [[String: Any]] = []
            var offset = 0
            while true {
                let r = try await getJSON("\(base)/sites/\(site.name)/clients?offset=\(offset)&limit=200")
                guard r.status == 200, let data = rows(r.json) else { throw r.status == 401 ? UniFiError.unauthorized : UniFiError.http(r.status) }
                all += data
                let total = (r.json as? [String: Any])?["totalCount"] as? Int ?? all.count
                offset += 200
                if data.isEmpty || offset >= total { break }
            }
            let names = try await integrationDeviceNames(base: base, site: site)
            list = all.compactMap { d -> UniFiClientInfo? in
                guard let ip = d["ipAddress"] as? String else { return nil }
                let type = (d["type"] as? String ?? "").uppercased()
                let uplink = d["uplinkDeviceId"] as? String
                return UniFiClientInfo(
                    ip: ip, mac: d["macAddress"] as? String ?? "", name: d["name"] as? String, hostname: nil, wired: type == "WIRED",
                    switchName: type == "WIRED" ? uplink.flatMap { names[$0] } : nil, switchMAC: nil, port: nil,
                    apName: type == "WIRELESS" ? uplink.flatMap { names[$0] } : nil, ssid: nil, network: nil)
            }
        }
        clientCache[site.name] = (Date(), list)
        return list
    }

    private func classicDeviceNames(base: String, site: UniFiSite) async throws -> [String: String] {
        if let cached = deviceNames[site.name] { return cached }
        var names: [String: String] = [:]
        for path in ["stat/device-basic", "stat/device"] {
            let r = try await getJSON("\(base)/api/s/\(site.name)/\(path)")
            guard r.status == 200, let data = rows(r.json) else { continue }
            for d in data {
                guard let mac = (d["mac"] as? String)?.lowercased() else { continue }
                if let name = d["name"] as? String, !name.isEmpty { names[mac] = name }
            }
            if !names.isEmpty { break }
        }
        deviceNames[site.name] = names
        return names
    }

    private func integrationDeviceNames(base: String, site: UniFiSite) async throws -> [String: String] {
        if let cached = deviceNames[site.name] { return cached }
        var names: [String: String] = [:]
        let r = try await getJSON("\(base)/sites/\(site.name)/devices?limit=200")
        if r.status == 200, let data = rows(r.json) {
            for d in data {
                guard let id = d["id"] as? String, let name = d["name"] as? String, !name.isEmpty else { continue }
                names[id] = name
            }
        }
        deviceNames[site.name] = names
        return names
    }

    /// The site's internet address, from the gateway's health record (classic API only).
    func publicIP(of site: UniFiSite) async -> String? {
        guard case .classic(let base)? = flavour else { return nil }
        guard let r = try? await getJSON("\(base)/api/s/\(site.name)/stat/health"), r.status == 200, let data = rows(r.json) else { return nil }
        for d in data where (d["subsystem"] as? String) == "wan" {
            if let ip = d["wan_ip"] as? String, !ip.isEmpty { return ip }
        }
        return nil
    }

    // MARK: the lookup

    /// Where a client with this address is: which site (the remote machine's public IP settles it when the
    /// same private range exists at several sites), which switch and port, and what it is called.
    func lookup(ip: String, publicIP: String?) async throws -> UniFiLookup {
        let sites = try await sites()
        // Every site's clients, a few sites at a time.
        var hits: [(site: UniFiSite, client: UniFiClientInfo, all: [UniFiClientInfo])] = []
        var failures = 0
        for chunk in stride(from: 0, to: sites.count, by: 6).map({ Array(sites[$0..<min($0 + 6, sites.count)]) }) {
            let results = await withTaskGroup(of: (UniFiSite, [UniFiClientInfo]?).self) { group in
                for site in chunk {
                    group.addTask { (site, try? await self.clients(of: site)) }
                }
                var out: [(UniFiSite, [UniFiClientInfo]?)] = []
                for await r in group { out.append(r) }
                return out
            }
            for (site, list) in results {
                guard let list else { failures += 1; continue }
                if let c = list.first(where: { $0.ip == ip }) { hits.append((site, c, list)) }
            }
        }
        if hits.count > 1, let publicIP {
            for h in hits where await self.publicIP(of: h.site) == publicIP {
                return UniFiLookup(site: h.site, siteByPublicIP: true, client: h.client, clientsByIP: Self.index(h.all),
                                   note: nil)
            }
        }
        if let h = hits.first {
            let note = hits.count > 1 ? "also at \(hits.count - 1) other site\(hits.count > 2 ? "s" : "")" : nil
            return UniFiLookup(site: h.site, siteByPublicIP: false, client: h.client, clientsByIP: Self.index(h.all), note: note)
        }
        // No client with that address anywhere: the public IP can still say which site this is.
        if let publicIP {
            for site in sites where await self.publicIP(of: site) == publicIP {
                let list = (try? await clients(of: site)) ?? []
                return UniFiLookup(site: site, siteByPublicIP: true, client: nil, clientsByIP: Self.index(list),
                                   note: "no client with \(ip) is known there right now")
            }
        }
        let note = failures > 0 ? "\(ip) not found (\(failures) site\(failures == 1 ? "" : "s") could not be read)" : "\(ip) is not a known client on any of the \(sites.count) sites"
        return UniFiLookup(site: nil, siteByPublicIP: false, client: nil, clientsByIP: [:], note: note)
    }

    private static func index(_ list: [UniFiClientInfo]) -> [String: UniFiClientInfo] {
        var out: [String: UniFiClientInfo] = [:]
        for c in list where out[c.ip] == nil { out[c.ip] = c }
        return out
    }
}
