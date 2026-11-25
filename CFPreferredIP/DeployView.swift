import SwiftUI
import UIKit

// MARK: - Cloudflare 部署页

struct DeployView: View {
    let onGoNodes: () -> Void

    @StateObject private var vm = DeployViewModel()

    @AppStorage("cf.deploy.account") private var accountID = ""
    @AppStorage("cf.deploy.name") private var workerName = "edgetunnel"
    @State private var customDomain = ""
    @State private var sourceURL = DeploySource.main

    @State private var tokenInput = ""
    @State private var copied: String?
    @State private var tokenSubmitting = false
    @State private var tokenSubmitted = false
    @State private var tokenError: String?
    @State private var domainSubmitted = false
    @State private var dangerAction: DangerAction?

    private enum DangerAction: String, Identifiable {
        case node, subscription
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                tokenSection
                domainSection
                runSection
                if !vm.steps.isEmpty { stepsSection }
                if let r = vm.result { resultSection(r) }
                if vm.hasSavedToken { dangerSection }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 96) }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .onAppear {
            loadWorkerOptions(workerName)
            vm.restore(workerName: workerName)
        }
        .onChange(of: workerName) { newName in
            loadWorkerOptions(newName)
            vm.switchWorker(workerName: newName)
        }
        .onChange(of: customDomain) { value in
            domainSubmitted = false
            UserDefaults.standard.set(value, forKey: workerOptionKey(workerName, "customDomain"))
            // 部署域名只作节点入口改写用（节点页经回退链读取），不再写进订阅绑定域名：
            // 入口域名绑在节点 Worker 上，拿去绑订阅 Worker 必然冲突。
        }
        .onChange(of: tokenInput) { _ in
            tokenSubmitted = false
            tokenError = nil
        }
        .onChange(of: sourceURL) { value in
            UserDefaults.standard.set(value, forKey: workerOptionKey(workerName, "sourceURL"))
        }
        .confirmationDialog(
            dangerAction == .node ? "删除节点 Worker 和 KV？" : "删除订阅 Worker 和 KV？",
            isPresented: Binding(get: { dangerAction != nil }, set: { if !$0 { dangerAction = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                let action = dangerAction
                dangerAction = nil
                Task {
                    if action == .node { await vm.destroyNodeDeployment(workerName: workerName) }
                    else { await vm.destroySubscriptionDeployment() }
                }
            }
            Button("取消", role: .cancel) { dangerAction = nil }
        } message: {
            Text(dangerAction == .node
                 ? "会在 Cloudflare 上真正删除节点 Worker 和它的 KV，无法恢复。原来的订阅和节点会全部失效。"
                 : "会在 Cloudflare 上真正删除订阅 Worker 和 KV，无法恢复。客户端里的订阅链接会失效，重新同步会生成新的。")
        }
        .alert("已复制", isPresented: Binding(get: { copied != nil }, set: { if !$0 { copied = nil } })) {
            Button("好") {}
        } message: { Text(copied ?? "") }
    }

    private func submitDomain() {
        let value = customDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(value, forKey: workerOptionKey(workerName, "customDomain"))
        domainSubmitted = true
    }

    private func submitToken() {
        let input = tokenInput
        tokenSubmitting = true
        tokenSubmitted = false
        tokenError = nil
        Task {
            let error = await vm.submitToken(input)
            tokenSubmitting = false
            if let error {
                tokenError = error
            } else {
                tokenInput = ""
                tokenSubmitted = true
            }
        }
    }

    private func workerOptionKey(_ name: String, _ field: String) -> String {
        "cf.deploy.worker.\(name).\(field)"
    }

    private func loadWorkerOptions(_ name: String) {
        let defaults = UserDefaults.standard
        let domainKey = workerOptionKey(name, "customDomain")
        let sourceKey = workerOptionKey(name, "sourceURL")
        if let savedDomain = defaults.string(forKey: domainKey) {
            customDomain = savedDomain
        } else if name == "edgetunnel", let legacy = defaults.string(forKey: "cf.deploy.domain") {
            customDomain = legacy
            defaults.set(legacy, forKey: domainKey)
        } else {
            customDomain = ""
        }
        if let savedSource = defaults.string(forKey: sourceKey) {
            sourceURL = savedSource
        } else if name == "edgetunnel", let legacy = defaults.string(forKey: "cf.deploy.source") {
            sourceURL = legacy
            defaults.set(legacy, forKey: sourceKey)
        } else {
            sourceURL = DeploySource.main
        }
    }

    // MARK: 域名

    private var domainSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("第 2 步：自定义域名（可选）")
                .font(.headline)

            HStack(spacing: 8) {
                TextField("例如 node.example.com；没有就留空", text: $customDomain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .fieldBox()

                Button("提交") { submitDomain() }
                    .buttonStyle(.borderedProminent)
            }

            Text("填写后优先使用你的域名；不填写就自动使用 Cloudflare 免费域名。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if domainSubmitted {
                Text("已提交，部署时直接使用此设置。")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .card()
    }

    // MARK: 令牌

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("第 1 步：填 API 令牌")
                .font(.headline)

            Text("打开预设权限页，创建令牌后粘贴回来即可。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Link(destination: URL(string: "https://dash.cloudflare.com/profile/api-tokens?permissionGroupKeys=%5B%7B%22key%22%3A%22workers_scripts%22%2C%22type%22%3A%22edit%22%7D%2C%7B%22key%22%3A%22workers_kv_storage%22%2C%22type%22%3A%22edit%22%7D%2C%7B%22key%22%3A%22account_settings%22%2C%22type%22%3A%22read%22%7D%2C%7B%22key%22%3A%22zone%22%2C%22type%22%3A%22read%22%7D%2C%7B%22key%22%3A%22workers_routes%22%2C%22type%22%3A%22edit%22%7D%5D&accountId=%2A&zoneId=all&name=CFPreferredIP%20Deploy")!) {
                Label("一键打开预设权限页面", systemImage: "arrow.up.right.square")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .buttonStyle(PillButtonStyle())

            HStack(spacing: 8) {
                SecureField(vm.hasSavedToken ? "令牌已安全保存，留空即可沿用" : "粘贴刚创建的 API 令牌", text: $tokenInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .fieldBox()

                Button(tokenSubmitting ? "验证中…" : "提交") { submitToken() }
                    .buttonStyle(.borderedProminent)
                    .disabled(tokenSubmitting || tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if tokenSubmitted {
                Text("令牌已提交保存，下一步部署直接使用。")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if let tokenError {
                Text(tokenError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("令牌只保存在本机钥匙串，账户会自动识别。")
                .font(.caption)
                .foregroundStyle(.secondary)

        }
        .card()
    }

    // MARK: 执行

    private var runSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                to: nil, from: nil, for: nil)
                let t = tokenInput
                Task {
                    await vm.run(tokenInput: t, accountInput: accountID, workerName: workerName,
                                 customDomain: customDomain, sourceURL: sourceURL)
                    if vm.hasSavedToken { tokenInput = "" }
                    // 部署完成后停留在本页；结果区有「去生成优选节点」按钮，用户自己决定何时过去。
                }
            } label: {
                HStack(spacing: 8) {
                    if vm.running { ProgressView().tint(.white) }
                    Text(vm.running ? "正在部署…" : "开始部署")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(PillButtonStyle())
            .disabled(vm.running)

            if let n = vm.notice {
                Text(n)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var stepsSection: some View {
        VStack(spacing: 0) {
            ForEach(Array(vm.steps.enumerated()), id: \.element.id) { index, s in
                HStack(alignment: .top, spacing: 10) {
                    stepIcon(s.state)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.title).font(.subheadline.weight(.medium))
                        if !s.detail.isEmpty {
                            Text(s.detail)
                                .font(.caption)
                                .foregroundStyle(s.state == .failed ? Color.red : Color.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
                if index < vm.steps.count - 1 { Divider() }
            }
        }
        .card(padding: 14)
    }

    @ViewBuilder
    private func stepIcon(_ s: DeployStep.State) -> some View {
        switch s {
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .skipped:
            Image(systemName: "minus.circle.fill").foregroundStyle(.gray)
        }
    }

    // MARK: 结果

    private func resultSection(_ r: DeployResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("部署信息").font(.title3.bold())

            VStack(spacing: 0) {
                infoRow("订阅地址", r.subscriptionURL)
                Divider()
                infoRow("管理后台", r.adminURL)
                Divider()
                infoRow("管理密码", r.admin)
                Divider()
                infoRow("UUID", r.uuid)
                if let d = r.workersDevHost, r.customHost != nil {
                    Divider()
                    infoRow("workers.dev", d)
                }
            }
            .padding(.horizontal, 14)
            .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            Text("管理密码和订阅地址都是私密信息，截图时注意遮挡。点任意一行可复制。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                onGoNodes()
            } label: {
                Text("去生成优选节点").frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle())
        }
    }

    private var dangerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("危险操作").font(.title3.bold()).foregroundStyle(.red)
            Button(role: .destructive) {
                dangerAction = .subscription
            } label: {
                Text("删除订阅 Worker 和 KV").frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(tint: .red, filled: false))
            .disabled(vm.dangerBusy)

            Button(role: .destructive) {
                dangerAction = .node
            } label: {
                Text("删除节点 Worker 和 KV（\(workerName)）").frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(tint: .red, filled: false))
            .disabled(vm.dangerBusy)

            if vm.dangerBusy { ProgressView().frame(maxWidth: .infinity) }
            if let m = vm.dangerMessage {
                Text(m).font(.caption).foregroundStyle(m.hasPrefix("删除失败") ? Color.red : Color.green)
            }
            Text("会在 Cloudflare 上真正删除，无法恢复，删除前会再确认一次。如果给 Worker 绑定过自定义域名，请到 Cloudflare 后台确认已解绑。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            copied = title
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

}
