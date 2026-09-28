import Foundation

/// 录音来源
enum RecordingSource: String, Codable, CaseIterable {
    /// 仅麦克风
    case microphone = "microphone"
    /// 仅系统音频
    case systemAudio = "system"
    /// 麦克风 + 系统音频（混音）
    case mixed = "mixed"

    var displayName: String {
        switch self {
        case .microphone:   return String(localized: "仅麦克风")
        case .systemAudio:  return String(localized: "仅系统音频")
        case .mixed:        return String(localized: "麦克风 + 系统音频")
        }
    }

    var iconName: String {
        switch self {
        case .microphone:   return "mic.fill"
        case .systemAudio:  return "speaker.wave.2.fill"
        case .mixed:        return "mic.and.signal.meter.fill"
        }
    }
}

/// 离线参考回声消除偏好的无 UI 存取层。
///
/// 默认开启：混音产物里远端的话会同时出现在两条音轨上，导致转写重复与说话人误判，
/// 消除它没有副作用（失败时回退为原始音轨）。控制项只在专业模式的录音页暴露，
/// 普通模式沿用默认值。
enum EchoReductionPreference {
    static let defaultsKey = "echo_reduction_enabled"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }

    static func set(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: defaultsKey)
    }
}

/// 录音配置（纯值类型，由 SettingsViewModel 通过 UserDefaults 持久化）
struct RecordingConfig: Sendable {
    /// 录音来源
    var source: RecordingSource
    /// 是否启用系统静音自动检测（检测到系统输入设备 mute 时自动暂停麦克风采集）
    var autoMuteDetection: Bool
    /// 是否启用应用层静音检测（通过 Accessibility API 检测 Teams/Zoom 等会议软件的静音状态）
    var appMuteDetection: Bool
    /// 录音文件格式（m4a/AAC，便于转写前统一转换）
    var fileFormat: String

    init(
        source: RecordingSource = .mixed,
        autoMuteDetection: Bool = true,
        appMuteDetection: Bool = false,
        fileFormat: String = "m4a"
    ) {
        self.source = source
        self.autoMuteDetection = autoMuteDetection
        self.appMuteDetection = appMuteDetection
        self.fileFormat = fileFormat
    }
}
