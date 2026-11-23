import SwiftUI
import UIKit
import Foundation
import Network
import Darwin

// MARK: - App

@main
struct CFPreferredIPApp: App {
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
         httpsLatency: Double? = nil, colo: String? = nil, speed: Double? = nil) {
        self.id = id
        self.ip = ip
        self.tcpLatency = tcpLatency
        self.httpsLatency = httpsLatency
        self.colo = colo
        self.speed = speed
    }

    var bestLatency: Double { httpsLatency ?? tcpLatency }
}

struct PingResult {
    let ms: Double
    let colo: String?
}

struct HistoryIP: Codable, Identifiable {
    let id: UUID
    let ip: String
    let tcpLatency: Double
    let httpsLatency: Double?
    let colo: String?
    let speed: Double?
}

struct ScanHistory: Codable, Identifiable {
    let id: UUID
    let date: Date
    let port: Int
    let results: [HistoryIP]
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

enum CIDR {
    static func randomIPs(from cidr: String, count: Int) -> [String] {
        let parts = cidr.trimmingCharacters(in: .whitespaces).split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]) else { return [] }

        let addr = String(parts[0])
        let isV6 = addr.contains(":")
        let family = isV6 ? AF_INET6 : AF_INET
        let total = isV6 ? 128 : 32
        guard prefix >= 0, prefix <= total else { return [] }

        var bytes = [UInt8](repeating: 0, count: 16)
        guard inet_pton(family, addr, &bytes) == 1 else { return [] }

        let hostBits = total - prefix
        let capacity = hostBits < 63 ? (UInt64(1) << UInt64(hostBits)) : UInt64.max
        let want = Int(min(UInt64(max(0, count)), capacity))
        guard want > 0 else { return [] }

        // 小网段直接枚举，避免随机碰撞导致抽样数量不足。
        if hostBits <= 16 && want == Int(capacity) {
            var all: [String] = []
            all.reserveCapacity(want)
            for value in UInt64(0)..<capacity {
                var b = bytes
                for bit in 0..<hostBits {
                    let mask = UInt8(0x80 >> (bit % 8))
                    let sourceBit = (value >> UInt64(hostBits - bit - 1)) & 1
                    if sourceBit == 1 { b[(prefix + bit) / 8] |= mask }
                    else { b[(prefix + bit) / 8] &= ~mask }
                }
                if let s = string(from: b, family: family) { all.append(s) }
            }
            return all.shuffled()
        }

        var set = Set<String>()
        var tries = 0
        while set.count < want && tries < want * 20 + 20 {
            tries += 1
            var b = bytes
            if prefix < total {
                for bit in prefix..<total {
                    let mask = UInt8(0x80 >> (bit % 8))
                    if Bool.random() { b[bit / 8] |= mask } else { b[bit / 8] &= ~mask }
                }
            }
            if let s = string(from: b, family: family) { set.insert(s) }
        }
        return Array(set)
    }

    private static func string(from bytes: [UInt8], family: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 64)
        let ok = bytes.withUnsafeBytes { raw in
            inet_ntop(family, raw.baseAddress, &buf, socklen_t(64)) != nil
        }
        return ok ? String(cString: buf) : nil
    }
}

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

    /// 3) 下载测速（MB/s）
    static func downloadSpeed(ip: String, port: UInt16, seconds: Double = 5) async -> Double? {
        let holder = ConnectionHolder()
        return await withTaskCancellationHandler(operation: {
        await withCheckedContinuation { (cont: CheckedContinuation<Double?, Never>) in
            let conn = makeTLS(ip: ip, port: port)
            holder.set(conn)
            let q = DispatchQueue(label: "speed.\(ip)")
            let once = Once()
            var total = 0
            var firstByte: UInt64 = 0
            var headerParsed = false
            var invalidResponse = false
            var responseBuffer = Data()

            func finish() {
                once.run {
                    conn.cancel()
                    if invalidResponse || !headerParsed || firstByte == 0 || total == 0 {
                        cont.resume(returning: nil)
                    } else {
                        let sec = Double(DispatchTime.now().uptimeNanoseconds - firstByte) / 1e9
                        cont.resume(returning: sec > 0 ? Double(total) / sec / 1_000_000 : nil)
                    }
                }
            }

            func receive() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let data = data, !data.isEmpty {
                        if !headerParsed {
                            responseBuffer.append(data)
                            if let marker = responseBuffer.range(of: Data("\r\n\r\n".utf8)) {
                                let headerData = responseBuffer[..<marker.lowerBound]
                                let header = String(data: headerData, encoding: .utf8) ?? ""
                                let firstLine = header.components(separatedBy: "\r\n").first ?? ""
                                let statusCode = Int(firstLine.split(separator: " ").dropFirst().first ?? "") ?? 0
                                invalidResponse = !(200..<300).contains(statusCode)
                                headerParsed = true
                                let bodyStart = marker.upperBound
                                let bodyCount = responseBuffer.count - bodyStart
                                if bodyCount > 0 {
                                    if firstByte == 0 { firstByte = DispatchTime.now().uptimeNanoseconds }
                                    total += bodyCount
                                }
                                responseBuffer.removeAll(keepingCapacity: false)
                            } else if responseBuffer.count > 16 * 1024 {
                                invalidResponse = true
                            }
                        } else if !invalidResponse {
                            if firstByte == 0 { firstByte = DispatchTime.now().uptimeNanoseconds }
                            total += data.count
                        }
                    }
                    let elapsed = firstByte == 0 ? 0 :
                        Double(DispatchTime.now().uptimeNanoseconds - firstByte) / 1e9
                    if error != nil || isComplete || elapsed >= seconds {
                        finish()
                    } else {
                        receive()
                    }
                }
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let req = "GET /__down?bytes=100000000 HTTP/1.1\r\nHost: \(sni)\r\nUser-Agent: Mozilla/5.0\r\nConnection: close\r\n\r\n"
                    conn.send(content: req.data(using: .utf8), completion: .contentProcessed { _ in })
                    receive()
                case .failed, .cancelled:
                    finish()
                default: break
                }
            }
            conn.start(queue: q)
            q.asyncAfter(deadline: .now() + seconds + 4) { finish() }
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
    @Published var ranges = defaultRanges
    @Published var useV4 = true
    @Published var useV6 = false
    @Published var port = 443
    @Published var samplePerRange = 20
    @Published var useHTTPS = true
    @Published var httpsTopN = 30
    @Published var speedTopN = 10

    // 状态
    @Published var results: [IPResult] = []
    @Published var status = "就绪"
    @Published var running = false
    @Published var exportURL: URL?
    @Published var networkStatus = "检查中…"
    @Published private(set) var history: [ScanHistory] = []

    private var task: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "cf-preferred-ip.path")
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private let historyKey = "cf.preferred.ip.scan.history"

    init() {
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let saved = try? JSONDecoder().decode([ScanHistory].self, from: data) {
            history = saved
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let text: String
            if path.status == .satisfied {
                let interface = path.usesInterfaceType(.wifi) ? "Wi-Fi" :
                    path.usesInterfaceType(.cellular) ? "蜂窝网络" : "网络"
                text = "已连接 · \(interface)"
            } else {
                text = "无网络连接"
            }
            Task { @MainActor [weak self] in
                self?.networkStatus = text
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    deinit {
        pathMonitor.cancel()
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
        results = []
        exportURL = nil
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Cloudflare IP 优选") { [weak self] in
            self?.task?.cancel()
            self?.endBackgroundTask()
        }
        task = Task { [weak self] in
            guard let self else { return }
            await self.run()
            self.running = false
            self.task = nil
            self.endBackgroundTask()
        }
    }

    func stop() {
        task?.cancel()
        status = "正在停止…"
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    func restore(_ item: ScanHistory) {
        results = item.results.map {
            IPResult(id: $0.id, ip: $0.ip, tcpLatency: $0.tcpLatency,
                     httpsLatency: $0.httpsLatency, colo: $0.colo, speed: $0.speed)
        }
        port = item.port
        exportURL = nil
        status = "已恢复 \(item.results.count) 个结果"
    }

    func clearHistory() {
        history.removeAll()
        UserDefaults.standard.removeObject(forKey: historyKey)
    }

    private func saveHistory() {
        let savedResults = results.map {
            HistoryIP(id: $0.id, ip: $0.ip, tcpLatency: $0.tcpLatency,
                      httpsLatency: $0.httpsLatency, colo: $0.colo, speed: $0.speed)
        }
        guard !savedResults.isEmpty else { return }
        let item = ScanHistory(id: UUID(), date: Date(), port: port, results: savedResults)
        history.insert(item, at: 0)
        history = Array(history.prefix(10))
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    private func run() async {
        let p = UInt16(port)

        // 1. 生成 IP
        let lines = ranges.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let selected = lines.filter { $0.contains(":") ? useV6 : useV4 }
        let ips = selected.flatMap { CIDR.randomIPs(from: $0, count: samplePerRange) }
        guard !ips.isEmpty else { status = "没有有效的 IP 段（检查 IPv4/IPv6 开关）"; return }

        // 2. TCP 延迟（并发 100）
        status = "TCP 测试 0/\(ips.count)"
        var pool: [IPResult] = []
        var finished = 0

        await withTaskGroup(of: (String, Double?).self) { group in
            var it = ips.makeIterator()
            func addNext() {
                if let ip = it.next() {
                    group.addTask { (ip, await Tester.tcpLatency(ip: ip, port: p)) }
                }
            }
            for _ in 0..<100 { addNext() }
            for await (ip, ms) in group {
                finished += 1
                if let ms = ms { pool.append(IPResult(ip: ip, tcpLatency: ms)) }
                if finished % 10 == 0 { status = "TCP 测试 \(finished)/\(ips.count)" }
                if Task.isCancelled { group.cancelAll(); break }
                addNext()
            }
        }
        if Task.isCancelled { return }
        pool.sort { $0.tcpLatency < $1.tcpLatency }
        results = pool
        guard !pool.isEmpty else { status = "没有可连通的 IP（试试换端口或网络）"; return }

        // 3. HTTPS 延迟验证（可选）
        if useHTTPS {
            status = "HTTPS 验证中…"
            let cand = Array(pool.prefix(httpsTopN))
            var verified: [IPResult] = []
            await withTaskGroup(of: (Int, PingResult?).self) { group in
                for (i, c) in cand.enumerated() {
                    group.addTask { (i, await Tester.httpsPing(ip: c.ip, port: p)) }
                }
                for await (i, ping) in group {
                    if let ping = ping {
                        var r = cand[i]
                        r.httpsLatency = ping.ms
                        r.colo = ping.colo
                        verified.append(r)
                    }
                    if Task.isCancelled { group.cancelAll(); break }
                }
            }
            if Task.isCancelled { return }
            verified.sort { $0.bestLatency < $1.bestLatency }
            guard !verified.isEmpty else {
                results = []
                status = "HTTPS 验证全部失败：这些 IP 可能不是 Cloudflare 或被拦截"
                return
            }
            pool = verified
            results = pool
        }

        // 4. 下载测速（串行）
        let top = Array(pool.prefix(speedTopN))
        for (i, item) in top.enumerated() {
            if Task.isCancelled { return }
            status = "下载测速 \(i + 1)/\(top.count)  \(item.ip)"
            let speed = await Tester.downloadSpeed(ip: item.ip, port: p)
            if let idx = results.firstIndex(where: { $0.id == item.id }) {
                results[idx].speed = speed ?? 0
            }
        }

        // 5. 排序：有测速的按速度，其余按延迟
        results.sort {
            switch ($0.speed, $1.speed) {
            case let (a?, b?): return a != b ? a > b : $0.bestLatency < $1.bestLatency
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.bestLatency < $1.bestLatency
            }
        }
        status = "完成，共 \(results.count) 个可用 IP"
        writeCSV()
        saveHistory()
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

struct ContentView: View {
    @StateObject private var vm = ViewModel()
    @State private var showSettings = false
    @State private var copied: String?

    private var hasNetwork: Bool { vm.networkStatus != "无网络连接" }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    overviewCard
                    resultSection
                    historySection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("IP 优选")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button { vm.copyAll() } label: {
                            Label("复制全部 IP", systemImage: "doc.on.doc")
                        }
                        .disabled(vm.results.isEmpty)
                        if let url = vm.exportURL {
                            ShareLink(item: url) {
                                Label("导出 CSV", systemImage: "arrow.down.doc")
                            }
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(vm.results.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView(vm: vm) }
            .alert("已复制", isPresented: Binding(get: { copied != nil }, set: { if !$0 { copied = nil } })) {
                Button("好") {}
            } message: { Text(copied ?? "") }
        }
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Cloudflare 优选")
                        .font(.title2.bold())
                    Text("寻找低延迟、高速度的可用 IP")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.72))
                }
                Spacer()
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 34))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.9))
            }

            HStack(spacing: 8) {
                Circle().fill(hasNetwork ? Color.green : Color.red).frame(width: 8, height: 8)
                Text(vm.networkStatus)
                Spacer()
                Text("端口 \(vm.port)")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.white.opacity(0.86))

            HStack(spacing: 10) {
                Image(systemName: vm.running ? "stop.fill" : "play.fill")
                Text(vm.running ? "停止测速" : "开始优选")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .foregroundStyle(vm.running ? .red : .blue)
            .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { vm.running ? vm.stop() : vm.start() }
            .opacity(hasNetwork || vm.running ? 1 : 0.55)

            if vm.running {
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text(vm.status).lineLimit(1)
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.82))
            }
        }
        .padding(20)
        .background(
            LinearGradient(colors: [Color.blue, Color.indigo], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .shadow(color: .blue.opacity(0.22), radius: 16, y: 8)
    }

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("优选结果").font(.title3.bold())
                Spacer()
                Text("\(vm.results.count) 个")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }

            if vm.results.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("还没有测速结果").font(.headline)
                    Text("点击上方按钮开始寻找更快的 IP")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
                .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(vm.results.enumerated()), id: \.element.id) { index, r in
                        resultRow(rank: index + 1, result: r)
                        if r.id != vm.results.last?.id { Divider().padding(.leading, 58) }
                    }
                }
                .padding(.horizontal, 14)
                .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    private func resultRow(rank: Int, result: IPResult) -> some View {
        Button {
            UIPasteboard.general.string = result.ip
            copied = result.ip
        } label: {
            HStack(spacing: 12) {
                Text("\(rank)")
                    .font(.caption.bold())
                    .foregroundStyle(rank <= 3 ? .white : .secondary)
                    .frame(width: 28, height: 28)
                    .background(rank <= 3 ? Color.blue : Color.secondary.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 6) {
                    Text(result.ip)
                        .font(.system(.subheadline, design: .monospaced).weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    HStack(spacing: 6) {
                        metricPill("\(Int(result.bestLatency.rounded())) ms", icon: "clock", color: .orange)
                        if let colo = result.colo {
                            metricPill(colo, icon: "mappin", color: .blue)
                        }
                    }
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 5) {
                    if let speed = result.speed {
                        Text(String(format: "%.2f", speed))
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.green)
                        Text("MB/s").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 13)
        }
        .buttonStyle(.plain)
    }

    private func metricPill(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
    }

    @ViewBuilder private var historySection: some View {
        if !vm.history.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("最近测试").font(.title3.bold())
                    Spacer()
                    Button("清空") { vm.clearHistory() }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.red)
                }
                VStack(spacing: 0) {
                    ForEach(vm.history) { item in
                        Button { vm.restore(item) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(.blue)
                                    .frame(width: 30, height: 30)
                                    .background(Color.blue.opacity(0.12), in: Circle())
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.subheadline.weight(.medium))
                                    Text("端口 \(item.port) · \(item.results.count) 个 IP")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.bold()).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        if item.id != vm.history.last?.id { Divider().padding(.leading, 42) }
                    }
                }
                .padding(.horizontal, 14)
                .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var vm: ViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("IPv4", isOn: $vm.useV4)
                    Toggle("IPv6（需网络支持）", isOn: $vm.useV6)
                } header: {
                    Label("IP 版本", systemImage: "network")
                }

                Section {
                    TextField("端口", value: $vm.port, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                    HStack {
                        ForEach([443, 2053, 2083, 2087, 2096, 8443], id: \.self) { p in
                            Button(String(p)) { vm.port = p }
                                .buttonStyle(.bordered)
                                .font(.caption2)
                        }
                    }
                } header: {
                    Text("测试端口")
                } footer: {
                    Text("Cloudflare 支持的 HTTPS 端口：443 / 2053 / 2083 / 2087 / 2096 / 8443")
                }

                Section {
                    Stepper("每段抽样：\(vm.samplePerRange)", value: $vm.samplePerRange, in: 1...200, step: 5)
                    Toggle("HTTPS 延迟验证（显示数据中心）", isOn: $vm.useHTTPS)
                    if vm.useHTTPS {
                        Stepper("验证前 \(vm.httpsTopN) 个", value: $vm.httpsTopN, in: 5...100, step: 5)
                    }
                    Stepper("下载测速前 \(vm.speedTopN) 个", value: $vm.speedTopN, in: 1...50)
                } header: {
                    Label("测试参数", systemImage: "gauge.with.dots.needle.67percent")
                }

                Section {
                    TextEditor(text: $vm.ranges)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 260)
                    Button("恢复默认") { vm.ranges = defaultRanges }
                } header: {
                    Label("IP 段", systemImage: "list.bullet.rectangle")
                } footer: {
                    Text("每行一个 CIDR，支持 IPv4 和 IPv6。仅建议填写 Cloudflare 官方地址段。")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .tint(.blue)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }
}
