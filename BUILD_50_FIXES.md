# Build 50 修复说明

## 入口验活
- 将 TLS 握手 SNI 与 WebSocket HTTP Host 拆开处理；模板中两者不相同时，分别使用原值。
- `workers.dev` 被用户自定义域名替换时，只替换对应字段，不覆盖另一个显式域名。
- 入口探测只选择 TLS + WebSocket 的 VLESS / Trojan 模板。TCP、gRPC、Reality 等不适用 HTTP/1.1 WebSocket Upgrade 的模板不会再被误当作验活目标。
- Chrome uTLS 探测和 iOS 原生 TLS 回退均使用相同的 SNI / Host 分离规则。

## 测速设置持久化
- IPv4、IPv6、端口、IPv6 每段抽样数、HTTPS 验证、验证前 N 个、目标可用 IP 数、每 IP 测速秒数、邻近网段二次抽样，以及 IP 段、随机网段和测速地址，均在属性初始化时从 UserDefaults 恢复。
- 用户修改时继续即时写入 UserDefaults；不再依赖 ViewModel 的 init 阶段给 `@Published` 属性赋值来恢复设置。

## 验证情况
- NodeBuilder / HTTP parser / ScanLogic Swift smoke tests：通过。
- Worker subscription tests：16 项通过。
- Worker conversion tests：通过。
- 所有 CFPreferredIP Swift 源文件语法解析：通过。
- Go 源码已 gofmt；当前执行环境无法下载 go1.26 toolchain，未能在本机编译 uTLS / gomobile framework。
- 完整 `scripts/run-tests.sh` 的部署逻辑 type-check 在 Linux 环境因缺少 Apple `CryptoKit` 模块而中断；需在 macOS / Xcode 环境完成最终构建。
