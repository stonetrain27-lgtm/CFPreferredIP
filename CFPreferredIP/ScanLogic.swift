import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// 与界面、网络请求无关的纯逻辑：综合分、排行榜整理、网段判断、邻近抽样、测速方案、测速地址健康度。
// 单独成文件，方便在 tests/NodeBuilderSmokeTests.swift 里直接编译测试（scripts/run-tests.sh）。

struct HistoryIP: Codable, Identifiable {
    let id: UUID
    let ip: String
    let tcpLatency: Double
    let httpsLatency: Double?
    let colo: String?
    var speed: Double?
    var lossRate: Double? = nil      // 旧版本存档没有这些字段，解码为 nil
    var testedAt: Double? = nil      // timeIntervalSince1970
    var network: String? = nil

    var score: Double {
        LeaderboardScore.value(speed: speed, latency: httpsLatency ?? tcpLatency, loss: lossRate ?? 0,
                               testedAt: testedAt.map { Date(timeIntervalSince1970: $0) })
    }
}

/// 排行榜综合分：速度 × 延迟系数 × 丢包系数 × 新鲜度系数。
enum LeaderboardScore {
    static let freshDays = 3.0

    static func value(speed: Double?, latency: Double, loss: Double, testedAt: Date?) -> Double {
        guard let s = speed, s > 0 else { return 0 }
        let latencyFactor = 1.0 / (1.0 + max(0, latency - 50) / 150)   // 50ms 内不扣分，200ms 打 5 折
        let lossFactor = max(0.1, 1.0 - loss * 2)                      // 25% 丢包打 5 折
        var ageFactor = 0.8                                            // 旧数据没有测速时间，略降权
        if let t = testedAt {
            let days = Date().timeIntervalSince(t) / 86400
            ageFactor = days <= freshDays ? 1.0 : max(0.5, 1.0 - (days - freshDays) * 0.05)
        }
        return s * latencyFactor * lossFactor * ageFactor
    }
}

/// 当前网络类型。优选 IP 因网络（Wi-Fi / 蜂窝 / 运营商）而异，排行榜按网络分开记。
enum NetworkKey {
    static let defaultsKey = "cf.network.key"
    static var saved: String { UserDefaults.standard.string(forKey: defaultsKey) ?? "unknown" }


    static func label(_ key: String) -> String {
        switch key {
        case "wifi": return "Wi-Fi"
        case "cellular": return "蜂窝网络"
        case "wired": return "有线网络"
        default: return "未知网络"
        }
    }
}

/// 排行榜存档（所有网络的记录放在一起，按 network 字段区分）。
enum LeaderboardStore {
    static let key = "cf.preferred.ip.speed.leaderboard"
    static let perNetworkLimit = 100

    static func load() -> [HistoryIP] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([HistoryIP].self, from: data) else { return [] }
        return items
    }

    static func save(_ items: [HistoryIP]) {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// 同一网络内同一 IP 只留最后一条；旧版没有网络标记的记录（network == nil）若该 IP 已有带标记的新记录就丢掉；
    /// 每个网络按综合分排序、最多保留 100 条。
    static func normalized(_ items: [HistoryIP]) -> [HistoryIP] {
        var byKey: [String: HistoryIP] = [:]
        for item in items {
            guard let speed = item.speed, speed > 0, let c = CIDR.canonicalIP(item.ip) else { continue }
            byKey["\(item.network ?? "")|\(c)"] = HistoryIP(
                id: item.id, ip: c, tcpLatency: item.tcpLatency, httpsLatency: item.httpsLatency,
                colo: item.colo, speed: speed, lossRate: item.lossRate, testedAt: item.testedAt, network: item.network)
        }
        let taggedIPs = Set(byKey.values.filter { $0.network != nil }.map(\.ip))
        var groups: [String: [HistoryIP]] = [:]
        for v in byKey.values {
            if v.network == nil, taggedIPs.contains(v.ip) { continue }
            groups[v.network ?? "", default: []].append(v)
        }
        return groups.values.flatMap { $0.sorted { $0.score > $1.score }.prefix(perNetworkLimit) }
    }

    /// 把一批新测出的结果并进已有记录：打上网络和测速时间，再整理。
    static func merged(existing: [HistoryIP], scanned: [HistoryIP], network: String, now: Date) -> [HistoryIP] {
        var all = existing
        for item in scanned {
            guard let speed = item.speed, speed > 0, let c = CIDR.canonicalIP(item.ip) else { continue }
            all.append(HistoryIP(id: item.id, ip: c, tcpLatency: item.tcpLatency, httpsLatency: item.httpsLatency,
                                 colo: item.colo, speed: speed, lossRate: item.lossRate,
                                 testedAt: now.timeIntervalSince1970, network: network))
        }
        return normalized(all)
    }

    /// 某个网络下能看到的记录：该网络的，加上旧版没有网络标记的；按综合分排序，最多 100 条。
    static func visible(_ items: [HistoryIP], network: String) -> [HistoryIP] {
        items.filter { $0.network == nil || $0.network == network }
            .sorted { $0.score > $1.score }
            .prefix(perNetworkLimit).map { $0 }
    }
}

/// 测速方案：一键套用一组参数，省得逐项调。
enum ScanPreset: String, CaseIterable, Identifiable {
    case fast, standard, precise
    var id: String { rawValue }
    var title: String {
        switch self { case .fast: return "快速"; case .standard: return "标准"; case .precise: return "精确" }
    }
    var httpsTopN: Int { switch self { case .fast: return 100; case .standard: return 300; case .precise: return 500 } }
    var speedTopN: Int { switch self { case .fast: return 10; case .standard: return 30; case .precise: return 60 } }
    var speedSeconds: Double { switch self { case .fast: return 5; case .standard: return 8; case .precise: return 12 } }
    var samplePerRange: Int { switch self { case .fast: return 10; case .standard: return 24; case .precise: return 40 } }
    var refineNeighbors: Bool { self == .precise }

    /// 当前参数正好等于哪个预设（都不等于返回 nil）。
    static func matching(httpsTopN: Int, speedTopN: Int, speedSeconds: Double,
                         samplePerRange: Int, refineNeighbors: Bool) -> ScanPreset? {
        allCases.first {
            $0.httpsTopN == httpsTopN && $0.speedTopN == speedTopN && $0.speedSeconds == speedSeconds
                && $0.samplePerRange == samplePerRange && $0.refineNeighbors == refineNeighbors
        }
    }
}

/// 自定义测速地址的健康度。连续失败只是「该去确认一下」的信号，是否切到官方接口由调用方确认地址本身是否失效后再决定；
/// 备用接口自己也连续失败就放弃备用，回到自定义地址，之后不再切换。
final class DownloadHealth: @unchecked Sendable {
    static let threshold = 8
    private let lock = NSLock()
    private var streak = 0
    private var fallback = false
    private var gaveUp = false

    var useFallback: Bool { lock.lock(); defer { lock.unlock() }; return fallback }

    func recordSuccess() { lock.lock(); streak = 0; lock.unlock() }

    /// 记录一次失败。连续失败达到阈值时返回 true（调用方应去确认测速地址本身是否还活着）。
    func recordFailure() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !fallback, !gaveUp else { return false }
        streak += 1
        if streak >= Self.threshold { streak = 0; return true }
        return false
    }

    func activateFallback() {
        lock.lock(); defer { lock.unlock() }
        guard !gaveUp else { return }
        fallback = true
        streak = 0
    }

    /// 备用接口的测速结果；它连续失败达到阈值就放弃备用。
    func recordFallbackResult(success: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard fallback else { return }
        if success { streak = 0; return }
        streak += 1
        if streak >= Self.threshold { fallback = false; gaveUp = true; streak = 0 }
    }

    func reset() {
        lock.lock(); streak = 0; fallback = false; gaveUp = false; lock.unlock()
    }
}

/// 邻近网段补测：验证通过的 IP 所在的 /24 里，再各抽几个新 IP 来测。
enum NeighborSampler {
    /// - seeds: 验证通过、按延迟由低到高排好的 IP（只看前 seedLimit 个 IPv4）
    /// - ranges: 用户选的网段；只处理整个 /24 都落在某个网段内的（小网段不越界）
    /// - known: 已经测过的 IP，不重复
    static func extraIPs(seeds: [String], ranges: [String], known: Set<String>,
                         perSubnet: Int = 8, seedLimit: Int = 20,
                         random: (ClosedRange<Int>) -> Int = { Int.random(in: $0) }) -> [String] {
        let v4Ranges = ranges.filter { !$0.contains(":") }
        var seen = known
        var seenPrefix = Set<String>()
        var extra: [String] = []
        for seed in seeds.prefix(seedLimit) where !seed.contains(":") {
            let parts = seed.split(separator: ".")
            guard parts.count == 4,
                  v4Ranges.contains(where: { CIDR.fullyCovers24($0, of: seed) }) else { continue }
            let prefix = parts[0...2].joined(separator: ".")
            guard seenPrefix.insert(prefix).inserted else { continue }
            var picked = 0
            var tries = 0
            while picked < perSubnet, tries < perSubnet * 8 {
                tries += 1
                let candidate = "\(prefix).\(random(1...254))"
                if seen.insert(candidate).inserted { extra.append(candidate); picked += 1 }
            }
        }
        return extra
    }
}

enum CIDR {
    static func isValid(_ cidr: String) -> Bool {
        let parts = cidr.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]) else { return false }
        let address = String(parts[0])
        let isV6 = address.contains(":")
        guard prefix >= 0, prefix <= (isV6 ? 128 : 32) else { return false }
        var bytes = [UInt8](repeating: 0, count: 16)
        return inet_pton(isV6 ? AF_INET6 : AF_INET, address, &bytes) == 1
    }


    static func canonicalIP(_ address: String) -> String? {
        let value = address.trimmingCharacters(in: CharacterSet(charactersIn: "[] \t\n\r"))
        let family: Int32 = value.contains(":") ? AF_INET6 : AF_INET
        var bytes = [UInt8](repeating: 0, count: 16)
        guard inet_pton(family, value, &bytes) == 1 else { return nil }
        return string(from: bytes, family: family)
    }

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

    /// 电脑版 CFST 的抽样方式：网段内每个 /24 子网随机抽一个 IP。
    /// 仅 IPv4；/24 及更小的段退回随机抽样（smallCount 个）。
    static func onePerSubnet(from cidr: String, smallCount: Int) -> [String] {
        let parts = cidr.trimmingCharacters(in: .whitespaces).split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]), prefix >= 0, prefix < 24 else {
            return randomIPs(from: cidr, count: smallCount)
        }
        let addr = String(parts[0])
        guard !addr.contains(":") else { return randomIPs(from: cidr, count: smallCount) }
        var bytes = [UInt8](repeating: 0, count: 16)
        guard inet_pton(AF_INET, addr, &bytes) == 1 else { return [] }
        let base = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        let hostMask: UInt32 = prefix == 0 ? UInt32.max : (UInt32.max >> UInt32(prefix))
        let network = base & ~hostMask
        let subnetCount = 1 << (24 - prefix)
        var out: [String] = []
        out.reserveCapacity(subnetCount)
        for i in 0..<subnetCount {
            let ip = network + (UInt32(i) << 8) + UInt32.random(in: 0...255)
            out.append("\(ip >> 24).\((ip >> 16) & 0xff).\((ip >> 8) & 0xff).\(ip & 0xff)")
        }
        return out
    }

    private static func string(from bytes: [UInt8], family: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 64)
        let ok = bytes.withUnsafeBytes { raw in
            inet_ntop(family, raw.baseAddress, &buf, socklen_t(64)) != nil
        }
        return ok ? String(cString: buf) : nil
    }
}

extension CIDR {
    static func ipv4Value(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let n = UInt32(part), n <= 255 else { return nil }
            value = (value << 8) | n
        }
        return value
    }

    /// 这个 IPv4 所在的整个 /24 是否都在 cidr 里（cidr 至少是 /24 那么大）。
    static func fullyCovers24(_ cidr: String, of ip: String) -> Bool {
        let parts = cidr.trimmingCharacters(in: .whitespaces).split(separator: "/")
        guard parts.count == 2, let length = Int(parts[1]), (1...24).contains(length),
              let base = ipv4Value(String(parts[0])), let value = ipv4Value(ip) else { return false }
        let mask: UInt32 = ~UInt32(0) << UInt32(32 - length)
        return (base & mask) == (value & mask)
    }
}
