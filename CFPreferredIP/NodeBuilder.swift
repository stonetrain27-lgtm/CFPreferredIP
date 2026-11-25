import Foundation
import Darwin

// MARK: - 模型

enum NodeKind: String {
    case vless = "VLESS"
    case vmess = "VMess"
    case trojan = "Trojan"
    case hy2 = "Hysteria2"
    case anytls = "AnyTLS"
    case ss = "Shadowsocks"
    case socks = "SOCKS5"
    case mtproto = "MTProto"
    case surge = "Surge"
}

/// 该节点能否使用 Cloudflare 优选 IP
enum CDNStatus {
    case ready        // 传输适合 CDN，且地址已经是域名
    case needsDomain  // 传输适合 CDN，但地址是 IP，需要填写 CF 域名
    case direct       // 直连协议（Reality / UDP / TCP 等），CF 无法代理
}

struct NodeTemplate: Identifiable {
    let id = UUID()
    let raw: String
    let kind: NodeKind
    let name: String
    let host: String
    let port: String
    let transport: String
    let security: String
    let status: CDNStatus
    /// 节点自带的 CF 域名（来自 sni / host 参数），地址是优选 IP 时靠它识别
    var domain: String = ""

    var label: String {
        var parts = [kind.rawValue]
        if kind == .vless || kind == .vmess || kind == .trojan {
            parts.append(transport.uppercased())
            if security != "none" { parts.append(security.uppercased()) }
        }
        return parts.joined(separator: " · ")
    }
}

struct BuildOptions {
    var domain = ""
    var force = false
}

struct GeneratedNode: Identifiable {
    let id = UUID()
    let ip: String
    let name: String
    let link: String
}

// MARK: - URL 拆分（保持原样，只替换需要的部分）

struct URLParts {
    var scheme: String
    var userinfo: String?
    var host: String
    var port: String?
    var path: String
    var query: String
    var fragment: String?
}

struct Query {
    var items: [(String, String)] = []

    init(_ s: String) {
        for part in s.split(separator: "&", omittingEmptySubsequences: true) {
            if let eq = part.firstIndex(of: "=") {
                items.append((String(part[..<eq]), String(part[part.index(after: eq)...])))
            } else {
                items.append((String(part), ""))
            }
        }
    }

    func get(_ key: String) -> String? {
        guard let item = items.first(where: { $0.0 == key }) else { return nil }
        return item.1.removingPercentEncoding ?? item.1
    }

    mutating func set(_ key: String, _ value: String) {
        if let i = items.firstIndex(where: { $0.0 == key }) {
            items[i].1 = value
        } else {
            items.append((key, value))
        }
    }

    mutating func setIfMissing(_ key: String, _ value: String) {
        if (get(key) ?? "").isEmpty { set(key, value) }
    }

    var string: String {
        items.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }
}

// MARK: - 生成器

enum NodeBuilder {
    static let cdnTransports: Set<String> = ["ws", "httpupgrade", "grpc", "xhttp", "splithttp"]
    static let hostTransports: Set<String> = ["ws", "httpupgrade", "xhttp", "splithttp"]

    // MARK: 工具

    static func isIP(_ s: String) -> Bool {
        let h = s.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var a4 = in_addr()
        var a6 = in6_addr()
        return inet_pton(AF_INET, h, &a4) == 1 || inet_pton(AF_INET6, h, &a6) == 1
    }

    static func decodeBase64(_ s: String) -> Data? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = t.count % 4
        if rem > 0 { t += String(repeating: "=", count: 4 - rem) }
        return Data(base64Encoded: t)
    }

    static func encodeFragment(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.subtracting(CharacterSet(charactersIn: "#"))) ?? s
    }

    static func splitURL(_ s: String) -> URLParts? {
        guard let r = s.range(of: "://") else { return nil }
        let scheme = String(s[..<r.lowerBound])
        var rest = String(s[r.upperBound...])

        var fragment: String?
        if let h = rest.firstIndex(of: "#") {
            fragment = String(rest[rest.index(after: h)...])
            rest = String(rest[..<h])
        }
        var query = ""
        if let q = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: q)...])
            rest = String(rest[..<q])
        }
        var path = ""
        if let sl = rest.firstIndex(of: "/") {
            path = String(rest[sl...])
            rest = String(rest[..<sl])
        }
        var userinfo: String?
        if let at = rest.lastIndex(of: "@") {
            userinfo = String(rest[..<at])
            rest = String(rest[rest.index(after: at)...])
        }

        var host = rest
        var port: String?
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...]
            if after.hasPrefix(":") { port = String(after.dropFirst()) }
        } else if rest.filter({ $0 == ":" }).count == 1, let colon = rest.lastIndex(of: ":") {
            host = String(rest[..<colon])
            port = String(rest[rest.index(after: colon)...])
        }
        return URLParts(scheme: scheme, userinfo: userinfo, host: host, port: port,
                        path: path, query: query, fragment: fragment)
    }

    static func build(_ p: URLParts, name: String?) -> String {
        var s = p.scheme + "://"
        if let u = p.userinfo { s += u + "@" }
        s += p.host.contains(":") ? "[\(p.host)]" : p.host
        if let port = p.port, !port.isEmpty { s += ":" + port }
        s += p.path
        if !p.query.isEmpty { s += "?" + p.query }
        if let n = name, !n.isEmpty { s += "#" + encodeFragment(n) }
        return s
    }

    static func stringValue(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    static func classify(host: String, domain: String, transport: String, security: String) -> CDNStatus {
        guard security != "reality", cdnTransports.contains(transport) else { return .direct }
        return (isIP(host) && domain.isEmpty) ? .needsDomain : .ready
    }

    /// 从 sni / host 参数里取出非 IP 的域名（订阅里的节点地址常常已经是优选 IP）
    static func embeddedDomain(_ q: Query) -> String {
        for key in ["sni", "host"] {
            let v = (q.get(key) ?? "").trimmingCharacters(in: .whitespaces)
            if !v.isEmpty, !isIP(v) { return v }
        }
        return ""
    }

    /// SIP003 plugin 参数（分号分隔）里的 host / sni
    static func pluginDomain(_ plugin: String) -> String {
        for part in plugin.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            let k = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
            let v = kv[1].trimmingCharacters(in: .whitespaces)
            if (k == "host" || k == "sni"), !v.isEmpty, !isIP(v) { return v }
        }
        return ""
    }

    // MARK: 解析模板

    private static let urlRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])(?:vless|vmess|trojan|hysteria2|hy2|anytls|ss|socks5|socks|tg)://[^\s"'<>]+|https://t\.me/proxy\?[^\s"'<>]+"#,
        options: [.caseInsensitive])

    private static let surgeRegex = try! NSRegularExpression(
        pattern: #"^\s*([^=,\n]+?)\s*=\s*([A-Za-z0-9\-]+)\s*,\s*([^,\s]+)\s*,\s*(\d+)\s*(,.*)?$"#)

    struct SurgeLine {
        var name: String
        var type: String
        var host: String
        var port: String
        var rest: String
    }

    static func parseSurge(_ line: String) -> SurgeLine? {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let m = surgeRegex.firstMatch(in: line, range: full) else { return nil }
        func g(_ i: Int) -> String {
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
        return SurgeLine(name: g(1), type: g(2), host: g(3), port: g(4), rest: g(5))
    }

    static func parseTemplates(_ text: String, keepPorts: Bool = false) -> [NodeTemplate] {
        parseTemplatesDetailed(text, keepPorts: keepPorts).templates
    }

    /// 去掉「只有地址 / 名称 / 端口不同」的重复节点（订阅里常见：同一节点配了几十个优选地址、
    /// 或同一个 IP 配了多个 CF 端口）。一个优选 IP 只生成一条节点，端口取同组里第一个模板的。
    private static func identityKey(_ t: NodeTemplate, keepPorts: Bool) -> String {
        let hostPart = t.domain.isEmpty ? t.host : ""
        switch t.kind {
        case .vmess:
            guard var obj = vmessPayload(t.raw) else { return t.raw }
            obj["ps"] = nil
            if !t.domain.isEmpty {
                obj["add"] = nil
                if !keepPorts { obj["port"] = nil }
            }
            guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
                  let str = String(data: d, encoding: .utf8) else { return t.raw }
            return "vmess|" + str
        case .surge, .mtproto, .ss:
            return t.raw
        default:
            guard let p = splitURL(t.raw) else { return t.raw }
            return [p.scheme.lowercased(), p.userinfo ?? "", hostPart,
                    keepPorts ? (p.port ?? "") : "", p.path, p.query].joined(separator: "|")
        }
    }

    /// keepPorts：订阅里同一节点配了多个 CF 端口时，true 保留每个端口各一个模板，false 合并为第一个端口。
    static func parseTemplatesDetailed(_ text: String, keepPorts: Bool = false) -> (templates: [NodeTemplate], merged: Int) {
        var result: [NodeTemplate] = []
        var seen = Set<String>()
        var keys = Set<String>()
        var merged = 0

        func add(_ t: NodeTemplate) {
            if keys.insert(identityKey(t, keepPorts: keepPorts)).inserted {
                result.append(t)
            } else {
                merged += 1
            }
        }

        for line in text.components(separatedBy: .newlines) {
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            let matches = urlRegex.matches(in: line, range: full)

            if !matches.isEmpty {
                for m in matches {
                    let token = ns.substring(with: m.range)
                    if seen.insert(token).inserted, let t = parseURL(token) {
                        add(t)
                    }
                }
            } else if let s = parseSurge(line) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard seen.insert(trimmed).inserted else { continue }
                let rest = s.rest.lowercased()
                let ws = rest.contains("ws=true")
                let tls = rest.contains("tls=true") || s.type.lowercased().contains("tls")
                let status: CDNStatus = (ws && !isIP(s.host)) ? .ready : .direct
                add(NodeTemplate(raw: trimmed, kind: .surge, name: s.name,
                                 host: s.host, port: s.port,
                                 transport: ws ? "ws" : "tcp",
                                 security: tls ? "tls" : "none",
                                 status: status))
            }
        }
        return (result, merged)
    }

    private static func parseURL(_ token: String) -> NodeTemplate? {
        let lower = token.lowercased()
        if lower.hasPrefix("vmess://") { return parseVMess(token) }
        if lower.hasPrefix("ss://") { return parseSS(token) }
        if lower.hasPrefix("tg://") || lower.hasPrefix("https://t.me/") { return parseMTProto(token) }

        guard let p = splitURL(token) else { return nil }
        let q = Query(p.query)
        let fragName = p.fragment.flatMap { $0.removingPercentEncoding ?? $0 } ?? ""

        switch p.scheme.lowercased() {
        case "vless", "trojan":
            let kind: NodeKind = p.scheme.lowercased() == "vless" ? .vless : .trojan
            let transport = (q.get("type") ?? "tcp").lowercased()
            let security = (q.get("security") ?? (kind == .trojan ? "tls" : "none")).lowercased()
            let domain = embeddedDomain(q)
            return NodeTemplate(raw: token, kind: kind,
                                name: fragName.isEmpty ? kind.rawValue : fragName,
                                host: p.host, port: p.port ?? "",
                                transport: transport, security: security,
                                status: classify(host: p.host, domain: domain,
                                                 transport: transport, security: security),
                                domain: domain)
        case "hysteria2", "hy2":
            return NodeTemplate(raw: token, kind: .hy2,
                                name: fragName.isEmpty ? NodeKind.hy2.rawValue : fragName,
                                host: p.host, port: p.port ?? "",
                                transport: "udp", security: "tls", status: .direct)
        case "anytls":
            return NodeTemplate(raw: token, kind: .anytls,
                                name: fragName.isEmpty ? NodeKind.anytls.rawValue : fragName,
                                host: p.host, port: p.port ?? "",
                                transport: "tcp", security: "tls", status: .direct)
        case "socks5", "socks":
            return NodeTemplate(raw: token, kind: .socks,
                                name: fragName.isEmpty ? NodeKind.socks.rawValue : fragName,
                                host: p.host, port: p.port ?? "",
                                transport: "tcp", security: "none", status: .direct)
        default:
            return nil
        }
    }

    private static func vmessPayload(_ raw: String) -> [String: Any]? {
        var body = String(raw.dropFirst(8))
        if let h = body.firstIndex(of: "#") { body = String(body[..<h]) }
        guard let data = decodeBase64(body),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private static func parseVMess(_ token: String) -> NodeTemplate? {
        guard let obj = vmessPayload(token) else { return nil }
        let add = stringValue(obj["add"])
        let net = stringValue(obj["net"]).lowercased()
        let transport = net.isEmpty ? "tcp" : net
        let tls = stringValue(obj["tls"]).lowercased()
        let security = tls.isEmpty ? "none" : tls
        let ps = stringValue(obj["ps"])
        var domain = ""
        for key in ["sni", "host"] {
            let v = stringValue(obj[key]).trimmingCharacters(in: .whitespaces)
            if !v.isEmpty, !isIP(v) { domain = v; break }
        }
        return NodeTemplate(raw: token, kind: .vmess,
                            name: ps.isEmpty ? NodeKind.vmess.rawValue : ps,
                            host: add, port: stringValue(obj["port"]),
                            transport: transport, security: security,
                            status: classify(host: add, domain: domain,
                                             transport: transport, security: security),
                            domain: domain)
    }

    private static func parseSS(_ token: String) -> NodeTemplate? {
        let body = String(token.dropFirst(5))
        let pieces = body.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = pieces.first else { return nil }
        let main = String(first)
        var name = ""
        if pieces.count > 1 {
            let f = String(pieces[1])
            name = f.removingPercentEncoding ?? f
        }

        if main.contains("@") {
            guard let p = splitURL(token) else { return nil }
            let plugin = (Query(p.query).get("plugin") ?? "").lowercased()
            let domain = pluginDomain(plugin)
            let viaWS = plugin.contains("websocket") && (!isIP(p.host) || !domain.isEmpty)
            return NodeTemplate(raw: token, kind: .ss,
                                name: name.isEmpty ? NodeKind.ss.rawValue : name,
                                host: p.host, port: p.port ?? "",
                                transport: viaWS ? "ws" : "tcp", security: "none",
                                status: viaWS ? .ready : .direct,
                                domain: domain)
        }

        // 旧格式：ss://BASE64(method:password@host:port)
        guard let data = decodeBase64(main),
              let decoded = String(data: data, encoding: .utf8),
              let at = decoded.lastIndex(of: "@") else { return nil }
        let hostport = String(decoded[decoded.index(after: at)...])
        var host = hostport
        var port = ""
        if let c = hostport.lastIndex(of: ":") {
            host = String(hostport[..<c])
            port = String(hostport[hostport.index(after: c)...])
        }
        return NodeTemplate(raw: token, kind: .ss,
                            name: name.isEmpty ? NodeKind.ss.rawValue : name,
                            host: host, port: port,
                            transport: "tcp", security: "none", status: .direct)
    }

    private static func parseMTProto(_ token: String) -> NodeTemplate? {
        guard let p = splitURL(token) else { return nil }
        let q = Query(p.query)
        guard let server = q.get("server"), !server.isEmpty else { return nil }
        return NodeTemplate(raw: token, kind: .mtproto, name: NodeKind.mtproto.rawValue,
                            host: server, port: q.get("port") ?? "",
                            transport: "tcp", security: "none", status: .direct)
    }

    // MARK: 生成

    struct EntryTarget {
        let domain: String
        let port: UInt16
        let path: String
    }

    /// 入口验活目标：取第一个带域名的 VLESS / Trojan 模板（域名是 workers.dev 且用户另填了域名时用用户的）。
    static func entryTarget(from templates: [NodeTemplate], ownDomain: String) -> EntryTarget? {
        for t in templates where t.kind == .vless || t.kind == .trojan {
            var d = t.domain
            if d.isEmpty, !isIP(t.host) { d = t.host }
            if d.hasSuffix(".workers.dev"), !ownDomain.isEmpty { d = ownDomain }
            guard !d.isEmpty, let p = splitURL(t.raw) else { continue }
            let path = Query(p.query).get("path") ?? "/"
            return EntryTarget(domain: d, port: UInt16(t.port) ?? 443, path: path.isEmpty ? "/" : path)
        }
        return nil
    }

    /// 每个 IP 只生成一个节点时，只用一个模板（优先 443 端口）；否则全部模板。
    static func pickTemplates(_ templates: [NodeTemplate], opts: BuildOptions,
                              onePerIP: Bool) -> (used: [NodeTemplate], eligibleCount: Int) {
        let eligibleAll = templates.filter { eligible($0, opts) }
        guard onePerIP, let first = eligibleAll.first(where: { $0.port == "443" }) ?? eligibleAll.first else {
            return (templates, eligibleAll.count)
        }
        return ([first], eligibleAll.count)
    }

    /// 订阅来源是不是本 App 自己同步出来的订阅（域名和路径密钥都对得上）。
    static func isOwnSubscription(_ url: String, ownPath: String?, ownHosts: [String]) -> Bool {
        guard let c = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = c.host?.lowercased(),
              let pathKey = ownPath, !pathKey.isEmpty, c.path == "/" + pathKey else { return false }
        return ownHosts.map { $0.lowercased() }.contains(host)
    }

    /// 节点域名以订阅来源为准：来源是自定义域名才用；本 App 自己的订阅或 workers.dev 不算。
    static func sourceDomain(subURL: String, ownSubscription: Bool) -> String {
        if ownSubscription { return "" }
        let host = URLComponents(string: subURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() ?? ""
        return host.hasSuffix(".workers.dev") ? "" : host
    }

    static func eligible(_ t: NodeTemplate, _ opts: BuildOptions) -> Bool {
        if opts.force { return true }
        switch t.status {
        case .ready: return true
        case .needsDomain: return !opts.domain.isEmpty
        case .direct: return false
        }
    }

    /// 去掉上一次生成追加的后缀（如 "-LAX-1"、"-优选2"、"_2053"），避免用自己的订阅再替换时名字越叠越长。
    static func baseName(_ s: String) -> String {
        var name = s
        while let r = name.range(of: #"(-[A-Z]{3}-\d+|-优选\d+)(_\d{2,5})?( \d+(\.\d+)?MB/s \d+ms)?$"#, options: .regularExpression) {
            let next = String(name[..<r.lowerBound])
            if next.isEmpty { break }
            name = next
        }
        return name
    }

    static func generate(templates: [NodeTemplate], ips: [IPResult],
                         opts: BuildOptions, maxNodes: Int = 20,
                         statsLabel: ((IPResult) -> String)? = nil) -> (nodes: [GeneratedNode], skipped: Int, truncated: Bool) {
        let eligibleTemplates = templates.filter { eligible($0, opts) }
        let skipped = templates.count - eligibleTemplates.count
        let limit = max(0, maxNodes)
        guard limit > 0, !eligibleTemplates.isEmpty, !ips.isEmpty else { return ([], skipped, false) }

        // 订阅里有多个端口时，名字里带上端口，避免同一 IP 的几条节点重名。
        let multiPort = Set(eligibleTemplates.map(\.port)).count > 1
        let total = eligibleTemplates.count * ips.count
        // Interleave templates per IP so the cap does not starve later templates.
        var nodes: [GeneratedNode] = []
        nodes.reserveCapacity(min(limit, total))
        for (ipIndex, result) in ips.enumerated() {
            for template in eligibleTemplates {
                let suffix = result.colo.map { "\($0)-\(ipIndex + 1)" } ?? "优选\(ipIndex + 1)"
                var name = "\(baseName(template.name))-\(suffix)"
                if multiPort, !template.port.isEmpty { name += "_\(template.port)" }
                if let label = statsLabel?(result), !label.isEmpty { name += " \(label)" }
                if let link = render(template, ip: result.ip, name: name, opts: opts) {
                    nodes.append(GeneratedNode(ip: result.ip, name: name, link: link))
                    if nodes.count >= limit { return (nodes, skipped, total > nodes.count) }
                }
            }
        }
        return (nodes, skipped, false)
    }

    static func render(_ t: NodeTemplate, ip: String, name: String, opts: BuildOptions) -> String? {
        switch t.kind {
        case .vmess: return renderVMess(t, ip: ip, name: name, opts: opts)
        case .ss: return renderSS(t, ip: ip, name: name)
        case .surge: return renderSurge(t, ip: ip, name: name)
        case .mtproto: return renderMTProto(t, ip: ip)
        case .vless, .trojan, .hy2, .anytls, .socks: return renderGeneral(t, ip: ip, name: name, opts: opts)
        }
    }

    /// 是否把节点改写成「域名 + CF TLS」模式
    private static func useDomain(_ t: NodeTemplate, _ opts: BuildOptions) -> Bool {
        !opts.domain.isEmpty && t.domain.isEmpty && isIP(t.host)
            && cdnTransports.contains(t.transport) && t.security != "reality"
    }


    /// 模板域名是 workers.dev 且用户填了自己的域名时，用用户域名（与验活 entryTarget 口径一致）。
    private static func effectiveDomain(_ d: String, _ opts: BuildOptions) -> String {
        if d.hasSuffix(".workers.dev"), !opts.domain.isEmpty { return opts.domain }
        return d
    }

    private static func renderGeneral(_ t: NodeTemplate, ip: String, name: String, opts: BuildOptions) -> String? {
        guard var p = splitURL(t.raw) else { return nil }
        var q = Query(p.query)
        let origHost = p.host
        p.host = ip

        switch t.kind {
        case .vless, .trojan:
            if useDomain(t, opts) {
                q.set("security", "tls")
                q.set("sni", opts.domain)
                if hostTransports.contains(t.transport) { q.set("host", opts.domain) }
            } else {
                let rawD = !t.domain.isEmpty ? t.domain : (isIP(origHost) ? "" : origHost)
                let d = effectiveDomain(rawD, opts)
                if !d.isEmpty {
                    if d != rawD {
                        if t.security == "tls" { q.set("sni", d) }
                        if hostTransports.contains(t.transport) { q.set("host", d) }
                    } else {
                        if t.security == "tls" { q.setIfMissing("sni", d) }
                        if hostTransports.contains(t.transport) { q.setIfMissing("host", d) }
                    }
                }
            }
        case .hy2, .anytls:
            if !isIP(origHost) { q.setIfMissing("sni", origHost) }
        default:
            break
        }

        p.query = q.string
        return build(p, name: name)
    }

    private static func renderVMess(_ t: NodeTemplate, ip: String, name: String, opts: BuildOptions) -> String? {
        guard var obj = vmessPayload(t.raw) else { return nil }
        let origAdd = stringValue(obj["add"])
        obj["add"] = ip
        obj["ps"] = name

        if useDomain(t, opts) {
            obj["tls"] = "tls"
            obj["sni"] = opts.domain
            if hostTransports.contains(t.transport) { obj["host"] = opts.domain }
        } else {
            let rawD = !t.domain.isEmpty ? t.domain : (isIP(origAdd) ? "" : origAdd)
            let d = effectiveDomain(rawD, opts)
            if !d.isEmpty {
                if d != rawD {
                    if t.security == "tls" { obj["sni"] = d }
                    if hostTransports.contains(t.transport) { obj["host"] = d }
                } else {
                    if stringValue(obj["sni"]).isEmpty && t.security == "tls" { obj["sni"] = d }
                    if stringValue(obj["host"]).isEmpty && hostTransports.contains(t.transport) { obj["host"] = d }
                }
            }
        }

        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return nil }
        return "vmess://" + data.base64EncodedString()
    }

    private static func renderSS(_ t: NodeTemplate, ip: String, name: String) -> String? {
        let body = String(t.raw.dropFirst(5))
        let pieces = body.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = pieces.first else { return nil }
        let main = String(first)

        if main.contains("@") {
            guard var p = splitURL(t.raw) else { return nil }
            p.host = ip
            return build(p, name: name)
        }

        guard let data = decodeBase64(main),
              let decoded = String(data: data, encoding: .utf8),
              let at = decoded.lastIndex(of: "@") else { return nil }
        let creds = String(decoded[..<at])
        let newHost = ip.contains(":") ? "[\(ip)]" : ip
        let payload = "\(creds)@\(newHost):\(t.port)"
        return "ss://" + Data(payload.utf8).base64EncodedString() + "#" + encodeFragment(name)
    }

    private static func renderSurge(_ t: NodeTemplate, ip: String, name: String) -> String? {
        guard let s = parseSurge(t.raw) else { return nil }
        var rest = s.rest
        if t.status == .ready, !rest.lowercased().contains("sni="), !isIP(s.host) {
            rest += ", sni=\(s.host)"
        }
        return "\(name) = \(s.type), \(ip), \(s.port)\(rest)"
    }

    private static func renderMTProto(_ t: NodeTemplate, ip: String) -> String? {
        guard var p = splitURL(t.raw) else { return nil }
        var q = Query(p.query)
        q.set("server", ip)
        p.query = q.string
        return build(p, name: nil)
    }
}

// MARK: - 订阅拉取（edgetunnel 等订阅链接）

enum SubscriptionFetcher {
    enum FetchError: LocalizedError {
        case badURL
        case http(Int)
        case tooLarge
        case clash
        case noNodes

        var errorDescription: String? {
            switch self {
            case .badURL: return "订阅地址无效，需要 https:// 开头的链接"
            case .http(let c): return "服务器返回 \(c)，请检查订阅路径或密钥"
            case .tooLarge: return "订阅内容太大（超过 500 KB）"
            case .clash: return "检测到 Clash YAML，但包含当前无法无损转换的节点或高级字段；请移除不支持项，或改用通用节点链接订阅。"
            case .noNodes: return "没有在返回内容里找到节点链接"
            }
        }
    }

    private static let maxBytes = 500_000

    static func fetch(_ urlString: String) async throws -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              url.host != nil else { throw FetchError.badURL }

        var req = URLRequest(url: url, timeoutInterval: 20)
        // 订阅服务通常按 User-Agent 决定输出格式，伪装成通用客户端以拿到 Base64 链接列表
        req.setValue("v2rayN/7.0", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw FetchError.http(0) }
        guard (200..<300).contains(http.statusCode) else { throw FetchError.http(http.statusCode) }
        guard data.count <= maxBytes else { throw FetchError.tooLarge }
        let body = String(decoding: data, as: UTF8.self)
        return try normalize(body)
    }

    static func normalize(_ body: String) throws -> String {
        if !NodeBuilder.parseTemplates(body).isEmpty { return body }

        let compact = body.components(separatedBy: .whitespacesAndNewlines).joined()
        if let data = NodeBuilder.decodeBase64(compact), !compact.isEmpty {
            let decoded = String(decoding: data, as: UTF8.self)
            if !NodeBuilder.parseTemplates(decoded).isEmpty { return decoded }
        }
        if body.range(of: #"(?m)^\s*proxies\s*:"#, options: .regularExpression) != nil {
            let parsed = parseClashYAML(body)
            // 混有无法无损转换的节点时整体拒绝，避免用户误以为所有节点都已导入。
            if !parsed.links.isEmpty && parsed.unsupported == 0 {
                return parsed.links.joined(separator: "\n")
            }
            throw FetchError.clash
        }
        throw FetchError.noNodes
    }

    /// 仅解析 Clash 常见 proxies 列表的简单映射字段；不尝试实现完整 YAML 规范。
    /// 锚点、别名、复杂流式集合、多文档和代理组均不在支持范围内。
    private static func parseClashYAML(_ text: String) -> (links: [String], unsupported: Int) {
        var entries: [[String: String]] = []
        var current: [String: String]?
        var pathStack: [(indent: Int, key: String)] = []
        var syntaxErrors = 0
        var inProxies = false

        func scalar(_ raw: String) -> String {
            var value = raw.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\n", with: "\n")
            } else if value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2 {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            } else if value.hasPrefix("#") {
                value = ""
            } else if let hash = value.indices.first(where: { index in
                value[index] == "#" && index > value.startIndex && value[value.index(before: index)].isWhitespace
            }) {
                value = String(value[..<hash]).trimmingCharacters(in: .whitespaces)
            }
            return value
        }

        for rawLine in text.components(separatedBy: .newlines) {
            if rawLine.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if rawLine.contains("\t") { continue }
            let indent = rawLine.prefix(while: { $0 == " " }).count
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if indent == 0 {
                if line == "proxies:" || line.hasPrefix("proxies: #") {
                    inProxies = true
                    current = nil
                    pathStack.removeAll()
                } else if !line.hasPrefix("#") {
                    inProxies = false
                }
                continue
            }
            guard inProxies else { continue }
            if line.hasPrefix("-") {
                guard indent == 2 else { syntaxErrors += 1; continue }
                if let current { entries.append(current) }
                current = [:]
                pathStack.removeAll()
                let remainder = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                if !remainder.isEmpty {
                    guard let colon = remainder.firstIndex(of: ":") else { syntaxErrors += 1; continue }
                    let key = String(remainder[..<colon]).trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty else { syntaxErrors += 1; continue }
                    let value = scalar(String(remainder[remainder.index(after: colon)...]))
                    if !value.isEmpty { current?[key] = value }
                }
                continue
            }
            guard current != nil else { syntaxErrors += 1; continue }
            guard let colon = line.firstIndex(of: ":") else { syntaxErrors += 1; continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { syntaxErrors += 1; continue }
            let value = scalar(String(line[line.index(after: colon)...]))
            while let last = pathStack.last, last.indent >= indent { pathStack.removeLast() }
            if value.isEmpty {
                pathStack.append((indent, key))
            } else {
                let fullKey = (pathStack.map(\.key) + [key]).joined(separator: ".").lowercased()
                current?[fullKey] = value
            }
        }
        if let current { entries.append(current) }
        let links = entries.compactMap(makeClashLink)
        return (links, entries.count - links.count + syntaxErrors)
    }

    private static func makeClashLink(_ item: [String: String]) -> String? {
        func get(_ key: String) -> String { item[key, default: ""] }
        func enc(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=?#%"))) ?? value
        }
        func hostPort() -> String {
            let host = get("server")
            return host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        }
        let name = get("name")
        let fragment = name.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.subtracting(CharacterSet(charactersIn: "#"))) ?? name
        let type = get("type").lowercased()
        let server = hostPort()
        guard !server.isEmpty, let port = Int(get("port")), (1...65535).contains(port) else { return nil }

        // 不支持的字段不能静默丢弃，否则导入成功但节点实际行为会改变。
        let common: Set<String> = ["name", "type", "server", "port"]
        let allowed: Set<String>
        switch type {
        case "vless":
            allowed = common.union(["uuid", "network", "tls", "servername", "sni", "client-fingerprint", "alpn",
                                   "ws-opts.path", "ws-opts.headers.host", "grpc-opts.grpc-service-name",
                                   "flow", "skip-cert-verify"])
        case "trojan":
            allowed = common.union(["password", "network", "tls", "servername", "sni", "client-fingerprint", "alpn",
                                   "ws-opts.path", "ws-opts.headers.host", "grpc-opts.grpc-service-name",
                                   "skip-cert-verify"])
        case "vmess":
            allowed = common.union(["uuid", "alterid", "cipher", "network", "tls", "servername", "sni",
                                   "ws-opts.path", "ws-opts.headers.host", "skip-cert-verify"])
        case "hysteria2", "hy2":
            allowed = common.union(["password", "servername", "sni", "skip-cert-verify"])
        case "ss":
            allowed = common.union(["cipher", "password"])
        case "socks5":
            allowed = common.union(["username", "password"])
        default:
            return nil
        }
        if item.keys.contains(where: { !allowed.contains($0) }) ||
            get("skip-cert-verify").lowercased() == "true" {
            return nil
        }

        switch type {
        case "vless", "trojan":
            let credential = type == "vless" ? get("uuid") : get("password")
            guard !credential.isEmpty else { return nil }
            let userInfoAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            let safeCredential = credential.addingPercentEncoding(withAllowedCharacters: userInfoAllowed) ?? credential
            let network = get("network").lowercased()
            var query: [(String, String)] = []
            if !network.isEmpty { query.append(("type", network)) }
            let rawTLS = get("tls").lowercased()
            let tls = (type == "trojan" && rawTLS.isEmpty) ? "true" : rawTLS
            guard tls.isEmpty || ["true", "false", "1", "0", "tls"].contains(tls) else { return nil }
            let hasTLSOptions = !get("servername").isEmpty || !get("sni").isEmpty ||
                !get("client-fingerprint").isEmpty || !get("alpn").isEmpty
            if !get("servername").isEmpty && !get("sni").isEmpty && get("servername") != get("sni") { return nil }
            if tls != "true" && tls != "1" && tls != "tls" && hasTLSOptions { return nil }
            if network != "ws" && (!get("ws-opts.path").isEmpty || !get("ws-opts.headers.host").isEmpty) { return nil }
            if network != "grpc" && !get("grpc-opts.grpc-service-name").isEmpty { return nil }
            if tls == "true" || tls == "1" || tls == "tls" {
                query.append(("security", "tls"))
                let sni = get("servername").isEmpty ? get("sni") : get("servername")
                if !sni.isEmpty { query.append(("sni", sni)) }
                if !get("client-fingerprint").isEmpty { query.append(("fp", get("client-fingerprint"))) }
                if !get("alpn").isEmpty { query.append(("alpn", get("alpn"))) }
            } else if type == "trojan" {
                // NodeBuilder's Trojan URI default is TLS; encode explicit no-TLS.
                query.append(("security", "none"))
            }
            if network == "ws" {
                let path = get("ws-opts.path")
                if !path.isEmpty { query.append(("path", path)) }
                let wsHost = get("ws-opts.headers.host")
                if !wsHost.isEmpty { query.append(("host", wsHost)) }
            } else if network == "grpc" {
                let service = get("grpc-opts.grpc-service-name")
                if !service.isEmpty {
                    guard type != "vmess" else { return nil }
                    query.append(("serviceName", service))
                }
            }
            if type == "vless", !get("flow").isEmpty { query.append(("flow", get("flow"))) }
            let queryText = query.map { "\($0.0)=\(enc($0.1))" }.joined(separator: "&")
            return "\(type)://\(safeCredential)@\(server):\(port)" + (queryText.isEmpty ? "" : "?\(queryText)") + (fragment.isEmpty ? "" : "#\(fragment)")

        case "vmess":
            guard !get("uuid").isEmpty else { return nil }
            let vmessTLS = get("tls").lowercased()
            guard vmessTLS.isEmpty || ["true", "false", "1", "0", "tls"].contains(vmessTLS) else { return nil }
            let vmessSNI = get("servername").isEmpty ? get("sni") : get("servername")
            if !get("servername").isEmpty && !get("sni").isEmpty && get("servername") != get("sni") { return nil }
            let vmessNetwork = get("network").isEmpty ? "tcp" : get("network").lowercased()
            if !["true", "1", "tls"].contains(vmessTLS) && !vmessSNI.isEmpty { return nil }
            if vmessNetwork != "ws" && (!get("ws-opts.path").isEmpty || !get("ws-opts.headers.host").isEmpty) { return nil }
            var obj: [String: Any] = ["v": "2", "ps": name, "add": get("server"), "port": String(port),
                                     "id": get("uuid"), "aid": get("alterid").isEmpty ? "0" : get("alterid"),
                                     "scy": get("cipher").isEmpty ? "auto" : get("cipher"), "net": vmessNetwork,
                                     "type": "none", "tls": ["true", "1", "tls"].contains(vmessTLS) ? "tls" : ""]
            if !vmessSNI.isEmpty { obj["sni"] = vmessSNI }
            if !get("ws-opts.path").isEmpty { obj["path"] = get("ws-opts.path") }
            if !get("ws-opts.headers.host").isEmpty { obj["host"] = get("ws-opts.headers.host") }
            guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return nil }
            return "vmess://" + data.base64EncodedString()

        case "hysteria2", "hy2":
            let password = get("password")
            guard !password.isEmpty else { return nil }
            let userInfoAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            let safePassword = password.addingPercentEncoding(withAllowedCharacters: userInfoAllowed) ?? password
            let sni = get("servername").isEmpty ? get("sni") : get("servername")
            let query = sni.isEmpty ? "" : "?sni=\(enc(sni))"
            return "hy2://\(safePassword)@\(server):\(port)\(query)" + (fragment.isEmpty ? "" : "#\(fragment)")

        case "ss":
            let method = get("cipher"), password = get("password")
            guard !method.isEmpty, !password.isEmpty else { return nil }
            let auth = Data("\(method):\(password)".utf8).base64EncodedString()
            return "ss://\(auth)@\(server):\(port)" + (fragment.isEmpty ? "" : "#\(fragment)")

        case "socks5":
            let user = get("username"), password = get("password")
            let userAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            let passAllowed = userAllowed
            let safeUser = user.addingPercentEncoding(withAllowedCharacters: userAllowed) ?? user
            let safePassword = password.addingPercentEncoding(withAllowedCharacters: passAllowed) ?? password
            let auth = user.isEmpty ? "" : "\(safeUser):\(safePassword)@"
            return "socks5://\(auth)\(server):\(port)" + (fragment.isEmpty ? "" : "#\(fragment)")
        default:
            return nil
        }
    }
}
