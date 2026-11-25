# CFPreferredIP 1.1（Build 12）

iOS Cloudflare IP 优选与节点生成工具，使用 SwiftUI、Network.framework 和 Cloudflare API。最低支持 iOS 16。完整改动对照与未完成的外部验收项见 [`FINAL_ACCEPTANCE.md`](FINAL_ACCEPTANCE.md)。

## 功能总览

### IP 优选

- IPv4 / IPv6 CIDR 抽样，支持编辑完整网段、恢复默认、同步 Cloudflare 官方列表。
- 随机抽取一部分网段用于下一轮测速；IPv4 / IPv6 分别抽样，不会意外抽空其中一个地址族。
- TCP 多次握手平均延迟、HTTPS/TLS 验证和 Cloudflare `colo` 识别。
- 3 条独立 TLS 下载流并发聚合；校验 HTTP 状态、Cloudflare 响应标记、Content-Length / chunked framing 和内容编码。
- 低于 0.05 MB/s、零速度或异常响应的测速候选不会进入累计排行榜，也不会作为本轮有效测速结果显示。
- 累计速度排行榜跨轮次合并、按 IP 去重、最新测速覆盖、速度降序、最多 100 条并持久化。
- 排行榜重测会重新执行 TCP、HTTPS 和下载测速；确认失败的条目移除，停止时未完成的条目保留。

测速速度是当前设备、网络、运营商路由和 Cloudflare 边缘状态下的近似值，不代表长期固定吞吐。下载测速使用 `speed.cloudflare.com`，测试时应关闭会改变路由的代理/VPN，或至少保证所有候选走同一网络路径。

### 节点生成

- 订阅输入只保留「粘贴」和「优选 IP 替换」；填写了订阅 URL 时，替换前会自动重新拉取，避免使用过期缓存。
- 节点结果默认隐藏，点击替换后逐条展示；一次最多生成 20 条。
- 优先使用累计排行榜中的高速 IP。
- 替换连接地址和节点名称，不改动原有 SNI、Host、路径、UUID、端口及其他协议参数。
- 只有原节点地址是 IP、且模板中没有域名时，才使用高级设置中的 Cloudflare 域名补齐 SNI / Host。
- 支持常见 VLESS、VMess、Trojan、Shadowsocks、SOCKS5、Hysteria2、AnyTLS、MTProto 与 Surge 节点格式。
- 支持 Clash YAML 的常见 `proxies:` 子集转换。不是完整 YAML 解析器；遇到 Reality、插件、跳过证书验证、锚点/别名、复杂集合等无法无损转换的配置，会拒绝导入而不是静默丢失参数。

可使用优选 IP 的典型场景是经 Cloudflare 代理的 VLESS / VMess / Trojan + WS、gRPC、HTTPUpgrade 等 TCP/TLS 传输。Reality、Hysteria2/UDP、AnyTLS、普通 SOCKS5、MTProto 等直连协议不会因替换成 Cloudflare IP 而自动获得 Cloudflare 代理能力。

### Cloudflare 部署

- 一键部署 edgetunnel Worker，默认脚本来源固定到不可变提交：[`a8ab11125ece9bc27983f609a6359be81b21050c`](https://github.com/cmliu/edgetunnel/commit/a8ab11125ece9bc27983f609a6359be81b21050c)。
- GitHub Raw 下载失败时回退 jsDelivr 的同一 commit，不回退到可变的 `main`。
- Worker 名称、部署域名和脚本来源按 Worker 名隔离；旧版 edgetunnel 全局配置会迁移。
- ADMIN、UUID、KEY 等部署凭据先写入 iOS Keychain，成功后才上传 Worker。
- 独立订阅 Worker：名称 `cfpreferredip-subscription`，独立 KV，纯文本一行一条节点链接；随机路径密钥用于读取，独立 Bearer 密钥用于更新。
- 独立订阅 Worker 支持 `workers.dev` 和可选自定义域名；自定义域名与 edgetunnel Worker 完全分开。
- 每次重新生成节点可更新已部署订阅 Worker 的 KV 内容，订阅 URL 保持不变。
- 部署恢复信息（订阅路径密钥、更新密钥、KV ID、host）保存在 Keychain；失败后可再次同步，不会自动删除 Cloudflare 远端资源。

## Cloudflare API 令牌权限

建议创建自定义 API Token，并只授权实际使用的账户 / 区域资源：

- **Account → Workers Scripts → Write**：上传 Worker、启用 workers.dev、绑定 Worker 自定义域名。
- **Account → Workers KV Storage → Write**：列出/创建 KV Namespace 并写入 KV 内容。
- **Zone → Zone → Read**：仅在绑定自定义域名时用于查找域名所属 Zone。
- 自动识别 Account ID 时，如果账户列表读取被拒绝，可在部署页手动填写 32 位 Account ID；不需要为此扩大到全局 API Key。

Cloudflare API 文档列出了上述操作对应的接受权限：Worker 上传和自定义域名绑定接受 Workers Scripts Write；KV Namespace 列表/创建接受 Workers KV Storage Write；Zone 查询接受 Zone Zone Read。不同账户成员角色、资源范围和 Cloudflare 产品状态仍可能影响实际调用；应用会显示 API 返回的错误。这里的文档核对不等于使用真实账户完成了端到端部署。

官方 API 参考：[Upload Worker](https://developers.cloudflare.com/api/resources/workers/subresources/scripts/methods/update/)、[Search Worker Scripts](https://developers.cloudflare.com/api/resources/workers/subresources/scripts/methods/search/)、[Attach Worker Domain](https://developers.cloudflare.com/api/resources/workers/subresources/domains/methods/update/)、[List Zones](https://developers.cloudflare.com/api/resources/zones/methods/list/)、[List KV Namespaces](https://developers.cloudflare.com/api/resources/kv/subresources/namespaces/methods/list/)、[Create KV Namespace](https://developers.cloudflare.com/api/resources/kv/subresources/namespaces/methods/create/)。

## 使用步骤

1. 在「设置 → IP 段」确认 IPv4 / IPv6 网段和抽样数量。
2. 在「IP 优选」开始测速，等待累计排行榜出现有效速度条目。
3. 在「Cloudflare 部署」部署 edgetunnel 并自动导入订阅，或在「节点」页粘贴订阅 URL。
4. 点击「优选 IP 替换」，生成最多 20 条节点。
5. 复制节点链接；如需稳定订阅 URL，点击「同步并复制订阅链接」部署/更新独立订阅 Worker。

纯文本订阅可直接用于支持通用 URI 列表的客户端（例如 Shadowrocket、v2rayN）。部分 Clash 客户端要求 Clash YAML，而本项目的独立 Worker 返回的是纯文本 URI 列表，不会伪装成 Clash YAML；可在客户端或订阅转换服务中转换。

## 本机清除与远端资源

「清除本机部署与订阅数据」会删除当前 Worker 的本机部署凭据、共享 API Token、订阅 Worker 密钥与地址、订阅 URL / 内容缓存和手动节点模板。它**不会**删除 Cloudflare 账户中的 Worker 或 KV，也不会自动撤销已经被别人保存的旧订阅 URL。若要让旧订阅路径失效，需要重新部署/同步以轮换路径密钥，或在 Cloudflare 控制台手动管理远端 Worker。

## 构建

项目由 XcodeGen 管理：

```bash
brew install xcodegen
xcodegen generate
open CFPreferredIP.xcodeproj
```

Deployment Target 为 iOS 16.0，Swift 语言版本为 5.9。也可以在 macOS 上执行：

```bash
xcodebuild -project CFPreferredIP.xcodeproj -scheme CFPreferredIP -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO build
```

未签名构建不等于可直接安装到 iPhone；实际安装仍需要合适的签名/分发流程。

## 自动化测试

在 macOS 或具备 Swift 5.9 与 Node.js 的环境运行：

```bash
./scripts/run-tests.sh
```

脚本包含 NodeBuilder / HTTP 下载 parser 的协议与 framing 断言、Cloudflare 部署逻辑 Swift 类型检查、独立订阅 Worker 请求/鉴权/大小限制 smoke tests，以及全部 Swift 文件语法解析。Linux 上的类型检查使用 Security / Combine 接口桩，不执行真实 Keychain；macOS 上则使用系统框架。它们不替代 Xcode/iOS SDK 完整构建、真机网络测试或 Cloudflare 真实账户验收。

## 已知边界

- 本仓库未包含用户的 Cloudflare API Token，因此不能替用户完成真实账户部署、验证账号权限或检查 DNS / TLS 证书生效状态。
- edgetunnel 使用固定上游 commit；绑定变量按 `KV`、`ADMIN`、`UUID`、`KEY` 提交给 Cloudflare。上游 README 明确说明 `ADMIN` 和 `KV` 的部署配置；完整变量在真实账户部署后仍需核验 Worker 运行与订阅输出，不能把静态绑定检查当成运行验收。
- 当前运行环境没有 Xcode / iOS SDK；静态 Swift 语法解析不能视为完整 iOS 编译。请按下方最终验收清单在 macOS / 真机完成平台验收。
- iOS 后台任务时长由系统控制，App 不保证锁屏或切后台后能无限期完成测速。
