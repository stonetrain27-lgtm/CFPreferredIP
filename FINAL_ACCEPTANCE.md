# CFPreferredIP 1.1（Build 12）最终验收清单

对照来源：`Claude对话-CFPreferredIP改进清单.pdf`（2026-11-23，2 页）。本文件将原清单逐项对应到最终源码，并明确区分代码完成与外部环境验收。

## A. Claude 通读 v10 后提出的六项

| 原问题 | 最终处理 | 状态 |
|---|---|---|
| 下载测速单连接、慢且不稳 | 每个候选 IP 使用 3 条独立 TLS 流并发聚合；每条请求 32 MB，默认测量 6 秒；按实际收到的 body 字节计算 MB/s | 已实现 |
| 未过滤回源 / 非 Cloudflare 响应 | 下载响应必须有 `cf-ray` 或 `server: cloudflare`；HTTPS trace 验证仍要求 `colo=` | 已实现 |
| 零速度 IP 仍留在有效结果 | 已测速候选若没有正速度或低于 0.05 MB/s，会从本轮有效结果移除；未进入测速 Top-N 的条目标记为“未测速” | 已实现 |
| HTTP chunked / Content-Length 计数偏差 | 解析 HTTP header、Content-Length、chunked 终止块与 trailer；拒绝重复冲突长度、chunked + Content-Length、非 identity Content-Encoding、非法长度、异常 chunk size 和截断响应 | 已实现 |
| 清除不彻底 | 清除当前 Worker 的 Keychain 凭据、共享 API Token、Account ID、订阅 URL、订阅缓存、手动节点模板和独立订阅 Worker 密钥 | 已实现（只清本机） |
| 上游脚本使用可变 main | 默认固定到 commit `a8ab11125ece9bc27983f609a6359be81b21050c`；Raw 与 jsDelivr fallback 使用同一个 SHA | 已实现 |
| 部署页多个 Worker 状态互相覆盖 | customHost、devHost、customDomain、sourceURL 按 Worker 名称隔离；旧 edgetunnel 全局项迁移 | 已实现 |
| API 权限和变量名未实测 | 已按 Cloudflare 当前 API 文档核对 Worker 上传、域名绑定、Zone 查询和 KV Namespace 操作的接受权限；上传配置写入 `KV`、`ADMIN`、`UUID`、`KEY` | 文档/静态配置已核对；真实账户未实测 |
| 订阅只支持 Base64 | 新增常见 Clash `proxies:` YAML 子集转换；遇到未知字段、Reality、插件、跳过证书验证等无法无损转换的内容时整体拒绝 | 已实现（不是完整 YAML 规范） |

## B. John 提出的四类功能

### 1. 累积速度排行榜

- 每轮扫描把正速度 IP 合并进持久化排行榜。
- 通过规范化 IP 地址去重；重复 IP 以最新成功测速数据覆盖。
- 速度从高到低排序，最多保存 100 条。
- 排行榜重测重新执行 TCP、HTTPS 和下载验证；完整失败项移除。
- 用户中途停止时，已完成失败项移除，未完成项保留。
- 节点生成直接取排行榜前 N 个 IP。
- 保留一键清空排行榜。
- 旧“最近测试”快照 UI 与存储已移除；启动时清除旧历史 key。

**状态：代码实现完成**

### 2. 节点页改版

- 普通流程只显示订阅 URL 输入、粘贴和“优选 IP 替换”。
- 填写订阅 URL 时，点击替换会先重新拉取，不会因为本地有旧缓存而跳过。
- 原始节点模板默认隐藏在“高级设置与手动节点”中。
- 生成结果初始隐藏，点击替换后逐条显示。
- 全局生成上限硬性限制为 20 条，多个模板按 IP 轮询，避免前面的模板独占全部名额。
- 只替换连接地址和节点名称；保留 SNI、Host、路径、UUID、端口和其他协议参数。
- 只有模板地址本身是 IP 且模板没有域名时，才允许高级设置域名补 SNI / Host。

**状态：代码实现完成**

### 3. IP 段二级设置页

- 设置首页只显示 IP 段入口及网段数量。
- 二级页支持编辑网段、恢复默认、从 Cloudflare 官方 IPv4 / IPv6 地址列表更新。
- 支持随机抽取网段子集；IPv4 / IPv6 分别抽样，完整列表保留。
- IPv4 / IPv6 开关与每段抽样数量步进器保留。
- 扫描前校验 CIDR；发现无效网段会停止并提示，不静默跳过。
- 重叠网段生成的重复 IP 会去重。

**状态：代码实现完成**

### 4. 独立订阅 Worker

- 固定 Worker 名称 `cfpreferredip-subscription`，不复用 edgetunnel Worker 或 KV。
- 使用独立 KV，公开 GET 路径为随机密钥；更新接口使用独立 Bearer 密钥。
- 订阅正文为纯文本，一行一条节点链接，不做 Base64。
- 节点替换后自动更新已部署 Worker 的 KV；订阅 URL 保持稳定。
- 提供“同步并复制订阅链接”按钮。
- 支持 workers.dev 与独立自定义域名；自定义域名设置与 edgetunnel 分离。
- 订阅路径密钥、更新密钥、KV ID、host 均保存到 Keychain。
- 上传前保存可恢复密钥；失败后重试复用原路径密钥和同名 KV。
- 自动更新时若发现远端 Worker 不存在，或 KV 写入失败，会尝试按同一配置重新部署恢复。
- 不自动删除远端 Worker / KV，避免误删用户资源。

**状态：代码实现完成**

## C. Cloudflare 权限文档核对

- Worker 上传与自定义域名绑定：`Workers Scripts Write`。
- KV Namespace 列表 / 创建 / 写入：`Workers KV Storage Write`。
- Zone 查询：`Zone Zone Read`。
- Account ID 自动枚举若被账户读取权限阻止，可手动填写 Account ID。

官方文档：
- https://developers.cloudflare.com/api/resources/workers/subresources/scripts/methods/update/
- https://developers.cloudflare.com/api/resources/workers/subresources/domains/methods/update/
- https://developers.cloudflare.com/api/resources/workers/subresources/scripts/methods/search/
- https://developers.cloudflare.com/api/resources/zones/methods/list/
- https://developers.cloudflare.com/api/resources/kv/subresources/namespaces/methods/list/
- https://developers.cloudflare.com/api/resources/kv/subresources/namespaces/methods/create/

文档接受权限不代表当前账户的角色、资源范围或服务状态一定允许调用。真实账户部署仍需实际验证。

## D. 本轮自动化验证

- `swiftc -parse CFPreferredIP/*.swift`：通过（语法解析，不是 iOS SDK 语义编译）。
- `tests/NodeBuilderSmokeTests.swift`：61 项 NodeBuilder / HTTP parser 断言通过，覆盖 VLESS WS、VMess、Clash 常见子集、SNI / Host 保留、未知字段拒绝和 20 条上限。
- `CloudflareAPI.swift` + `CloudflareDeploy.swift` + NodeBuilder：Swift 语义类型检查通过；当前 Linux 环境用 Security / Combine 接口桩做类型检查，不执行真实 Keychain。
- `tests/worker-subscription.test.mjs`：16 项断言通过，覆盖 404、Bearer 鉴权、KV 读写、空 body、大小限制、非法/不匹配 Content-Length 和 KV 故障。
- `node --check worker/subscription/worker.js`：通过。
- `bash -n scripts/run-tests.sh`：通过。
- `Info.plist` plist 解析、`project.yml` YAML 解析：通过。
- ZIP 完整性检查：通过。

## E. 仍需真实设备 / 账户完成的外部验收

以下事项不可能仅凭本地源码或静态测试诚实地标记为通过：

1. macOS Xcode + iOS SDK 的完整 Release 编译、签名与安装。
2. iPhone 真机上 TCP / TLS / 下载测速、后台切换、订阅导入和节点逐条显示体验。
3. 用户自己的 Cloudflare API Token 是否具备正确账户与 Zone 资源权限。
4. edgetunnel 固定 commit 在真实 Cloudflare Worker 中的启动、KV 绑定、管理登录、订阅内容和节点连接。
5. 独立订阅 Worker 在真实账户中的创建、KV 更新、workers.dev / 自定义域名证书生效和外部客户端拉取。

本项目没有接收或保存用户的 Cloudflare Token，也没有对用户账户执行部署。上述限制不影响本地源码和 smoke tests 的完成状态，但属于正式上线前必须执行的验收步骤。
