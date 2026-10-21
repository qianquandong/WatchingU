# v0.4 · 开发者一次性 Google 配置

本工程是源码原型。没有创建你的 Google 项目、登录 Google、上传真实录音、删除真实文件或在你的设备安装提醒。

**本文件给开发者/自用构建者阅读，不应让每位普通用户执行。**客户端标识随App配置；发布后用户只需在App中选择自己的Google账户并授权。当前工程仍使用占位客户端，真实OAuth配置与设备测试尚未完成。

## Google Drive

1. 使用自己的 Google Cloud 项目，启用 Drive API。在 Google Auth Platform 按页面要求配置应用信息、受众和测试用户（若处于测试状态）。
2. 创建 iOS 类型 OAuth 客户端，Bundle ID 必须等于手机 target 的 PRODUCT_BUNDLE_IDENTIFIER。
3. 将客户端 ID 填进 Local.xcconfig 的 GOOGLE_CLIENT_ID；Google 提供的 REVERSED_CLIENT_ID 填进 GOOGLE_REVERSED_CLIENT_ID。它成为手机的 URL scheme。不要把 web client 或 client secret 当作替代。
4. Xcode 首次联网解析 GoogleSignIn 10.0.0。认证和令牌刷新由官方 SDK 处理；任务清单和录音 JSON 不存 OAuth token。
5. 安装后，在手机“录音与备份”打开“自动备份”，使用官方 Google 登录按钮完成账户选择和 drive.file 授权。连接本身不启用上传，需在下一页完成时间和保留设置。
6. 手机点“完成并开启”后请求备份完成通知；拒绝通知不影响已保存的备份设置。在手表点“启用每日提醒”。手机不重复安装晨间提醒。

Google 的测试状态、管理员政策、授权撤销等可能导致长期授权失效。出现提示时需重新连接；失败不会删除本地录音。容量与账户政策以你的 Google 账户为准。本工程没有云服务后台或支付流程。

## 每日固定时间

默认 America/Chicago 08:00 提醒、22:00 停止。提醒里的开始按钮使用 foreground 动作，让手表进入前台后执行录音，不在后台偷偷启动麦克风。每天不需要重新设置提醒；首次授权后系统保存重复通知请求。

22:00 后手表尝试同步；Drive上传从用户选定的22:00、23:00或自定义夜间时间开始，直到次日08:00。默认值22:00。未传齐的文件排队等候；系统已接管的传输可能延迟完成。计划不是 ChatGPT 定时任务，聊天中的同意并未安装任何设备通知。

本版不需要实时判断入睡，HealthKit 编译开关默认空、使用 NoHealth.entitlements。源码中保留可选旧 SleepMonitor，但当前流程与界面不使用它。完成新版设置会关闭旧睡眠/时间兜底配置。旧设置缺少uploadClock时默认沿用录音停止时间22:00，不破坏之前的录音/备份索引。

## 本地只留一天

“当天完成”要求手表已发出最终清单、手机索引逐段匹配、所有音频与 JSON 均有同一账户的校验回执。只传完手机当前收到的几段，不算当天完成。

保留最近一个完整归档日及更新的本地音频，删除更早而且云端再次通过校验的副本。没有新录音的日期不让最近副本自动过期。若当天有缺失、草稿未恢复、清单冲突、授权变化、正在播放或导出，则保留额外文件。保留数量可能暂时超过一天。

手表在手机持久保存确认后释放音频；手机的“留一天”不会强迫手表也额外保留一天。两端保留少量索引和清单。Drive 历史音频永远不会因本地保留策略被删除。

## 上传协议

每段 M4A 和对应 ISO-8601 时间 JSON 先申请固定 Drive ID，再以 resumable 会话配合后台 URLSession 文件上传。重试发送完整小片段，不实现跨进程逐字节续传。308、会话失效或响应丢失后先按固定 ID 对账，禁止盲目追加。

HTTP 200、完成回调和自填 appProperties 都不是删除证明。需要服务端 ID、trashed=false、size 与 sha256Checksum 对上，音频和 JSON 两份均验证。清理前重新查询云端，并在本地保存、读回回执之后才能删除音频。

## 真机验收前提

Mac + 支持设备系统的 Xcode、已配对的 iPhone / Watch、可用签名 Team、自己的 Google iOS OAuth 客户端与登录账户、麦克风和通知权限。

本工程已准备好配置模板与检查脚本；上述设备登录、签名和编译没有由聊天完成。后台时间、提醒显示、续航及14小时录音完整性需要实测。

## 官方资料

- [Google iOS 集成](https://developers.google.com/identity/sign-in/ios/start-integrating)
- [Google iOS API 授权](https://developers.google.com/identity/sign-in/ios/api-access)
- [GoogleSignIn 10.0.0](https://github.com/google/GoogleSignIn-iOS/releases/tag/10.0.0)
- [Drive 上传](https://developers.google.com/workspace/drive/api/guides/manage-uploads)
- [Drive 服务端文件字段](https://developers.google.com/workspace/drive/api/reference/rest/v3/files)
- [通知前台动作](https://developer.apple.com/documentation/usernotifications/unnotificationactionoptions/foreground)
- [Watch 后台执行](https://developer.apple.com/documentation/watchkit/background-execution)
- [Watch 后台任务](https://developer.apple.com/documentation/watchkit/using-background-tasks)
- [减少网络能耗](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/MinimizeNetworking.html)

核对日期：2026-10-20（达拉斯）。


## 发布前开发者验收

- 完成应用品牌信息、同意页面、受众/发布状态和适用的Google审核；只申请drive.file及SDK登录所需范围。不要向所有普通用户展示“创建客户端”“填Client ID”或让用户绕过未验证App警告。
- 用真实签名App验证GoogleSignInSwift按钮、账户选择、取消、拒绝权限、掉线、过期授权和重新连接。
- 取消引导不改变原备份开关。账户已连接但开关仍关时，需要显示这一状态并提供单独断开按钮。
- 先连接再选时间，最后一次性保存开关、上传时间、Wi-Fi和保留策略。配置错误由开发者处理，普通用户只看可恢复的提示。

官方集成与scope依据：https://developers.google.com/identity/sign-in/ios/start-integrating 、 https://developers.google.com/workspace/drive/api/guides/api-specific-auth 。
