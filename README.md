# Memonta

Memonta 是一款原生 macOS 会议助手，使用 SwiftUI 构建，支持会议录音、本地语音转写、说话人分离、AI 总结与待办提取，以及截图和图片笔记。

## 主要能力

- 同时采集麦克风和系统音频，并保存可恢复的录音分片
- 使用 WhisperKit 在本地完成语音转写
- 使用 sherpa-onnx 完成说话人分离
- 连接 OpenAI 兼容接口生成总结、待办和视频画面要点
- 管理截图、OCR、提醒事项和本地文件镜像
- 支持简体中文、繁体中文及多种界面语言

## 环境要求

- macOS 15 或更高版本
- Xcode 27
- Swift 6
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

`project.yml` 是工程配置的唯一事实源。不要直接修改生成的 `Memonta.xcodeproj`。

## 构建

```sh
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project Memonta.xcodeproj \
  -scheme Memonta \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

工程当前包含开发团队配置。若该团队对你的 Apple ID 不可用，请在本机设置签名团队后重新生成工程；CI 不使用开发者团队证书（构建步骤无签名，测试宿主使用 ad-hoc 签名）。

首次运行会按功能请求麦克风、屏幕录制、语音识别、辅助功能或提醒事项权限。本地模型不随源码仓库分发，可在应用内下载或手动指定模型目录。

## 测试

```sh
# 本地化资源一致性
python3 Scripts/check_l10n.py

# 单元测试
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project Memonta.xcodeproj \
  -scheme Memonta \
  -configuration Debug \
  -destination 'platform=macOS' \
  test -only-testing:MemontaTests
```

UI 测试需要有图形界面的 macOS 会话以及相应的系统权限，因此不在基础 CI 中运行。完整构建说明见 [构建与运行](docs/wiki/13-构建与运行.md)。

## 数据与隐私

录音、转写、总结、截图和模型默认保存在本机。使用云端 LLM 时，应用会向用户配置的服务发送完成请求所需的数据；请在使用前确认服务提供方的隐私政策。API Key 与加密密钥存放在 macOS Keychain 中。

请勿在 issue 中上传会议内容、API Key、崩溃报告原件或其他敏感数据。安全问题请按 [安全政策](SECURITY.md) 私下报告。

## 文档

- [产品需求](PRD.md)
- [开发实践](DEVELOPMENT_GUIDE.md)
- [项目 Wiki](docs/wiki/Home.md)
- [发布检查](docs/RELEASE_CHECKLIST.md)

## 许可证

Memonta 源代码以 [MIT License](LICENSE) 发布。第三方依赖、词典及用户另行下载的模型适用各自的许可证，详见 [第三方声明](THIRD_PARTY_NOTICES.md)。MIT 许可证不自动授予 Memonta 名称、图标或其他商标的使用权。
