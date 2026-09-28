import SwiftUI
import SwiftData
import os
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Carbon)
import Carbon.HIToolbox
#endif

// MARK: - 隐私政策详情视图
struct PrivacyPolicyDetailView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Memonta 隐私政策")
                    .font(.title)
                    .fontWeight(.bold)

                Text("最后更新：2025 年")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                privacySection(title: "数据收集", content: "Memonta 收集以下数据用于提供录音、转写、总结与待办功能：\n• 音频文件（您导入的录音或本机录制的会议音频）\n• 转写文本（由音频生成）\n• 总结与待办（由大模型生成）\n• 截图、画面要点与声纹（可选功能生成）\n\n所有数据仅存储在您的设备本地，不会上传到我们的服务器。")

                privacySection(title: "麦克风与系统音频", content: "会议录音功能需要访问以下权限：\n• 麦克风：录制本机麦克风输入的语音\n• 系统音频：通过 ScreenCaptureKit 录制系统输出音频，需「屏幕录制」权限\n\n权限仅在你主动开始录音时启用，停止录音后立即释放。系统音频录制可在设置中开关。")

                privacySection(title: "麦克风设备选择", content: "录音使用的输入设备可自行指定（「设置 → 录音 → 输入设备」，或菜单栏「麦克风」）。可选范围与系统「声音 → 输入」一致，包含外接麦克风与虚拟/回环设备。该选择只保存在本机、只作用于本应用，不会修改系统默认输入设备。")

                privacySection(title: "录屏与视频数据", content: "录屏产生的视频文件与导入的原始视频都只保存在本机数据文件夹中，不会上传到我们的服务器。打开视频条目可在「画面」页随时「清理视频」删除原始视频，关键帧与画面要点保留。\n\n注意：图片与视频帧本身不做文本脱敏；启用云端视觉模型时画面会直接上传给该服务，请自行确认画面中是否包含敏感信息。")

                privacySection(title: "配置导出", content: "「设置 → 大模型 → 配置迁移」导出的文件包含你的 API Key，会用本机密钥自动加密（与本地数据同一套，密钥保存在系统钥匙串），再保存到你选择的位置；因为没有额外口令，该文件只能在本机 Memonta 导入。密钥不会上传，文件请妥善保管。")

                privacySection(title: "数据传输", content: "当您使用云端转写或云端大模型时，相关数据将传输至您配置的第三方服务（如 OpenAI）。\n\n本地模式（WhisperKit/SpeechAnalyzer + LM Studio/Ollama）下，所有处理在设备本地完成，无需网络传输。\n\n为降低敏感信息外泄，向云端大模型发送文本前会执行 PII 去标识化（人名、公司、账号、手机号、身份证号、邮箱等替换为占位符），收到结果后再在本地还原。该脱敏只作用于文本请求；云端转写上传的是音频，无法对音频内容脱敏。PII 识别使用本机词典与正则，不依赖云端。")

                privacySection(title: "数据存储", content: "• 录音、转写、总结、待办与图片统一存储在用户文稿目录下的 Memonta 文件夹（~/Documents/Memonta/），并按 yyyy-MM 月份归档到子文件夹；声纹库位于该目录下的 Voiceprints 子文件夹\n• 转写、总结与待办以加密形式保存在本机数据库与条目文件夹中\n• 加密密钥与 API Key 保存在 macOS 钥匙串（Keychain）中，不写入普通偏好或日志\n• 删除应用（卸载）不会自动删除数据文件夹、本地数据库与钥匙串项目，需要手动清理")

                privacySection(title: "屏幕共享说明", content: "在会议软件中共享屏幕时，你可以通过菜单栏「隐藏主窗口」隐藏本软件界面，同时 Dock 图标也会隐藏，避免被会议参与者看到。录音会在后台继续运行，可通过菜单栏图标控制。")

                privacySection(title: "用户权利", content: "您可以随时：\n• 删除任意录音及其转写、总结与待办\n• 在系统设置中撤销麦克风、屏幕录制与语音识别访问权限\n• 在 Finder 中复制数据文件夹完成手动备份（路径见「设置 → 数据管理」）\n• 手动删除数据文件夹以彻底清除本机数据")

                privacySection(title: "第三方服务", content: "本应用可能调用您自行配置的第三方 API 服务（如 OpenAI、LM Studio、Ollama）。这些服务的数据处理受其各自隐私政策约束，请参阅相关服务条款。")

                privacySection(title: "本地处理说明", content: "Memonta 的录音、转写与总结默认全部在本机完成，音频与文本不会上传；只有当您主动配置并使用云端转写或云端大模型时，相关内容才会发送到您自行指定的第三方服务。")

                privacySection(title: "联系我们", content: "如有隐私相关问题，请通过应用内「用户反馈」功能联系我们。")
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("隐私政策")
    }

    /// title/content 用 LocalizedStringKey 接收：字面量调用自动按当前语言查
    /// Localizable 表（各语言翻译已存在）；若用 String 参数，Text(变量) 会按
    /// verbatim 渲染、永不翻译，导致切换语言后隐私政策文字不变
    private func privacySection(title: LocalizedStringKey, content: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(content)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
