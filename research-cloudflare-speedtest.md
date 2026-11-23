# CloudflareSpeedTest 核查

来源：
- https://github.com/XIU2/CloudflareSpeedTest
- https://github.com/XIU2/CloudflareSpeedTest/issues/168
- https://github.com/XIU2/CloudflareSpeedTest/discussions/490
- https://github.com/XIU2/CloudflareSpeedTest/releases

关键结论：

1. 官方项目默认采用两阶段流程：先进行大量延迟测速并排序，再从低延迟候选中进行下载测速。README 给出的默认参数包括延迟测速线程 200、单 IP 延迟测速 4 次、下载测速数量 10、单 IP 下载测速最长 10 秒。
2. 官方项目支持平均延迟上下限、丢包率上限、下载速度下限。下载速度下限可用于过滤回源 IP 和下载测速为 0 的结果；README 明确指出 Cloudflare 公布的 IP 段包含回源 IP 和任播 IP，回源 IP 可能无法使用。
3. 官方项目的下载测速地址不是永远可靠。维护者说明公益测速地址可能被限速或不可用，建议使用 Cloudflare 官方 __down 接口、自建 Cloudflare Worker 或自己的 CDN 下载地址。可用下载文件建议至少 200MB、最好不超过 512MB；官方讨论还指出当前 __down 接口可能有大小/流量限制。
4. 官方项目在 v2.3.0 增加地区码和 debug，v2.3.5 优化 HTTPing/下载测速完成后的连接释放。
5. 因此当前 iOS 版本速度只有约 4MB/s，不能只归因于 IP 本身。更可能的影响因素包括：测速文件/接口、单次测速时间、候选数量、当前运营商路线、回源 IP、连接释放和实际使用链路。当前代码还把下载测速结果作为单连接吞吐，和官方 Go 工具的多次延迟筛选/速度下限策略并不完全一致。
