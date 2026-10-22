# GitHub 自动更新与 Mac App Store 分发准备

分析日期：2026-10-10。本文是基于当前工作区源码与官方文档的实施建议，不表示自动更新、签名公证或商店审核已经完成。官方政策、工具版本与托管配额应在实际发布时再次核对。

> 2026-10-22：直发版已新增 Sparkle、安装保护及预览/公证发布工作流；实际操作见 [GitHub 发布操作](GITHUB_RELEASE.md)。下文保留最初分析，现状和待办以源码、当前操作说明与实测为准。商店分发方案尚未实施。

## 1. 推荐方案

采用**共享业务代码、独立分发产物**：

| 项目 | GitHub 直发版 | Mac App Store 版 |
|---|---|---|
| 应用更新 | Sparkle 2 | Mac App Store |
| 构建与发布自动化 | GitHub Actions | GitHub Actions 构建并上传 App Store Connect |
| 安装包分发 | GitHub Releases | App Store / TestFlight |
| 签名 | Developer ID Application | 商店分发证书与相应 provisioning profile |
| 公证 | Developer ID 分发需走 Apple notarization | 不走直发版公证流程，使用商店提交流程 |
| App Sandbox | 首期可维持现状，同时推进兼容改造 | 必须启用 |
| Sparkle 及其 helper | 包含 | 构建产物中完全排除 |

GitHub 提供构建、托管与版本记录；Sparkle 负责客户端检查、下载验证、替换应用和重启。GitHub Releases 本身不具备替换本机应用的能力。Sparkle 官方提供 SwiftUI 集成方式，无需自行编写安装器。[Sparkle 入门](https://sparkle-project.org/documentation/)、[SwiftUI 集成](https://sparkle-project.org/documentation/programmatic-setup/)

商店版只能通过商店更新，且需要沙盒；因此不能把直发版原样提交，也不能只把“检查更新”按钮隐藏。建议在构建时排除更新器依赖、实现、配置与 helper。[Apple 审核指南 §2.4.5](https://developer.apple.com/app-store/review/guidelines/#hardware-compatibility)

这项方案不要求立即启用收费、账号或云同步，也不涉及恢复已取消的 iOS 平台。

## 2. 已核实的项目现状

| 核查点 | 当前证据 | 对方案的影响 |
|---|---|---|
| 工程配置 | [project.yml](../project.yml) 仅声明 macOS；最低 macOS 15，Swift 6；目前一个应用 target | 在 XcodeGen 层增加分发区分 |
| 更新器 | project.yml 未声明 Sparkle；未发现 SUFeedURL 或现成更新服务 | 需要新增客户端更新集成 |
| CI | [.github/workflows/ci.yml](../.github/workflows/ci.yml) 负责本地化检查、Debug 构建和单元测试 | 需要独立发布工作流；当前 CI 不证明分发签名有效 |
| 运行保护 | ENABLE_HARDENED_RUNTIME=YES | 已有公证基础，仍需验证导出产物 |
| 沙盒 | [Memonta.entitlements](../Memonta/Resources/Memonta.entitlements) 没有 com.apple.security.app-sandbox | 现有文件访问不能视为商店就绪 |
| 网络 | 生成 plist 设置 NSAllowsArbitraryLoads 与 NSAllowsLocalNetworking | 需要核查 ATS 例外理由，不能破坏现有统一 URL 校验 |
| 版本 | [bump_build_number.sh](../Scripts/bump_build_number.sh) 在 Release 构建时修改 project.yml 并尝试修改产物 plist | 不适合双产物、并行 CI 和可重现发布 |
| 文件目录 | AudioRecording、自定义模型、词典和声纹使用 Documents/Memonta 等路径；自定义目录持久化主要是路径字符串 | 沙盒需持久授权与目录迁移 |
| 退出 | [MemontaApp.swift](../Memonta/MemontaApp.swift) 收尾时 flush 镜像、启动 worker，最后跳过静态析构退出 | 自动更新必须设计独立退出语义 |
| 后台处理 | [BackgroundWorker.swift](../Memonta/Services/BackgroundWorker.swift) 通过 Process 启动同一可执行文件 --background-worker | 安装前应停止旧 worker，防止跨版本运行 |
| 跨应用访问 | [AppMuteDetector.swift](../Memonta/Services/AppMuteDetector.swift) 使用 AXUIElement 检测会议软件静音状态 | 商店沙盒兼容的高优先级阻碍 |
| 隐私 | 已有 [PrivacyInfo.xcprivacy](../Memonta/Resources/PrivacyInfo.xcprivacy)，密钥保存在 Keychain | 需要核对实际行为、SDK 与商店隐私申报，文件存在不代表完成合规 |
| 原生依赖 | ONNX framework 修复与嵌入校验已接入构建 | 发布链必须继续保留，并检查最终导出包 |

本次未访问 GitHub 仓库设置或开发者账户：仓库可见性、现有 Releases、Pages、Actions 成功状态、证书有效性与 App Store Connect 记录仍待实际接入时核对。工作区已有未提交改动，本文依据当前文件分析，不代表某个已发布 tag 的状态。

当前 CI 使用 xcode-27 标签。官方目前将其列为 Public preview，不能据此断言现有标签无效；发布时应确认具体 Xcode/SDK 版本并记录构建环境，避免浮动镜像变化。[GitHub runner 文档](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)

## 3. GitHub 与 Sparkle 如何配合

### 3.1 发布物布局

建议每个版本提供：

```text
GitHub Release：v<营销版本>
  Memonta-<版本>-<构建号>-macOS.zip     Sparkle 全量更新包
  Memonta-<版本>-<构建号>-macOS.dmg     可选，便于首次安装
  SHA256SUMS                             人工核验
  appcast-<构建号>.xml                    可选，留存当次 feed 快照
  更新说明

独立的稳定 HTTPS 地址：
  /stable/appcast.xml
  /beta/appcast.xml                      可选，测试渠道
  /notes/<构建号>.html
```

ZIP 应包含正确签名、公证并 staple 后的 Memonta.app，保留 framework 符号链接及包结构；不要使用 GitHub 自动生成的 Source code ZIP 作为安装包。dSYM 和完整 xcarchive 可保存在受控构建存储中，不必公开给最终用户。

建议**Release assets 保存不可变版本包，独立静态站点保存可更新的 feed**。feed 内下载链接指向明确 tag 与文件名，不能指向会变化的“latest 同名 ZIP”，否则缓存、签名和版本可能错配。

初期可用 GitHub Pages 托管少量 XML 与更新说明；大文件留在 Releases。长期最好让客户端使用自己控制的 HTTPS 域名，便于未来切换到对象存储/CDN。该域名为待配置项，不是项目现有基础设施。商业化时还应复核 Pages 的用途限制，不能将其视为无限制商业托管。[Pages 限制](https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits)

Releases 当前单文件限制为小于 2 GiB；模型继续走现有下载链路，不捆绑进每次更新包。[Releases 文档](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)

### 3.2 公有与私有仓库

- 公有仓库：可以直接公开 Release 与 feed，客户端不需要访问 GitHub REST API。
- 私有源码仓库：建议另建公开的发行仓库，只放签名安装包、feed 和更新说明；不必公开源码。
- 发行包也必须私有：需要有认证的下载服务和短期授权机制，作为独立功能评估。不能在 App 或 appcast 内嵌 PAT、GITHUB_TOKEN，也不能把 CI 的临时下载地址交给客户端长期使用。

客户端通过静态 feed 检查更新，避免每次启动查询 /releases/latest 带来的 API 配额、渠道筛选和认证复杂度。断网或 GitHub 不可达时保持应用正常使用，检查失败可重试；不能显示“已是最新版本”。国内网络应实际测试，必要时将相同签名产物同步到可控 CDN，不能用明文 HTTP 绕过验证。

### 3.3 更新器接入点

建议新增组件（名称为建议，尚未创建）：

| 组件 | 作用 |
|---|---|
| DistributionChannel | 编译期区分 direct 与 appStore，和普通/专业体验模式相互独立 |
| AppUpdateService | 仅直发版使用，MainActor 持有一个 SPUStandardUpdaterController，提供检查状态 |
| UpdateInstallationCoordinator | 安装前检查采集、合并、存储迁移、任务与 worker；协调退出原因 |
| StorageAccessCoordinator | 管理用户选择目录的 bookmark、解析及访问生命周期，两渠道共用 |

直发版 plist 至少配置 SUFeedURL 与 SUPublicEDKey；公钥随 App 发布，私钥留在安全发布环境。更新服务在主应用完成必要初始化与隐私流程后启动；worker、单元测试和 UI 测试启动模式不启动更新器。

在应用菜单、菜单栏及设置页提供“检查更新”；菜单可用状态跟随 Sparkle 的 canCheckForUpdates。用户文案进入 Localizable.xcstrings；首期采用 Sparkle 标准更新界面，减少自定义安装 UI 的维护量。Swift 6 下隔离更新控制器与 UI 状态，不为接入 Objective-C 回调随意放宽 Sendable 约束。

首期建议：用户可选择自动检查；可选后台下载；安装仍由用户确认，并等待安全状态。不启用默认无人值守安装，不收集更新器系统画像。后续如开放退出时自动安装，还须单独验证该路径。

### 3.4 安全验证各自负责什么

| 机制 | 负责的问题 |
|---|---|
| HTTPS | 传输与服务端身份验证 |
| Developer ID 签名 | 应用与嵌入可执行代码的开发者身份和完整性 |
| Apple 公证与 stapling | 外部分发的系统安全检查与票据可用性 |
| Sparkle EdDSA 签名 | 验证客户端收到的更新归档 |
| SHA-256 | 便于人工核验；没有受信签名时不能替代身份验证 |
| GitHub release/build attestation | 帮助核查来源；不替代客户端 Sparkle 验证 |

公证完成并 staple 后再生成最终更新 ZIP，然后生成 EdDSA 签名与 appcast。归档一旦签名，不得再次打包或修改。使用 Sparkle generate_appcast 生成元数据，避免人工拼错长度、版本与签名；如选定版本支持并启用签名 feed，还需维护 feed 与更新说明的相应签名。[Sparkle 发布与签名](https://sparkle-project.org/documentation/publishing/)

密钥分开管理：Developer ID 证书及私钥、Apple 公证凭据、Sparkle EdDSA 私钥、商店上传凭据不是同一种密钥。使用发布环境 Secrets 和临时 Keychain；Sparkle 私钥经标准输入或受控临时文件传给工具，不放进命令参数或日志。备份并设计密钥轮换路径，不能直接替换公钥而不考虑已安装旧版本。[Sparkle 安全说明](https://sparkle-project.org/documentation/security-and-reliability/)

Sparkle 通过 SPM 接入并锁定版本；保留其许可证及第三方 notices。主许可证为 MIT，但分发时仍需核对所选版本附带的全部第三方声明；包体影响通过接入前后 Release 产物实测，不在分析阶段估算成固定数值。[Sparkle LICENSE](https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE)

## 4. Memonta 特有的更新退出问题

这是自动更新首期的关键验收项。

目前 applicationShouldTerminate 返回 terminateLater，异步执行采集收尾、EntryMirrorStore.flush、BackgroundWorker.spawnIfNeeded、模型卸载，最后通过 ProcessLimits.exitSkippingStaticDestructors 结束进程。此行为是为了避开 ONNX 静态析构问题，不能接入更新器时直接删除。

普通退出继续用户已发起任务；**更新退出应先持久化任务，再停止旧代码执行，由新版恢复**。否则旧 worker 可能持有数据库独占锁、继续写磁盘，并在 App bundle 替换期间加载旧路径资源。

建议状态流：

```text
已发现更新 → 下载并验证 → 等待可安装
  → 进入更新准备状态，阻止新的采集/处理入口
  → 录音、录屏、合并或迁移仍在进行：延后安装
  → 持久化可恢复任务与检查点，等待取消实际完成
  → 停止旧 worker，确认退出及数据库所有权交接
  → 保存索引、等待 EntryMirrorStore.flush 成功
  → 卸载推理资源，禁止 spawnIfNeeded
  → 交还 Sparkle 安装/重启控制
  → 新版启动按现有锁与恢复协议接管
```

不能为了安装更新强行中断正在录制的会议；遇到写入失败、flush 未完成或 worker 无法收尾时，取消/延后这次安装，恢复可操作状态并报告原因。普通退出目前允许镜像超时后由下次启动补写；更新安装前应采用更严格门槛。协调器必须幂等，重复回调不能重复保存、卸载或启动进程。

Sparkle 提供 shouldPostponeRelaunchForUpdate 等延后回调，但官方指出部分安装路径不会调用它，不能只在一个 delegate 方法中做保护。安装状态也应进入 App 自己的退出协调流程；首期保持自动静默安装关闭，单独验证“立即安装并重启”和“下载后普通退出”。[SPUUpdaterDelegate](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html)

**尚未验证的兼容点**：Memonta 自定义 _exit 退出与 Sparkle 安装器握手/退出观察是否兼容。应在两个真实签名、公证版本间做技术验证，检查安装器是否已准备、是否需要标准退出通知、是否能可靠重启。失败时调整更新专用协议，不能假定 _exit 一定兼容，也不能恢复已知会崩溃的普通析构路径。

对于用户在主应用未运行时手动替换应用、或未来商店在后台替换 App 的情况，Sparkle 安装协调器不能兜底；如保留独立 worker，还需设计更新/终止协议或缩短 worker 生命周期。商店首版可关闭“退出后继续”，从而降低这一风险。

## 5. 工程、版本和 Actions 实施方案

### 5.1 两个 target，共用模板

建议保留现有 Memonta target / scheme 作为直发版，再增加 MemontaAppStore，公共设置由 XcodeGen targetTemplates 或其他受支持的配置复用方式表达。两个 target 均仅为 macOS，并共用模型与业务源码；分别提供 entitlements、分发编译标志、plist 键和依赖。

采用独立 target 比只增加配置更容易明确表达“商店 target 不链接 Sparkle”。即使 SPM 解析时看到 Sparkle 包，商店导出产物也不应包含其 framework、helper、SUFeedURL 或 EdDSA 配置。配合 #if DIRECT_DISTRIBUTION / #if APP_STORE 和源文件排除；不能只依赖运行时 receipt 检测。

保留 Debug / Release 配置名可减少现有脚本兼容风险：bump_build_number.sh 当前只匹配精确 Release；若改成 Release-Direct 等名字，它将直接跳过。无论选哪种配置形式，都应先重构版本分配，不能依赖脚本偶然行为。

新增文件、依赖、project.yml 或构建脚本变更后执行 xcodegen generate；不要手改生成工程。ONNX 修复与 Verify Embedded Frameworks 两个阶段必须继续执行，不得为发布成功放宽校验。新增测试配置要明确测试宿主，不能一直只测试直发版。

### 5.2 统一版本规则

建议发布前在 project.yml 中确定并提交 MARKETING_VERSION 与 CURRENT_PROJECT_VERSION，生成工程后打 tag；发布构建只读取版本，不在编译过程中修改源码或 plist。两个渠道可从相同提交构建，但使用各自签名配置。

理由：现在每个干净 CI checkout 会从同一构建号开始自增，重复运行可能产生相同编号；双 target 构建又可能各自加一次。同一 tag 的版本和实际包还可能不一致；postCompile 时 plist 的生成顺序也需要验证。仅在 xcodebuild 命令传入 CURRENT_PROJECT_VERSION，仍可能被当前脚本覆盖，不能作为完整修复。

执行规则：

1. 发布前串行分配全局递增整数构建号，须大于所有已发布直发稳定/测试渠道的构建号，并满足商店相应版本的要求。
2. 将编号固化到 project.yml；tag 必须指向该提交。并行发布用发布锁/串行工作流避免重复分配。
3. appcast 的 sparkle:version 与导出 App 的 CFBundleVersion 相同；展示版本与 CFBundleShortVersionString 相同。
4. 构建后从最终导出 App 读取版本并校验 tag、元数据及提交；不能凭输入变量认定正确。
5. 不直接使用 github.run_number 充当全局编号，它按 workflow 计数；换工作流、双渠道和重跑会带来额外规则。

示意：A 为 9.4.0(200)，B 为 9.4.1(201)，纠正 B 的问题应发布 9.4.2(202)。不能把 feed 改回 A 并指望所有已更新用户自动降级。稳定与 beta 建议分离 feed，beta 用户退回稳定时也要保证有可升级的较高构建号。[Sparkle 版本与渠道](https://sparkle-project.org/documentation/publishing/)

### 5.3 发布工作流顺序

建议新增 .github/workflows/release-direct.yml；首次可以手动 workflow_dispatch 验证，稳定后由受保护 tag 触发。流程应是：

1. checkout 精确 tag/commit；检查版本、工作区、锁文件和构建环境。
2. 生成工程、固定 SwiftPM 解析结果、检查本地化并运行相关测试。
3. 在受保护发布 job 注入签名凭据，导入临时 Keychain；归档并按 Developer ID 导出。
4. 验证最终 App、ONNX 与 Sparkle 嵌入组件签名、架构、动态库引用、Hardened Runtime、时间戳及 get-task-allow。
5. 用 notarytool 提交中间 ZIP，确认 Accepted，读取日志；对 App staple 并验证。
6. 重新制作最终更新 ZIP；如提供 DMG，另行签名、公证并 staple 对应 DMG。
7. 对最终 ZIP 生成 Sparkle 签名、appcast 和哈希；首期全量更新，暂不引入 delta。
8. 创建 draft Release，上传所有不可变附件，确认文件和元数据完整。
9. 发布 Release，验证公开下载链接及文件哈希；最后部署稳定 feed。
10. 从正式地址验证 feed 与签名；保留本次发布报告、构建环境、dSYM、公证日志；无论成功失败均清理临时凭据。

ZIP 本身不能 staple，票据应 staple 到 App 后重打包；同一签名文件不能在发布阶段被修改。App 与 DMG 的公证步骤区分处理。[Apple 公证流程](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

不要在 draft Release 的链接尚不能公开访问时更新 feed。GitHub 与静态站点不支持跨服务原子发布，采用“包先可用、feed 后切换”，并保存上一份 feed 以便撤回。下载链接、HTTPS 重定向、XML 内容类型、缓存与签名全部需要端到端检查。

若启用 immutable releases，必须在 draft 阶段附齐文件；发布后不能修改附件和关联 tag。需要继续变化的 appcast.xml 不能只放在一个已不可变的 Release 里，宜独立托管；Release 可留存当次 feed 快照。[GitHub immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)

现有校验脚本重签构建目录 framework 和 App 内 SherpaOnnxC 副本时使用 --timestamp=none，不能据此认定最终分发包满足公证要求。归档/导出后的 App 及其嵌入代码才是验收对象；必要调整应保留当前调试构建的修复保证。Sparkle 内有不同权限的嵌套组件，签名遵循官方指南，不能用一条 --deep 重签命令给所有组件套同一份 entitlements。[Sparkle 嵌套组件签名](https://sparkle-project.org/documentation/sandboxing/)

发布凭据不进入普通 PR job；Actions 权限默认 contents:read，仅发布步骤授予必要写权限。保护 tag、发布环境与 workflow 文件；固定第三方 Actions 到审核过的提交。首次保留对具体 draft 包的人工验收，之后根据发布成熟度决定自动发布程度。自托管签名 runner 不承载不受信 PR 代码。

### 5.4 接入前要准备的资源

| 资源 | 用途与管理方式 |
|---|---|
| 具备相应权限的 Apple Developer Program 账户 | 创建直发签名证书、商店 App ID 和商店签名资料；现有 DEVELOPMENT_TEAM 字段不证明账户权限或证书可用 |
| Developer ID Application 证书及其私钥 | 在 CI 临时 Keychain 中使用，不提交 .p12 或密码 |
| 公证认证凭据 | 使用 Apple 支持的认证方式，限制用途并保存为受保护 Secret |
| Sparkle EdDSA 密钥对 | 公钥进直发 App，私钥仅发布环境持有并备份 |
| 发行仓库与稳定 feed 托管 | 公开可下载的安装包、可持续更新的 HTTPS appcast；如源码私有，配置独立发行仓库的最小写权限 |
| App Store Connect 应用记录及上传权限 | 商店阶段准备，上传凭据与直发公证凭据按用途分别管理 |
| 真实测试 Mac 与隔离测试数据 | 验证录音、屏幕权限、Keychain、旧版升级及沙盒迁移 |

后续可增加 release-appstore.yml：从固定提交生成商店 target → 测试并归档 → 商店签名导出 → 验证不含更新器 → 上传 App Store Connect → TestFlight → 提交审核。上传成功、审核通过和对用户上架是不同状态，GitHub Actions 不能替代 Apple 审核。

费用主要来自开发者计划、私有仓库的 macOS Actions 用量、产物保留，以及可能的域名/CDN；公开仓库与私有仓库的 Actions 计费条件不同。首期不增加更新后端服务，具体额度和价格在选定账户、流量及 runner 后核算。[GitHub runner 与计费入口](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)

## 6. 为 App Store 提前准备的改造

### 6.1 沙盒存储与目录授权：第一优先级

现在已有短期 startAccessingSecurityScopedResource 调用，但检索未发现持久 security-scoped bookmark 实现。只把文件夹路径存到 UserDefaults，不能保证沙盒 App 下次启动还能访问。

建议将内部数据库、队列控制元数据及可重建缓存放入通过 FileManager 标准 API 解析的容器位置；用户录音/笔记可保存在容器内，或保留用户显式选择的外部目录。已有外部目录需要通过系统选择器授权，不能偷偷复制或宣称历史路径自动可读。[Apple 沙盒目录](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)

为数据根、Whisper 模型、说话人分离模型、词典等长期外部资源保存 app-scoped bookmark；启用相应 bookmark entitlement，处理过期、卷离线、权限撤销与重新授权。权限应覆盖整个录音、下载、扫描或推理生命周期，结束时成对释放，不能在设置页选完目录后就失去授权。[持久文件访问](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)

沿用 StorageSession 冻结根目录、pending 目录重启生效、原子创建条目、跨进程锁及 EntryMirrorStore 的既有约束。队列、worker、录音分片和索引不能分别解析出不同根目录；内部元数据的路径调整需要可恢复迁移，不能独立搬走 lock 文件却保留旧进程写入。文件系统继续为条目权威源。

跨进程访问外部目录需要显式设计 bookmark/授权传递和生命周期，不能认为子进程知道路径就获得权限。若新增 helper，按 Apple 的进程间文件访问规则验证；最小商店版可先不保留退出后 worker。

### 6.2 跨应用静音检测：明确功能差异

Apple 将辅助应用使用 Accessibility API 列为 App Sandbox 不兼容活动。当前 AppMuteDetector 会读取其他会议 App 的 AX 树，属于直接相关的兼容风险；单纯让用户在系统设置授予辅助功能权限，不会解除沙盒限制。[Apple 沙盒限制](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)

建议直发版保留该能力；商店首版排除跨应用 AX 检测与相关授权入口，保留经实测可用的 CoreAudio 麦克风静音监听及 Memonta 自身静音控制。硬件静音与 Teams/Zoom 内部静音是不同信号，界面不得把前者描述成能可靠检测后者。若后续有会议软件公开 SDK，可另行评估。

这个分发差异通过编译与服务能力边界表达，与 AppExperience 的普通/专业模式分开：切到专业模式不能重新启用商店不支持的服务。产品说明、帮助、截图与 PRD 应在真正实施时同步。

### 6.3 后台处理与进程

当前退出即 spawnIfNeeded，并非 launchd 登录项。商店要求用户同意退出后继续运行；“用户发起过转写”与“明确同意退出后运行”应在产品流程中分别表达。可选路线是提供清楚的后台续跑开关，或商店首版退出时保存任务、下次打开恢复。[审核指南 §2.4.5(iii)](https://developer.apple.com/app-store/review/guidelines/#hardware-compatibility)

如需要退出后持续执行，应验证受支持的 helper/agent 结构、签名和沙盒权限；XPC 适合应用内服务隔离，但不能仅把现有 worker 改名 XPC 就假定会在主应用退出后持续运行。仅为续跑任务不必新增开机启动；若未来做登录项，再评估 SMAppService 与用户授权。

SpeakerDiarizationService 当前调用 /usr/bin/tar 解压。Process 并非统一被禁止，但外部系统工具的执行与目标文件权限必须在真实沙盒中验证；更稳妥的备选是合适的应用内解压实现，加入路径穿越与资源限制检查，并评估依赖许可证/体积。DEBUG 下 tccutil 清理代码不得进入 Release 运行路径，不能以删掉所有 Process 调用代替针对性分析。

### 6.4 签名身份、Bundle ID 与渠道迁移

两条可行路线需要在注册 App Store 记录前决定：

| 路线 | 优点 | 代价 |
|---|---|---|
| 两渠道使用相同 Bundle ID 与团队 | 面向“同一产品替换安装”，更利于延续部分身份 | 不适合作为独立双开版本；仍要迁移容器、偏好、Keychain 并验证签名/TCC，不能保证无缝 |
| 商店版使用独立 Bundle ID | 更容易共存和明确隔离渠道 | 需设计数据导入、偏好及密钥迁移；权限通常需要重新授权 |

当前直发版标识已存在，建议先保留。如果长期主张“两渠道共存且能力不同”，倾向为商店版预留独立标识；如果目标是商店版接替直发版，应先做同标识沙盒迁移验证，再确定商店标识。不能为了隔离更新器贸然改已发布直发版 Bundle ID。

相同团队或相同 Keychain service 字符串不等于跨渠道自动可读。需核查签名访问控制、access group、商店 provisioning 与既有条目。当前 AES 密钥使用 com.Memonta.encryption 服务，API Key 另有服务；必须分别验证。读取旧 AES 密钥失败不能静默生成新密钥并继续写入，否则旧录音文本可能无法解密。

推荐迁移顺序：停止双方写入并备份 → 新版显式授权旧数据目录 → 验证索引/镜像和旧数据解密 → 在目标身份中安全建立所需密钥访问 → 重建索引及必要偏好 → 验证成功才切换。原始 AES 密钥不得写入仓库、日志、普通配置或未加密迁移文件；无法直接共享时另设计经过认证加密的迁移流程。

双渠道并存时，默认使用各自容器/索引，用户主动迁移；不默认同时写同一外部目录。确需共享时，必须统一数据根、锁、队列协议与格式兼容性；数据库 flock 不是不同版本所有写入操作都兼容的证明。

### 6.5 模型、权限和商店资料

- 模型：当前模型从外部下载，不能简单以“它是权重”断言审核一定允许。保持推理代码内置、模型只服务已申报能力，提供可信源、完整性校验、大小/用途说明、失败重试与取消；审核备注说明首次下载。不能下载新可执行代码绕过审核。[审核指南 §2.4.5 / §2.5.2](https://developer.apple.com/app-store/review/guidelines/)
- 录音与截图：为麦克风、系统音频/屏幕捕获、提醒事项和系统语音识别逐项准备按功能请求及拒绝后的降级；真实沙盒 Release 中验证，不能把所有 ScreenCaptureKit 功能一并认定不可用。
- 隐私：已有 manifest 与商店隐私标签是不同材料。结合云端音频、脱敏文本、图片/视频帧、声纹及各第三方 SDK 核查真实数据流；仅本地处理不能直接等同云端共享。现有 PII 文本脱敏不覆盖图片/视频帧。[App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)
- 第三方 AI：对发送范围、接收服务及用户同意作明确检查；配置 API Key 或同意总隐私政策，不能直接视作已满足每项外发授权。[审核指南 §5.1.2](https://developer.apple.com/app-store/review/guidelines/#data-use-and-sharing)
- ATS：逐一确认远端 HTTPS、回环 HTTP 例外和本地模型服务需求；保留统一 URL 校验，不扩大明文远程网络访问。若仍需例外，记录准确用途供审核解释。
- 加密出口申报：项目使用 AES-GCM；根据实际用途填写 App Store Connect 加密问卷与必要材料，不能仅凭使用系统 CryptoKit 就直接填写豁免。[Apple 加密出口说明](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/)
- 发布资料：隐私政策网址、支持网址、商店描述/截图、年龄分级、版权/第三方模型许可证、审核操作说明、可用测试数据；如需要云端账号/API 凭据，提供安全可用的审核路径，不能在公开 Release 附真实密钥。
- 商业化：当前普通/专业模式是体验模式，不能直接当成 StoreKit 付费权益。未来收费时另行设计商店购买/恢复与直发授权，不能把外部许可证激活界面直接放进商店版。

## 7. 验证与验收

### 7.1 自动更新

| 场景 | 验收结果 |
|---|---|
| 两个真实签名、公证版本 A → B | 安装后版本正确，签名有效，可启动；旧数据可读 |
| 镜像篡改、归档损坏或签名错误 | 拒绝安装，旧 App 与用户数据保持可用 |
| 无网、404、限流、超时、坏 XML | 给出可恢复失败；不误报最新，不阻塞主功能 |
| 无更新、跳过版本、beta 切稳定 | 版本比较及用户偏好符合预期 |
| 更新最低系统高于本机 | 不安装不兼容版本，保留可用版本 |
| 正在录音、录屏或混音 | 可检查/下载，延后安装，不中断采集 |
| 队列运行、worker 持锁、镜像写失败 | 暂停/延后安装；不能并发跨版本写入 |
| 更新准备失败或用户取消 | 恢复可操作状态；没有永久冻结入口或重复恢复任务 |
| 从 Downloads / 只读 DMG 首启 | 提示正确安装位置；从正常 Applications 位置验证更新 |
| 普通用户、磁盘不足、重启失败 | 行为明确，不把应用成功替换等同于业务恢复成功 |
| 每个宣称支持的 CPU 架构与系统 | 分别验证依赖切片与运行；构建机为 arm64 不证明 Universal 支持 |

首个包含 Sparkle 的版本要由现有用户手动安装一次；没有更新器的旧版本不能凭空获得自动更新能力。若不引入可控代理，GitHub 故障时也不存在保证可用的在线更新通道，应保留手动下载入口。

### 7.2 App Store

使用真实沙盒、商店签名路径和 TestFlight/商店测试构建验收：容器默认路径、外部目录重启访问、bookmark 失效、模型下载/解压/加载、采集权限拒绝、后台同意与退出、数据迁移、旧密钥解密、提醒事项确认写入。不能只在本机非沙盒 Debug 中通过。

产物检查应确认：App Sandbox 已启用；Sparkle、helper 和 feed 配置均不存在；Debug TCC 重置路径不可达；功能入口与分发能力一致；依赖许可证和隐私材料完整。客户端更新行为仍由商店控制。

### 7.3 撤回与数据迁移

发现坏版本时，先从活动 feed 移除该版本并恢复上一份 feed，停止继续推送；已安装用户通过更高构建号的修复版恢复。不要覆盖旧 Release 附件，也不要默认自动降级 SQLite/SwiftData。

模型/镜像/队列格式改动需可恢复迁移；更新包替换 App 不会自动备份数据。迁移前关闭所有写入，备份数据库及必要 WAL/SHM、文件镜像和配置，验证后再切换。旧 App 能否读取新格式需独立证明；无法证明时不能宣传“一键回滚”。

## 8. 建议落地次序

| 阶段 | 工作 | 完成门槛 |
|---|---|---|
| 1：确定发布基础 | 决定发行仓库可见性、feed 地址、签名凭据与构建号规则 | 能从固定提交导出并公证可启动的直发包 |
| 2：更新闭环 | 接入 Sparkle，增加更新专用退出协调，补发布工作流 | 两个真实公证版本间升级，录音/worker/加密数据验收通过 |
| 3：沙盒基础 | 持久目录授权、目录迁移、依赖与权限回归；确定 Bundle ID 策略 | 商店 target 的真实沙盒构建能跑通主链路 |
| 4：商店适配 | 排除更新器与 AX 检测，确定后台续跑策略，完善隐私/模型/商店资料 | TestFlight 验证并提交审核 |

优先做阶段 1 与阶段 2，同时将存储授权抽象按沙盒要求设计。无需等 App Store 审核才实现 GitHub 更新，但也不能把“Sparkle 已接入”当作商店准备完成。

## 9. 本次实际完成与未验证范围

已阅读工程配置、entitlements、CI、版本脚本、framework 签名校验、存储路径、目录选择、Keychain、后台 worker 与退出流程，并核对 Sparkle、GitHub、Apple 官方资料。新增本文并在发布检查中提供导航。

本次为分析与文档工作，未改业务代码、版本、依赖、签名配置或 GitHub 设置；未创建 Release、注册 App Store 记录或上传产物。没有执行构建/测试、公证或真实更新；仅对文档引用、格式及工作区改动范围作检查。这些运行验证应在上述实施阶段执行。
