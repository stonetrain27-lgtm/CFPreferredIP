import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Security
import Combine
import CryptoKit

// MARK: - 钥匙串（令牌、管理密码、UUID 等敏感信息）

enum KeychainStore {
    private static let service = "com.trainstone.CFPreferredIP.deploy"

    private static func baseQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    static func get(_ key: String) -> String? {
        var q = baseQuery(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String, for key: String) -> Bool {
        let identity = baseQuery(key)
        guard !value.isEmpty else {
            let status = SecItemDelete(identity as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }

        let data = Data(value.utf8)
        // Update in place first. Deleting before adding could destroy a valid
        // credential if the subsequent add failed (for example, keychain locked).
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var query = identity
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecSuccess { return true }
        // Handle a concurrent first-write race without deleting either value.
        if addStatus == errSecDuplicateItem {
            return SecItemUpdate(identity as CFDictionary, attributes as CFDictionary) == errSecSuccess
        }
        return false
    }

    @discardableResult
    static func delete(_ key: String) -> Bool {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Cryptographically secure hexadecimal secret generation.
    static func randomHex(byteCount: Int) -> String? {
        guard byteCount > 0, byteCount <= 256 else { return nil }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 敏感本地数据（订阅地址/内容、节点模板与链接）
//
// 这些值含访问凭据（订阅密钥路径、节点 UUID），存钥匙串，不再放 UserDefaults 明文。
// 读取顺序：钥匙串 → 旧 UserDefaults（首次读到时迁移：写钥匙串、验读一致后才删旧值）。
enum SecureLocalStore {
    static func read(_ key: String) -> String {
        if let v = KeychainStore.get("local:" + key) { return v }
        let d = UserDefaults.standard
        guard let old = d.string(forKey: key), !old.isEmpty else { return "" }
        if KeychainStore.set(old, for: "local:" + key),
           KeychainStore.get("local:" + key) == old {
            d.removeObject(forKey: key)
        }
        return old
    }

    static func write(_ key: String, _ value: String) {
        if value.isEmpty {
            KeychainStore.delete("local:" + key)
        } else {
            KeychainStore.set(value, for: "local:" + key)
        }
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func remove(_ key: String) {
        KeychainStore.delete("local:" + key)
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - Cloudflare API

/// Restrict script-download redirects to the same HTTPS source allowlist.
private final class AllowedScriptRedirectDelegate: NSObject, URLSessionTaskDelegate {
    private let allowedHosts: Set<String> = ["raw.githubusercontent.com", "cdn.jsdelivr.net"]

    func urlSession(_ session: URLSession, task: URLSessionTask,
                   willPerformHTTPRedirection response: HTTPURLResponse,
                   newRequest request: URLRequest,
                   completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), allowedHosts.contains(host) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

// MARK: - 独立纯文本订阅 Worker 管理

@MainActor
final class SubscriptionWorkerManager {
    static let workerName = "cfpreferredip-subscription"
    static let namespaceTitle = "cfpreferredip-subscription-content"
    static let kvContentKey = "subscription-content"
    static let publicPathKeychain = "subscription:path"
    static let updateSecretKeychain = "subscription:update-secret"
    static let hostKeychain = "subscription:host"
    static let workersDevHostKeychain = "subscription:workers-dev-host"
    static let kvIDKeychain = "subscription:kv-id"
    /// 上一次成功写入 KV 的内容：内容没变就不再写，节省免费额度（每天 1000 次写入）。
    static let lastContentKeychain = "subscription:last-content"

    private static func randomSecret(_ length: Int = 48) -> String {
        KeychainStore.randomHex(byteCount: length) ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// 重置订阅链接：换一个新的路径密钥并重新部署，旧链接立即失效。
    static func rotateLink(nodes: [String], customDomain: String = "", bindDomain: String = "") async throws -> String {
        let oldPath = KeychainStore.get(publicPathKeychain)
        let oldContent = KeychainStore.get(lastContentKeychain)
        _ = KeychainStore.delete(publicPathKeychain)
        _ = KeychainStore.delete(lastContentKeychain)
        do {
            return try await syncAndGetURL(nodes: nodes, customDomain: customDomain, bindDomain: bindDomain)
        } catch {
            // 失败时还原，避免本机记录的路径和 Cloudflare 上的不一致
            if let oldPath { _ = KeychainStore.set(oldPath, for: publicPathKeychain) }
            if let oldContent { _ = KeychainStore.set(oldContent, for: lastContentKeychain) }
            throw error
        }
    }

    /// 检测订阅链接能不能访问、里面有几条节点。
    static func checkSubscription(_ urlString: String) async -> (ok: Bool, message: String) {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https" else { return (false, "订阅地址无效") }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("v2rayN/7.0", forHTTPHeaderField: "User-Agent")
        let start = Date()
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            guard let http = resp as? HTTPURLResponse else { return (false, "没有收到 HTTP 响应") }
            guard http.statusCode == 200 else { return (false, "订阅返回 HTTP \(http.statusCode)") }
            let text = String(decoding: data, as: UTF8.self)
            let count = text.split(whereSeparator: \.isNewline).filter { $0.contains("://") }.count
            return count > 0
                ? (true, "订阅正常 · \(count) 条节点 · \(ms) ms")
                : (false, "订阅可以访问，但里面没有节点")
        } catch {
            return (false, "无法访问订阅：\(error.localizedDescription)")
        }
    }

    /// 删除 Cloudflare 上的订阅 Worker 和 KV，并清掉本机相关记录。不可恢复。
    static func destroy() async throws -> String {
        guard let token = KeychainStore.get("token"), !token.isEmpty else {
            throw CFAPIError(message: "请先保存 Cloudflare API 令牌")
        }
        let api = CloudflareAPI(token: token)
        let saved = UserDefaults.standard.string(forKey: "cf.deploy.account")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let account = saved.isEmpty ? try await api.accountID() : saved
        var removed: [String] = []
        // 先删 Worker，再删它绑定的 KV
        if try await api.workerExists(account: account, name: workerName) {
            try await api.deleteWorker(account: account, name: workerName)
            removed.append("订阅 Worker")
        }
        if let kvID = try await api.findKV(account: account, title: namespaceTitle) {
            try await api.deleteKV(account: account, namespaceID: kvID)
            removed.append("订阅 KV")
        }
        for key in [publicPathKeychain, updateSecretKeychain, hostKeychain, workersDevHostKeychain,
                    kvIDKeychain, lastContentKeychain] {
            _ = KeychainStore.delete(key)
        }
        SecureLocalStore.remove("cf.nodes.subLinkDisplay")
        return removed.isEmpty
            ? "Cloudflare 上没有找到订阅 Worker 和 KV，本机记录已清理"
            : "已删除：" + removed.joined(separator: "、") + "。重新同步订阅会自动重新创建"
    }

    static func syncAndGetURL(nodes: [String], customDomain: String = "", bindDomain: String = "") async throws -> String {
        guard !nodes.isEmpty else { throw CFAPIError(message: "没有生成节点，无法更新订阅") }
        guard let token = KeychainStore.get("token"), !token.isEmpty else {
            throw CFAPIError(message: "请先在 Cloudflare 部署页保存 API 令牌")
        }
        let api = CloudflareAPI(token: token)
        let accountSaved = UserDefaults.standard.string(forKey: "cf.deploy.account")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let account = accountSaved.isEmpty ? try await api.accountID() : accountSaved
        let pathKey = KeychainStore.get(publicPathKeychain) ?? randomSecret()
        let updateSecret = KeychainStore.get(updateSecretKeychain) ?? randomSecret()
        let rawDomain = customDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedDomain = rawDomain.hasSuffix(".") ? String(rawDomain.dropLast()) : rawDomain
        guard normalizedDomain.isEmpty || isValidHostname(normalizedDomain) else {
            throw CFAPIError(message: "订阅自定义域名格式无效，请只填写主机名，例如 sub.example.com；不要填写协议、端口或路径")
        }
        let uploadNodes = rewrittenNodes(nodes, customDomain: normalizedDomain)
        let sourceURL = Bundle.main.url(forResource: "worker", withExtension: "js")
            ?? Bundle.main.url(forResource: "worker", withExtension: "js", subdirectory: "worker/subscription")
            ?? Bundle.main.url(forResource: "worker", withExtension: "js", subdirectory: "subscription")
        guard let sourceURL, let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            throw CFAPIError(message: "App 内未找到独立订阅 Worker 文件 worker.js，请确认 XcodeGen resources 配置")
        }

        // Persist recovery data before any remote mutation. A retry can reuse the same
        // path secret and KV namespace instead of creating a second logical service.
        guard KeychainStore.set(pathKey, for: publicPathKeychain),
              KeychainStore.set(updateSecret, for: updateSecretKeychain) else {
            throw CFAPIError(message: "无法将订阅密钥保存到钥匙串，已取消部署")
        }
        UserDefaults.standard.set(account, forKey: "cf.deploy.account")

        // Namespace lookup/create is idempotent by title. Persist its ID before
        // uploading the Worker so an interrupted retry can recover the same KV.
        let kvID = try await api.ensureKV(account: account, title: namespaceTitle)
        guard KeychainStore.set(kvID, for: kvIDKeychain) else {
            throw CFAPIError(message: "KV 已准备，但 Namespace ID 无法保存到钥匙串。请保留 App 数据后重试；再次同步会复用同名 KV。")
        }

        let bindings: [[String: Any]] = [
            ["type": "kv_namespace", "name": "SUBSCRIPTION_KV", "namespace_id": kvID],
            ["type": "secret_text", "name": "SUB_PATH_KEY", "text": pathKey],
            ["type": "secret_text", "name": "UPDATE_SECRET", "text": updateSecret],
            ["type": "plain_text", "name": "SUBSCRIPTION_KV_KEY", "text": kvContentKey]
        ]
        try await api.uploadWorker(account: account, name: workerName, source: source, bindings: bindings)

        // workers.dev is a fallback, not a prerequisite for a custom domain.
        var fallbackHost = KeychainStore.get(workersDevHostKeychain) ?? ""
        do {
            let subdomain = try await api.ensureWorkersSubdomain(account: account, preferred: "cfpreferredip")
            try await api.enableWorkersDev(account: account, name: workerName)
            let candidate = "\(workerName).\(subdomain).workers.dev"
            if KeychainStore.set(candidate, for: workersDevHostKeychain) { fallbackHost = candidate }
        } catch {
            if normalizedDomain.isEmpty { throw error }
            // Continue with the requested custom domain even if workers.dev is unavailable.
        }

        let content = uploadNodes.joined(separator: "\n") + "\n"
        try await api.putKVValue(account: account, namespaceID: kvID, key: kvContentKey, value: content)
        _ = KeychainStore.set(content, for: lastContentKeychain)

        var selectedHost = fallbackHost
        // 绑定域名与节点改写域名是两个角色：改写域名是节点入口（多半已绑在节点 Worker 上），
        // 不能拿来绑订阅 Worker。绑定只认 bindDomain；绑定失败但已有可用地址时不算同步失败。
        let bindRaw = bindDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let bindHost = bindRaw.hasSuffix(".") ? String(bindRaw.dropLast()) : bindRaw
        if !bindHost.isEmpty, isValidHostname(bindHost) {
            let storedHost = KeychainStore.get(hostKeychain) ?? ""
            do {
                if let owner = try await api.domainOwner(account: account, hostname: bindHost) {
                    if owner == workerName {
                        selectedHost = bindHost
                    } else {
                        // 已被别的 Worker 占用：不抢，订阅继续用现有地址。
                        selectedHost = storedHost.isEmpty ? fallbackHost : storedHost
                        if bindHost != normalizedDomain {
                            UserDefaults.standard.set("已同步。域名 \(bindHost) 已被另一个 Worker 占用，订阅继续用现有地址", forKey: "cf.subscription.notice")
                        }
                    }
                } else {
                    guard let zoneID = try await api.findZone(for: bindHost, account: account) else {
                        throw CFAPIError(message: "找不到域名所属 Cloudflare Zone，请确认该域名已添加到当前账户")
                    }
                    try await api.attachDomain(account: account, name: workerName,
                                               hostname: bindHost, zoneID: zoneID)
                    selectedHost = bindHost
                }
            } catch {
                let usableHost = storedHost.isEmpty ? fallbackHost : storedHost
                if usableHost.isEmpty {
                    if !fallbackHost.isEmpty { _ = KeychainStore.set(fallbackHost, for: hostKeychain) }
                    let fallbackNote = fallbackHost.isEmpty ? "当前未能建立 workers.dev 备用地址。" : "workers.dev 备用地址：https://\(fallbackHost)/\(pathKey)。"
                    throw CFAPIError(message: "订阅 Worker 已部署，但自定义域名绑定失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)。\(fallbackNote)修正域名或权限后再次同步即可重试。")
                }
                selectedHost = usableHost
                UserDefaults.standard.set("已同步。自定义域名 \(bindHost) 绑定失败，订阅继续用现有地址", forKey: "cf.subscription.notice")
            }
        }
        // 兜底纠正：若最终选出的还是 workers.dev 地址，去 CF 查这个订阅 Worker
        // 实际绑着的自定义域名（例如早先绑好的），有就用它——存储里的旧值可能
        // 被某次失败的同步覆盖成备用地址，不可信，以 CF 现状为准。
        if selectedHost.hasSuffix(".workers.dev"),
           let domains = try? await api.workerDomains(account: account, service: workerName),
           let custom = domains.first {
            selectedHost = custom
        }
        if selectedHost.isEmpty {
            throw CFAPIError(message: "Worker 已部署且订阅内容已写入，但未能建立可用域名。请配置 workers.dev 子域名或填写已接入 Cloudflare 的自定义域名后重试。")
        }
        guard KeychainStore.set(selectedHost, for: hostKeychain) else {
            let recoveryURL = fallbackHost.isEmpty ? "暂无 workers.dev 备用地址，请保留 App 数据并重新同步。" : "备用地址：https://\(fallbackHost)/\(pathKey)。请保留 App 数据并重新同步。"
            throw CFAPIError(message: "订阅 Worker 已部署，但无法保存服务主机地址。\(recoveryURL)")
        }
        return "https://\(selectedHost)/\(pathKey)"
    }

    private static func isValidHostname(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, host.count <= 253 else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 &&
            label.first != "-" && label.last != "-" &&
            label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }


    /// 同步时把链接里自带的 workers.dev 域名换成用户填的自定义域名（没填则原样）。
    /// 在上传口统一改写：旧生成的节点直接点同步也会用新域名，不必重新生成。
    private static func rewrittenNodes(_ nodes: [String], customDomain: String) -> [String] {
        let domain = customDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !domain.isEmpty else { return nodes }
        return nodes.map { rewriteLinkDomain($0, to: domain) }
    }

    private static func rewriteLinkDomain(_ link: String, to domain: String) -> String {
        if link.lowercased().hasPrefix("vmess://") {
            let raw = String(link.dropFirst("vmess://".count))
            guard let data = NodeBuilder.decodeBase64(raw),
                  var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return link }
            var changed = false
            for key in ["host", "sni"] {
                if let v = obj[key] as? String, v.lowercased().hasSuffix(".workers.dev") {
                    obj[key] = domain
                    changed = true
                }
            }
            guard changed, let out = try? JSONSerialization.data(withJSONObject: obj) else { return link }
            return "vmess://" + out.base64EncodedString()
        }
        guard let current = embeddedDomain(of: link), current.lowercased().hasSuffix(".workers.dev") else { return link }
        return link.replacingOccurrences(of: current, with: domain)
    }

    private static func embeddedDomain(of link: String) -> String? {
        guard let q = link.split(separator: "?", maxSplits: 1).last else { return nil }
        let query = q.split(separator: "#", maxSplits: 1).first.map(String.init) ?? String(q)
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == "host" || kv[0] == "sni" {
                let v = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                if !v.isEmpty { return v }
            }
        }
        return nil
    }

    /// Update the existing KV on every node replacement. If the remote Worker was
    /// deleted manually, redeploy it with the same saved path/update secrets and KV.
    @discardableResult
    static func updateExisting(nodes: [String], customDomain: String = "", bindDomain: String = "") async throws -> String? {
        guard !nodes.isEmpty else { throw CFAPIError(message: "没有节点可同步") }
        guard let token = KeychainStore.get("token"), !token.isEmpty,
              let account = UserDefaults.standard.string(forKey: "cf.deploy.account"), !account.isEmpty,
              let namespaceID = KeychainStore.get(kvIDKeychain), !namespaceID.isEmpty else {
            throw CFAPIError(message: "尚未部署独立订阅 Worker")
        }
        let rawDomain = customDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedDomain = rawDomain.hasSuffix(".") ? String(rawDomain.dropLast()) : rawDomain
        guard normalizedDomain.isEmpty || isValidHostname(normalizedDomain) else {
            throw CFAPIError(message: "订阅自定义域名格式无效，请只填写主机名，例如 sub.example.com；不要填写协议、端口或路径")
        }
        let uploadNodes = rewrittenNodes(nodes, customDomain: normalizedDomain)
        let api = CloudflareAPI(token: token)
        let exists = try await api.workerExists(account: account, name: workerName)
        if !exists {
            return try await syncAndGetURL(nodes: uploadNodes, customDomain: customDomain, bindDomain: bindDomain)
        }
        let content = uploadNodes.joined(separator: "\n") + "\n"
        if KeychainStore.get(lastContentKeychain) == content {
            // 内容与上次完全一致：不重复写 KV。需要强制重写时点「同步订阅」。
            UserDefaults.standard.set("订阅内容没有变化，已跳过 KV 写入", forKey: "cf.subscription.notice")
            return nil
        }
        do {
            try await api.putKVValue(account: account, namespaceID: namespaceID, key: kvContentKey, value: content)
            _ = KeychainStore.set(content, for: lastContentKeychain)
            // 内容已更新；顺手以 CF 现状为准纠正订阅主机（自定义域名优先于 workers.dev 与本地旧值）
            if let domains = try? await api.workerDomains(account: account, service: workerName),
               let custom = domains.first,
               let pathKey = KeychainStore.get(publicPathKeychain), !pathKey.isEmpty {
                _ = KeychainStore.set(custom, for: hostKeychain)
                return "https://\(custom)/\(pathKey)"
            }
            return nil
        } catch {
            if Task.isCancelled { throw error }
            // A deleted KV namespace or stale local namespace ID can be recovered
            // by the idempotent title lookup/create + Worker upload path.
            return try await syncAndGetURL(nodes: uploadNodes, customDomain: customDomain, bindDomain: bindDomain)
        }
    }

}


// MARK: - 部署流程

struct DeployStep: Identifiable {
    enum State { case running, done, failed, skipped }
    let id = UUID()
    var title: String
    var state: State
    var detail: String = ""
}

struct DeployResult {
    var workerName: String
    var workersDevHost: String?
    var customHost: String?
    var admin: String
    var uuid: String
    var key: String

    var primaryHost: String { customHost ?? workersDevHost ?? "" }
    var adminURL: String { "https://\(primaryHost)/admin" }
    var subscriptionURL: String { "https://\(primaryHost)/\(key)" }
}

enum DeploySource {
    // Reviewed, immutable upstream snapshot. Keep fallback on the exact same commit.
    static let commit = "a8ab11125ece9bc27983f609a6359be81b21050c"
    /// 上面 commit 处 _worker.js 的 SHA-256（主源与备用源实测字节一致）；默认源下载后必须比对。
    static let sha256 = "1e84d11af0544654bf56a06fa833e77184a57193288a9ffccf62c031a9fb7d65"
    static let main = "https://raw.githubusercontent.com/cmliu/edgetunnel/\(commit)/_worker.js"
    static let fallback = "https://cdn.jsdelivr.net/gh/cmliu/edgetunnel@\(commit)/_worker.js"
}

@MainActor
final class DeployViewModel: ObservableObject {

    @Published var steps: [DeployStep] = []
    @Published var running = false
    @Published var result: DeployResult?
    @Published var notice: String?
    @Published var hasSavedToken = KeychainStore.get("token") != nil
    @Published var dangerBusy = false
    @Published var dangerMessage: String?

    /// 删除订阅 Worker 和 KV（Cloudflare 上真实删除）。
    func destroySubscriptionDeployment() async {
        guard !dangerBusy else { return }
        dangerBusy = true
        dangerMessage = nil
        defer { dangerBusy = false }
        do {
            dangerMessage = try await SubscriptionWorkerManager.destroy()
        } catch {
            dangerMessage = "删除失败：" + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// 删除节点 Worker 和它的 KV（Cloudflare 上真实删除），并清掉本机对应记录（保留令牌）。
    func destroyNodeDeployment(workerName rawName: String) async {
        guard !dangerBusy else { return }
        dangerBusy = true
        dangerMessage = nil
        defer { dangerBusy = false }
        let name = rawName.trimmingCharacters(in: .whitespaces).lowercased()
        do {
            guard let token = KeychainStore.get("token"), !token.isEmpty else {
                throw CFAPIError(message: "请先保存 Cloudflare API 令牌")
            }
            let api = CloudflareAPI(token: token)
            let saved = UserDefaults.standard.string(forKey: "cf.deploy.account")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let account = saved.isEmpty ? try await api.accountID() : saved
            var removed: [String] = []
            if try await api.workerExists(account: account, name: name) {
                try await api.deleteWorker(account: account, name: name)
                removed.append("节点 Worker「\(name)」")
            }
            if let kvID = try await api.findKV(account: account, title: "edgetunnel-\(name)") {
                try await api.deleteKV(account: account, namespaceID: kvID)
                removed.append("节点 KV")
            }
            forgetAll(workerName: name)
            _ = KeychainStore.set(token, for: "token")   // 删除部署不应顺带丢掉令牌
            hasSavedToken = true
            notice = nil
            dangerMessage = removed.isEmpty
                ? "Cloudflare 上没有找到这个节点 Worker，本机记录已清理"
                : "已删除：" + removed.joined(separator: "、")
        } catch {
            dangerMessage = "删除失败：" + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: 工具

    static func validWorkerName(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 63 else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        return s.allSatisfy { allowed.contains($0) } && !s.hasPrefix("-") && !s.hasSuffix("-")
    }

    static func validAccountID(_ s: String) -> Bool {
        s.range(of: "^[A-Fa-f0-9]{32}$", options: .regularExpression) != nil
    }

    static func validCustomHostname(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 253, !s.contains("/"), !s.contains(":") else { return false }
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 &&
            label.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil &&
            !label.hasPrefix("-") && !label.hasSuffix("-")
        }
    }

    private static func randomString(_ n: Int) -> String {
        KeychainStore.randomHex(byteCount: max(8, n)) ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func hostStorageKey(workerName: String, field: String) -> String {
        "cf.deploy.worker.\(workerName).\(field)"
    }

    private func begin(_ title: String) {
        steps.append(DeployStep(title: title, state: .running))
    }

    private func finish(_ detail: String = "", state: DeployStep.State = .done) {
        guard !steps.isEmpty else { return }
        steps[steps.count - 1].state = state
        steps[steps.count - 1].detail = detail
    }

    private func step<T>(_ title: String, _ work: () async throws -> T) async throws -> T {
        begin(title)
        do {
            let r = try await work()
            if steps[steps.count - 1].state == .running { finish() }
            return r
        } catch {
            finish((error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                   state: .failed)
            throw error
        }
    }

    // MARK: 恢复上次的部署信息

    func restore(workerName: String) {
        guard result == nil,
              let uuid = KeychainStore.get("uuid:\(workerName)"),
              let admin = KeychainStore.get("admin:\(workerName)"),
              let key = KeychainStore.get("key:\(workerName)") else { return }
        let d = UserDefaults.standard
        let customKey = Self.hostStorageKey(workerName: workerName, field: "customHost")
        let devKey = Self.hostStorageKey(workerName: workerName, field: "devHost")
        var custom = d.string(forKey: customKey) ?? ""
        var dev = d.string(forKey: devKey) ?? ""
        // One-time migration of legacy global host fields for the default Worker.
        if workerName == "edgetunnel" {
            if custom.isEmpty { custom = d.string(forKey: "cf.deploy.customHost") ?? "" }
            if dev.isEmpty { dev = d.string(forKey: "cf.deploy.devHost") ?? "" }
            if !custom.isEmpty { d.set(custom, forKey: customKey) }
            if !dev.isEmpty { d.set(dev, forKey: devKey) }
        }
        guard !custom.isEmpty || !dev.isEmpty else { return }
        result = DeployResult(workerName: workerName,
                             workersDevHost: dev.isEmpty ? nil : dev,
                             customHost: custom.isEmpty ? nil : custom,
                             admin: admin, uuid: uuid, key: key)
    }

    func switchWorker(workerName: String) {
        result = nil
        restore(workerName: workerName)
    }

    func forgetAll(workerName: String) {
        let d = UserDefaults.standard
        let keys = ["token", "admin:\(workerName)", "uuid:\(workerName)", "key:\(workerName)",
                    SubscriptionWorkerManager.publicPathKeychain,
                    SubscriptionWorkerManager.updateSecretKeychain,
                    SubscriptionWorkerManager.hostKeychain,
                    SubscriptionWorkerManager.workersDevHostKeychain,
                    SubscriptionWorkerManager.kvIDKeychain,
                    SubscriptionWorkerManager.lastContentKeychain]
        let keychainCleared = keys.map { KeychainStore.delete($0) }.allSatisfy { $0 }

        d.removeObject(forKey: Self.hostStorageKey(workerName: workerName, field: "customHost"))
        d.removeObject(forKey: Self.hostStorageKey(workerName: workerName, field: "devHost"))
        d.removeObject(forKey: Self.hostStorageKey(workerName: workerName, field: "customDomain"))
        d.removeObject(forKey: Self.hostStorageKey(workerName: workerName, field: "sourceURL"))
        d.removeObject(forKey: "cf.deploy.account")
        if workerName == "edgetunnel" {
            d.removeObject(forKey: "cf.deploy.customHost")
            d.removeObject(forKey: "cf.deploy.devHost")
            d.removeObject(forKey: "cf.deploy.domain")
            d.removeObject(forKey: "cf.deploy.source")
        }
        // Subscription URLs and node links contain access credentials; remove their
        // local copies together with the standalone Worker secrets.
        for key in ["cf.nodes.subURL", "cf.nodes.subText", "cf.nodes.template", "cf.nodes.port",
                    "cf.subscription.customDomain"] {
            d.removeObject(forKey: key)
        }
        for key in ["cf.nodes.subURL", "cf.nodes.subText", "cf.nodes.template",
                    "cf.nodes.result", "cf.nodes.subLinkDisplay"] {
            SecureLocalStore.remove(key)
        }
        d.set(d.integer(forKey: "cf.deploy.clearGeneration") + 1, forKey: "cf.deploy.clearGeneration")
        hasSavedToken = KeychainStore.get("token") != nil
        result = nil
        steps = []
        notice = keychainCleared
            ? "已清除本机当前 Worker 的令牌/部署密钥、账户 ID、订阅地址、订阅内容和节点模板。Cloudflare 上的 Worker/KV 不会被删除。"
            : "本机缓存已清除，但部分钥匙串项目未能删除。请保持设备解锁后再次清除；Cloudflare 上的 Worker/KV 不会被删除。"
    }


    // MARK: 脚本下载

    private func downloadSource(_ urlString: String) async throws -> String {
        var candidates = [urlString]
        if urlString == DeploySource.main { candidates.append(DeploySource.fallback) }
        var lastError = "下载失败"
        for c in candidates {
            guard let url = URL(string: c),
                  url.scheme?.lowercased() == "https",
                  url.user == nil, url.password == nil,
                  let host = url.host?.lowercased(),
                  ["raw.githubusercontent.com", "cdn.jsdelivr.net"].contains(host),
                  url.query == nil, url.fragment == nil else {
                lastError = "脚本来源仅允许 HTTPS 的 raw.githubusercontent.com 或 cdn.jsdelivr.net，且不能带账号、查询参数或片段"
                continue
            }
            do {
                // URLSession.shared 会自动跟随重定向；用独立 session 在每一跳再次验证主机。
                let redirectGuard = AllowedScriptRedirectDelegate()
                let session = URLSession(configuration: .ephemeral, delegate: redirectGuard,
                                        delegateQueue: nil)
                defer { session.finishTasksAndInvalidate() }
                let (data, resp) = try await session.data(
                    for: URLRequest(url: url, timeoutInterval: 30))
                if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    lastError = "HTTP \(http.statusCode)（\(resp.url?.host ?? url.host ?? "")）"
                    continue
                }
                guard let finalURL = resp.url,
                      finalURL.scheme?.lowercased() == "https",
                      finalURL.user == nil, finalURL.password == nil,
                      let finalHost = finalURL.host?.lowercased(),
                      ["raw.githubusercontent.com", "cdn.jsdelivr.net"].contains(finalHost) else {
                    lastError = "下载最终地址不在允许的 HTTPS 来源内，已阻止"
                    continue
                }
                guard data.count <= 9_000_000 else { lastError = "脚本过大（\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))），超过应用安全上传上限 9 MB"; continue }
                if urlString == DeploySource.main {
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    guard digest == DeploySource.sha256 else {
                        lastError = "脚本 SHA-256 不符，已阻止部署（期望 \(DeploySource.sha256.prefix(12))…，实际 \(digest.prefix(12))…）"
                        continue
                    }
                }
                let text = String(decoding: data, as: UTF8.self)
                guard text.contains("export default") else {
                    lastError = "下载到的内容不像 Worker 脚本"
                    continue
                }
                return text
            } catch {
                lastError = error.localizedDescription
            }
        }
        throw CFAPIError(message: lastError)
    }

    // MARK: 主流程

    // MARK: 令牌提交（先验证再保存；部署时直接用已保存的令牌）
    func submitToken(_ input: String) async -> String? {
        let token = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return "请先填写 Cloudflare API 令牌" }
        do {
            try await CloudflareAPI(token: token).verifyToken()
        } catch {
            return "令牌验证失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
        guard KeychainStore.set(token, for: "token") else {
            return "Cloudflare 令牌无法保存到钥匙串，请解锁设备后重试"
        }
        hasSavedToken = true
        return nil
    }

    func run(tokenInput: String, accountInput: String, workerName: String,
             customDomain: String, sourceURL: String) async {
        guard !running else { return }
        running = true
        notice = nil
        steps = []
        result = nil
        defer { running = false }

        let name = workerName.trimmingCharacters(in: .whitespaces).lowercased()
        let domain = customDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (KeychainStore.get("token") ?? "")
            : tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !token.isEmpty else { notice = "请先填写 Cloudflare API 令牌"; return }
        guard Self.validWorkerName(name) else {
            notice = "Worker 名称只能用小写字母、数字和连字符"
            return
        }

        do {
            let api = CloudflareAPI(token: token)

            _ = try await step("验证 Cloudflare 令牌") {
                try await api.verifyToken()
                return "令牌状态有效"
            }

            let account: String = try await step("确认账户") {
                let manual = accountInput.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolved = manual.isEmpty ? try await api.accountID() : manual
                guard Self.validAccountID(resolved) else {
                    throw CFAPIError(message: "Account ID 格式不正确，应为 32 位十六进制字符串")
                }
                return resolved
            }

            // 通过令牌预检后才保存，避免把无效令牌覆盖到钥匙串。
            if !tokenInput.isEmpty {
                guard KeychainStore.set(token, for: "token") else {
                    throw CFAPIError(message: "Cloudflare 令牌无法保存到钥匙串，已中止部署，避免 Worker 创建后本机无法恢复管理。请解锁设备后重试。")
                }
                hasSavedToken = true
            }

            guard domain.isEmpty || Self.validCustomHostname(domain) else {
                throw CFAPIError(message: "自定义域名格式不正确：只填写主机名，不要包含 https://、路径或端口")
            }

            let source = try await step("下载 edgetunnel 脚本") {
                try await downloadSource(sourceURL.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            // 密钥：同名 Worker 重复部署时沿用，订阅链接不会变
            let admin = KeychainStore.get("admin:\(name)") ?? Self.randomString(16)
            let uuid = KeychainStore.get("uuid:\(name)") ?? UUID().uuidString.lowercased()
            let key = KeychainStore.get("key:\(name)") ?? Self.randomString(12)

            // Persist all secrets before the remote upload. If Keychain fails, do not
            // create/update a Worker whose credentials cannot be recovered locally.
            let adminSaved = KeychainStore.set(admin, for: "admin:\(name)")
            let uuidSaved = KeychainStore.set(uuid, for: "uuid:\(name)")
            let keySaved = KeychainStore.set(key, for: "key:\(name)")
            guard adminSaved && uuidSaved && keySaved else {
                throw CFAPIError(message: "部署凭据无法完整写入钥匙串，已中止上传。请检查设备解锁状态后重试；不会创建无法管理的 Worker。")
            }

            let kvID = try await step("准备 KV 命名空间") {
                try await api.ensureKV(account: account, title: "edgetunnel-\(name)")
            }

            let bindings: [[String: Any]] = [
                ["type": "kv_namespace", "name": "KV", "namespace_id": kvID],
                ["type": "secret_text", "name": "ADMIN", "text": admin],
                ["type": "secret_text", "name": "UUID", "text": uuid],
                ["type": "secret_text", "name": "KEY", "text": key]
            ]

            try await step("上传 Worker") {
                try await api.uploadWorker(account: account, name: name,
                                           source: source, bindings: bindings)
            }

            // workers.dev：用户未填自定义域名时也能直接部署；账户未注册子域名则尝试自动创建
            var devHost: String?
            begin("准备 Cloudflare 免费域名")
            do {
                let sub = try await api.ensureWorkersSubdomain(account: account, preferred: name)
                try await api.enableWorkersDev(account: account, name: name)
                devHost = "\(name).\(sub).workers.dev"
                finish(devHost ?? "")
            } catch {
                finish((error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                       state: .failed)
            }

            // 自定义域名：先查这个域名现在绑在谁身上。
            // 已在本 Worker 上 = 已绑好；被别的 Worker 占用 = 跳过（不算失败）；没绑才去绑。
            var customHost: String?
            if !domain.isEmpty {
                let owner = try? await api.domainOwner(account: account, hostname: domain)
                if owner == name {
                    begin("绑定自定义域名 \(domain)")
                    finish(domain)
                    customHost = domain
                } else if let owner {
                    begin("绑定自定义域名 \(domain)")
                    finish("该域名已绑在「\(owner)」上，跳过；本次用免费域名", state: .skipped)
                } else {
                    customHost = try? await step("绑定自定义域名 \(domain)") {
                        guard let zone = try await api.findZone(for: domain, account: account) else {
                            throw CFAPIError(message: "没有在账户里找到该域名所在的区域，请确认域名已托管到 Cloudflare，且令牌有区域读取权限")
                        }
                        try await api.attachDomain(account: account, name: name,
                                                   hostname: domain, zoneID: zone)
                        return domain
                    }
                }
            }

            guard devHost != nil || customHost != nil else {
                notice = "Worker 已上传，但没有可用的访问地址。请先绑定自定义域名，或在 Cloudflare 控制台注册 workers.dev 子域名后重试。"
                return
            }

            let r = DeployResult(workerName: name, workersDevHost: devHost, customHost: customHost,
                                 admin: admin, uuid: uuid, key: key)
            result = r
            let defaults = UserDefaults.standard
            defaults.set(customHost ?? "", forKey: Self.hostStorageKey(workerName: name, field: "customHost"))
            defaults.set(devHost ?? "", forKey: Self.hostStorageKey(workerName: name, field: "devHost"))

            await importSubscription(r)
        } catch {
            if notice == nil {
                notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// 部署完成后，从 Worker 自己拉订阅，交给「节点」页
    func importSubscription(_ r: DeployResult) async {
        let url = r.subscriptionURL

        begin("拉取订阅并导入节点页")
        var lastError = ""
        // 新 Worker 或新域名的证书需要一点时间生效，多试几次
        for attempt in 0..<6 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 5_000_000_000) }
            do {
                let text = try await SubscriptionFetcher.fetch(url)
                let count = NodeBuilder.parseTemplatesDetailed(text).templates.count
                // 地址与内容成对写入：拉不到内容时不换地址，避免来源标签与实际模板不是同一家
                SecureLocalStore.write("cf.nodes.subURL", url)
                SecureLocalStore.write("cf.nodes.subText", text)
                finish("识别到 \(count) 个节点模板")
                return
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        finish("暂时拉不到订阅：\(lastError)。域名或证书可能还在生效，稍后到「节点」页再次点击「优选 IP 替换」（会自动重试拉取）", state: .failed)
    }
}
