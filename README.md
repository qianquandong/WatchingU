# WatchingU · DayTape 0.5

原生 Apple Watch + iPhone 录音与个人档案应用。手表持续采集，手机负责转写、检索、回顾与备份。独立编写，没有使用 Auday 的安装包、反编译代码或素材。

**这是功能扩展分支，尚未完成签名安装与配对真机验收。** 编译和规则测试不能证明真实 14 小时续航、后台任务准时运行或识别准确率。功能明细见 [docs/FEATURES_0.5.md](docs/FEATURES_0.5.md)，验证记录见 [VALIDATION.md](VALIDATION.md)。

## 功能

- Watch 连续分段录音、音频帧位置的重要时刻标记、中断提示、前台恢复、快捷指令和表盘组件。
- 约 15 分钟的有界批次同步；低电量延后自动传输，手动例外只限本批。手机持久保存并核验后才确认，未确认音频保留在手表。
- iPhone 本机多语言转写、50 秒检查点、暂停续接、任务状态、文字编辑、关键词/本机语义搜索，以及文字定位原声。设备缺少本机模型时明确报错，不静默回退云端。
- 可选云端/自建转写：独立密钥、明确的原声分享开关、实际接收地址与检查点。默认使用本机；变更接收地址后须重新开启分享。自动远程转写只在充电且获得运行机会时进行。
- 用户配置的兼容 AI 服务：有原文引用的高光、决策与行动项、每日总结、反思和历史问答。个人记忆可编辑、停用、删除；AI 建议的记忆默认不启用。
- 长日回顾全量分块、递归合并与持久缓存；显示原文块进度和未完成转写的覆盖缺口，中断后只补未完成块。
- 可选本机说话人区分、三段本人声纹采集与可修正的声音标签。FluidAudio 0.12.4 / Core ML 模型由用户首次准备时下载，不上传录音到模型下载站点。
- 默认关闭的大致地点，以及录音对应时间范围内的心率、HRV SDNN、步数、活动能量与睡眠关联；不把指标当作情绪或医学诊断。
- 按日期/小时批量导出本机原声、TXT/JSON 转写、重要标记、关联与 Markdown/JSON 回顾。跨范围或来源不明的 AI 结果不进入范围导出；已仅存在云端的原声明确列为未包含。
- iPhone 锁屏/主屏小组件、Watch 表盘组件，显示最近保存的状态。系统决定刷新频率，不声称实时读数。
- 按用户选择日期范围的本地加密电脑只读接口与 MCP 客户端；原声读取默认关闭，离开接入页或退后台即撤销本次连接。
- Google Drive 原声与片段元数据的充电自动备份、单次手动备份、超过 24 小时积压提醒、稳定远端 ID、双文件校验和完整日清理保护。转写和回顾另可通过 ZIP 导出。
- 待转写和正在播放/识别/导出的音频不会自动清理。用户可明确删除本机录音与相关文字；云盘副本保留，迟到重传不会恢复已删除内容。

## 录音与备份

固定 America/Chicago 日程：08:00 提醒，用户点通知或开始按钮后才在前台启动麦克风，正常运行的录音会话到 22:00 停止。系统中断可能形成缺口；应用显示中断，不假装已补录。

Watch 到手机与手机到 Drive 是独立两步。手表按批次同步，不必等手表充电。手机云端自动请求需要已知充电/接电满电、符合 Wi-Fi 选项、有前台或 BGProcessing 运行机会。拔电或运行时间到期会取消自动工作并保留文件。已发出的在途字节无法收回。

“立即备份”只对点击时的批次绕过充电条件，仍遵守网络选项。忘记充电会保留本地文件、安排超过 24 小时通知，等下次符合条件时补传；通知受系统权限和 Focus 影响。真实 OAuth/Drive 和配对交付仍需验收。

## 在 Mac 构建

1. 克隆仓库，打开 DayTape.xcodeproj。使用支持 Swift 6 依赖的 Xcode；CI 使用 Xcode 26 系列，部署目标为 iOS 17 / watchOS 10。
2. 在 Local.xcconfig 设置唯一 DAYTAPE_BUNDLE_PREFIX 与 Team。四个 target 使用同一个 App Group；Phone 配置 HealthKit entitlement，默认关闭健康读取。
3. Xcode 解析固定 GoogleSignIn 10.0.0、FluidAudio 0.12.4。先安装 iPhone，再安装配对 Watch；按明确操作授权麦克风、通知和可选位置。
4. 手机选择本机转写语言。远程功能需自己的服务商、模型和密钥；费用由该服务商收取。本机录音/转写/搜索/回放不要求启用远程 AI。
5. Drive 开发配置见 [CLOUD_SETUP.md](CLOUD_SETUP.md)，发布签名及四个 profile 见 [TESTFLIGHT_SETUP.md](TESTFLIGHT_SETUP.md)。普通用户只需登录授权，不应自己申请 OAuth 客户端。
6. 按 [ACCEPTANCE.md](ACCEPTANCE.md)、[docs/REVIEW_FINDINGS.md](docs/REVIEW_FINDINGS.md) 完成脱离调试器的设备回归。

python3 Scripts/generate_project.py 可以确定性重建四 target 工程、Info.plist、entitlements 与 schemes；先保留任何手工 Xcode 改动。

## 检查

```sh
bash Scripts/ci_build.sh
python3 -m venv .build/client-venv
.build/client-venv/bin/python -m pip install -r Tools/requirements.txt
.build/client-venv/bin/python -m unittest discover -s Tools -p 'test_*.py' -v
```

CI 检查 C 规则、Swift 持久化/日期/清单/上下文/加密/ZIP/AI 分块，编译 iPhone、Watch 和各自小组件，并启动 iPhone 模拟器保存真实首页截图。测试不调用付费 AI、不上传真实用户录音，不把假文字当作转写实测。

## 电脑接入

手机设置 → 电脑只读接入，选择日期并开启。手机与电脑用同一 Wi-Fi；把手机复制的连接 JSON 保存为本地私密文件，不放进 Git。

```sh
python3 Tools/daytape_bridge.py --pairing pairing.json status
python3 Tools/daytape_bridge.py --pairing pairing.json search --query "会议"
python3 Tools/daytape_bridge.py --pairing pairing.json --stdio
```

最后一条可作为通用 MCP 客户端的 stdio 命令。工具只有搜索、读某日转写、读已保存回顾/记忆与可选原声，不提供修改、删除或生成付费请求。AES-GCM 密钥每次开启重新随机生成；校验重放、时间戳、长度和完整输入来源范围。关闭接入即撤销本次密钥。

## 实际边界

本机语音/语义模型的可用语言由设备和系统决定，不保证与 Auday 的语言和准确率相同。声音识别是估计，可手动修正。远程 AI 与健康/位置关联均为可选；缺少配置、授权或证据时显示真实状态，不制造结果。

原声通过 HTTPS 上传用户的 Drive，尚未额外实现端到端加密；电脑接口的应用层加密是独立通道。App Groups、HealthKit 和四 target 的真实签名需要相应能力及 profile。模拟器成功不等于 TestFlight 已可安装，也没有证明本应用比苹果自带更省电。

第三方组件和声音模型来源/许可位于 Licenses/，随 Phone bundle 提供并可在设置查看。
