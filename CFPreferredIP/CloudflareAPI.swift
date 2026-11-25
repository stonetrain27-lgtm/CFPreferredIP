import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct CFAPIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct CloudflareAPI {
    let token: String
    private let base = "https://api.cloudflare.com/client/v4"

    func call(_ method: String, _ path: String,
              query: [String: String] = [:],
              json: Any? = nil,
              body: Data? = nil,
              contentType: String? = nil) async throws -> Any? {
        guard var comps = URLComponents(string: base + path) else {
            throw CFAPIError(message: "地址无效：\(path)")
        }
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw CFAPIError(message: "地址无效：\(path)") }

        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json = json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let body = body {
            req.httpBody = body
            if let ct = contentType { req.setValue(ct, forHTTPHeaderField: "Content-Type") }
        }

        let retryableMethod = ["GET", "PUT"].contains(method.uppercased())
        let transientStatuses: Set<Int> = [408, 425, 429, 500, 502, 503, 504]
        var lastNetworkError: Error?

        for attempt in 0..<3 {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    throw CFAPIError(message: "Cloudflare API 未返回有效 HTTP 响应")
                }
                let status = http.statusCode
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let ok = (obj?["success"] as? Bool) ?? false
                if (200..<300).contains(status), ok {
                    return obj?["result"]
                }

                if retryableMethod, transientStatuses.contains(status), attempt < 2 {
                    let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                        .flatMap { Double($0) }
                        .flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
                    let delay = min(3.0, max(0.4, retryAfter ?? (0.5 * pow(2.0, Double(attempt)))))
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }

                var msgs: [String] = []
                for e in (obj?["errors"] as? [[String: Any]]) ?? [] {
                    let code = NodeBuilder.stringValue(e["code"])
                    let message = NodeBuilder.stringValue(e["message"])
                    msgs.append(code.isEmpty ? message : "\(message)（\(code)）")
                }
                if msgs.isEmpty { msgs.append("HTTP \(status)") }
                throw CFAPIError(message: msgs.joined(separator: "；"))
            } catch let error as CFAPIError {
                throw error
            } catch {
                lastNetworkError = error
                guard retryableMethod, attempt < 2 else { throw error }
                let delay = 0.5 * pow(2.0, Double(attempt))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw CFAPIError(message: "Cloudflare API 重试后仍失败：\(lastNetworkError?.localizedDescription ?? "未知网络错误")")
    }

    // MARK: 账户 / 令牌预检

    func verifyToken() async throws {
        let result = try await call("GET", "/user/tokens/verify")
        let status = (result as? [String: Any])?["status"] as? String ?? ""
        guard status.lowercased() == "active" else {
            throw CFAPIError(message: "Cloudflare 令牌验证未通过（状态：\(status.isEmpty ? "未知" : status)），请检查令牌或重新创建")
        }
    }

    func accountID() async throws -> String {
        let r = try await call("GET", "/accounts", query: ["per_page": "20"])
        let list = (r as? [[String: Any]]) ?? []
        if list.count == 1, let id = list[0]["id"] as? String { return id }
        if list.isEmpty { throw CFAPIError(message: "令牌下没有可用账户，请手动填写 Account ID") }
        throw CFAPIError(message: "令牌能访问多个账户，请手动填写 Account ID")
    }

    /// 获取账户 workers.dev 子域名；尚未注册时尝试自动注册一个。
    func ensureWorkersSubdomain(account: String, preferred: String) async throws -> String {
        if let r = try? await call("GET", "/accounts/\(account)/workers/subdomain"),
           let obj = r as? [String: Any],
           let sub = obj["subdomain"] as? String, !sub.isEmpty {
            return sub
        }

        let base = String(preferred.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }.prefix(22))
        let seed = base.isEmpty ? "cf-worker" : base
        var lastError = "无法注册 workers.dev 子域名"
        for _ in 0..<3 {
            let suffix = String((0..<5).compactMap { _ in "abcdefghjkmnpqrstuvwxyz23456789".randomElement() })
            let candidate = "\(seed)-\(suffix)"
            do {
                let r = try await call("PUT", "/accounts/\(account)/workers/subdomain",
                                       json: ["subdomain": candidate])
                if let obj = r as? [String: Any],
                   let sub = obj["subdomain"] as? String, !sub.isEmpty {
                    return sub
                }
                lastError = "Cloudflare 未返回 workers.dev 子域名"
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        throw CFAPIError(message: "账户尚未开通 workers.dev 子域名，自动注册失败：\(lastError)。可先在 Cloudflare 控制台开通，或填写自己的自定义域名。")
    }

    // MARK: KV

    func ensureKV(account: String, title: String) async throws -> String {
        // The API is paginated (up to 1000 per page). Search every page so a
        // retry never creates a duplicate namespace when the account is large.
        var reachedLastPage = false
        for page in 1...100 {
            let result = try await call("GET", "/accounts/\(account)/storage/kv/namespaces",
                                        query: ["per_page": "1000", "page": String(page), "order": "title", "direction": "asc"])
            let list = (result as? [[String: Any]]) ?? []
            if let existing = list.first(where: { ($0["title"] as? String) == title }),
               let id = existing["id"] as? String { return id }
            if list.count < 1000 { reachedLastPage = true; break }
        }
        guard reachedLastPage else {
            throw CFAPIError(message: "KV Namespace 数量超出安全检索范围，已停止创建以避免重复资源")
        }

        let created = try await call("POST", "/accounts/\(account)/storage/kv/namespaces", json: ["title": title])
        guard let id = (created as? [String: Any])?["id"] as? String else {
            throw CFAPIError(message: "创建 KV 命名空间失败：返回内容里没有 id")
        }
        return id
    }

    /// 按标题查找 KV 命名空间，不创建。没有则返回 nil。
    func findKV(account: String, title: String) async throws -> String? {
        for page in 1...100 {
            let result = try await call("GET", "/accounts/\(account)/storage/kv/namespaces",
                                        query: ["per_page": "1000", "page": String(page), "order": "title", "direction": "asc"])
            let list = (result as? [[String: Any]]) ?? []
            if let existing = list.first(where: { ($0["title"] as? String) == title }),
               let id = existing["id"] as? String { return id }
            if list.count < 1000 { return nil }
        }
        return nil
    }

    /// 删除 Worker 脚本（force 一并解除绑定）。不可恢复。
    func deleteWorker(account: String, name: String) async throws {
        _ = try await call("DELETE", "/accounts/\(account)/workers/scripts/\(name)", query: ["force": "true"])
    }

    /// 删除 KV 命名空间及其全部内容。不可恢复。
    func deleteKV(account: String, namespaceID: String) async throws {
        _ = try await call("DELETE", "/accounts/\(account)/storage/kv/namespaces/\(namespaceID)")
    }

    /// Write a plain-text value into a Cloudflare KV namespace.
    func putKVValue(account: String, namespaceID: String, key: String, value: String) async throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        _ = try await call("PUT", "/accounts/\(account)/storage/kv/namespaces/\(namespaceID)/values/\(encodedKey)",
                           body: Data(value.utf8), contentType: "text/plain; charset=utf-8")
    }


    // MARK: Worker

    func uploadWorker(account: String, name: String, source: String,
                      bindings: [[String: Any]]) async throws {
        let metadata: [String: Any] = [
            "main_module": "worker.js",
            "compatibility_date": "2025-11-04",
            "bindings": bindings
        ]
        let metaData = try JSONSerialization.data(withJSONObject: metadata)
        let boundary = "----CFPreferredIP" + UUID().uuidString

        var body = Data()
        func add(_ s: String) { body.append(Data(s.utf8)) }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"metadata\"\r\nContent-Type: application/json\r\n\r\n")
        body.append(metaData)
        add("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"worker.js\"; filename=\"worker.js\"\r\nContent-Type: application/javascript+module\r\n\r\n")
        body.append(Data(source.utf8))
        add("\r\n--\(boundary)--\r\n")

        _ = try await call("PUT", "/accounts/\(account)/workers/scripts/\(name)",
                           body: body,
                           contentType: "multipart/form-data; boundary=\(boundary)")
    }

    func enableWorkersDev(account: String, name: String) async throws {
        _ = try await call("POST", "/accounts/\(account)/workers/scripts/\(name)/subdomain",
                           json: ["enabled": true])
    }

    func workerExists(account: String, name: String) async throws -> Bool {
        let result = try await call("GET", "/accounts/\(account)/workers/scripts-search",
                                    query: ["name": name, "order_by": "name", "per_page": "100"])
        let scripts = result as? [[String: Any]] ?? []
        return scripts.contains { ($0["script_name"] as? String) == name }
    }

    // MARK: 自定义域名

    func findZone(for hostname: String, account: String? = nil) async throws -> String? {
        let labels = hostname.lowercased().split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }
        for i in 0..<(labels.count - 1) {
            let candidate = labels[i...].joined(separator: ".")
            var query = ["name": candidate]
            if let account, !account.isEmpty { query["account.id"] = account }
            let r = try await call("GET", "/zones", query: query)
            if let arr = r as? [[String: Any]], let id = arr.first?["id"] as? String {
                return id
            }
        }
        return nil
    }

    func attachDomain(account: String, name: String, hostname: String, zoneID: String) async throws {
        _ = try await call("PUT", "/accounts/\(account)/workers/domains",
                           json: ["hostname": hostname,
                                  "service": name,
                                  "zone_id": zoneID,
                                  "enabled": true])
    }

    /// 列出绑在指定 Worker 上的全部自定义域名（排序后返回）。
    /// 用于自动选用订阅地址：Worker 已经绑了自己的域名时，绝不回退到 workers.dev。
    func workerDomains(account: String, service: String) async throws -> [String] {
        let r = try await call("GET", "/accounts/\(account)/workers/domains",
                               query: ["service": service])
        guard let arr = r as? [[String: Any]] else { return [] }
        return arr.filter { ($0["service"] as? String) == service }
                  .compactMap { $0["hostname"] as? String }
                  .sorted()
    }

    /// 查某主机名当前绑在哪个 Worker 上（没绑返回 nil）。绑定前先查，避免抢别的 Worker 的域名。
    func domainOwner(account: String, hostname: String) async throws -> String? {
        let r = try await call("GET", "/accounts/\(account)/workers/domains",
                               query: ["hostname": hostname])
        guard let arr = r as? [[String: Any]] else { return nil }
        let target = hostname.lowercased()
        for item in arr where (item["hostname"] as? String)?.lowercased() == target {
            return item["service"] as? String
        }
        return nil
    }
}
