# DayTape 0.5 功能与验证边界

记录日期：2026-10-28。本文根据本轮仓库实现编写，不是上架或真机验收证明。最新分支的测试、两端构建、客户端及模拟器启动结果以 [PR #1 Checks](https://github.com/qianquandong/WatchingU/pull/1/checks) 和[分支 CI](https://github.com/qianquandong/WatchingU/actions?query=branch%3Afeat%2Fdaytape-memory-suite) 对应提交为准；历史记录见 `VALIDATION.md`。不能把“代码已实现”写成“所有功能均已验证”。

## 已进入代码的功能

| 功能 | 实现与可见行为 | 主要代码 | 仍需验证 |
|---|---|---|---|
| 手表录音与恢复 | 录音分片保存、状态及错误提示、持久收件确认和补传；不把传输排队当作已云备份。 | `Watch/WatchRecorder.swift`、`Shared/ClipStore.swift`、`Shared/Connectivity.swift` | 实际硬件上的长录音、耗电、中断、磁盘压力和重启恢复。 |
| 充电自动云备份 | iPhone 的电池状态为 charging/full，并满足用户的网络选项，才允许自动 Drive 请求；旧夜间钟点不再作为门槛。 | `Phone/NightArchiveController.swift`、`Shared/ChargingBackupPolicy.swift` | 拔电时取消、Wi-Fi 切换、系统后台机会和 Google 登录刷新。 |
| 手动立即备份 | 仅本轮请求时已经结束的录音可以绕过充电条件；网络限制仍生效，退出执行窗口后不留下长期豁免。 | 同上 | 多次点击、前后台切换、与自动备份同时发生时的行为。 |
| 24 小时积压提醒 | 预安排本地通知，无需全天轮询；通知去重，已无积压时取消。未授权通知不会建立“已安排”标记。忘记充电会保留本地音频。 | `Phone/BackupReminder.swift` | 拒绝后再授权、投递与去重、备份最后一笔时断电、手机重启。 |
| 云校验和本地保留 | 稳定远端 ID，音频及 JSON 分别校验 SHA-256 与字节数，日清单确认后才按保留策略清理；正在播放、上传、导出或处理的音频应受保护。 | `Phone/ArchiveJournal.swift`、`Phone/NightArchiveController.swift`、`Shared/ClipStore.swift` | 请求已到服务器但响应丢失、旧后台上传迁移、账号更换和异常断网。 |
| 本机转写 | Apple 本机语音识别，每窗口不超过 55 秒；串行队列、持久检查点、暂停和重试；设备没有对应本机模型时提示，不自动改用云识别。 | `Phone/Intelligence/LocalSpeechTranscriber.swift`、`IntelligenceController.swift` | 不同语言和设备、系统权限、本机模型可用性、长录音吞吐和取消延迟。 |
| 可选远程／自建转写 | 默认仍为本机，旧设置也不会启用原声分享。用户选择服务、保存独立转写密钥后，还要单独允许向该地址分享原始录音；该授权与只发送文字的远程 AI 开关独立。支持兼容 `audio/transcriptions` 的 JSON／verbose_json 响应，复用 50 秒检查点。 | `Phone/Intelligence/RemoteSpeechTranscriber.swift`、`IntelligenceController.swift`、`IntelligenceViews.swift` | 以对应提交 CI 为准；真实服务兼容性、费用、时间戳、取消及原声授权撤回需另外验收。 |
| 检索与回听 | 关键词检索；语言有本机 NLEmbedding 时提供语义检索，否则说明降级；结果保留原录音位置，可回听。 | `Phone/Intelligence/IntelligenceController.swift`、`IntelligenceViews.swift` | 中文／多语召回、检索耗时与定位准确度。 |
| AI 总结、高光、回顾及历史问答 | 用户显式开启远程 AI 后，使用配置的 HTTPS 接口和模型；密钥存 Keychain；显示原片段引用、覆盖范围和处理错误。自动回顾另有充电要求。 | `Phone/Intelligence/CompatibleAIClient.swift`、`IntelligenceController.swift`、`IntelligenceViews.swift` | 实际服务的兼容性、长上下文流程、引用和行动项质量；不能以引用格式正确代替事实验证。 |
| 个人记忆 | 可添加、修改、停用和删除；AI 建议记忆先保持未启用。 | `Shared/IntelligenceModels.swift`、`Phone/Intelligence/IntelligenceViews.swift` | 修改和删除后派生内容失效、范围导出对未知来源记录的处理。 |
| 重要时刻 | 手表主动标记，持久传输后关联到录音及时间偏移；iPhone 可点击回听。 | `Watch/CaptureWriter.swift`、`Watch/WatchRecorder.swift`、`Shared/RecordingContext.swift` | 分片边界、离线传输、重复包和标记回听。 |
| 本机说话人及本人声纹 | FluidAudio 0.12.4 的实际 Diarizer/WeSpeaker 模型；三段 15 秒采集、删除本人声纹、手动识别已完成转写的录音；模型估计标签可编辑。 | `Phone/Product/VoiceIdentityService.swift` | 模型下载和存储、识别精度、多人重叠、权限取消和耗时；不能称为认证身份或已达到商用品质。 |
| 可选地点与健康关联 | 默认关闭；手表粗略、低频、单次地点采样；iPhone 读取同一时间范围内可用的健康样本。没有数据不补造，不诊断情绪或压力。 | `Watch/WatchLocationSampler.swift`、`Phone/Context/PhoneContextService.swift` | 各项授权、设置跨设备同步、时间区间和实际能耗。 |
| 批量导出 | 按日期、时段选择录音，选择音频、时间戳文字、JSON、回顾和可选关联，生成 ZIP；明确列出云端原声未包含的录音。 | `Phone/Product/ArchiveExport.swift`、`Shared/StoredZIP.swift` | 独立解压、大导出、存储不足、分享生命周期和严格范围控制。 |
| 电脑只读接入 | iPhone 前台主动开启、限定日期和原声权限，随机会话密钥，AES-GCM 加密帧、重放限制；关闭页面或退到后台停止。提供 Python 客户端。 | `Phone/Product/DesktopBridge.swift`、`Shared/BridgeCrypto.swift`、`Tools/daytape_bridge.py` | iPhone 实际网络、Bonjour／权限、畸形连接回收、范围限制及跨语言加密互通。 |
| 小组件／快捷入口 | 录音状态及统计快照，回顾标题由用户选择；标题标为隐私内容；手表入口打开录音操作。 | `Widgets/DayTapeWidgets.swift`、`Watch/RecordingIntent.swift` | App Group、Widget 刷新、锁屏展示和真机启动行为。 |
| 用户删除 | 主动删除本机音频、转写和关联；删除墓碑阻止迟到补传复活。Google Drive 内容保留独立管理。 | `Shared/ClipStore.swift`、`Phone/Product/DayTapeRootView.swift` | 删除中断、存储失败、在途任务及派生 AI 内容清除。 |

代码中的设置和错误提示不代表系统保证在准确时刻执行。BGProcessing 的 `requiresExternalPower` 是请求条件，执行时仍检查实际电源和网络，并在窗口过期时取消任务；云上传没有交给无法严格保证充电条件的常驻后台 URLSession。

远程转写会向所选服务发送实际音频窗口，不属于本机转写的失败回退。自动远程转写另需手机充电；用户主动转写仍需有效运行机会。修改远程转写接收地址会撤销原声分享授权，修改文字 AI 地址也会关闭文字 AI 授权，必须针对新地址重新开启。关闭分享或删除独立转写密钥会停止远程转写并保留原声；已发出的字节无法收回。客户端限制重定向，不把用户授权自动转交其他接收地址。

## 本轮差评样本如何转成要求

调查读取 12 个地区的官方公开评论页，取得 32 条不同文字评论，其中 9 条为 1–3 星，14 条为 4–5 星中的具体意见。官方网页展示数量有限，RSS 未返回评论条目，因此这份样本不是全网或全部历史差评。逐条转述、日期、星级、开发者回应及来源在工作区交付文件 `outputs/Auday差评调查-2026-10-28.md` 和同名 CSV 中。

| 样本问题 | 对本项目的实现要求 | 验收重点 |
|---|---|---|
| 开始无反应、没有留下录音（CN 14698715099；JP 14653004942） | 权限错误可见、真实录音状态、分片持久化及恢复。 | 首次拒绝后授权、录音引擎启动失败、重启后已有分片可用。 |
| 同步长期等待、手表断连（JP 14668848672；GB 14628594194） | 可区分等待、传输、确认和失败；幂等重试，保留未确认音频。 | 离线一整天后恢复，不要求重装，不重复或丢失录音。 |
| 长转写慢、失败或拖慢手机（US 14680261316；JP 14684622415） | 串行限长窗口、检查点、暂停／重试、诚实的后台状态。 | 大量积压、窗口中断、已完成窗口不重做、失败后可继续。 |
| 总结遗漏决策和行动项（US 14671918348） | 依据原片段生成，处理长输入，保留可回听来源及覆盖提示。 | 由人核对事实、决定和行动项；不能只检查模型返回 JSON。 |
| 自配模型不兼容、配置难（JP 14656461526；CN 14705177888） | 显式授权远程 AI、固定非私人文本的连接测试、可定位的错误。 | 至少测试实际支持的每种服务和模型，不声称任意兼容接口都可用。 |
| 多人归属错误、转写质量不足（CN 14713712385 等） | 真实本机声纹模型、保守标签、可手动修正。 | 本人、陌生人和重叠说话的实际样本，避免把模型估计当事实。 |
| 希望删无关录音、暂停方便（CN 14700775405；JP 14656258087） | 可见停止／继续、显式用户删除和迟到补传墓碑。 | 删除后不复活；录音中断留缺口，不伪造连续录音。 |
| 录音被运动／通话打断、耗电（JP 14661548321；14653391421） | 中断提示和恢复诊断；减少传输、定位和处理频率。 | 与系统录音的同条件耗电对照，以及电话、AirPods、Siri、闹钟、运动场景。 |

公开评论是用户报告，不能把每条因果归因或开发者“已修复”的回复当成独立复测结果。本项目也尚无与苹果自带录音、Auday 的续航对照数据，不能承诺更省电或可以连续录一整天。

## 检查与交付状态

- 已有共享逻辑测试覆盖存储、确认、日归档、充电门槛、手动批次截止点、24 小时提醒时点、上下文、ZIP 路径和 CRC，以及加密互通等；测试存在不等于已经在本环境运行。
- 本轮 Windows 静态审查运行了 `git diff --check`。历史提交 `d996bad` 的 [CI 40642265497](https://github.com/qianquandong/WatchingU/actions/runs/40642265497) 中，iPhone／Watch 构建通过；73 项 Swift 测试的失败集中于 ZIP Unicode 读取的 2 个断言，随后改用 Python zipfile 独立读取。它是历史快照，后续修补的结果应在 [PR #1 Checks](https://github.com/qianquandong/WatchingU/pull/1/checks) 或[分支 CI](https://github.com/qianquandong/WatchingU/actions?query=branch%3Afeat%2Fdaytape-memory-suite) 核对。
- 根任务报告 Python 客户端的 3 个测试已通过；这不等于 iPhone 服务端或真实网络已通过。
- `.github/workflows/ci.yml` 调用原生构建、共享测试和客户端测试。CI 全绿之后仍需上述真机验收。
- 本轮发现及修补状态见 `REVIEW_FINDINGS.md`。新功能代码、真实权限和系统调度均未满足“全部已验证”的表述条件。
