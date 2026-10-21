# v0.4.1 验证记录 · 2026-10-21

## GitHub macOS CI：通过

- 验证提交：`38c1bcbc5c0c33ac32a27a6ad2426c3530daead9`。
- [Native CI #2](https://github.com/qianquandong/WatchingU/actions/runs/39549608563)：全部通过，运行于 GitHub 托管 macOS 15、Xcode 26.3。
- 生产 C 规则：40,045 条断言通过。
- SwiftPM：35 项测试，0 失败。
- iPhone 与 Watch：两个 scheme 的通用模拟器无签名编译、资源编译和链接通过。手机构建包含配套 Watch 应用。
- 对应运行保留日志、Swift xUnit 和两个 xcresult，保留 7 天。

首轮编译两端均通过，Swift 测试发现 macOS 跳过了仅对 iOS 启用的存储校验入口。现已移除该条件，使共享接收协议在所有平台验证迟到片段，并增加重新打开存储、重复收到旧封闭清单后仍保留阻止标记与音频的检查。第二轮完整测试和编译均通过。

## Swift 测试覆盖

- StorageTests：8 项真实临时文件、清理、引用与云端证明测试。
- ScheduleTests：10 项边界、夏令时、夜间窗口、配置和保留策略测试。
- DayArchiveTests：10 项缺片段、缺证明、账户、清单冲突、迟到片段、幂等、账目持久、活动录音和草稿保护测试。
- BackupClockTests：7 项备份时间、跨午夜、旧配置迁移和夏令时测试。

## TestFlight 流程

- 手动 main 工作流：校验配置，运行完整 CI，签名归档 iPhone 与内嵌 Watch，导出并验证 IPA，再上传 App Store Connect。
- 支持 API 密钥自动签名，以及 Apple Distribution P12 与两个分目标描述文件的手动签名。
- TestFlight 上传要求 Xcode 26 和 iOS／watchOS 26 SDK 或更高版本；脚本在打包前检查。
- 一次性 Mac 配置脚本把用户提供的密钥送入 GitHub Secrets，固定目标为 github.com/qianquandong/WatchingU，不打印私钥，不启动工作流。
- Shell、YAML、内嵌 Python、SDK 边界以及模拟配置／导出校验已检查；这些不能替代真实 Apple 签名上传。

## 尚未验证

- Apple 真实签名、App Store Connect 上传、处理和 TestFlight 安装。
- 真实 Google OAuth、Drive 文件上传或真实录音清理。
- Apple Watch 通知动作、冷启动、22:00 锁屏停止、音频边界和中断恢复。
- WCSession 夜间交付、重启恢复、iPhone 后台唤醒和通知实际送达。
- 08:00–22:00 真机 14 小时录音覆盖率、质量、能耗与缓存。

CI 没有设置真实设备提醒，也没有删除真实录音。源码默认值在安装并授权后才生效。
