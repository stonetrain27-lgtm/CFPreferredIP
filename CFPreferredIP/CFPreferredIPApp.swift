import SwiftUI
import UIKit
import Foundation
import Network
import Darwin
import BackgroundTasks
import Fingerprint

// MARK: - App

@main
struct CFPreferredIPApp: App {
    init() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: bgTaskIdentifier, using: nil) { task in
            if let processing = task as? BGProcessingTask {
                BackgroundResumer.handle(processing)
            } else {
                task.setTaskCompleted(success: false)
            }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AutoRefresher.taskIdentifier, using: nil) { task in
            if let refresh = task as? BGAppRefreshTask {
                AutoRefresher.handle(refresh)
            } else {
                task.setTaskCompleted(success: false)
            }
        }
        AutoRefresher.schedule()
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

// MARK: - Model

struct IPResult: Identifiable {
    let id: UUID
    let ip: String
    var tcpLatency: Double            // ms
    var httpsLatency: Double? = nil   // ms
    var colo: String? = nil           // 数据中心代码，如 HKG / LAX
    var speed: Double? = nil          // MB/s

    init(id: UUID = UUID(), ip: String, tcpLatency: Double,
         httpsLatency: Double? = nil, colo: String? = nil, speed: Double? = nil,
         lossRate: Double = 0, testedAt: Date? = nil, network: String? = nil) {
        self.id = id
        self.ip = ip
        self.tcpLatency = tcpLatency
        self.httpsLatency = httpsLatency
        self.colo = colo
        self.speed = speed
        self.lossRate = lossRate
        self.testedAt = testedAt
        self.network = network
    }

    var bestLatency: Double { httpsLatency ?? tcpLatency }
    var lossRate: Double = 0          // TCP 握手丢包率（0~1）
    var testedAt: Date? = nil         // 最近一次测速时间
    var network: String? = nil        // 测速时的网络类型（wifi / cellular / wired / other）

    /// 排行榜综合分：以速度为主，延迟、丢包、测速时间扣分。越大越好。
    var score: Double {
        LeaderboardScore.value(speed: speed, latency: bestLatency, loss: lossRate, testedAt: testedAt)
    }

    static func byScore(_ a: IPResult, _ b: IPResult) -> Bool {
        let (x, y) = (a.score, b.score)
        if x != y { return x > y }
        let (sa, sb) = (a.speed ?? 0, b.speed ?? 0)
        return sa != sb ? sa > sb : a.bestLatency < b.bestLatency
    }

    /// CFST 同款排序：先比丢包率（无丢包的排前面），再比延迟。
    static func byQuality(_ a: IPResult, _ b: IPResult) -> Bool {
        a.lossRate != b.lossRate ? a.lossRate < b.lossRate : a.bestLatency < b.bestLatency
    }
}

struct TCPProbe {
    let avg: Double    // 成功握手的平均延迟 ms
    let loss: Double   // 丢包率 0~1
}

struct PingResult {
    let ms: Double
    let colo: String?
}


let defaultDownloadURL = "https://cf.xiu2.xyz/url"
let officialDownloadURL = "https://speed.cloudflare.com/__down?bytes=99999999"


extension NetworkKey {
    static func from(_ path: NWPath) -> String? {
        guard path.status == .satisfied else { return nil }
        if path.usesInterfaceType(.wifi) { return "wifi" }
        if path.usesInterfaceType(.cellular) { return "cellular" }
        if path.usesInterfaceType(.wiredEthernet) { return "wired" }
        return "other"
    }
}

extension HistoryIP {
    init(result r: IPResult) {
        self.init(id: r.id, ip: r.ip, tcpLatency: r.tcpLatency, httpsLatency: r.httpsLatency, colo: r.colo,
                  speed: r.speed, lossRate: r.lossRate, testedAt: r.testedAt?.timeIntervalSince1970,
                  network: r.network)
    }
}

/// 节点名里带上的速度和延迟，例如 "12.3MB/s 45ms"。
func nodeStatsLabel(_ r: IPResult) -> String {
    guard let speed = r.speed, speed > 0 else { return "" }
    return String(format: "%.1fMB/s %dms", speed, Int(r.bestLatency.rounded()))
}

extension HistoryIP {
    var asResult: IPResult? {
        guard let speed, speed > 0 else { return nil }
        return IPResult(id: id, ip: ip, tcpLatency: tcpLatency, httpsLatency: httpsLatency, colo: colo,
                        speed: speed, lossRate: lossRate ?? 0,
                        testedAt: testedAt.map { Date(timeIntervalSince1970: $0) }, network: network)
    }
}

/// 后台自动更新订阅（iOS 后台刷新，系统决定执行时间，不保证按时执行）。
enum AutoRefresher {
    static let taskIdentifier = "com.trainstone.CFPreferredIP.refresh"
    static let enabledKey = "cf.nodes.autoRefresh"

    static func schedule() {
        guard UserDefaults.standard.bool(forKey: enabledKey) else { return }
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    }

    static func handle(_ task: BGAppRefreshTask) {
        schedule()   // 先排下一次
        let work = Task {
            let ok = await refresh()
            task.setTaskCompleted(success: ok)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// 拉取订阅 → 取当前网络排行榜前 N 个 IP → 验入口 → 生成节点 → 同步订阅。
    @MainActor
    static func refresh() async -> Bool {
        let d = UserDefaults.standard
        guard d.bool(forKey: enabledKey) else { return false }
        // 没部署过订阅 Worker 就不在后台创建，避免在用户不知情时改动 Cloudflare
        guard KeychainStore.get(SubscriptionWorkerManager.hostKeychain) != nil,
              KeychainStore.get(SubscriptionWorkerManager.kvIDKeychain) != nil else { return false }

        let subURL = SecureLocalStore.read("cf.nodes.subURL").trimmingCharacters(in: .whitespacesAndNewlines)
        var text = SecureLocalStore.read("cf.nodes.template")
        if subURL.isEmpty {
            text += "\n" + SecureLocalStore.read("cf.nodes.subText")
        } else {
            guard let fetched = try? await SubscriptionFetcher.fetch(subURL) else { return false }
            text += "\n" + fetched
        }
        if Task.isCancelled { return false }

        let onePerIP = d.object(forKey: "cf.nodes.onePerIP") as? Bool ?? true
        let keepPorts = (d.object(forKey: "cf.nodes.keepPorts") as? Bool ?? false) && !onePerIP
        let parsed = NodeBuilder.parseTemplatesDetailed(text, keepPorts: keepPorts)

        let ownHosts = [SubscriptionWorkerManager.hostKeychain, SubscriptionWorkerManager.workersDevHostKeychain]
            .compactMap { KeychainStore.get($0) }
        let sourceIsOwn = NodeBuilder.isOwnSubscription(
            subURL, ownPath: KeychainStore.get(SubscriptionWorkerManager.publicPathKeychain), ownHosts: ownHosts)
        let sourceDomain = NodeBuilder.sourceDomain(subURL: subURL, ownSubscription: sourceIsOwn)
        let userDomain = (d.string(forKey: "cf.nodes.domain") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let options = BuildOptions(domain: userDomain.isEmpty ? sourceDomain : userDomain,
                                   force: d.bool(forKey: "cf.nodes.force"))

        let topN = max(1, d.object(forKey: "cf.nodes.topN") as? Int ?? 5)
        let net = NetworkKey.saved
        let pool = LeaderboardStore.load()
            .filter { $0.network == nil || $0.network == net }
            .compactMap { $0.asResult }
            .sorted(by: IPResult.byScore)
        guard !pool.isEmpty else { return false }

        var ips = Array(pool.prefix(topN))
        if d.object(forKey: "cf.nodes.verifyEntry") as? Bool ?? true,
           let target = NodeBuilder.entryTarget(from: parsed.templates, ownDomain: options.domain) {
            let candidates = Array(pool.prefix(min(pool.count, topN * 2 + 2)))
            let sniName = target.sni, hostName = target.host, portNumber = target.port, pathValue = target.path
            let passed: Set<Int> = await withTaskGroup(of: (Int, Bool).self) { group in
                for (i, c) in candidates.enumerated() {
                    let ip = c.ip
                    group.addTask { (i, await Tester.entryCheck(ip: ip, port: portNumber, sni: sniName, host: hostName, path: pathValue)) }
                }
                var ok = Set<Int>()
                for await (i, pass) in group where pass { ok.insert(i) }
                return ok
            }
            let good = candidates.enumerated().filter { passed.contains($0.offset) }.map(\.element)
            if !good.isEmpty { ips = Array(good.prefix(topN)) }
        }
        if Task.isCancelled { return false }

        let used = NodeBuilder.pickTemplates(parsed.templates, opts: options, onePerIP: onePerIP).used
        let withStats = d.bool(forKey: "cf.nodes.nameWithStats")
        let maxNodes = d.object(forKey: "cf.nodes.maxNodes") as? Int ?? 40
        let generated = NodeBuilder.generate(templates: used, ips: ips, opts: options, maxNodes: maxNodes,
                                             statsLabel: withStats ? nodeStatsLabel : nil)
        guard !generated.nodes.isEmpty else { return false }

        do {
            _ = try await SubscriptionWorkerManager.updateExisting(
                nodes: generated.nodes.map(\.link), customDomain: sourceDomain, bindDomain: "")
        } catch {
            return false
        }
        let saved = generated.nodes.map { ["name": $0.name, "link": $0.link] }
        if let data = try? JSONSerialization.data(withJSONObject: saved),
           let json = String(data: data, encoding: .utf8) {
            SecureLocalStore.write("cf.nodes.result", json)
        }
        d.set(Date().timeIntervalSince1970, forKey: "cf.nodes.lastSync")
        d.set("后台自动更新 · \(generated.nodes.count) 条 · 排行榜（\(NetworkKey.label(net))）", forKey: "cf.nodes.lastSyncInfo")
        return true
    }
}




let bgTaskIdentifier = "com.trainstone.CFPreferredIP.processing"

/// 扫描断点：测速阶段的进度存档，切后台或被系统杀后可续测。
struct ScanState: Codable {
    var port: Int
    var downloadURL: String
    var items: [HistoryIP]
    var target: Int? = nil          // 目标测出几个可用 IP
    var backups: [HistoryIP]? = nil // 备用候选：前面的测速失败时按顺序补上
}

/// 用户手动停止后留下的「未测完」IP：已测出速度的已进排行榜，这里只存还没测的。
/// 不在主页面显示，只在「设置 → 未完成的测试」里提供继续 / 丢弃。
struct PausedScan: Codable {
    var port: Int
    var downloadURL: String
    var date: Date
    var items: [HistoryIP]
    var target: Int? = nil
    var backups: [HistoryIP]? = nil
}

/// 后台处理任务里续测：只用存档 + 静态测速，不依赖界面 ViewModel。
enum BackgroundResumer {
    static func handle(_ task: BGProcessingTask) {
        let work = Task {
            defer { task.setTaskCompleted(success: !Task.isCancelled) }
            Tester.resetDownloadHealth()
            guard let data = UserDefaults.standard.data(forKey: "cf.scan.state"),
                  var state = try? JSONDecoder().decode(ScanState.self, from: data) else { return }
            let p = UInt16(clamping: state.port)
            let target = state.target ?? state.items.count
            var got = state.items.filter { ($0.speed ?? 0) > 0 }.count
            var backups = state.backups ?? []
            var i = 0
            while i < state.items.count {
                if Task.isCancelled { return }
                if got >= target { break }
                guard state.items[i].speed == nil else { i += 1; continue }
                let speed = await Tester.downloadSpeed(ip: state.items[i].ip, port: p, urlString: state.downloadURL)
                state.items[i].speed = speed ?? 0
                if (speed ?? 0) > 0 {
                    got += 1
                } else if !backups.isEmpty {
                    state.items.append(backups.removeFirst())   // 失败了就补一个备用候选
                }
                state.backups = backups
                if let d = try? JSONEncoder().encode(state) {
                    UserDefaults.standard.set(d, forKey: "cf.scan.state")
                }
                i += 1
            }
            mergeIntoLeaderboardStore(state.items)
            UserDefaults.standard.removeObject(forKey: "cf.scan.state")
        }
        task.expirationHandler = { work.cancel() }
    }

    private static func mergeIntoLeaderboardStore(_ items: [HistoryIP]) {
        LeaderboardStore.save(LeaderboardStore.merged(existing: LeaderboardStore.load(), scanned: items,
                                                      network: NetworkKey.saved, now: Date()))
    }
}

let defaultRanges = """
173.245.48.0/20
103.21.244.0/22
103.22.200.0/22
103.31.4.0/22
141.101.64.0/18
108.162.192.0/18
190.93.240.0/20
188.114.96.0/20
197.234.240.0/22
198.41.128.0/17
162.158.0.0/15
104.16.0.0/13
104.24.0.0/14
172.64.0.0/13
131.0.72.0/22
2400:cb00::/32
2606:4700::/32
2803:f800::/32
2405:b500::/32
2405:8100::/32
2a06:98c0::/29
2c0f:f248::/32
"""

// MARK: - CIDR（IPv4 + IPv6）


// MARK: - Network tests


/// 保证 continuation 只 resume 一次
final class Once {
    private var done = false
    private let lock = NSLock()
    func run(_ block: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        if done { return }
        done = true
        block()
    }
}

/// 在 Task 被取消时，安全地取消底层 NWConnection。
final class ConnectionHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NWConnection?
    private var cancelled = false

    func set(_ connection: NWConnection) {
        lock.lock()
        self.connection = connection
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { connection.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let connection = self.connection
        lock.unlock()
        connection?.cancel()
    }
}

enum Tester {
    /// 自定义测速地址连续失败多次（地址本身挂了）时，自动切到官方测速接口。
    static let downloadHealth = DownloadHealth()
    static func resetDownloadHealth() { downloadHealth.reset() }
    static var downloadFallbackActive: Bool { downloadHealth.useFallback }

    static let sni = "speed.cloudflare.com"

    private static func nwPort(_ p: UInt16) -> NWEndpoint.Port {
        NWEndpoint.Port(rawValue: p) ?? 443
    }

    private static func makeTLS(ip: String, port: UInt16) -> NWConnection {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, sni)
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        return NWConnection(host: NWEndpoint.Host(ip), port: nwPort(port), using: params)
    }

    /// 1) TCP 握手延迟（ms）
    static func tcpLatency(ip: String, port: UInt16, timeout: Double = 1.5) async -> Double? {
        let holder = ConnectionHolder()
        return await withTaskCancellationHandler(operation: {
        await withCheckedContinuation { (cont: CheckedContinuation<Double?, Never>) in
            let conn = NWConnection(host: NWEndpoint.Host(ip), port: nwPort(port), using: .tcp)
            holder.set(conn)
            let q = DispatchQueue(label: "tcp.\(ip)")
            let once = Once()
            let start = DispatchTime.now().uptimeNanoseconds

            func finish(_ v: Double?) {
                once.run {
                    conn.cancel()
                    cont.resume(returning: v)
                }
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                case .failed, .cancelled:
                    finish(nil)
                default: break
                }
            }
            conn.start(queue: q)
            q.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
        }, onCancel: {
            holder.cancel()
        })
    }

    /// XIU2 风格的多次握手取平均值，降低单次 TCP 抖动导致的误选。
    static func averagedTCPLatency(ip: String, port: UInt16, attempts: Int = 3) async -> Double? {
        var samples: [Double] = []
        samples.reserveCapacity(attempts)
        for i in 0..<attempts {
            if Task.isCancelled { return nil }
            if let value = await tcpLatency(ip: ip, port: port) {
                samples.append(value)
            } else if i == 0 {
                return nil   // 第一次就连不上，直接淘汰，不再白等 2 个超时
            }
        }
        guard !samples.isEmpty else { return nil }
        return samples.reduce(0, +) / Double(samples.count)
    }

    /// CFST 同款 TCP 探测：握手 4 次（超时 1 秒），记录丢包率；
    /// 前两次都连不上就直接淘汰，不再白等。
    static func tcpProbe(ip: String, port: UInt16, attempts: Int = 4) async -> TCPProbe? {
        var samples: [Double] = []
        var fails = 0
        for _ in 0..<attempts {
            if Task.isCancelled { return nil }
            if let v = await tcpLatency(ip: ip, port: port, timeout: 1.0) {
                samples.append(v)
            } else {
                fails += 1
                if samples.isEmpty && fails >= 2 { return nil }
            }
        }
        guard !samples.isEmpty else { return nil }
        return TCPProbe(avg: samples.reduce(0, +) / Double(samples.count),
                        loss: Double(fails) / Double(attempts))
    }

    /// 2) HTTPS 延迟：TLS 建立后，发送 /cdn-cgi/trace，测请求到首字节的时间，并解析 colo
    static func httpsPing(ip: String, port: UInt16, timeout: Double = 4) async -> PingResult? {
        let holder = ConnectionHolder()
        return await withTaskCancellationHandler(operation: {
        await withCheckedContinuation { (cont: CheckedContinuation<PingResult?, Never>) in
            let conn = makeTLS(ip: ip, port: port)
            holder.set(conn)
            let q = DispatchQueue(label: "https.\(ip)")
            let once = Once()
            var sentAt: UInt64 = 0
            var firstByteMs: Double?
            var buffer = Data()

            func finish() {
                once.run {
                    conn.cancel()
                    guard let ms = firstByteMs,
                          let text = String(data: buffer, encoding: .utf8),
                          text.hasPrefix("HTTP/") else {
                        cont.resume(returning: nil)
                        return
                    }
                    guard let headerEnd = text.range(of: "\r\n\r\n") else {
                        cont.resume(returning: nil)
                        return
                    }
                    let header = String(text[..<headerEnd.lowerBound])
                    let firstLine = header.components(separatedBy: "\r\n").first ?? ""
                    let statusCode = Int(firstLine.split(separator: " ").dropFirst().first ?? "") ?? 0
                    guard (200..<300).contains(statusCode) else {
                        cont.resume(returning: nil)
                        return
                    }
                    let body = String(text[headerEnd.upperBound...])
                    guard body.contains("colo=") else {
                        cont.resume(returning: nil)
                        return
                    }
                    var colo: String?
                    if let r = body.range(of: "colo=") {
                        let c = body[r.upperBound...].prefix(while: { !$0.isNewline })
                        colo = c.isEmpty ? nil : String(c)
                    }
                    cont.resume(returning: PingResult(ms: ms, colo: colo))
                }
            }

            func receive() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, isComplete, error in
                    if let data = data, !data.isEmpty {
                        if firstByteMs == nil {
                            firstByteMs = Double(DispatchTime.now().uptimeNanoseconds - sentAt) / 1_000_000
                        }
                        buffer.append(data)
                    }
                    if error != nil || isComplete || buffer.count > 8192 {
                        finish()
                    } else {
                        receive()
                    }
                }
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let req = "GET /cdn-cgi/trace HTTP/1.1\r\nHost: \(sni)\r\nUser-Agent: Mozilla/5.0\r\nConnection: close\r\n\r\n"
                    sentAt = DispatchTime.now().uptimeNanoseconds
                    conn.send(content: req.data(using: .utf8), completion: .contentProcessed { _ in })
                    receive()
                case .failed, .cancelled:
                    finish()
                default: break
                }
            }
            conn.start(queue: q)
            q.asyncAfter(deadline: .now() + timeout) { finish() }
        }
        }, onCancel: {
            holder.cancel()
        })
    }

    /// 3) 入口验活：用节点真实域名对候选 IP 做 TLS 握手，再发一次 WebSocket
    /// 升级请求，Worker 回 101 才算这个 IP 能当入口。测速用的是
    /// speed.cloudflare.com，「下载快但当入口连不上」的 IP 测不出来，
    /// 必须用真实域名、真实路径多验这一遍。
    static func entryCheck(ip: String, port: UInt16, domain: String, path: String, timeout: Double = 6) async -> Bool {
        await entryCheck(ip: ip, port: port, sni: domain, host: domain, path: path, timeout: timeout)
    }

    static func entryCheck(ip: String, port: UInt16, sni: String, host: String, path: String, timeout: Double = 6) async -> Bool {
        // TLS SNI 与 HTTP Host 必须独立：节点模板允许二者不同。
        // 指纹库明确回了非 101 的 HTTP 状态才判死；传输层失败时回退原生栈。
        let code = await Task.detached(priority: .userInitiated) {
            FingerprintEntryCheckWithHost(ip, Int32(port), sni, host, path, Int32(timeout * 1000))
        }.value
        if code == 101 { return true }
        if code > 0 { return false }
        return await entryCheckNative(ip: ip, port: port, sni: sni, host: host, path: path, timeout: timeout)
    }

    static func entryCheckNative(ip: String, port: UInt16, domain: String, path: String, timeout: Double = 6) async -> Bool {
        await entryCheckNative(ip: ip, port: port, sni: domain, host: domain, path: path, timeout: timeout)
    }

    static func entryCheckNative(ip: String, port: UInt16, sni: String, host: String, path: String, timeout: Double = 6) async -> Bool {
        let holder = ConnectionHolder()
        return await withTaskCancellationHandler(operation: {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, sni)
            let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            let conn = NWConnection(host: NWEndpoint.Host(ip), port: nwPort(port), using: params)
            holder.set(conn)
            let q = DispatchQueue(label: "entry.\(ip)")
            let once = Once()
            var buffer = Data()

            func finish(_ ok: Bool) {
                once.run {
                    conn.cancel()
                    cont.resume(returning: ok)
                }
            }

            func receive() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) { data, _, isComplete, error in
                    if let data = data, !data.isEmpty { buffer.append(data) }
                    if let text = String(data: buffer, encoding: .utf8),
                       let firstLine = text.components(separatedBy: "\r\n").first {
                        if firstLine.contains(" 101") { finish(true); return }
                        if text.contains("\r\n\r\n") { finish(false); return }
                    }
                    if error != nil || isComplete { finish(false) } else { receive() }
                }
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
                    let p = path.isEmpty ? "/" : path
                    let req = "GET \(p) HTTP/1.1\r\nHost: \(host)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\nUser-Agent: Mozilla/5.0\r\n\r\n"
                    conn.send(content: req.data(using: .utf8), completion: .contentProcessed { _ in })
                    receive()
                case .failed, .cancelled:
                    finish(false)
                default: break
                }
            }
            conn.start(queue: q)
            q.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
        }, onCancel: {
            holder.cancel()
        })
    }

    /// 4) 下载测速（电脑版 CFST 同款口径）：
    /// - 默认地址 cf.xiu2.xyz/url，跟随跳转到真实大文件、响应头到齐后才开始计时；
    /// - 速度按 100 个时间片做指数加权平均（EWMA，衰减 2/31，与 CFST 用的
    ///   VividCortex/ewma 一致），再按 CFST 公式 ewma / (时长/120) 换算，
    ///   不再用总字节÷总时间的全程平均（慢启动会被全额摊进去，数字偏低且失真）；
    /// - 跳转地址不可用时，回退到 speed.cloudflare.com 官方接口测一次。
    static func downloadSpeed(ip: String, port: UInt16, seconds: Double = 10, urlString: String = "https://cf.xiu2.xyz/url") async -> Double? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !downloadHealth.useFallback,
           let url = URL(string: trimmed), let host = url.host, !host.isEmpty, host != sni {
            var path = url.path.isEmpty ? "/" : url.path
            if let q = url.query { path += "?" + q }
            let speed = await downloadViaCustomURL(ip: ip, port: port, seconds: seconds, host: host, path: path)
            if let speed, speed > 0 {
                downloadHealth.recordSuccess()
            } else if !Task.isCancelled, downloadHealth.recordFailure() {
                // 连续失败多次：先确认是测速地址本身挂了，还是只是这些 IP 不行。
                // 只有地址本身连不上才切到官方接口；地址正常就继续用它，不能把「很多 IP 本来就失败」当成地址故障。
                let alive = await hostAlive(url)
                if !alive { downloadHealth.activateFallback() }
            }
            return speed
        }
        // 官方测速接口（不跳转）。自定义地址为空、就是官方域名、或测速地址确认已失效时走这里。
        var fallbackSpeed: Double?
        if case .speed(let v) = await downloadAttempt(ip: ip, port: port, seconds: seconds, host: sni, path: "/__down?bytes=99999999") {
            fallbackSpeed = v
        }
        if !Task.isCancelled { downloadHealth.recordFallbackResult(success: (fallbackSpeed ?? 0) > 0) }
        return fallbackSpeed
    }

    /// 测速地址本身能不能访问（走系统网络，不指定 IP）。只发 HEAD，拿到任何 HTTP 响应（5xx 除外）就算活着。
    private static func hostAlive(_ url: URL) async -> Bool {
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.httpMethod = "HEAD"
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return false }
            return http.statusCode < 500
        } catch {
            return false
        }
    }

    private static func downloadViaCustomURL(ip: String, port: UInt16, seconds: Double, host: String, path: String) async -> Double? {
        var currentHost = host
        var currentPath = path
        for _ in 0...3 {
            switch await downloadAttempt(ip: ip, port: port, seconds: seconds, host: currentHost, path: currentPath) {
            case .speed(let v):
                return v
            case .redirect(let location):
                guard let next = URL(string: location, relativeTo: URL(string: "https://\(currentHost)\(currentPath)")),
                      let nh = next.host, !nh.isEmpty else { return nil }
                currentHost = nh
                var np = next.path.isEmpty ? "/" : next.path
                if let q = next.query { np += "?" + q }
                currentPath = np
            case .fail:
                return nil
            }
        }
        return nil
    }

    private enum AttemptOutcome {
        case speed(Double)
        case redirect(String)
        case fail
    }

    /// 单次下载尝试：连候选 IP、以 host 为 SNI/Host 发请求。
    /// 3xx 返回跳转目标；200 则进入下载计时并按时间片 EWMA 算速。
    private static func downloadAttempt(ip: String, port: UInt16, seconds: Double, host: String, path: String) async -> AttemptOutcome {
        let holder = ConnectionHolder()
        return await withTaskCancellationHandler(operation: {
        await withCheckedContinuation { (cont: CheckedContinuation<AttemptOutcome, Never>) in
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
            let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            let conn = NWConnection(host: NWEndpoint.Host(ip), port: nwPort(port), using: params)
            holder.set(conn)
            let q = DispatchQueue(label: "speed.\(ip)")
            let once = Once()
            var headerParsed = false
            var headerBuffer = Data()
            // EWMA 状态（与 CFST 一致：100 个时间片、衰减 2/31）
            let slice = seconds / 100
            let decay = 2.0 / 31.0
            var total = 0
            var bodyStart: UInt64 = 0
            var lastSliceTotal = 0
            var sliceIndex = 1
            var ewma = 0.0

            func ewmaAdd(_ v: Double) {
                ewma = ewma == 0 ? v : v * decay + ewma * (1 - decay)
            }
            func finalSpeed() -> AttemptOutcome {
                guard total > 0, ewma > 0 else { return .fail }
                return .speed(ewma / (seconds / 120) / 1_000_000)
            }
            func finish(_ outcome: AttemptOutcome) {
                once.run {
                    conn.cancel()
                    cont.resume(returning: outcome)
                }
            }

            func receive() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 2 * 1024 * 1024) { data, _, isComplete, error in
                    if let data = data, !data.isEmpty {
                        if !headerParsed {
                            headerBuffer.append(data)
                            if let marker = headerBuffer.range(of: Data("\r\n\r\n".utf8)) {
                                let headerData = headerBuffer[..<marker.lowerBound]
                                let header = String(data: headerData, encoding: .utf8) ?? ""
                                let lines = header.components(separatedBy: "\r\n")
                                let statusCode = Int(lines.first?.split(separator: " ").dropFirst().first ?? "") ?? 0
                                if (300..<400).contains(statusCode) {
                                    for line in lines.dropFirst() where line.lowercased().hasPrefix("location:") {
                                        let loc = line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces)
                                        finish(.redirect(loc))
                                        return
                                    }
                                    finish(.fail)
                                    return
                                }
                                guard statusCode == 200 else { finish(.fail); return }
                                let lowerHeader = header.lowercased()
                                guard lowerHeader.contains("cf-ray:") || lowerHeader.contains("server: cloudflare") else {
                                    finish(.fail)
                                    return
                                }
                                headerParsed = true
                                bodyStart = DispatchTime.now().uptimeNanoseconds
                                let bodyCount = headerBuffer.count - marker.upperBound
                                if bodyCount > 0 { total += bodyCount }
                                headerBuffer.removeAll(keepingCapacity: false)
                            } else if headerBuffer.count > 32 * 1024 {
                                finish(.fail)
                                return
                            }
                        } else {
                            total += data.count
                            let now = DispatchTime.now().uptimeNanoseconds
                            let elapsed = Double(now - bodyStart) / 1e9
                            if elapsed >= slice * Double(sliceIndex) {
                                ewmaAdd(Double(total - lastSliceTotal))
                                lastSliceTotal = total
                                // 直接跳到当前时间片，避免大块到达/停顿后 sliceIndex 滞后真实时间
                                sliceIndex = Int(elapsed / slice) + 1
                            }
                            if elapsed >= seconds {
                                finish(finalSpeed())
                                return
                            }
                        }
                    }
                    if error != nil {
                        // 出错时与 CFST 一样：已有数据就按当前 EWMA 出结果
                        finish(headerParsed ? finalSpeed() : .fail)
                    } else if isComplete {
                        if headerParsed, bodyStart > 0 {
                            // 文件提前下完：把最后一个不满的时间片按比例补进 EWMA（CFST 的 EOF 处理）
                            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - bodyStart) / 1e9
                            let sliceElapsed = elapsed - slice * Double(sliceIndex - 1)
                            if sliceElapsed > 0.001, total > lastSliceTotal {
                                ewmaAdd(Double(total - lastSliceTotal) / (sliceElapsed / slice))
                            }
                            finish(finalSpeed())
                        } else {
                            finish(.fail)
                        }
                    } else {
                        receive()
                    }
                }
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let req = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_12_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/98.0.4758.80 Safari/537.36\r\nAccept: */*\r\nConnection: close\r\n\r\n"
                    conn.send(content: req.data(using: .utf8), completion: .contentProcessed { _ in })
                    receive()
                case .failed, .cancelled:
                    finish(.fail)
                default: break
                }
            }
            conn.start(queue: q)
            q.asyncAfter(deadline: .now() + seconds + 6) {
                finish(headerParsed ? finalSpeed() : .fail)
            }
        }
        }, onCancel: {
            holder.cancel()
        })
    }

}

// MARK: - ViewModel

@MainActor
final class ViewModel: ObservableObject {
    // 设置
    // 所有测速设置在属性初始化时直接从 UserDefaults 读取，避免依赖 init 中
    // 对 @Published 属性赋值来恢复（初始化阶段的 didSet 不应承担持久化职责）。
    @Published var ranges = UserDefaults.standard.string(forKey: "cf.preferred.ip.ranges") ?? defaultRanges {
        didSet { UserDefaults.standard.set(ranges, forKey: "cf.preferred.ip.ranges") }
    }
    @Published var randomizedRanges: String? = UserDefaults.standard.string(forKey: "cf.preferred.ip.randomizedRanges") {
        didSet { UserDefaults.standard.set(randomizedRanges, forKey: "cf.preferred.ip.randomizedRanges") }
    }
    @Published var rangeFetchStatus = ""
    @Published var useV4 = (UserDefaults.standard.object(forKey: "cf.scan.useV4") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(useV4, forKey: "cf.scan.useV4") }
    }
    @Published var useV6 = (UserDefaults.standard.object(forKey: "cf.scan.useV6") as? Bool) ?? false {
        didSet { UserDefaults.standard.set(useV6, forKey: "cf.scan.useV6") }
    }
    @Published var port = UserDefaults.standard.object(forKey: "cf.scan.port") == nil ? 443 : UserDefaults.standard.integer(forKey: "cf.scan.port") {
        didSet { UserDefaults.standard.set(port, forKey: "cf.scan.port") }
    }
    @Published var samplePerRange = UserDefaults.standard.object(forKey: "cf.scan.samplePerRange") == nil ? 24 : UserDefaults.standard.integer(forKey: "cf.scan.samplePerRange") {
        didSet { UserDefaults.standard.set(samplePerRange, forKey: "cf.scan.samplePerRange") }
    }
    @Published var downloadURL = UserDefaults.standard.string(forKey: "cf.preferred.ip.downloadURL") ?? "https://cf.xiu2.xyz/url" {
        didSet { UserDefaults.standard.set(downloadURL, forKey: "cf.preferred.ip.downloadURL") }
    }
    @Published var useHTTPS = (UserDefaults.standard.object(forKey: "cf.scan.useHTTPS") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(useHTTPS, forKey: "cf.scan.useHTTPS") }
    }
    @Published var httpsTopN = UserDefaults.standard.object(forKey: "cf.scan.httpsTopN") == nil ? 300 : UserDefaults.standard.integer(forKey: "cf.scan.httpsTopN") {
        didSet { UserDefaults.standard.set(httpsTopN, forKey: "cf.scan.httpsTopN") }
    }
    @Published var speedTopN = UserDefaults.standard.object(forKey: "cf.scan.speedTopN") == nil ? 30 : UserDefaults.standard.integer(forKey: "cf.scan.speedTopN") {
        didSet { UserDefaults.standard.set(speedTopN, forKey: "cf.scan.speedTopN") }
    }
    @Published var speedSeconds = UserDefaults.standard.object(forKey: "cf.scan.speedSeconds") == nil ? 8.0 : UserDefaults.standard.double(forKey: "cf.scan.speedSeconds") {
        didSet { UserDefaults.standard.set(speedSeconds, forKey: "cf.scan.speedSeconds") }
    }

    // 状态
    @Published var results: [IPResult] = []
    @Published var status = "就绪"
    @Published var running = false
    @Published var exportURL: URL?
    @Published var networkStatus = "检查中…"
    @Published private(set) var leaderboard: [IPResult] = []      // 当前网络下可见的排行榜
    @Published private(set) var networkKey: String = NetworkKey.saved
    @Published var refineNeighbors = (UserDefaults.standard.object(forKey: "cf.scan.refineNeighbors.v2") as? Bool) ?? false {
        didSet { UserDefaults.standard.set(refineNeighbors, forKey: "cf.scan.refineNeighbors.v2") }
    }  // 邻近网段二次抽样
    private var allBoard: [HistoryIP] = []                           // 所有网络的记录

    @Published private(set) var paused: PausedScan?

    private var task: Task<Void, Never>?
    private var retesting = false
    private var speedPhaseStarted = false
    private var speedTarget = 30
    private var speedBackups: [IPResult] = []
    private var speedTestedIPs = Set<String>()
    private let pausedKey = "cf.scan.paused"
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "cf-preferred-ip.path")
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var activeObserver: NSObjectProtocol?

    init() {
        // The cumulative speed leaderboard replaces the old "recent scan" snapshot list.
        UserDefaults.standard.removeObject(forKey: "cf.preferred.ip.scan.history")
        allBoard = LeaderboardStore.normalized(LeaderboardStore.load())
        LeaderboardStore.save(allBoard)
        refreshLeaderboard()

        paused = loadPaused()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let text: String
            if path.status == .satisfied {
                let interface = path.usesInterfaceType(.wifi) ? "Wi-Fi" :
                    path.usesInterfaceType(.cellular) ? "蜂窝网络" : "网络"
                text = "已连接 · \(interface)"
            } else {
                text = "无网络连接"
            }
            let key = NetworkKey.from(path)
            Task { @MainActor [weak self] in
                self?.networkStatus = text
                if let key { self?.networkChanged(to: key) }
            }
        }
        pathMonitor.start(queue: pathQueue)

        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.appBecameActive() }
        }
    }

    deinit {
        pathMonitor.cancel()
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
    }

    func start() {
        guard !running, task == nil else { return }
        guard pathMonitor.currentPath.status == .satisfied else {
            status = "当前没有可用网络连接"
            return
        }
        guard (1...65535).contains(port) else {
            status = "端口必须在 1 到 65535 之间"
            return
        }
        running = true
        retesting = false
        speedPhaseStarted = false
        speedTestedIPs = []
        speedBackups = []
        results = []
        exportURL = nil
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Cloudflare IP 优选") { [weak self] in
            // 不取消扫描：测速进度会存档，后台任务或下次打开 App 时自动续测。
            self?.endBackgroundTask()
        }
        let bgRequest = BGProcessingTaskRequest(identifier: bgTaskIdentifier)
        bgRequest.requiresNetworkConnectivity = true
        bgRequest.requiresExternalPower = false
        bgRequest.earliestBeginDate = Date(timeIntervalSinceNow: 30)
        try? BGTaskScheduler.shared.submit(bgRequest)
        task = Task { [weak self] in
            guard let self else { return }
            await self.run()
            self.running = false
            self.task = nil
            self.endBackgroundTask()
        }
    }

    func stop() {
        guard running else { return }
        task?.cancel()
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: bgTaskIdentifier)
        if retesting {
            // 排行榜重测有自己的收尾逻辑
            status = "正在停止…"
            return
        }
        finalizeStoppedScan()
    }

    /// 停止测速：立刻把已测出速度的 IP 并入排行榜，没测的丢进「未完成的测试」，主页面清空。
    private func finalizeStoppedScan() {
        clearScanState()
        let measured = results.filter { ($0.speed ?? 0) > 0 }
        // 只有进了下载测速阶段（已通过验活）的剩余 IP 才值得保留续测
        let remaining = speedPhaseStarted ? results.filter { !speedTestedIPs.contains($0.ip) } : []
        if !measured.isEmpty { mergeLeaderboard(measured) }
        if !remaining.isEmpty {
            let items = remaining.map {
                HistoryIP(id: $0.id, ip: $0.ip, tcpLatency: $0.tcpLatency,
                          httpsLatency: $0.httpsLatency, colo: $0.colo, speed: nil, lossRate: $0.lossRate)
            }
            let backupItems = speedBackups.map {
                HistoryIP(id: $0.id, ip: $0.ip, tcpLatency: $0.tcpLatency,
                          httpsLatency: $0.httpsLatency, colo: $0.colo, speed: nil, lossRate: $0.lossRate)
            }
            savePaused(PausedScan(port: port, downloadURL: downloadURL, date: Date(), items: items,
                                  target: max(1, speedTarget - measured.count), backups: backupItems))
        }
        results = []
        exportURL = nil
        running = false
        endBackgroundTask()
        var parts = ["已停止"]
        if !measured.isEmpty { parts.append("\(measured.count) 个已测速 IP 已加入排行榜") }
        if !remaining.isEmpty { parts.append("剩余 \(remaining.count) 个可在 设置 → 未完成的测试 继续") }
        status = parts.joined(separator: " · ")
    }

    private func loadPaused() -> PausedScan? {
        guard let data = UserDefaults.standard.data(forKey: pausedKey) else { return nil }
        return try? JSONDecoder().decode(PausedScan.self, from: data)
    }

    private func savePaused(_ value: PausedScan) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: pausedKey)
        }
        paused = value
    }

    private func clearPaused() {
        UserDefaults.standard.removeObject(forKey: pausedKey)
        paused = nil
    }

    func discardPaused() { clearPaused() }

    func resumePaused() {
        guard !running, task == nil, let saved = paused else { return }
        guard pathMonitor.currentPath.status == .satisfied else {
            status = "当前没有可用网络连接"
            return
        }
        let rebuilt = saved.items.map {
            IPResult(id: $0.id, ip: $0.ip, tcpLatency: $0.tcpLatency,
                     httpsLatency: $0.httpsLatency, colo: $0.colo, speed: nil, lossRate: $0.lossRate ?? 0)
        }
        let savedBackups = (saved.backups ?? []).map {
            IPResult(id: $0.id, ip: $0.ip, tcpLatency: $0.tcpLatency,
                     httpsLatency: $0.httpsLatency, colo: $0.colo, speed: nil, lossRate: $0.lossRate ?? 0)
        }
        clearPaused()
        guard !rebuilt.isEmpty else { return }
        launchSpeedResume(rebuilt, port: saved.port, downloadURL: saved.downloadURL,
                          target: saved.target ?? rebuilt.count, backups: savedBackups,
                          message: "继续测试上次停止的 IP…")
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    /// 清空当前网络下看到的排行榜（其他网络的记录保留）。
    func clearLeaderboard() {
        allBoard.removeAll { $0.network == nil || $0.network == networkKey }
        persistBoard()
    }

    var networkLabel: String { NetworkKey.label(networkKey) }

    // MARK: 测速方案与重置

    var currentPreset: ScanPreset? {
        ScanPreset.matching(httpsTopN: httpsTopN, speedTopN: speedTopN, speedSeconds: speedSeconds,
                            samplePerRange: samplePerRange, refineNeighbors: refineNeighbors)
    }

    func applyPreset(_ preset: ScanPreset) {
        httpsTopN = preset.httpsTopN
        speedTopN = preset.speedTopN
        speedSeconds = preset.speedSeconds
        samplePerRange = preset.samplePerRange
        refineNeighbors = preset.refineNeighbors
    }

    /// 恢复 IP 版本、端口和测速相关设置（不动 IP 段和排行榜）。
    func resetScanSettings() {
        useV4 = true
        useV6 = false
        port = 443
        useHTTPS = true
        applyPreset(.standard)
        downloadURL = defaultDownloadURL
    }

    /// 留空表示使用官方测速接口；否则需要是 https:// 开头、带主机名的完整地址。
    var downloadURLIsValid: Bool {
        let t = downloadURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        guard let url = URL(string: t), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return false }
        return true
    }

    /// 超过 3 天没复测的条目数，排行榜里提示用户复测。
    var staleLeaderboardCount: Int {
        let limit = Date().addingTimeInterval(-LeaderboardScore.freshDays * 86400)
        return leaderboard.filter { ($0.testedAt ?? .distantPast) < limit }.count
    }

    private func networkChanged(to key: String) {
        guard key != networkKey else { return }
        networkKey = key
        UserDefaults.standard.set(key, forKey: NetworkKey.defaultsKey)
        refreshLeaderboard()
    }

    private func refreshLeaderboard() {
        leaderboard = LeaderboardStore.visible(allBoard, network: networkKey)
            .compactMap { $0.asResult }
            .sorted(by: IPResult.byScore)
    }

    private func persistBoard() {
        allBoard = LeaderboardStore.normalized(allBoard)
        LeaderboardStore.save(allBoard)
        refreshLeaderboard()
    }

    /// 用复测后的结果整体替换「当前网络可见」的那部分记录。
    private func replaceBoard(_ items: [IPResult], network net: String) {
        allBoard.removeAll { $0.network == nil || $0.network == net }
        allBoard += items.compactMap { r -> HistoryIP? in
            guard let speed = r.speed, speed > 0 else { return nil }
            return HistoryIP(id: r.id, ip: r.ip, tcpLatency: r.tcpLatency, httpsLatency: r.httpsLatency,
                             colo: r.colo, speed: speed, lossRate: r.lossRate,
                             testedAt: r.testedAt?.timeIntervalSince1970, network: r.network)
        }
        persistBoard()
    }

    func randomizeRangeSelection() {
        let all = ranges.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let invalid = all.filter { !CIDR.isValid($0) }
        guard invalid.isEmpty else {
            randomizedRanges = nil
            rangeFetchStatus = "发现无效 CIDR（\(invalid.prefix(3).joined(separator: "、"))），请先修正完整列表"
            return
        }
        let v4 = all.filter { !$0.contains(":") }
        let v6 = all.filter { $0.contains(":") }
        func half(_ values: [String]) -> [String] {
            guard !values.isEmpty else { return [] }
            return Array(values.shuffled().prefix(max(1, (values.count + 1) / 2)))
        }
        let chosen = half(v4) + half(v6)
        guard chosen.count < all.count else {
            randomizedRanges = nil
            rangeFetchStatus = "网段数量较少，继续使用全部列表"
            return
        }
        randomizedRanges = chosen.shuffled().joined(separator: "\n")
        rangeFetchStatus = "随机选择 \(chosen.count)/\(all.count) 个网段（IPv4 / IPv6 分别抽样，完整列表未修改）"
    }

    func useAllRanges() {
        randomizedRanges = nil
        rangeFetchStatus = "已恢复使用全部网段"
    }

    func fetchOfficialRanges() async {
        rangeFetchStatus = "正在获取 Cloudflare 官方网段…"
        do {
            async let v4Task = URLSession.shared.data(from: URL(string: "https://www.cloudflare.com/ips-v4")!)
            async let v6Task = URLSession.shared.data(from: URL(string: "https://www.cloudflare.com/ips-v6")!)
            let (v4Data, v4Response) = try await v4Task
            let (v6Data, v6Response) = try await v6Task
            guard let response4 = v4Response as? HTTPURLResponse, response4.statusCode == 200,
                  let response6 = v6Response as? HTTPURLResponse, response6.statusCode == 200 else { throw URLError(.badServerResponse) }
            let v4 = String(decoding: v4Data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
            let v6 = String(decoding: v6Data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
            let validV4 = v4.filter { CIDR.isValid($0) && !$0.contains(":") }
            let validV6 = v6.filter { CIDR.isValid($0) && $0.contains(":") }
            let valid = validV4 + validV6
            guard !valid.isEmpty, !validV4.isEmpty, !validV6.isEmpty else { throw URLError(.cannotParseResponse) }
            ranges = valid.joined(separator: "\n")
            randomizedRanges = nil
            rangeFetchStatus = "官方列表已更新：IPv4 \(validV4.count) 条，IPv6 \(validV6.count) 条"
        } catch {
            rangeFetchStatus = "获取失败：\(error.localizedDescription)"
        }
    }

    func retestLeaderboard(limit: Int? = nil) {
        guard !running, !leaderboard.isEmpty else { return }
        running = true
        retesting = true
        results = []
        status = "开始重新验证排行榜…"
        let testPort = UInt16(clamping: port)
        let net = networkKey
        let fullBoard = leaderboard
        let original = limit.map { Array(fullBoard.prefix(max(1, $0))) } ?? fullBoard
        let target = entryTarget()
        let dlURL = downloadURL
        Tester.resetDownloadHealth()
        task = Task { [weak self] in
            guard let self else { return }
            var checked: [IPResult] = []
            var completedIPs = Set<String>()
            var activeBatchIndex = -1
            let chunkSize = 8
            let chunks = stride(from: 0, to: original.count, by: chunkSize).map { Array(original[$0..<min($0 + chunkSize, original.count)]) }
            for (index, group) in chunks.enumerated() {
                if Task.isCancelled { break }
                activeBatchIndex = index
                // 第一步：TCP（含丢包率）、HTTPS、入口验活。占带宽很小，同组并发做；
                // 入口验活放在下载测速之前，通不过的 IP 不再浪费一次下载。
                let stage1 = await withTaskGroup(of: (String, IPResult?, Bool).self) { taskGroup in
                    for item in group {
                        taskGroup.addTask {
                            guard !Task.isCancelled else { return (item.ip, nil, false) }
                            guard let probe = await Tester.tcpProbe(ip: item.ip, port: testPort) else {
                                return (item.ip, nil, !Task.isCancelled)
                            }
                            guard !Task.isCancelled,
                                  let ping = await Tester.httpsPing(ip: item.ip, port: testPort) else {
                                return (item.ip, nil, !Task.isCancelled)
                            }
                            if let target {
                                guard !Task.isCancelled,
                                      await Tester.entryCheck(ip: item.ip, port: target.port, sni: target.sni, host: target.host, path: target.path) else {
                                    return (item.ip, nil, !Task.isCancelled)
                                }
                            }
                            guard !Task.isCancelled else { return (item.ip, nil, false) }
                            return (item.ip, IPResult(id: item.id, ip: item.ip, tcpLatency: probe.avg,
                                                      httpsLatency: ping.ms, colo: ping.colo, speed: nil,
                                                      lossRate: probe.loss), true)
                        }
                    }
                    var batchResults: [(String, IPResult?, Bool)] = []
                    for await result in taskGroup { batchResults.append(result) }
                    return batchResults
                }
                // 第二步：下载测速逐个进行。几个下载同时跑会抢同一条带宽，测出的速度偏低、互相影响，
                // 也和首次扫描（逐个测）口径不一致。
                var outcomes: [(String, IPResult?, Bool)] = []
                for (ip, partial, completed) in stage1 {
                    guard var r = partial else { outcomes.append((ip, nil, completed)); continue }
                    if Task.isCancelled { outcomes.append((ip, nil, false)); continue }
                    self.status = "排行榜重测 \(min(index * chunkSize + outcomes.count + 1, original.count))/\(original.count) · 下载测速 \(ip)"
                    let speed = await Tester.downloadSpeed(ip: ip, port: testPort, seconds: 5, urlString: dlURL)
                    if Task.isCancelled { outcomes.append((ip, nil, false)); continue }
                    if let speed, speed > 0 {
                        r.speed = speed
                        r.testedAt = Date()
                        r.network = net
                        outcomes.append((ip, r, true))
                    } else {
                        outcomes.append((ip, nil, true))
                    }
                }
                for (ip, result, completed) in outcomes {
                    if completed { completedIPs.insert(ip) }
                    if let result { checked.append(result) }
                }
                self.results = checked.sorted(by: IPResult.byScore)
                self.status = "排行榜重测 \(min((index + 1) * chunkSize, original.count))/\(original.count) · 有效 \(checked.count)"
            }
            if !Task.isCancelled {
                let untestedTail = Array(fullBoard.dropFirst(original.count))
                self.replaceBoard(checked + untestedTail, network: net)
                self.status = untestedTail.isEmpty
                    ? "重测完成：保留 \(checked.count)/\(original.count) 个有效 IP"
                    : "复测完成：前 \(original.count) 个里 \(checked.count) 个有效，其余 \(untestedTail.count) 个未测保留"
            } else {
                // 保留已确认成功的 IP、明确测试失败的 IP 从榜单移除；取消时尚未完成的 IP 不判为失败。
                let unfinishedCurrent = activeBatchIndex >= 0 ? chunks[activeBatchIndex].filter { !completedIPs.contains($0.ip) } : []
                let pendingLater = activeBatchIndex >= 0 ? chunks.dropFirst(activeBatchIndex + 1).flatMap { $0 } : original
                let safelyRetained = checked + unfinishedCurrent + pendingLater + Array(fullBoard.dropFirst(original.count))
                self.replaceBoard(safelyRetained, network: net)
                self.status = "重测已停止；已验证结果更新，未完成 IP 保留"
            }
            self.results = self.leaderboard
            self.running = false
            self.retesting = false
            self.task = nil
        }
    }

    /// 验活目标：从已保存的节点模板里取第一个带域名的 vless/trojan 模板。
    /// 模板域名是 workers.dev 且高级设置里填了自己的域名时，用后者验。
    /// 没有模板但填了域名时，用该域名根路径验。都没有则不验活。
    private func entryTarget() -> (sni: String, host: String, port: UInt16, path: String)? {
        let d = UserDefaults.standard
        let own = (d.string(forKey: "cf.nodes.domain") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = SecureLocalStore.read("cf.nodes.template") + "\n" + SecureLocalStore.read("cf.nodes.subText")
        let templates = NodeBuilder.parseTemplates(text)
        if let target = NodeBuilder.entryTarget(from: templates, ownDomain: own) {
            return (target.sni, target.host, target.port, target.path)
        }
        // 如果已有 VLESS / Trojan 模板但它不是 TLS+WS，不能退回用根路径
        // 假装它支持 WebSocket；只有完全没有可识别节点模板时才使用手填域名。
        if templates.contains(where: { $0.kind == .vless || $0.kind == .trojan }) { return nil }
        if !own.isEmpty { return (own, own, UInt16(clamping: port), "/") }
        return nil
    }

    private func mergeLeaderboard(_ scanned: [IPResult]) {
        allBoard = LeaderboardStore.merged(existing: allBoard, scanned: scanned.map { HistoryIP(result: $0) },
                                           network: networkKey, now: Date())
        persistBoard()
    }


    /// 按 IP 首段分组后轮询取候选，避免单个 Cloudflare 网段占满结果。
    /// 每组内部仍保持原来的延迟排序；如果其他网段确实不可达，则自动回填可用组。
    private func diverseCandidates(from items: [IPResult], limit: Int) -> [IPResult] {
        guard limit > 0, items.count > limit else { return items }
        let buckets = Dictionary(grouping: items) { item -> String in
            if item.ip.contains(":") {
                return item.ip.split(separator: ":").prefix(2).joined(separator: ":")
            }
            return item.ip.split(separator: ".").first.map(String.init) ?? item.ip
        }
        let keys = buckets.keys.sorted()
        var offsets = Dictionary(uniqueKeysWithValues: keys.map { ($0, 0) })
        var output: [IPResult] = []
        output.reserveCapacity(limit)

        while output.count < limit {
            var added = false
            for key in keys {
                guard let bucket = buckets[key], let offset = offsets[key], offset < bucket.count else { continue }
                output.append(bucket[offset])
                offsets[key] = offset + 1
                added = true
                if output.count == limit { break }
            }
            if !added { break }
        }
        return output
    }

    private func run() async {
        let p = UInt16(clamping: port)
        Tester.resetDownloadHealth()

        // 1. 生成 IP
        let activeLines = (randomizedRanges ?? ranges).split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let uniqueRanges = Array(NSOrderedSet(array: activeLines)) as? [String] ?? activeLines
        let invalidRanges = uniqueRanges.filter { !CIDR.isValid($0) }
        guard invalidRanges.isEmpty else {
            status = "发现 \(invalidRanges.count) 条无效 CIDR：\(invalidRanges.prefix(3).joined(separator: "、"))。请先到设置 → IP 段修正。"
            return
        }
        let selected = uniqueRanges.filter { $0.contains(":") ? useV6 : useV4 }
        // IPv4 按电脑版 CFST 抽样：每个 /24 子网随机抽一个；IPv6 仍按每段抽样数随机抽。
        let generatedIPs = selected.flatMap { range -> [String] in
            range.contains(":") ? CIDR.randomIPs(from: range, count: samplePerRange)
                                : CIDR.onePerSubnet(from: range, smallCount: samplePerRange)
        }
        let ips = Array(Set(generatedIPs)).shuffled()
        guard !ips.isEmpty else { status = "没有可测试的 IP（检查 IPv4/IPv6 开关及每段抽样数量）"; return }

        // 2. TCP 延迟（并发 200）
        status = "TCP 测试 0/\(ips.count)"
        var pool: [IPResult] = []
        var finished = 0

        await withTaskGroup(of: (String, TCPProbe?).self) { group in
            var it = ips.makeIterator()
            func addNext() {
                if let ip = it.next() {
                    group.addTask { (ip, await Tester.tcpProbe(ip: ip, port: p)) }
                }
            }
            for _ in 0..<200 { addNext() }
            for await (ip, probe) in group {
                finished += 1
                if let probe = probe {
                    var r = IPResult(ip: ip, tcpLatency: probe.avg)
                    r.lossRate = probe.loss
                    pool.append(r)
                }
                if finished % 10 == 0 { status = "TCP 测试 \(finished)/\(ips.count)" }
                if Task.isCancelled { group.cancelAll(); break }
                addNext()
            }
        }
        if Task.isCancelled { return }
        pool.sort(by: IPResult.byQuality)
        results = pool
        guard !pool.isEmpty else { status = "没有可连通的 IP（试试换端口或网络）"; return }

        // 3. 验活/验证：取延迟最低的前 httpsTopN 个并行验，不再按网段分组轮询砍名额。
        // 有节点模板时先做入口验活（真实域名 WS 握手），通过的再补一次 HTTPS 延迟拿 colo；
        // 没有模板时只做 HTTPS 验证。验活前置，避免测速名额浪费在当不了入口的 IP 上。
        let target = entryTarget()
        if useHTTPS || target != nil {
            let cand = Array(pool.prefix(min(httpsTopN, pool.count)))
            status = target != nil ? "入口验活 0/\(cand.count)…" : "HTTPS 验证中…"
            var verified: [IPResult] = []
            await withTaskGroup(of: (Int, PingResult?).self) { group in
                for (i, c) in cand.enumerated() {
                    group.addTask {
                        if let target {
                            let ok = await Tester.entryCheck(ip: c.ip, port: target.port, sni: target.sni, host: target.host, path: target.path)
                            guard ok else { return (i, nil) }
                            let ping = await Tester.httpsPing(ip: c.ip, port: p)
                            return (i, ping ?? PingResult(ms: c.tcpLatency, colo: nil))
                        }
                        return (i, await Tester.httpsPing(ip: c.ip, port: p))
                    }
                }
                var done = 0
                for await (i, ping) in group {
                    done += 1
                    if let ping = ping {
                        var r = cand[i]
                        r.httpsLatency = ping.ms
                        if let colo = ping.colo { r.colo = colo }
                        verified.append(r)
                    }
                    if target != nil { self.status = "入口验活 \(done)/\(cand.count) · 通过 \(verified.count)" }
                    if Task.isCancelled { group.cancelAll(); break }
                }
            }
            if Task.isCancelled { return }
            verified.sort(by: IPResult.byQuality)
            guard !verified.isEmpty else {
                results = []
                status = target != nil ? "入口验活全部失败：这些 IP 都当不了节点入口" : "HTTPS 验证全部失败：这些 IP 可能不是 Cloudflare 或被拦截"
                return
            }
            // 邻近网段二次抽样：只在「验证通过」的 IP 所在的 /24 里再补测，补测的 IP 同样要过验证，
            // 并且只是追加，不会挤掉原来的候选。
            if refineNeighbors, !Task.isCancelled {
                let extra = NeighborSampler.extraIPs(seeds: verified.map(\.ip), ranges: selected, known: Set(ips))
                if !extra.isEmpty {
                    self.status = "邻近网段补测 0/\(extra.count)…"
                    var found: [IPResult] = []
                    await withTaskGroup(of: IPResult?.self) { group in
                        for ip in extra {
                            group.addTask {
                                guard let probe = await Tester.tcpProbe(ip: ip, port: p) else { return nil }
                                var r = IPResult(ip: ip, tcpLatency: probe.avg)
                                r.lossRate = probe.loss
                                if let target {
                                    guard await Tester.entryCheck(ip: ip, port: target.port, sni: target.sni, host: target.host, path: target.path) else { return nil }
                                    let ping = await Tester.httpsPing(ip: ip, port: p)
                                    r.httpsLatency = ping?.ms ?? probe.avg
                                    if let colo = ping?.colo { r.colo = colo }
                                    return r
                                }
                                guard let ping = await Tester.httpsPing(ip: ip, port: p) else { return nil }
                                r.httpsLatency = ping.ms
                                if let colo = ping.colo { r.colo = colo }
                                return r
                            }
                        }
                        var done = 0
                        for await r in group {
                            done += 1
                            if let r { found.append(r) }
                            self.status = "邻近网段补测 \(done)/\(extra.count) · 新增可用 \(found.count)"
                            if Task.isCancelled { group.cancelAll(); break }
                        }
                    }
                    if Task.isCancelled { return }
                    verified.append(contentsOf: found)
                    verified.sort(by: IPResult.byQuality)
                }
            }
            pool = verified
            results = pool
        }

        // 4. 下载测速：一半取延迟最低的，另一半从其余验活通过的 IP 里随机抽，
        // 避免「延迟低但带宽小」的 IP 把名额占满、漏掉「延迟稍高但带宽大」的（断点续测）。
        // 其余的作为备用：前面的测速失败时，按延迟从低到高依次补上，直到凑够 n 个或用完。
        let n = max(1, speedTopN)
        let byLatency = Array(pool.prefix((n + 1) / 2))
        let rest = Array(pool.dropFirst(byLatency.count)).shuffled()
        let extra = Array(rest.prefix(n - byLatency.count))
        let backups = Array(rest.dropFirst(extra.count)).sorted(by: IPResult.byQuality)
        let primary = (byLatency + extra).sorted(by: IPResult.byQuality)
        await runSpeedPhase(pool: primary, p: p, target: n, backups: backups)
    }

    // MARK: 测速阶段（全部测完 + 断点续测）

    private func runSpeedPhase(pool: [IPResult], p: UInt16, target: Int, backups: [IPResult]) async {
        if Task.isCancelled { return }
        speedPhaseStarted = true
        speedTarget = target
        speedBackups = backups
        results = pool
        speedTestedIPs = Set(pool.filter { $0.speed != nil }.map { $0.ip })
        saveScanState()
        var gotSpeed = results.filter { ($0.speed ?? 0) > 0 }.count
        var queue = pool
        var idx = 0
        while idx < queue.count {
            let item = queue[idx]
            idx += 1
            if Task.isCancelled { return }
            if gotSpeed >= target { break }
            if speedTestedIPs.contains(item.ip) { continue }
            status = "下载测速 已测出 \(gotSpeed)/\(target) · 已试 \(speedTestedIPs.count + 1) 个"
                + (Tester.downloadFallbackActive ? " · 已切换官方测速接口" : "")
            var speed = await Tester.downloadSpeed(ip: item.ip, port: p, seconds: speedSeconds, urlString: downloadURL)
            // 一次失败可能只是网络抖动：重试一次再判定，避免误杀好 IP
            if (speed ?? 0) <= 0, !Task.isCancelled {
                speed = await Tester.downloadSpeed(ip: item.ip, port: p, seconds: speedSeconds, urlString: downloadURL)
            }
            // 被停止时这个 IP 还没测完，不算测过，留给「未完成的测试」
            if Task.isCancelled { return }
            speedTestedIPs.insert(item.ip)
            if let i = results.firstIndex(where: { $0.id == item.id }) {
                results[i].speed = speed
                results[i].testedAt = Date()
            }
            if let speed, speed > 0 {
                gotSpeed += 1
            } else if !speedBackups.isEmpty {
                // 这个失败了：补一个备用候选，名额不白占
                let next = speedBackups.removeFirst()
                queue.append(next)
                results.append(next)
            }
            saveScanState()
        }
        if Task.isCancelled { return }

        // 测速失败的、以及已凑够后没用上的候选，都移除。
        results.removeAll { !speedTestedIPs.contains($0.ip) || ($0.speed ?? 0) <= 0 }

        // 排序：综合分（速度为主，延迟、丢包扣分）
        results.sort(by: IPResult.byScore)

        status = "完成，共 \(results.count) 个可用 IP"
        mergeLeaderboard(results)
        writeCSV()
        clearScanState()
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: bgTaskIdentifier)
    }

    // MARK: 扫描断点存档

    private let scanStateKey = "cf.scan.state"

    private func saveScanState() {
        // 测过但失败的在存档里记 0，与「还没测」（nil）区分开，续测时不反复重测坏 IP。
        let items = results.map { r in
            HistoryIP(id: r.id, ip: r.ip, tcpLatency: r.tcpLatency,
                      httpsLatency: r.httpsLatency, colo: r.colo,
                      speed: speedTestedIPs.contains(r.ip) ? (r.speed ?? 0) : nil,
                      lossRate: r.lossRate)
        }
        let backupItems = speedBackups.map {
            HistoryIP(id: $0.id, ip: $0.ip, tcpLatency: $0.tcpLatency,
                      httpsLatency: $0.httpsLatency, colo: $0.colo, speed: nil, lossRate: $0.lossRate)
        }
        let state = ScanState(port: port, downloadURL: downloadURL, items: items,
                              target: speedTarget, backups: backupItems)
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: scanStateKey)
        }
    }

    private func loadScanState() -> ScanState? {
        guard let data = UserDefaults.standard.data(forKey: scanStateKey) else { return nil }
        return try? JSONDecoder().decode(ScanState.self, from: data)
    }

    private func clearScanState() {
        UserDefaults.standard.removeObject(forKey: scanStateKey)
    }

    private func loadLeaderboardFromStore() {
        allBoard = LeaderboardStore.normalized(LeaderboardStore.load())
        refreshLeaderboard()
    }

    func appBecameActive() {
        loadLeaderboardFromStore()
        resumePendingScan()
    }

    func resumePendingScan() {
        guard !running, task == nil, let state = loadScanState() else { return }
        let rebuilt = state.items.map {
            IPResult(id: $0.id, ip: $0.ip, tcpLatency: $0.tcpLatency,
                     httpsLatency: $0.httpsLatency, colo: $0.colo, speed: $0.speed, lossRate: $0.lossRate ?? 0)
        }
        guard !rebuilt.isEmpty else { clearScanState(); return }
        let stateBackups = (state.backups ?? []).map {
            IPResult(id: $0.id, ip: $0.ip, tcpLatency: $0.tcpLatency,
                     httpsLatency: $0.httpsLatency, colo: $0.colo, speed: nil, lossRate: $0.lossRate ?? 0)
        }
        launchSpeedResume(rebuilt, port: state.port, downloadURL: state.downloadURL,
                          target: state.target ?? rebuilt.count, backups: stateBackups,
                          message: "继续上次未完成的测速…")
    }

    private func launchSpeedResume(_ rebuilt: [IPResult], port savedPort: Int,
                                   downloadURL savedURL: String, target: Int,
                                   backups: [IPResult], message: String) {
        port = savedPort
        downloadURL = savedURL
        retesting = false
        speedPhaseStarted = false
        running = true
        results = rebuilt
        exportURL = nil
        status = message
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Cloudflare IP 优选") { [weak self] in
            self?.endBackgroundTask()
        }
        let p = UInt16(clamping: savedPort)
        task = Task { [weak self] in
            guard let self else { return }
            await self.runSpeedPhase(pool: rebuilt, p: p, target: target, backups: backups)
            self.running = false
            self.task = nil
            self.endBackgroundTask()
        }
    }

    // MARK: 导出

    private func csvEscape(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func writeCSV() {
        var s = "ip,port,tcp_ms,https_ms,colo,speed_MBps\n"
        for r in results {
            let https = r.httpsLatency.map { String(format: "%.0f", $0) } ?? ""
            let speed = r.speed.map { String(format: "%.2f", $0) } ?? ""
            s += "\(csvEscape(r.ip)),\(port),\(String(format: "%.0f", r.tcpLatency)),\(https),\(csvEscape(r.colo ?? "")),\(speed)\n"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cf_preferred_ips.csv")
        do {
            try s.write(to: url, atomically: true, encoding: .utf8)
            exportURL = url
        } catch {
            exportURL = nil
        }
    }

    func copyAll() {
        UIPasteboard.general.string = results.map(\.ip).joined(separator: "\n")
    }
}

// MARK: - UI

enum AppTab { case scan, nodes, settings }

/// 按压时产生轻微挤压与回弹，模拟液态玻璃的弹性反馈。
private struct LiquidTabButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(x: configuration.isPressed ? 1.045 : 1.0,
                         y: configuration.isPressed ? 0.84 : 1.0,
                         anchor: .center)
            .offset(y: configuration.isPressed ? 1.5 : 0)
            .animation(.spring(response: 0.32, dampingFraction: 0.48, blendDuration: 0.08),
                       value: configuration.isPressed)
    }
}

struct ContentView: View {
    @StateObject private var vm = ViewModel()
    @AppStorage("cf.appearance") private var appearanceMode = "system"
    @State private var tab: AppTab = .scan
    @State private var copied: String?
    @State private var keyboardVisible = false
    @State private var showCurrentResults = false
    @State private var resultsExpanded = true
    @State private var collapseTask: Task<Void, Never>?
    @Namespace private var tabSelectionNamespace
    @State private var glassShineRotation: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasNetwork: Bool { vm.networkStatus != "无网络连接" }

    private let tabs: [(tab: AppTab, title: String, icon: String)] = [
        (.scan, "优选", "bolt.fill"),
        (.nodes, "节点", "link"),
        (.settings, "设置", "slider.horizontal.3")
    ]

    var body: some View {
        Group {
            switch tab {
            case .scan:
                mainContent.toast($copied)
            case .nodes:
                NodesView(vm: vm)
            case .settings:
                SettingsView(vm: vm, onGoNodes: { tab = .nodes }, onGoScan: { tab = .scan })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .preferredColorScheme(appearanceMode == "light" ? .light : (appearanceMode == "dark" ? .dark : nil))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !keyboardVisible { bottomBar }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
    }

    private var mainContent: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                overviewCard
                if !vm.results.isEmpty { currentResultsSection }
                leaderboardSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 96) }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        // 顶部标题栏已移除，内容直接从安全区域下方开始。
        .sheet(isPresented: $showCurrentResults) { currentResultsSheet }
    }

    // MARK: 本次结果（按钮 + 弹页）

    /// 本次结果：测速中实时展开（横向滚动条，最新测出的速度立刻可见）；
    /// 测完保留展开 3 分钟，之后自动折叠成一行；完整列表在二级页（全部）里随时可看。
    private var currentResultsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if vm.running {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                }
                Text("本次结果").font(.headline)
                countPill("\(vm.results.count)")
                Spacer()
                Button { showCurrentResults = true } label: {
                    HStack(spacing: 2) {
                        Text("全部").font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                    }
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { resultsExpanded.toggle() }
                } label: {
                    Image(systemName: resultsExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)

            if resultsExpanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(chipItems, id: \.id) { item in resultChip(item) }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .onAppear { if vm.running { resultsExpanded = true } }
        .onChange(of: vm.running) { isRunning in
            if isRunning {
                collapseTask?.cancel()
                withAnimation { resultsExpanded = true }
            } else {
                collapseTask?.cancel()
                collapseTask = Task {
                    try? await Task.sleep(nanoseconds: 180 * 1_000_000_000)
                    if !Task.isCancelled {
                        await MainActor.run { withAnimation { resultsExpanded = false } }
                    }
                }
            }
        }
    }

    /// 本次结果弹页排序：已测出速度的按速度降序，其余按延迟升序（与测速收尾的排序一致，测速中也实时生效）。
    private var sortedCurrentResults: [IPResult] {
        vm.results.sorted {
            switch ($0.speed, $1.speed) {
            case let (a?, b?): return a != b ? a > b : $0.bestLatency < $1.bestLatency
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.bestLatency < $1.bestLatency
            }
        }
    }

    /// 滚动条内容：测速中按测出先后（最新在前），结束后按速度排序取前 30。
    private var chipItems: [IPResult] {
        vm.running ? Array(vm.results.suffix(30).reversed()) : Array(vm.results.prefix(30))
    }

    private func resultChip(_ item: IPResult) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.ip)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .lineLimit(1)
            if let s = item.speed, s > 0 {
                Text(String(format: "%.2f MB/s", s))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.green)
            } else {
                Text("\(Int(item.bestLatency.rounded())) ms")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassBackground(RoundedRectangle(cornerRadius: 12, style: .continuous),
                         fallback: Color(uiColor: .secondarySystemGroupedBackground))
    }

    private var currentResultsSheet: some View {
        NavigationStack {
            ScrollView {
                rowList(sortedCurrentResults)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("本次结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 16) {
                        Button { vm.copyAll(); copied = "已复制 \(vm.results.count) 个 IP" } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        if let url = vm.exportURL {
                            ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showCurrentResults = false }.fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: 底部导航（悬浮胶囊）

    private var bottomBar: some View {
        HStack(spacing: 4) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { _, item in
                let active = tab == item.tab
                Button {
                    // matchedGeometryEffect drives the selected glass capsule between tabs.
                    withAnimation(.spring(response: 0.46, dampingFraction: 0.58, blendDuration: 0.10)) {
                        tab = item.tab
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.icon)
                            .font(.system(size: 18, weight: .semibold))
                            .scaleEffect(active ? 1.08 : 1.0)
                        Text(item.title)
                            .font(.caption2.weight(active ? .bold : .semibold))
                    }
                    .foregroundStyle(active ? Color.blue : Color.primary.opacity(0.62))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background {
                        if active {
                            Capsule()
                                .fill(Color.blue.opacity(0.10))
                                .matchedGeometryEffect(id: "liquid-tab-selection", in: tabSelectionNamespace)
                                .modifier(GlassCapsule())
                                // A soft, moving specular highlight gives the glass a living surface.
                                .overlay {
                                    Capsule()
                                        .fill(
                                            AngularGradient(
                                                gradient: Gradient(colors: [
                                                    .white.opacity(0.02),
                                                    .white.opacity(0.30),
                                                    .blue.opacity(0.12),
                                                    .white.opacity(0.04),
                                                    .white.opacity(0.02)
                                                ]),
                                                center: .center
                                            )
                                        )
                                        .rotationEffect(.degrees(glassShineRotation))
                                        .blur(radius: 3)
                                        .clipShape(Capsule())
                                        .allowsHitTesting(false)
                                }
                                .overlay {
                                    Capsule().strokeBorder(
                                        LinearGradient(
                                            colors: [.white.opacity(0.62), .white.opacity(0.08), .blue.opacity(0.18)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 0.8
                                    )
                                    .allowsHitTesting(false)
                                }
                        }
                    }
                    .contentShape(Capsule())
                    .animation(.spring(response: 0.44, dampingFraction: 0.56, blendDuration: 0.08), value: active)
                }
                .buttonStyle(LiquidTabButtonStyle())
            }
        }
        .padding(6)
        .modifier(GlassCapsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.07)))
        .shadow(color: .black.opacity(0.12), radius: 15, y: 7)
        .padding(.horizontal, 24)
        .padding(.bottom, 6)
        .onAppear {
            guard !reduceMotion else { return }
            glassShineRotation = 0
            withAnimation(.linear(duration: 7).repeatForever(autoreverses: false)) {
                glassShineRotation = 360
            }
        }
    }

    // MARK: 顶部总览

    /// 头图主角：优先本轮最佳（每次扫描都会变），没有本轮结果时回退到排行榜历史最佳。
    private var heroBest: (ip: String, speed: Double, colo: String?, latency: Double, isCurrentRun: Bool)? {
        if let r = vm.results.filter({ ($0.speed ?? 0) > 0 })
            .max(by: { ($0.speed ?? 0) < ($1.speed ?? 0) }), let s = r.speed {
            return (r.ip, s, r.colo, r.bestLatency, true)
        }
        if let r = vm.leaderboard.first, let s = r.speed, s > 0 {
            return (r.ip, s, r.colo, r.bestLatency, false)
        }
        return nil
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(hasNetwork ? Color.green : Color.red).frame(width: 7, height: 7)
                    Text(vm.networkStatus)
                }
                Spacer()
                Text("端口 \(vm.port)")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.white.opacity(0.95))

            VStack(alignment: .leading, spacing: 4) {
                Text(heroBest?.isCurrentRun == false ? "历史最佳" : "本轮最佳")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.88))
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(heroBest.map { String(format: "%.2f", $0.speed) } ?? "--")
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("MB/s")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.88))
                }
                if let hero = heroBest {
                    Text("\(hero.ip) · \(hero.colo ?? "—") · \(Int(hero.latency.rounded())) ms")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.88))
                } else {
                    Text("完成一次优选后，这里会显示本轮最快的 IP")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.88))
                }
            }
            .foregroundStyle(.white)

            HStack(spacing: 0) {
                heroStat("排行榜最佳", vm.leaderboard.first?.speed.map { String(format: "%.2f MB/s", $0) } ?? "—")
                heroStat("排行榜", "\(vm.leaderboard.count) 条")
                heroStat("本轮已测", "\(vm.results.count) 个")
            }
            .padding(.top, 2)

            Button {
                vm.running ? vm.stop() : vm.start()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: vm.running ? "stop.fill" : "play.fill")
                    Text(vm.running ? "停止" : "开始优选")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(vm.running ? Color(red: 0.82, green: 0.10, blue: 0.12) : Color(red: 0.07, green: 0.33, blue: 0.93))
                .background(Color.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .opacity(hasNetwork || vm.running ? 1 : 0.55)

            if vm.running || vm.status != "就绪" {
                HStack(spacing: 8) {
                    if vm.running { ProgressView().tint(.white).controlSize(.small) }
                    Text(vm.status).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.95))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Color(red: 0.16, green: 0.46, blue: 1.0), Color(red: 0.36, green: 0.26, blue: 0.95)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .modifier(GlassBackground(
            shape: RoundedRectangle(cornerRadius: 24, style: .continuous),
            fallback: Color.blue.opacity(0.08)
        ))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.20), lineWidth: 1)
        )
        .shadow(color: Color.blue.opacity(0.16), radius: 16, y: 8)
    }

    // MARK: 排行榜

    private var leaderboardSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Text("排行榜").font(.headline).foregroundStyle(.primary)
                Spacer()
                if !vm.leaderboard.isEmpty {
                    if vm.running {
                        Button { vm.stop() } label: {
                            Image(systemName: "stop.circle.fill")
                        }
                    } else {
                        Menu {
                            Button("复测前 10 个") { vm.retestLeaderboard(limit: 10) }
                            Button("复测前 20 个") { vm.retestLeaderboard(limit: 20) }
                            Button("复测前 50 个") { vm.retestLeaderboard(limit: 50) }
                            Button("复测全部") { vm.retestLeaderboard() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    Button { vm.clearLeaderboard() } label: {
                        Image(systemName: "trash").foregroundStyle(vm.running ? Color.secondary : Color.red)
                    }
                    .disabled(vm.running)
                }
                countPill("\(vm.leaderboard.count)/100")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.blue)
            .padding(.horizontal, 4)

            if !vm.leaderboard.isEmpty {
                Text("当前网络：\(vm.networkLabel) · 按综合分排序（速度为主，延迟、丢包、测速时间扣分）"
                     + (vm.staleLeaderboardCount > 0 ? " · \(vm.staleLeaderboardCount) 条超过 3 天未复测，建议复测" : ""))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            if vm.leaderboard.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "bolt.horizontal")
                        .font(.system(size: 30, weight: .light))
                    Text("暂无记录").font(.subheadline)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
                .card(padding: 0)
            } else {
                rowList(vm.leaderboard)
            }
        }
    }

    private func heroStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func countPill(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .glassBackground(Capsule(), fallback: Color.secondary.opacity(0.12))
    }

    private func rowList(_ items: [IPResult]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                resultRow(rank: index + 1, result: item)
                if index < items.count - 1 { Divider().padding(.leading, 46) }
            }
        }
        .padding(.horizontal, 14)
        .glassBackground(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous),
                         fallback: Color(uiColor: .secondarySystemGroupedBackground))
    }

    private func resultRow(rank: Int, result: IPResult) -> some View {
        Button {
            UIPasteboard.general.string = result.ip
            copied = "已复制 \(result.ip)"
        } label: {
            HStack(spacing: 12) {
                Text("\(rank)")
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .foregroundStyle(rank <= 3 ? Color.white : Color.secondary)
                    .frame(width: 26, height: 26)
                    .background(rank <= 3 ? AnyShapeStyle(Color.blue.gradient) : AnyShapeStyle(Color.secondary.opacity(0.12)),
                                in: Circle())
                VStack(alignment: .leading, spacing: 6) {
                    Text(result.ip)
                        .font(.system(.subheadline, design: .monospaced).weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    HStack(spacing: 6) {
                        metricPill("\(Int(result.bestLatency.rounded())) ms", icon: "clock", color: .orange)
                        if result.lossRate > 0 {
                            metricPill("丢包 \(Int((result.lossRate * 100).rounded()))%", icon: "exclamationmark.triangle", color: .red)
                        }
                        if let colo = result.colo {
                            metricPill(colo, icon: "mappin", color: .blue)
                        }
                        if (result.speed ?? 0) > 0,
                           (result.testedAt ?? .distantPast) < Date().addingTimeInterval(-LeaderboardScore.freshDays * 86400) {
                            metricPill("久未复测", icon: "clock.arrow.circlepath", color: .gray)
                        }
                    }
                }
                Spacer(minLength: 4)
                if let speed = result.speed, speed > 0 {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.2f", speed))
                            .font(.system(.headline, design: .rounded).monospacedDigit())
                            .foregroundStyle(.green)
                        Text("MB/s").font(.caption2).foregroundStyle(.secondary)
                        Text("综合 \(String(format: "%.1f", result.score))")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.blue)
                    }
                } else {
                    Text("—")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func metricPill(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - 设置

struct SettingsView: View {
    @ObservedObject var vm: ViewModel
    let onGoNodes: () -> Void
    let onGoScan: () -> Void
    @AppStorage("cf.appearance") private var appearanceMode = "system"

    private var appearanceBinding: Binding<String> {
        Binding(get: { appearanceMode }, set: { appearanceMode = $0 })
    }

    var body: some View {
        NavigationStack {
            Form {
                if let p = vm.paused {
                    Section {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("剩余 \(p.items.count) 个 IP")
                                Text(p.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                vm.resumePaused()
                                onGoScan()
                            } label: {
                                Image(systemName: "play.circle.fill").font(.title2)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(vm.running ? Color.secondary : Color.blue)
                            .disabled(vm.running)
                            Button(role: .destructive) {
                                vm.discardPaused()
                            } label: {
                                Image(systemName: "trash.circle.fill").font(.title2)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                        }
                    } header: {
                        Label("未完成的测试", systemImage: "pause.circle")
                    }
                }

                Section {
                    Picker("外观模式", selection: appearanceBinding) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Label("外观", systemImage: "circle.lefthalf.filled")
                }

                Section {
                    NavigationLink {
                        DeployView(onGoNodes: onGoNodes)
                    } label: {
                        Label {
                            Text("Cloudflare 部署")
                        } icon: {
                            Image(systemName: "cloud.fill").foregroundStyle(.blue)
                        }
                    }
                }

                Section {
                    Toggle("IPv4", isOn: $vm.useV4)
                    Toggle("IPv6", isOn: $vm.useV6)
                } header: {
                    Label("IP 版本", systemImage: "network")
                }

                Section {
                    HStack(spacing: 12) {
                        Text("端口")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        TextField("443", value: $vm.port, format: .number.grouping(.never))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 96)
                    }
                    .padding(.vertical, 3)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach([443, 2053, 2083, 2087, 2096, 8443], id: \.self) { p in
                                Button(String(p)) { vm.port = p }
                                    .buttonStyle(PillButtonStyle(tint: .blue, filled: vm.port == p, compact: true))
                                    .font(.caption.weight(.medium))
                                    .frame(minWidth: 54)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                } header: {
                    Text("连接端口")
                }

                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Text("方案").foregroundStyle(.secondary)
                            ForEach(ScanPreset.allCases) { preset in
                                Button(preset.title) { vm.applyPreset(preset) }
                                    .buttonStyle(PillButtonStyle(tint: .blue, filled: vm.currentPreset == preset, compact: true))
                                    .font(.caption.weight(.medium))
                                    .frame(minWidth: 64)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    Stepper("IPv6 每段抽样：\(vm.samplePerRange)", value: $vm.samplePerRange, in: 1...200, step: 5)
                    Toggle("邻近网段补测", isOn: $vm.refineNeighbors)
                    Toggle("HTTPS 验证", isOn: $vm.useHTTPS)
                    if vm.useHTTPS {
                        Stepper("验证前 \(vm.httpsTopN) 个", value: $vm.httpsTopN, in: 50...500, step: 50)
                    }
                    Stepper("目标 \(vm.speedTopN) 个可用 IP", value: $vm.speedTopN, in: 10...300, step: 10)
                    Stepper("每个测 \(Int(vm.speedSeconds)) 秒", value: $vm.speedSeconds, in: 4...15, step: 1)
                    TextField("测速地址（留空用官方）", text: $vm.downloadURL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Button("默认地址") { vm.downloadURL = defaultDownloadURL }
                                .buttonStyle(PillButtonStyle(tint: .blue, filled: vm.downloadURL == defaultDownloadURL, compact: true))
                                .font(.caption.weight(.medium))
                            Button("Cloudflare 官方") { vm.downloadURL = officialDownloadURL }
                                .buttonStyle(PillButtonStyle(tint: .blue, filled: vm.downloadURL == officialDownloadURL, compact: true))
                                .font(.caption.weight(.medium))
                        }
                        .padding(.vertical, 3)
                    }
                    if !vm.downloadURLIsValid {
                        Text("测速地址需要是 https:// 开头的完整地址")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Label("测速", systemImage: "gauge.with.dots.needle.67percent")
                } footer: {
                    Text("""
                    方案：快速、标准、精确是一组预设，改任何一项后会取消高亮。
                    IPv6 每段抽样：每个 IPv6 网段随机测几个 IP。
                    邻近网段补测：验证通过的 IP 所在的网段里再多测几个，追加到候选里，不会挤掉原来的；需要开启 HTTPS 验证或已有节点模板。默认关闭。
                    HTTPS 验证：确认 IP 真是 Cloudflare 并取到数据中心；验证前 N 个指只验延迟最低的 N 个。
                    目标可用 IP：下载测速测出这么多个可用 IP 就停止。
                    每个测 N 秒：越长越准，也越慢。
                    测速地址连续失败时，会自动切换到官方测速接口。
                    """)
                }

                Section {
                    Button("恢复默认测速设置", role: .destructive) { vm.resetScanSettings() }
                } footer: {
                    Text("只恢复 IP 版本、端口和测速相关设置，不影响 IP 段和排行榜。")
                }

                Section {
                    NavigationLink {
                        IPRangesSettingsView(vm: vm)
                    } label: {
                        HStack {
                            Label("IP 段", systemImage: "list.bullet.rectangle")
                            Spacer()
                            Text("\(vm.ranges.split(whereSeparator: \.isNewline).count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 96) }
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .tint(.blue)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
        }
    }
}

struct IPRangesSettingsView: View {
    @ObservedObject var vm: ViewModel
    @State private var isFetching = false
    var body: some View {
        Form {
            Section("网段列表") {
                TextEditor(text: $vm.ranges)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 260)
                    .onChange(of: vm.ranges) { _ in vm.useAllRanges() }
                Button("恢复默认") { vm.ranges = defaultRanges; vm.useAllRanges() }
                Button {
                    Task { isFetching = true; await vm.fetchOfficialRanges(); isFetching = false }
                } label: {
                    Label(isFetching ? "更新中…" : "更新为官方列表", systemImage: "arrow.down.circle")
                }.disabled(isFetching)
            }
            Section {
                Button { vm.randomizeRangeSelection() } label: { Label("随机换一批网段", systemImage: "shuffle") }
                Button("使用全部网段") { vm.useAllRanges() }
                if let selected = vm.randomizedRanges {
                    Text("随机选择：\(selected.split(whereSeparator: \.isNewline).count) / \(vm.ranges.split(whereSeparator: \.isNewline).count)")
                        .font(.subheadline).foregroundStyle(.blue)
                    Text(selected).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                if !vm.rangeFetchStatus.isEmpty { Text(vm.rangeFetchStatus).font(.footnote).foregroundStyle(.secondary) }
            } header: {
                Text("测试范围")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 96) }
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .tint(.blue)
        .navigationTitle("IP 段")
        .navigationBarTitleDisplayMode(.inline)
    }
}
