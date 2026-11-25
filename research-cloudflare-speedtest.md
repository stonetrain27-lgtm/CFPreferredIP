# CloudflareSpeedTest 核查与本项目测速设计

核查参考：
- https://github.com/XIU2/CloudflareSpeedTest
- https://github.com/XIU2/CloudflareSpeedTest/issues/168
- https://github.com/XIU2/CloudflareSpeedTest/discussions/490
- https://github.com/XIU2/CloudflareSpeedTest/releases
- https://speed.cloudflare.com/

## 参考项目结论

1. CloudflareSpeedTest 的典型流程是先进行大量延迟测试并排序，再对较优候选进行下载测速；其 README 提供延迟测试次数、并发数、下载测速数量、速度下限等参数。
2. Cloudflare 公布的 IP 段包含任播 IP，也可能包含不适合作为优选结果的回源 IP。应通过真实 Cloudflare HTTPS 响应、数据中心标识和下载速度下限过滤，而不能只凭 TCP 端口连通判断。
3. 公益测速接口可能限速或暂时不可用；单次下载速度还会受到运营商路由、设备网络、测试端点、连接数量和测量时长影响。
4. 所以单个 IP 测得约 4 MB/s 不能简单归因于 IP 本身。测速工具只能提供当前设备和当前网络路径下的近似比较值，不保证长期吞吐。

## 当前 CFPreferredIP 实现（Update12 最终版）

- 第一阶段：从 CIDR 随机抽样并去重，执行 TCP 延迟测试；第二阶段可选执行 HTTPS/TLS 验证并读取 Cloudflare trace 的 `colo`；第三阶段只对延迟较优的 Top-N 候选执行下载测速。
- 每个候选 IP 使用 3 条独立 TLS 连接并发下载，默认每条请求 `speed.cloudflare.com/__down?bytes=32000000`，最长测量 6 秒，按有效负载字节聚合计算 MB/s。
- 下载响应必须为 2xx，并且包含 `cf-ray` 或 `server: cloudflare`；压缩内容编码、未知 Transfer-Encoding、冲突 Content-Length、chunked + Content-Length、非法长度和截断完成响应均拒绝。
- HTTP parser 独立为 `HTTPDownloadParser.swift`：非 chunked 响应流式计数、不缓存完整下载正文；chunked 解析增量消费 chunk framing，排除 chunk size / CRLF / trailer，只计有效负载字节。
- 聚合速度低于 0.05 MB/s（50 KB/s）或测速无效的候选不进入本轮有效测速结果和累计排行榜。
- 排行榜最多保留 100 个正速度 IP；普通扫描合并成功测速结果，排行榜重测则重新验证并移除完整失败项。

## 与 CloudflareSpeedTest 的差异 / 边界

- 本项目使用 iOS Network.framework 实现，不是 CloudflareSpeedTest 的 Go 实现；并发、时长、连接释放和网络调度行为不同。
- 当前没有实现 CloudflareSpeedTest 全部功能，例如完整丢包率统计、所有延迟阈值策略、地区筛选和自定义下载端点配置。
- `cf-ray` / `server: cloudflare` 与 `/cdn-cgi/trace` 的 `colo` 检查用于降低回源 IP 混入概率，但不能证明某 IP 在所有网络和时间段都可用。
- 下载测试使用 Cloudflare 公共端点；公共端点的限速、区域负载、账户策略或网络路径变化都可能影响结果。
- 本地 smoke tests 覆盖 HTTP header、Content-Length、chunked framing、Cloudflare 标记、截断和异常响应；真实 iPhone 蜂窝/Wi-Fi 路由测速仍需真机执行。
