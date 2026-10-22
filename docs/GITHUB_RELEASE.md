# GitHub 直发更新

当前代码接入 Sparkle 2.10.0。首次安装仍需手动下载 App；之后可从应用菜单或「设置 → 关于」检查更新。自动检查默认关闭，安装始终需要用户确认。

## 频道与安装保护

- 正式版读取 `https://raw.githubusercontent.com/oceanix-pr/Memonta/updates/stable/appcast.xml`。
- 未公证预览包读取同一 `updates` 分支的 `preview/appcast.xml`。源码仓库保持公开才能匿名读取这些地址；客户端不携带 GitHub Token。
- 更新归档放在明确 tag 的 GitHub Release 中；模型继续走原有下载渠道。首版仅全量更新。
- 录音启动/采集/合并、未收尾的视频资源、截图会话、媒体导入、磁盘对账、活动任务和未退出的孤儿执行体都会阻止安装。结束任务后，可在 Sparkle 中重试安装。
- 安装前保存共享 ModelContext、停止旧 worker、等待 EntryMirrorStore.flush，并在异步屏障后再次确认空闲。失败会取消本次退出并恢复界面。更新退出不再启动旧 worker，新版按既有启动协议恢复磁盘任务。
- 保留 ONNX 静态析构规避路径 `_exit`。完整的两版本替换、重启和系统权限连续性仍须在隔离测试数据上实测；单元测试和构建通过不能替代该验收。

## 密钥

Sparkle EdDSA 私钥与 Apple 证书相互独立。公钥位于 `project.yml`，私钥保存在生成它的 Mac 的登录 Keychain，account 为 `com.oceanix.Memonta.sparkle`。请备份私钥；直接更换公钥会使已安装版本无法验证后续包。

自动发布需要在仓库的 `release` environment 中配置 `SPARKLE_PRIVATE_KEY` Secret。使用锁定 Sparkle 版本附带的 `generate_keys --account com.oceanix.Memonta.sparkle -x <受控临时文件>` 导出后，可由 `gh secret set SPARKLE_PRIVATE_KEY --env release < <受控临时文件>` 上传，随后安全移除临时文件。不要把私钥粘贴到聊天、日志或仓库。

本机生成包不需要导出私钥：`release_direct.sh` 默认直接使用上述 Keychain account。CI 通过标准输入将 Secret 传给 Sparkle 工具，普通 PR/测试步骤不获得此 Secret。

## 没有 Apple 分发证书时

仍可生成带 Sparkle 更新签名的未公证预览包。它使用 ad-hoc 代码签名，不能通过正常的 Developer ID/Gatekeeper 分发验证，首次打开可能被系统阻止；系统录音、屏幕录制等权限也可能需要重新授予。

预览构建单独关闭 Hardened Runtime，以允许没有 Team ID 的 App 加载上游签名的 Sparkle；正式工程默认仍开启。不要把预览包标为正式发行版。预览更新与正式更新完全分频道，不能将预览设为 Latest。适用 macOS 系统版本与 CPU 架构以包内实际产物为准；Release 遵循 Xcode 的架构设置，发布前检查实际包内架构；本机运行验收不能替代 Intel Mac 验证。

## 发布流程

1. 在 `project.yml` 固定营销版本和递增构建号。`Scripts/bump_build_number.sh [新编号]` 现在只在发布前手动运行；任何 build/test/archive 都不再自增编号。两个频道共用全局递增编号，避免从测试频道迁移时发生降级。
2. `xcodegen generate`，检查锁文件、运行测试并提交，然后创建与营销版本对应的 tag，例如 `v9.4.0-preview.1` 或 `v9.4.0`。工作区未提交内容不会出现在 tag 中。
3. 推送 tag 触发 `release-direct.yml`；也可手动选择已存在 tag。预览版只需要 Sparkle Secret；正式版另需下述 Apple 凭据。
4. 流水线创建附带 ZIP、appcast.xml 与 SHA256SUMS 的 **draft Release**。先用具体包验证升级、录音保护、worker 交接、保存失败和重启，再发布草稿。草稿阶段不会影响现有 feed。
5. 用户发布 Release 后，`publish-update-feed.yml` 才会验证公开包地址、长度、签名字段及递增构建号，将 appcast 提交到 `updates` 分支对应频道。发布旧构建不能覆盖较新 feed。

Release 附件应保持不可变。修复已发布版本时发布更高构建号，不能把 feed 改回旧包期待客户端自动降级。GitHub Token 自动触发事件存在限制：通过另一个 Actions 的 GITHUB_TOKEN 发布 Release 时，不能假定会触发 `release:published`；本流程保留由用户发布草稿的最终步骤。

本机打包示例（工具路径和缓存路径按本机设置）：

```sh
RELEASE_TAG=v9.4.0-preview.1 \
  SPARKLE_BIN_DIR=/path/to/Sparkle/bin \
  PACKAGE_CACHE_PATH=/path/to/SourcePackages \
  bash Scripts/release_direct.sh preview
```

## 正式公证版额外配置

在 `release` environment 配置：

| 类型 | 名称 | 内容 |
|---|---|---|
| Secret | DEVELOPER_ID_P12_BASE64 | Developer ID Application 证书及私钥的 p12，Base64 编码 |
| Secret | DEVELOPER_ID_P12_PASSWORD | p12 密码 |
| Secret | NOTARY_API_KEY_P8 | Apple 公证 API 私钥 |
| Variable | APPLE_TEAM_ID | 签名团队 |
| Variable | NOTARY_KEY_ID | 公证 API Key ID |
| Variable | NOTARY_ISSUER_ID | 公证 API Issuer ID |

本机也可使用 `NOTARY_KEYCHAIN_PROFILE` 代替公证 API 文件。正式包经 archive/export、签名验证、公证 Accepted、staple 后才重新压缩并生成 Sparkle 签名。脚本会拒绝未经公证的正式 tag；保留现有 ONNX 修复与 Verify Embedded Frameworks，不放宽校验。

建议保护发布 tag、工作流和 release environment；自托管签名 runner 不执行不受信 PR。运行器当前沿用工程的 `xcode-27` 标签，发布前检查实际 Xcode/SDK 可用性。首次接入前后应实测 Release 包体积；Sparkle 为 MIT，附带第三方声明已随 App 分发于 `Sparkle-LICENSE.txt`。
