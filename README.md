# CFPreferredIP

一个面向 iOS 的 Cloudflare IP 优选工具，使用 SwiftUI 和 Network.framework 实现。

## 功能

- IPv4 / IPv6 CIDR 随机抽样
- TCP 握手延迟测试
- HTTPS / TLS 验证与 Cloudflare `colo` 识别
- 下载速度测试
- 可取消的网络连接与有限后台任务保护
- Wi-Fi / 蜂窝网络状态显示
- 优选结果复制和 CSV 导出
- 最近 10 次测速历史记录
- 深色模式和 iOS 系统动态布局

## 使用方式

1. 在 Xcode 中创建一个 iOS App 项目，产品名填写 `CFPreferredIP`。
2. 将 `CFPreferredIP/CFPreferredIPApp.swift` 替换到项目中。
3. Deployment Target 建议设置为 iOS 16.0 或更高。
4. 使用真机测试 IPv6、蜂窝网络和后台任务行为。

本工具只适合测试 Cloudflare 地址段，并使用 `speed.cloudflare.com` 作为 TLS SNI 和 HTTP Host。测速结果会受到运营商、Wi-Fi、VPN、代理和当前网络拥塞影响。

## 目录

```text
CFPreferredIP/
└── CFPreferredIPApp.swift
```

## 注意事项

iOS 不允许普通 App 无限期在后台运行。后台任务仅用于在短时间内尽量完成当前测试，系统收回后台时间后程序会取消网络连接。

本项目仅用于网络连通性和性能测试，请遵守当地法律、运营商规则及 Cloudflare 服务条款。
