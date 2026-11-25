import SwiftUI
import UIKit

// MARK: - 共用样式

enum Theme {
    static let corner: CGFloat = 20
    static let controlCorner: CGFloat = 14
    static let controlHeight: CGFloat = 48
    static let stroke = Color.primary.opacity(0.07)
    static let shadow = Color.black.opacity(0.055)
}

/// 液态玻璃背景（iOS 26+），旧系统回退到给定的填充色。
struct GlassBackground<S: Shape>: ViewModifier {
    let shape: S
    let fallback: Color
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(fallback, in: shape)
        }
    }
}

/// 液态玻璃胶囊（iOS 26+），旧系统回退到 regularMaterial。
struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}

extension View {
    func glassBackground<S: Shape>(_ shape: S, fallback: Color) -> some View {
        modifier(GlassBackground(shape: shape, fallback: fallback))
    }

    /// 统一的卡片外观
    func card(padding: CGFloat = 16) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
        return self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassBackground(shape, fallback: Color(uiColor: .secondarySystemGroupedBackground))
            .overlay(shape.strokeBorder(Theme.stroke, lineWidth: 0.8))
            .shadow(color: Theme.shadow, radius: 12, y: 5)
    }

    /// 全局统一输入控件：高度、内边距、底色和描边保持一致。
    func fieldBox() -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.controlCorner, style: .continuous)
        return self
            .frame(minHeight: Theme.controlHeight)
            .padding(.horizontal, 14)
            .background(Color(uiColor: .tertiarySystemFill), in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.055), lineWidth: 0.8))
    }

    func toast(_ message: Binding<String?>) -> some View {
        modifier(ToastModifier(message: message))
    }
}

/// 胶囊按钮：filled 为实心，否则为淡色底
struct PillButtonStyle: ButtonStyle {
    var tint: Color = .blue
    var filled = true
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, tint: tint, filled: filled, compact: compact)
    }

    private struct PillBody: View {
        @Environment(\.isEnabled) private var isEnabled
        let configuration: ButtonStyleConfiguration
        let tint: Color
        let filled: Bool
        let compact: Bool

        var body: some View {
            configuration.label
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(filled ? Color.white : tint)
                .frame(maxWidth: compact ? nil : .infinity)
                .padding(.horizontal, compact ? 16 : 0)
                .padding(.vertical, 14)
                .background(filled ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(0.10)),
                            in: Capsule())
                .opacity(isEnabled ? (configuration.isPressed ? 0.88 : 1) : 0.45)
                .scaleEffect(configuration.isPressed ? 0.965 : 1)
                .animation(.spring(response: 0.24, dampingFraction: 0.58), value: configuration.isPressed)
        }
    }
}

/// 底部轻提示（替代需要手动关闭的弹窗）
struct ToastModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let text = message {
                    Text(text)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: text) {
                            try? await Task.sleep(nanoseconds: 1_400_000_000)
                            if !Task.isCancelled { message = nil }
                        }
                }
            }
            .animation(.easeOut(duration: 0.25), value: message)
    }
}

// MARK: - 共用顶栏

struct TopBarView: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .glassBackground(Rectangle(), fallback: Color(uiColor: .secondarySystemGroupedBackground))
    }
}

// MARK: - 节点生成页

struct NodesView: View {
    @ObservedObject var vm: ViewModel

    @State private var templateText = ""
    @AppStorage("cf.nodes.domain") private var domain = ""
    @AppStorage("cf.nodes.force") private var force = false
    @AppStorage("cf.nodes.topN") private var topN = 5
    @AppStorage("cf.nodes.ipSource") private var ipSource = "latest"
    @AppStorage("cf.nodes.keepPorts") private var keepPorts = false
    @AppStorage("cf.nodes.onePerIP") private var onePerIP = true
    /// 每个 IP 只生成一个节点时，订阅里同一节点的多个端口只取一个，不做保留。
    private var effectiveKeepPorts: Bool { keepPorts && !onePerIP }
    @AppStorage("cf.nodes.maxNodes") private var maxNodes = 40
    @AppStorage("cf.nodes.verifyEntry") private var verifyEntry = true
    @AppStorage("cf.nodes.nameWithStats") private var nameWithStats = false
    @AppStorage("cf.nodes.autoRefresh") private var autoRefresh = false
    @AppStorage("cf.nodes.lastSync") private var lastSyncTime = 0.0
    @AppStorage("cf.nodes.lastSyncInfo") private var lastSyncInfo = ""
    @State private var verifyingEntry = false
    @State private var checkingSub = false
    @State private var subCheckMessage: String?
    @State private var subCheckOK = false
    @State private var rotatingLink = false
    @State private var confirmRotate = false

    /// 最近一次结果为空而排行榜有记录时，自动改用排行榜，省得用户手动切换。
    private var effectiveIPSource: String {
        (ipSource == "latest" && vm.results.isEmpty && !vm.leaderboard.isEmpty) ? "leaderboard" : ipSource
    }

    /// 超过 12 小时没同步：优选 IP 可能已经过期。
    private var syncIsStale: Bool {
        lastSyncTime > 0 && Date().timeIntervalSince1970 - lastSyncTime > 12 * 3600
    }
    @State private var subURL = ""
    @State private var subText = ""
    @State private var loadingSecureStores = false
    @AppStorage("cf.subscription.customDomain") private var subscriptionCustomDomain = ""

    /// 节点域名以「订阅来源」为准：来源是自定义域名时，workers.dev 模板就盖这个域名；
    /// 来源是 workers.dev 时不盖（保留模板原样；生成选项里手填的域名仍优先）。
    /// 不再读部署/订阅两侧存过的域名记录——那些旧值曾把别的 Worker 的域名盖到节点上，
    /// 造成域名与 UUID 对不上、节点连不上。
    private var sourceDomain: String {
        NodeBuilder.sourceDomain(subURL: subURL, ownSubscription: subURLIsOwnSubscription)
    }
    /// 订阅来源填的是不是本 App 自己同步出来的订阅（独立订阅 Worker）。
    /// 是的话它的域名不是节点入口，不能拿来改写节点的域名。
    private var subURLIsOwnSubscription: Bool {
        let hosts = [SubscriptionWorkerManager.hostKeychain, SubscriptionWorkerManager.workersDevHostKeychain]
            .compactMap { KeychainStore.get($0) }
        return NodeBuilder.isOwnSubscription(
            subURL, ownPath: KeychainStore.get(SubscriptionWorkerManager.publicPathKeychain), ownHosts: hosts)
    }
    @AppStorage("cf.deploy.clearGeneration") private var clearGeneration = 0
    // 已生成的节点和固定订阅链接保存在本地（钥匙串）：退出软件、切换页面后依然保留
    @State private var resultJSON = ""
    @State private var subscriptionLinkForDisplay = ""

    @State private var copied: String?
    @State private var fetching = false
    @State private var fetchMessage: String?
    @State private var fetchFailed = false
    @State private var showAdvanced = false
    @State private var publishingSubscription = false
    @State private var subscriptionSyncMessage: String?
    @State private var subscriptionSyncFailed = false

    private struct SavedNode: Codable {
        let name: String
        let link: String
    }

    private var savedNodes: [SavedNode] {
        guard let data = resultJSON.data(using: .utf8),
              let nodes = try? JSONDecoder().decode([SavedNode].self, from: data) else { return [] }
        return nodes
    }

    /// 从钥匙串恢复敏感字段（首次会把旧 UserDefaults 值迁移过去）。加载期间不触发回写与联动清空。
    private func loadSecureStores() {
        loadingSecureStores = true
        templateText = SecureLocalStore.read("cf.nodes.template")
        subURL = SecureLocalStore.read("cf.nodes.subURL")
        subText = SecureLocalStore.read("cf.nodes.subText")
        resultJSON = SecureLocalStore.read("cf.nodes.result")
        subscriptionLinkForDisplay = SecureLocalStore.read("cf.nodes.subLinkDisplay")
        loadingSecureStores = false
    }

    private func saveNodes(_ nodes: [SavedNode]) {
        if let data = try? JSONEncoder().encode(nodes), let text = String(data: data, encoding: .utf8) {
            resultJSON = text
        }
    }

    private struct InstallCommand: Identifiable {
        let id = UUID()
        let title: String
        let command: String
    }

    private var installCommands: [InstallCommand] {
        let base = "https://raw.githubusercontent.com/youko-nobody/xray-dual-installer/776055aea9f01d4c41fbe5b91288aa24b9f8d400/"
        func install(_ title: String, _ file: String) -> InstallCommand {
            InstallCommand(title: title,
                           command: "wget -O /root/\(file) \(base)\(file) && chmod +x /root/\(file) && /root/\(file)")
        }
        return [
            install("综合脚本", "install.sh"),
            InstallCommand(title: "查看已保存的节点信息", command: "/root/install.sh info"),
            install("VLESS + Reality", "install-reality.sh"),
            install("Reality + WS 双节点", "install-xray-dual-auto.sh"),
            install("Hysteria2", "install-hy2.sh"),
            install("Snell v6", "install-snell.sh"),
            install("SOCKS5", "install-socks5.sh"),
            install("MTProto", "install-mtproto.sh"),
            install("AnyTLS", "install-anytls.sh"),
            install("Shadowsocks 2022", "install-ss2022.sh")
        ]
    }

    var body: some View {
        let parsed = NodeBuilder.parseTemplatesDetailed(templateText + "\n" + subText, keepPorts: effectiveKeepPorts)
        let ipCount = min(topN, (effectiveIPSource == "leaderboard" ? vm.leaderboard : vm.results).count)

        ScrollView {
            VStack(spacing: 12) {
                ipPickerSection
                subscriptionSection
                outputSection(ipCount: ipCount, templateCount: parsed.templates.count)
                advancedSection(parsed.templates, merged: parsed.merged)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        // 根视图底部悬浮标签栏会占用可视区域；额外留出滚动尾部空间，
        // 避免最后一组表单/卡片被遮挡，确保可以完整滚动到最底部。
        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 96) }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        // 顶部标题栏已移除，内容直接从安全区域下方开始。
        .onAppear {
            loadSecureStores()
            if subURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { subText = "" }
        }
        .onChange(of: subURL) { newValue in
            // onAppear 从钥匙串恢复 subURL 时，onChange 会在 loadingSecureStores 复位之后才触发；
            // 与已存值相同说明不是用户修改，不能清掉订阅内容。
            if !loadingSecureStores && newValue != SecureLocalStore.read("cf.nodes.subURL") {
                SecureLocalStore.write("cf.nodes.subURL", newValue)
                subText = ""
            }
        }
        .onChange(of: subText) { newValue in
            if !loadingSecureStores { SecureLocalStore.write("cf.nodes.subText", newValue) }
        }
        .onChange(of: templateText) { newValue in
            if !loadingSecureStores { SecureLocalStore.write("cf.nodes.template", newValue) }
        }
        .onChange(of: resultJSON) { newValue in
            if !loadingSecureStores { SecureLocalStore.write("cf.nodes.result", newValue) }
        }
        .onChange(of: subscriptionLinkForDisplay) { newValue in
            if !loadingSecureStores { SecureLocalStore.write("cf.nodes.subLinkDisplay", newValue) }
        }
        .onChange(of: clearGeneration) { _ in
            // 仅在用户明确清理时删除本地保存的节点结果。
            resultJSON = ""
            subscriptionLinkForDisplay = ""
            subscriptionSyncMessage = nil
            subscriptionSyncFailed = false
        }
        .onChange(of: autoRefresh) { enabled in
            if enabled { AutoRefresher.schedule() } else { AutoRefresher.cancel() }
        }
        .confirmationDialog("重置订阅链接？", isPresented: $confirmRotate, titleVisibility: .visible) {
            Button("重置", role: .destructive) { Task { await rotateSubscriptionLink() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("旧链接会立即失效，所有客户端里的订阅都要换成新链接。")
        }
        .toast($copied)
    }

    // MARK: 替换 IP 选择（页面最上方：先选数量，再点「优选 IP 替换」，最后生成节点与订阅）

    private var ipPickerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("替换 IP").font(.headline)

            Picker("IP 来源", selection: Binding(get: { effectiveIPSource }, set: { ipSource = $0 })) {
                Text("最近一次结果（\(vm.results.count)）").tag("latest")
                Text("排行榜（\(vm.leaderboard.count) · \(vm.networkLabel)）").tag("leaderboard")
            }
            .pickerStyle(.segmented)

            Stepper(value: $topN, in: 1...20) {
                Text("使用前 \(topN) 个 IP").font(.subheadline)
            }
        }
        .card()
    }

    // MARK: 订阅

    private var subscriptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("订阅来源").font(.headline)

            HStack(spacing: 10) {
                TextField("https://订阅地址", text: $subURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .lineLimit(1)
                    .fieldBox()

                Button {
                    let sourceLink = subURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    let deployedLink = subscriptionLinkForDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
                    // 优先复制「替换优选 IP 之后」的固定订阅；还没生成过才退回原始订阅
                    let link = deployedLink.isEmpty ? sourceLink : deployedLink
                    guard !link.isEmpty else { return }
                    UIPasteboard.general.string = link
                    copied = deployedLink.isEmpty ? "已复制原始订阅（尚未替换）" : "已复制替换后的订阅链接"
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .buttonStyle(PillButtonStyle(filled: false, compact: true))
                .disabled(subURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && subscriptionLinkForDisplay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Button {
                Task { await prepareAndReplace() }
            } label: {
                HStack(spacing: 8) {
                    if fetching { ProgressView().tint(.white).controlSize(.small) }
                    else { Image(systemName: "arrow.triangle.2.circlepath") }
                    Text(fetching ? "正在获取" : (verifyingEntry ? "正在验证入口" : (publishingSubscription ? "正在同步订阅" : "优选 IP 替换")))
                }
            }
            .buttonStyle(PillButtonStyle())
            .disabled(fetching || publishingSubscription || verifyingEntry)

            VStack(spacing: 6) {
                Toggle("每个 IP 只生成一个节点", isOn: $onePerIP)
                Toggle("替换前验证节点入口", isOn: $verifyEntry)
                Toggle("节点名带速度和延迟", isOn: $nameWithStats)
            }
            .font(.subheadline)

            if subURLIsOwnSubscription {
                Text("这里填的是本 App 同步出来的订阅，替换会基于上一次的结果。建议改填 edgetunnel 的原始订阅链接。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let m = fetchMessage {
                Text(m)
                    .font(.caption)
                    .foregroundStyle(fetchFailed ? Color.red : Color.green)
            }

        }
        .card()
    }

    @MainActor
    private func prepareAndReplace() async {
        subscriptionSyncMessage = nil
        subscriptionSyncFailed = false
        fetchMessage = nil
        fetchFailed = false
        // 每次都重新拉取订阅，避免沿用过期的缓存内容
        if !subURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await fetchSubscription()
            guard !fetchFailed, !subText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        }
        let hasSource = !subText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !templateText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasSource else {
            fetchFailed = true
            fetchMessage = "请先填写订阅链接或添加节点模板"
            return
        }
        fetchMessage = nil
        fetchFailed = false
        let parsed = NodeBuilder.parseTemplatesDetailed(templateText + "\n" + subText, keepPorts: effectiveKeepPorts)
        let trimmedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSubDomain = sourceDomain
        let options = BuildOptions(domain: trimmedDomain.isEmpty ? trimmedSubDomain : trimmedDomain,
                                  force: force)
        let usingLeaderboard = effectiveIPSource == "leaderboard"
        let ipPool = usingLeaderboard ? vm.leaderboard : vm.results
        let sourceLabel = usingLeaderboard ? "排行榜（\(vm.networkLabel)）" : "最近一次结果"
        guard !ipPool.isEmpty else {
            fetchFailed = true
            fetchMessage = usingLeaderboard ? "排行榜暂无记录，请先完成一次优选" : "暂无最近一次结果，请先完成一次优选"
            return
        }
        // 替换前用节点真实域名验一遍入口（TLS + WebSocket 101），测速时没验过或结果已过期的 IP 在这里被筛掉
        var currentIPs = Array(ipPool.prefix(topN))
        var verifyNote: String?
        if verifyEntry, let target = NodeBuilder.entryTarget(from: parsed.templates, ownDomain: options.domain) {
            let candidates = Array(ipPool.prefix(min(ipPool.count, topN * 2 + 2)))
            verifyingEntry = true
            fetchMessage = "正在验证 \(candidates.count) 个 IP 能否连上节点入口…"
            let sniName = target.sni, hostName = target.host, portNumber = target.port, pathValue = target.path
            let passedIndexes: Set<Int> = await withTaskGroup(of: (Int, Bool).self) { group in
                for (i, c) in candidates.enumerated() {
                    let ip = c.ip
                    group.addTask { (i, await Tester.entryCheck(ip: ip, port: portNumber, sni: sniName, host: hostName, path: pathValue)) }
                }
                var ok = Set<Int>()
                for await (i, pass) in group where pass { ok.insert(i) }
                return ok
            }
            verifyingEntry = false
            let passed = candidates.enumerated().filter { passedIndexes.contains($0.offset) }.map(\.element)
            if passed.isEmpty {
                verifyNote = "入口验证 0/\(candidates.count) 通过，已改用未验证的 IP；请确认节点 Worker 在线、域名可访问"
            } else {
                currentIPs = Array(passed.prefix(topN))
                verifyNote = passed.count >= topN
                    ? "入口验证通过 \(passed.count)/\(candidates.count)，取最快的 \(topN) 个"
                    : "入口验证只有 \(passed.count)/\(candidates.count) 个 IP 通过，不足 \(topN) 个"
            }
        }
        // 默认：选几个 IP 就生成几个节点（每个 IP 只用一个模板，优先 443 端口）
        let picked = NodeBuilder.pickTemplates(parsed.templates, opts: options, onePerIP: onePerIP)
        let usedTemplates = picked.used
        var onePerIPNote: String?
        if onePerIP, picked.eligibleCount > 1, let first = picked.used.first {
            onePerIPNote = "订阅里有 \(picked.eligibleCount) 个不同的节点，只用「\(first.name)」；要全部替换请在高级里关闭「每个 IP 只生成一个节点」"
        }
        let generated = NodeBuilder.generate(templates: usedTemplates, ips: currentIPs,
                                             opts: options, maxNodes: maxNodes,
                                             statsLabel: nameWithStats ? nodeStatsLabel : nil)
        saveNodes(generated.nodes.map { SavedNode(name: $0.name, link: $0.link) })

        // 被跳过的节点不能悄悄丢：说明跳过了几个、为什么
        let skippedList = parsed.templates.filter { !NodeBuilder.eligible($0, options) }
        let directSkipped = skippedList.filter { $0.status == .direct }
        let needDomainSkipped = skippedList.filter { $0.status == .needsDomain }
        var notes: [String] = []
        if let verifyNote { notes.append(verifyNote) }
        if let onePerIPNote { notes.append(onePerIPNote) }
        if !directSkipped.isEmpty {
            let names = directSkipped.prefix(3).map(\.name).joined(separator: "、")
            notes.append("跳过 \(directSkipped.count) 个直连协议节点（\(names)\(directSkipped.count > 3 ? " 等" : "")，Cloudflare 无法代理，换 IP 没有意义）")
        }
        if !needDomainSkipped.isEmpty {
            notes.append("跳过 \(needDomainSkipped.count) 个地址是 IP 且没有域名的节点（可在高级里填 Cloudflare 域名）")
        }
        if generated.truncated {
            notes.append("已达上限 \(maxNodes) 条，更多请在高级里调大上限或减少使用的 IP 数")
        }
        if parsed.merged > 0 && !effectiveKeepPorts {
            notes.append("合并了 \(parsed.merged) 个仅端口/地址不同的重复节点")
        }
        if !generated.nodes.isEmpty && !notes.isEmpty {
            fetchMessage = "已生成 \(generated.nodes.count) 条。" + notes.joined(separator: "；")
        } else if verifyNote != nil {
            fetchMessage = nil
        }

        // 替换完成后立刻把「替换后的节点」同步进固定订阅（首次会自动部署订阅 Worker）
        if !generated.nodes.isEmpty {
            await syncAfterReplace(generated.nodes.map(\.link), info: "\(generated.nodes.count) 条 · \(sourceLabel)")
        } else {
            fetchFailed = true
            fetchMessage = "没有可替换的节点（订阅里的节点可能都是直连协议，或地址是 IP 且需要填写域名）"
        }
    }

    @MainActor
    private func syncAfterReplace(_ links: [String], info: String) async {
        guard let token = KeychainStore.get("token"), !token.isEmpty else {
            subscriptionSyncMessage = "节点已替换，但还没保存 Cloudflare 令牌，订阅未同步。请先在部署页保存令牌"
            subscriptionSyncFailed = true
            return
        }
        publishingSubscription = true
        subscriptionSyncMessage = nil
        subscriptionSyncFailed = false
        defer { publishingSubscription = false }
        do {
            let hasWorker = KeychainStore.get(SubscriptionWorkerManager.hostKeychain) != nil
                && KeychainStore.get(SubscriptionWorkerManager.kvIDKeychain) != nil
            let url: String?
            if hasWorker {
                url = try await SubscriptionWorkerManager.updateExisting(
                    nodes: links, customDomain: sourceDomain, bindDomain: "")
            } else {
                url = try await SubscriptionWorkerManager.syncAndGetURL(
                    nodes: links, customDomain: sourceDomain, bindDomain: "")
            }
            if let url { subscriptionLinkForDisplay = url }
            subscriptionSyncMessage = consumeSubscriptionNotice()
                ?? "订阅已更新为替换后的节点（Cloudflare 边缘缓存最长约 1 分钟生效）"
            subscriptionSyncFailed = false
            lastSyncTime = Date().timeIntervalSince1970
            lastSyncInfo = info
            subCheckMessage = nil
        } catch {
            subscriptionSyncMessage = "同步失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            subscriptionSyncFailed = true
        }
    }

    @MainActor
    private func fetchSubscription() async {
        fetching = true
        fetchMessage = nil
        defer { fetching = false }
        do {
            let text = try await SubscriptionFetcher.fetch(subURL)
            let count = NodeBuilder.parseTemplatesDetailed(text, keepPorts: effectiveKeepPorts).templates.count
            subText = text
            fetchFailed = false
            fetchMessage = "已拉取，识别到 \(count) 个节点"
        } catch {
            fetchFailed = true
            fetchMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: 输出

    private func outputSection(ipCount: Int, templateCount: Int) -> some View {
        let nodes = savedNodes
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("优选节点").font(.headline)
                Spacer()
                countPill("\(nodes.count) 个")
            }

            if nodes.isEmpty {
                Text(emptyHint(ipCount: ipCount, templateCount: templateCount))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            } else {
                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = nodes.map(\.link).joined(separator: "\n")
                        copied = "已复制 \(nodes.count) 条节点"
                    } label: {
                        Label("复制全部", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(PillButtonStyle(filled: false))

                    Button {
                        Task { await syncSubscription(nodes.map(\.link)) }
                    } label: {
                        HStack(spacing: 6) {
                            if publishingSubscription { ProgressView().tint(.white).controlSize(.small) }
                            else { Image(systemName: "link") }
                            Text(publishingSubscription ? "同步中" : "同步订阅")
                        }
                    }
                    .buttonStyle(PillButtonStyle())
                    .disabled(publishingSubscription)
                }

                if let message = subscriptionSyncMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(subscriptionSyncFailed ? Color.red : Color.green)
                }
                if lastSyncTime > 0 {
                    HStack(spacing: 4) {
                        Text("上次同步")
                        Text(Date(timeIntervalSince1970: lastSyncTime), style: .relative)
                        Text("前 · \(lastSyncInfo)")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if syncIsStale {
                    Text("订阅已经超过 12 小时没有更新，优选 IP 可能已过期，建议重新点「优选 IP 替换」。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if !subscriptionLinkForDisplay.isEmpty {
                    Button {
                        UIPasteboard.general.string = subscriptionLinkForDisplay
                        copied = "已复制订阅链接"
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "link").font(.caption)
                            Text(subscriptionLinkForDisplay)
                                .font(.system(.caption2, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                            Image(systemName: "doc.on.doc").font(.caption)
                        }
                        .foregroundStyle(.secondary)
                        .fieldBox()
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 10) {
                        Button {
                            Task { await checkSubscriptionLink() }
                        } label: {
                            HStack(spacing: 6) {
                                if checkingSub { ProgressView().controlSize(.small) }
                                else { Image(systemName: "checkmark.shield") }
                                Text(checkingSub ? "检测中" : "检测订阅")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PillButtonStyle(filled: false, compact: true))
                        .disabled(checkingSub || rotatingLink)

                        Button {
                            confirmRotate = true
                        } label: {
                            HStack(spacing: 6) {
                                if rotatingLink { ProgressView().controlSize(.small) }
                                else { Image(systemName: "arrow.triangle.2.circlepath.circle") }
                                Text(rotatingLink ? "重置中" : "重置链接")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PillButtonStyle(tint: .red, filled: false, compact: true))
                        .disabled(checkingSub || rotatingLink || publishingSubscription)
                    }
                    if let m = subCheckMessage {
                        Text(m)
                            .font(.caption)
                            .foregroundStyle(subCheckOK ? Color.green : Color.red)
                    }

                    // 各客户端专用订阅：同一个固定链接，用 target 参数选择格式
                    VStack(alignment: .leading, spacing: 8) {
                        Text("按客户端复制订阅").font(.caption).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(Self.clientFormats, id: \.target) { f in
                                Button {
                                    UIPasteboard.general.string = clientSubscriptionURL(target: f.target)
                                    copied = "已复制 \(f.title) 订阅"
                                } label: {
                                    Text(f.title).lineLimit(1).minimumScaleFactor(0.8)
                                }
                                .buttonStyle(PillButtonStyle(filled: false, compact: true))
                            }
                        }
                        Text("Clash / sing-box / Surge 订阅不含它们不支持的节点（如 xhttp，Surge 不含 VLESS）；这些客户端直接填通用链接时会按 User-Agent 自动识别格式。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 0) {
                    ForEach(Array(nodes.enumerated()), id: \.offset) { index, node in
                        Button {
                            UIPasteboard.general.string = node.link
                            copied = "已复制 \(node.name)"
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(node.name).font(.subheadline.weight(.medium))
                                Text(node.link)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if index < nodes.count - 1 { Divider() }
                    }
                }
            }
        }
        .card()
    }

    private static let clientFormats: [(title: String, target: String)] = [
        ("v2rayN / Shadowrocket / NekoBox", "base64"),
        ("Clash / Mihomo / Stash", "clash"),
        ("sing-box / Hiddify", "singbox"),
        ("Surge", "surge")
    ]

    private func clientSubscriptionURL(target: String) -> String {
        let base = subscriptionLinkForDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
        return base + (base.contains("?") ? "&" : "?") + "target=\(target)"
    }

    @MainActor
    private func checkSubscriptionLink() async {
        checkingSub = true
        subCheckMessage = nil
        defer { checkingSub = false }
        let r = await SubscriptionWorkerManager.checkSubscription(subscriptionLinkForDisplay)
        subCheckOK = r.ok
        subCheckMessage = r.message
    }

    @MainActor
    private func rotateSubscriptionLink() async {
        let links = savedNodes.map(\.link)
        guard !links.isEmpty else {
            subscriptionSyncFailed = true
            subscriptionSyncMessage = "没有可同步的节点，请先点「优选 IP 替换」"
            return
        }
        rotatingLink = true
        subscriptionSyncMessage = nil
        subCheckMessage = nil
        defer { rotatingLink = false }
        do {
            let url = try await SubscriptionWorkerManager.rotateLink(nodes: links, customDomain: sourceDomain)
            subscriptionLinkForDisplay = url
            UIPasteboard.general.string = url
            subscriptionSyncFailed = false
            subscriptionSyncMessage = "订阅链接已重置并复制，旧链接已失效，客户端里要换成新链接"
            lastSyncTime = Date().timeIntervalSince1970
            lastSyncInfo = "\(links.count) 条 · 重置链接"
        } catch {
            subscriptionSyncFailed = true
            subscriptionSyncMessage = "重置失败：" + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func emptyHint(ipCount: Int, templateCount: Int) -> String {
        if ipCount == 0 { return "暂无可用 IP" }
        if templateCount == 0 { return "添加订阅或节点模板后开始" }
        return "点击优选 IP 替换生成节点"
    }

    /// 同步过程中的软提示（如域名被占用但已改用现有地址）：取走并清掉，避免下次误报。
    private func consumeSubscriptionNotice() -> String? {
        let d = UserDefaults.standard
        defer { d.removeObject(forKey: "cf.subscription.notice") }
        return d.string(forKey: "cf.subscription.notice")
    }

    @MainActor
    private func syncSubscription(_ links: [String]) async {
        publishingSubscription = true
        subscriptionSyncMessage = nil
        subscriptionSyncFailed = false
        defer { publishingSubscription = false }
        do {
            let url = try await SubscriptionWorkerManager.syncAndGetURL(nodes: links, customDomain: sourceDomain, bindDomain: "")
            UIPasteboard.general.string = url
            subscriptionLinkForDisplay = url
            subscriptionSyncMessage = consumeSubscriptionNotice() ?? "已同步，订阅链接已复制"
            lastSyncTime = Date().timeIntervalSince1970
            lastSyncInfo = "\(links.count) 条 · 手动同步"
            subCheckMessage = nil
        } catch {
            subscriptionSyncFailed = true
            subscriptionSyncMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func countPill(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }

    // MARK: 高级

    private func advancedSection(_ templates: [NodeTemplate], merged: Int) -> some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 22) {
                templateSection(templates, merged: merged)
                optionsSection
                commandsSection
            }
            .padding(.top, 14)
        } label: {
            Label("高级", systemImage: "slider.horizontal.3")
                .font(.headline)
        }
        .tint(.secondary)
        .card()
    }

    private func templateSection(_ templates: [NodeTemplate], merged: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("节点模板").font(.subheadline.weight(.semibold))
                Spacer()
                Button("粘贴") {
                    if let s = UIPasteboard.general.string { templateText = s }
                }
                .font(.subheadline.weight(.medium))
                if !templateText.isEmpty {
                    Button("清除") { templateText = "" }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.red)
                }
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $templateText)
                    .font(.system(.caption, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minHeight: 100, maxHeight: 170)
                if templateText.isEmpty {
                    Text("vless:// vmess:// trojan:// …")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .padding(6)
            .background(Color(uiColor: .tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if !templates.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(templates.enumerated()), id: \.element.id) { index, t in
                        templateRow(t)
                        if index < templates.count - 1 { Divider() }
                    }
                }
            }
        }
    }

    private func templateRow(_ t: NodeTemplate) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(t.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text("\(t.label) · \(t.host):\(t.port)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            statusPill(t.status)
        }
        .padding(.vertical, 9)
    }

    private func statusPill(_ s: CDNStatus) -> some View {
        let text: String
        let color: Color
        switch s {
        case .ready:
            text = "可优选"
            color = .green
        case .needsDomain:
            text = "需填域名"
            color = .orange
        case .direct:
            text = "直连"
            color = .gray
        }
        return Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("生成选项").font(.subheadline.weight(.semibold))

            TextField("Cloudflare 域名（可选）", text: $domain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .fieldBox()

            Toggle("强制替换直连协议", isOn: $force)
                .font(.subheadline)

            if !onePerIP {
                Toggle("保留订阅里的多个端口", isOn: $keepPorts)
                    .font(.subheadline)
            }

            Toggle("后台自动更新订阅", isOn: $autoRefresh)
                .font(.subheadline)
            Text("由 iOS 决定执行时间（大约每隔几小时），不保证按时执行；需要先同步过一次订阅，并且排行榜里有记录。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Stepper(value: $maxNodes, in: 10...100, step: 10) {
                Text("最多生成 \(maxNodes) 条节点").font(.subheadline)
            }
        }
    }

    private var commandsSection: some View {
        DisclosureGroup {
            VStack(spacing: 0) {
                ForEach(Array(installCommands.enumerated()), id: \.element.id) { index, c in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(c.title).font(.subheadline.weight(.medium))
                            Spacer()
                            Button("复制") {
                                UIPasteboard.general.string = c.command
                                copied = "已复制 \(c.title)"
                            }
                            .font(.caption.weight(.semibold))
                        }
                        Text(c.command)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 10)
                    if index < installCommands.count - 1 { Divider() }
                }
            }
            .padding(.top, 6)
        } label: {
            Label("VPS 安装命令", systemImage: "terminal")
                .font(.subheadline.weight(.semibold))
        }
        .tint(.secondary)
    }
}
