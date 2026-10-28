# 验证记录

## v0.5 验证入口 · 2026-10-28

- 最新检查结果以 [PR #1 Checks](https://github.com/qianquandong/WatchingU/pull/1/checks) 和[分支 CI](https://github.com/qianquandong/WatchingU/actions?query=branch%3Afeat%2Fdaytape-memory-suite) 对应提交为准。CI 包含共享原生测试、iPhone／Watch／组件构建、Python 客户端测试及 iPhone 模拟器启动截图。
- 每次运行的结论只适用于其标注提交；后续远程转写、授权、取消、数据范围及删除恢复增量需要对应的新检查结果。模拟器构建／启动不证明签名安装、真实录音或配对交付。
- 默认及旧设置仍使用本机转写；文字 AI 授权不允许发送原声。远程 ASR 需要独立转写密钥、明确的音频接收地址及原声分享开关。修改相应服务地址会撤销原有授权，需重新开启。协议兼容性、实际服务收费及授权撤回效果均待真机／真实服务验收。
- Windows 环境已做源码审查和 `git diff --check`；Python 电脑客户端 3 项测试由根任务确认通过。不能据此宣称最新 Swift 测试、iPhone 服务端互通或全部功能已通过。
- 详细功能范围见 `docs/FEATURES_0.5.md`，独立审查问题及回归矩阵见 `docs/REVIEW_FINDINGS.md`。

本轮尚无与苹果自带录音或 Auday 的同条件耗电对照，不能承诺更省电、全天无缺口或后台任务准时执行。Google OAuth／Drive、配对 Watch、声音模型精度、权限与通知投递、HealthKit／位置、分享生命周期及真实 Apple 签名仍需验收。

### v0.5 完整检查快照：76c9096

- [Native CI 40643718236](https://github.com/qianquandong/WatchingU/actions/runs/40643718236) 全部通过：78 项 Swift 测试、40,045 条 C 规则断言、3 项 Python 加密／MCP 客户端测试。
- iPhone、Watch 和两端小组件完成模拟器目标编译；iPhone 模拟器成功安装启动，真实首页截图已经目视检查。
- 该快照涵盖远程转写的配置与协议逻辑；没有调用付费 AI 或实际转写服务。之后的删除恢复修补须查看上方对应提交检查。

### v0.5 历史 CI 快照：d996bad

- 证据：[Native CI 40642265497](https://github.com/qianquandong/WatchingU/actions/runs/40642265497)。该提交 iPhone-build、Watch-build 均通过。
- SwiftPM 执行 73 项测试，失败集中在一个 ZIP Unicode 名称读取场景的 2 个断言。测试原用系统 unzip CLI 按 Unicode 文件名读取，随后改为 Python 标准库 zipfile 独立解析。
- 此处保留当时真实结果。后续修补是否通过须查看上方 PR／分支的对应提交检查，不能把历史结果当作当前最终状态。

## v0.4.1 历史验证记录 · 2026-10-21

### GitHub macOS CI：通过

- 验证提交：`38c1bcbc5c0c33ac32a27a6ad2426c3530daead9`。
- [Native CI #2](https://github.com/qianquandong/WatchingU/actions/runs/39549608563)：全部通过，运行于 GitHub 托管 macOS 15、Xcode 26.3。
- 生产 C 规则：40,045 条断言通过。
- SwiftPM：35 项测试，0 失败。
- iPhone 与 Watch：两个 scheme 的通用模拟器无签名编译、资源编译和链接通过。手机构建包含配套 Watch 应用。
- 对应运行保留日志、Swift xUnit 和两个 xcresult，保留 7 天。

首轮编译两端均通过，Swift 测试发现 macOS 跳过了仅对 iOS 启用的存储校验入口。现已移除该条件，使共享接收协议在所有平台验证迟到片段，并增加重新打开存储、重复收到旧封闭清单后仍保留阻止标记与音频的检查。第二轮完整测试和编译均通过。

### Swift 测试覆盖

- StorageTests：8 项真实临时文件、清理、引用与云端证明测试。
- ScheduleTests：10 项边界、夏令时、夜间窗口、配置和保留策略测试。
- DayArchiveTests：10 项缺片段、缺证明、账户、清单冲突、迟到片段、幂等、账目持久、活动录音和草稿保护测试。
- BackupClockTests：7 项备份时间、跨午夜、旧配置迁移和夏令时测试。

### TestFlight 流程

- 手动 main 工作流：校验配置，运行完整 CI，签名归档 iPhone 与内嵌 Watch，导出并验证 IPA，再上传 App Store Connect。
- 支持 API 密钥自动签名，以及 Apple Distribution P12 与两个分目标描述文件的手动签名。
- TestFlight 上传要求 Xcode 26 和 iOS／watchOS 26 SDK 或更高版本；脚本在打包前检查。
- 一次性 Mac 配置脚本把用户提供的密钥送入 GitHub Secrets，固定目标为 github.com/qianquandong/WatchingU，不打印私钥，不启动工作流。
- Shell、YAML、内嵌 Python、SDK 边界以及模拟配置／导出校验已检查；这些不能替代真实 Apple 签名上传。

### 尚未验证

- Apple 真实签名、App Store Connect 上传、处理和 TestFlight 安装。
- 真实 Google OAuth、Drive 文件上传或真实录音清理。
- Apple Watch 通知动作、冷启动、22:00 锁屏停止、音频边界和中断恢复。
- WCSession 夜间交付、重启恢复、iPhone 后台唤醒和通知实际送达。
- 08:00–22:00 真机 14 小时录音覆盖率、质量、能耗与缓存。

CI 没有设置真实设备提醒，也没有删除真实录音。源码默认值在安装并授权后才生效。
