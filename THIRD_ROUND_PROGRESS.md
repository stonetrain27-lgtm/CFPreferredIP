# CFPreferredIP 第三轮进度


## 2026-11-23 — 立即开发（第 1 项）

### 完成
- 节点页订阅区精简：地址输入框 +「粘贴」+「优选 IP 替换」按钮。
- 替换动作：当订阅文本和手动模板均为空、但订阅 URL 已填写时，自动拉取后再显示生成结果。
- 无订阅源时显示明确提示，不触发空结果展示。
- 生成结果区域默认不展示，按用户动作展开/呈现。
- 新增 `worker/subscription/worker.js`：独立纯文本订阅服务 Worker，使用随机路径密钥 GET、独立 Bearer 写入鉴权、KV 保存文本、404 处理、写入 512 KiB 限制、no-store 缓存策略。
- README 更新第三轮内容与独立 Worker bindings。

### 尚未完成 / 需后续
- edgetunnel 上游固定 commit、部署地址/状态按 Worker 名隔离、完整 Cloudflare 权限实测。
- Xcode build、模拟器/真机测试及 Cloudflare Worker 实际部署/端到端验证。
### 验证
- 需在可用 Swift/Xcode 环境进行编译和 UI/网络测试。本环境将先进行可用的静态语法检查和 Worker 逻辑检查，不把静态检查冒充实机编译。

## 2026-11-24 — 第三轮（第 2 项，直接接入）

### 完成
- 独立订阅 Worker 管理接入 Cloudflare API 客户端：固定 Worker 名 `cfpreferredip-subscription`，独立 KV namespace。
- 点击「同步并复制订阅链接」会部署/更新 Worker，配置 KV 与 secret/plain text bindings，并将生成的节点文本写入 KV。
- 路径密钥、更新密钥、Worker host、KV namespace ID 保存到 iOS Keychain；自动解析/使用 Account ID 并本机保存。
- 成功同步后复制固定订阅 URL，并显示可点击 URL。
- 已部署服务后，每次「优选 IP 替换」会自动更新 KV 内容，保持 URL 不变。
- Worker JS 作为 target resource 添加到 XcodeGen project。
- README 更新实际接入说明。

### 验证
- Swift `swiftc -parse`：所有 Swift 源文件通过。
- Node `node --check`：订阅 Worker 语法通过。
- 真实 Cloudflare API 权限、Worker 部署/访问及 Xcode build 尚未实测（环境无 Xcode）。

### 需要继续
- 订阅 Worker 的自定义域名可选绑定。
- 端到端测试并核对 Cloudflare API 所需最小权限。
- 处理 Worker deploy/首次 workers.dev 访问可能延迟、错误状态反馈。
- edgetunnel 上游固定 commit，部署地址/状态按 Worker 名隔离。

## 2026-11-24 — 第三轮（第 3 项）

### 完成
- Cloudflare DeployViewModel 的 workers.dev/customHost 保存键改为 Worker 名称分区，切换 Worker 名会加载对应结果。
- 默认 edgetunnel profile 会迁移旧的全局 host 键，避免升级后丢失原部署信息。
- 清除本地部署配置会移除对应 Worker 的 host 信息；清除默认 edgetunnel 时同步清除独立订阅 Worker 本地密钥和订阅缓存，但不会删除云端 Worker/KV。
- 节点生成结果改为逐条渐显动画，重触发会取消前一次显示任务，离开页面会取消任务。

### 验证
- `swiftc -parse CFPreferredIP/*.swift`：通过。
- Xcode 完整 build 仍待真机/macOS Xcode 环境。

## 2026-11-24 — 第三轮（第 4 项：部署输入安全预检）

### 完成
- Cloudflare API 令牌在部署前调用 token verify endpoint 预检，只有验证状态 active 才继续。
- 令牌验证前不覆盖钥匙串内原有令牌，避免错误令牌污染已保存配置。
- 手动 Account ID 加入 32 位十六进制格式校验。
- 自定义域名输入校验：只接受 hostname，不允许 URL scheme、路径或端口；逐段检查字符和连字符位置。
- edgetunnel 脚本下载源限制为 HTTPS GitHub Raw / jsDelivr，并拒绝 URL 用户信息、query、fragment。
- 部署页面明确提示默认 main 分支未固定 commit，避免把当前安全限制误当作版本固定。

### 验证
- `swiftc -parse CFPreferredIP/*.swift`：通过。
- 令牌真实预检、权限最小集与部署仍需用户 Cloudflare 账户实测。
- 下载源允许列表和格式验证已加入；尚未固定上游 SHA commit。

## 2026-11-24 — 第三轮（第 5 项：排行榜重测停止逻辑修正）

### 修改
- 重测排行榜时，明确跟踪当前测试批次索引。
- 停止重测后：已完成批次中验证成功的 IP 保留、验证失败的 IP 移除；尚未开始的批次原样保留。
- 移除旧停止分支对循环内部 `group` 变量的引用，避免作用域/编译风险。
- 批次中的各阶段（TCP、HTTPS、下载测速）增加取消状态检查，避免取消后继续启动后续测试阶段。

### 验证
- Swift 语法解析：通过。
- Worker JS 语法：通过。
- Xcode/iOS SDK 语义编译、设备网络测试：仍待有 Xcode 的环境执行。

## Update 6（下载重定向来源校验）
- Worker 脚本下载改用独立 ephemeral URLSession，并通过 URLSessionTaskDelegate 校验每次 HTTP 重定向目标仍为 HTTPS 且主机仅限 `raw.githubusercontent.com` / `cdn.jsdelivr.net`，拒绝跳转到其他主机。
- 下载完成后再次检查最终响应 URL 的 scheme、凭据及 host，作为第二道校验。
- Swift 文件语法解析通过；Worker JS 语法检查通过。此检查不等于 Xcode 编译或实际网络行为测试。

## Update7（排行榜取消语义、网段输入校验与去重安全）
- 排行榜重测现在区分“测试完成但失败”与“因取消而未完成”：停止时未完成的当前批次 IP 和后续批次保留，不再被误判为失败删除；已完整测试且失败的 IP 才会被移除。
- 官方 IPv4/IPv6 网段拉取新增严格 CIDR 验证（地址格式与前缀范围），且要求两种地址族都返回有效网段，避免异常响应覆盖原配置。
- 排行榜合并改为逐项构建字典，兼容旧存储可能存在重复 IP，避免 `Dictionary(uniqueKeysWithValues:)` 对重复 key 触发运行时崩溃。
- 验证：Swift 语法解析、Worker JS 语法检查通过；未进行 Xcode 构建、真机测试或 Cloudflare 线上部署。

## Update8（钥匙串写入安全、Cloudflare API 响应校验、订阅 Worker 防御性检查）

### 修改
- Keychain 更新改为优先 `SecItemUpdate`，仅在条目不存在时新增；不再先删除旧凭据再添加，避免写入失败时把原有有效令牌/密钥一并丢失。
- Keychain 空值删除现在区分成功与条目不存在；部署完成后分别检查 ADMIN、UUID、KEY 的持久化结果，失败时明确提示，不再静默忽略。
- Cloudflare API 客户端要求有效 HTTP 响应，并同时验证 HTTP 2xx 与 JSON `success=true`；避免只看 JSON 字段而忽略非成功 HTTP 状态。
- 独立订阅 Worker 对 `Content-Length` 做格式与范围校验，拒绝负数/非数字长度；读写 KV 前检查 binding 是否存在，缺失时返回 503 而不是抛出未处理异常。

### 验证
- Swift `swiftc -parse CFPreferredIP/*.swift`：通过（仅语法解析，非 iOS SDK 语义编译）。
- `node --check worker/subscription/worker.js`：通过。
- Worker smoke tests：错误路径 404、未授权 PUT 404、非法 Content-Length 400、授权 PUT 204、订阅 GET 返回内容 200、KV binding 缺失 503，均通过。
- 未执行 Xcode build、iOS 模拟器/真机、真实 Cloudflare API 部署。


## Update9（Clash 常见节点转换与测速 HTTP framing 加固）

### 修改
- 订阅归一化新增常见 Clash `proxies:` 列表转换，支持基础 VLESS、VMess、Trojan、Shadowsocks、SOCKS5、Hysteria2 字段；WebSocket path/Host、gRPC service name、TLS SNI/fingerprint/ALPN 等可表达字段会映射到节点 URI。
- 对 Reality、SS 插件、跳过证书验证及无法转换/格式错误的 proxy 条目采取整体拒绝策略；混合支持/不支持节点时不再静默丢弃部分节点。
- 下载测速响应头解析改为逐字段、大小写不敏感处理；校验重复/非法 Content-Length，拒绝同时出现 chunked 与 Content-Length 的歧义 framing，以及不支持的 Transfer-Encoding。
- chunked 解析增加长度边界与整数溢出保护，避免异常 chunk size 造成错误计数或越界计算。
- README 明确列出 Clash 解析支持边界，避免误称完整 YAML 支持。

### 验证
- `swiftc -parse CFPreferredIP/*.swift`：通过。
- 使用 Linux Swift 临时 harness（仅为测试兼容性将 Darwin 导入替换为 Glibc，并补入 FoundationNetworking / IPResult 测试桩）验证 VLESS-WS、Trojan-gRPC、SS Clash 样例转换后可被现有 `NodeBuilder.parseTemplates` 识别，共 3/3。
- 尚未执行 Xcode/iOS SDK 语义编译、模拟器/真机订阅导入与真实下载测速；此轮测试不代表完整 Clash YAML 规范兼容。


## Update10（上游固定版本、Worker 配置隔离与部署凭据恢复）

### 修改
- edgetunnel 默认上游从可变 `main` 分支改为固定完整 commit `a8ab11125ece9bc27983f609a6359be81b21050c`；GitHub Raw 下载失败时，jsDelivr 回退使用同一个 SHA。GitHub 提交页面可核验该提交及其 2026-10-08 变更记录。
- 部署页自定义域名和脚本来源由全局 AppStorage 改为按 Worker 名称分别保存，切换 Worker 时加载独立配置。
- 对旧版 `edgetunnel` 的全局域名/脚本来源配置执行一次迁移，其他 Worker 不继承这些旧全局值。
- ADMIN、UUID、KEY 改为在上传前写入 Keychain；三个写入任一失败即停止上传，避免远端 Worker 已创建但本地没有完整密钥的恢复死角。

### 验证
- `swiftc -parse CFPreferredIP/*.swift`：通过（仅 Swift 语法解析）。
- 需在 Xcode/iOS SDK 环境完成语义编译与 UI 行为测试；Cloudflare Token 权限及真实部署仍待实测。

## Update11（独立订阅 Worker 自定义域名与部署恢复）

### 修改
- 节点生成页新增独立订阅 Worker 的可选自定义域名输入，使用单独的 `cf.subscription.customDomain` 设置，不复用 edgetunnel Worker 的域名配置。
- 同步时规范化输入域名并做基础 hostname 校验；通过 Cloudflare Zone 查询获取 zone ID，再调用 Workers Custom Domains API 绑定。
- 在上传 Worker 前持久化订阅路径密钥、更新密钥和 KV Namespace ID；在尝试自定义域名绑定前先保存 `workers.dev` 备用主机。
- 自定义域名绑定失败时保留已部署 Worker、KV 和可用的备用主机信息，并提示修正配置后重试；自定义域名不再依赖 workers.dev 子域名先行开通；没有加入自动删除远端资源的破坏性回滚。
- Cloudflare 当前文档确认绑定接口为 `PUT /accounts/{account_id}/workers/domains`，需要 Workers Scripts Write；Zone 查询还需要 Zone 读取权限。
- 清理本地订阅部署信息时同步清除新增的备用主机 Keychain 项。

### 验证
- `swiftc -parse CFPreferredIP/*.swift`：通过（仅 Swift 语法解析）。
- `node --check worker/subscription/worker.js`：通过（Worker 本体本轮未修改）。
- 尚未执行 Xcode/iOS SDK 语义编译、模拟器/真机 UI 测试、Cloudflare 真实账户部署、Zone 权限验证或自定义域名 DNS/HTTPS 验收。

## Final（2026-11-24）：对照原始 Claude / John 清单完成收尾

### 最终实现
- 下载测速改为每个候选 IP 3 条 TLS 流并发聚合，32 MB 请求、默认 6 秒；验证 Cloudflare 响应标记，低于 0.05 MB/s 或无效测速项不进入有效结果。
- HTTP 下载解析完善 Content-Length、chunked terminal chunk/trailer、Content-Encoding、截断响应和错误状态检查；异常连接或取消不再计为有效速度。
- 累积排行榜规范化 IP 去重、持久化最多 100 条、重测与停止语义保留；旧“最近测试”历史快照界面和 key 移除。
- 节点生成硬性最多 20 条；按 IP 轮询模板；订阅 URL 每次替换前刷新；仅在原地址为 IP 且模板无域名时使用高级域名补齐 SNI/Host。
- Clash YAML 解析增加协议字段白名单和语法错误拒绝，防止不支持字段被静默丢弃。
- 独立订阅 Worker 增加空内容、Content-Length 一致性、KV 读写异常保护；远端 Worker 缺失或 KV 更新失败时自动尝试按保存的密钥恢复部署。
- Cloudflare API GET/PUT 加入有限重试；KV Namespace 查询提高到 per_page=1000；Zone 查询按 Account ID 限定；自定义域名 API 使用 enabled=true。
- Keychain 随机密钥改用 SecRandomCopyBytes；清除本机部署数据时同时清理订阅 URL、订阅内容、手动节点模板与账户 ID。
- README 重写为当前实际功能与限制；新增 FINAL_ACCEPTANCE.md、NodeBuilder 与 Worker smoke tests。

### 最终验证
- `./scripts/run-tests.sh`：NodeBuilder / HTTP parser 61 项断言、Cloudflare 部署逻辑 Swift 类型检查（Linux 使用 Security / Combine 接口桩）、Worker 16 项断言、全部 Swift 源码语法解析通过。
- `node --check worker/subscription/worker.js`：通过。
- Xcode/iOS SDK 编译、iPhone 真机测试、Cloudflare 真实账户部署与 DNS/TLS 生效验收仍未执行；具体边界见 `FINAL_ACCEPTANCE.md`。
