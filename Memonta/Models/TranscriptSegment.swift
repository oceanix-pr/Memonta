import Foundation
import SwiftData

/// 转写片段模型
@Model
final class TranscriptSegment {
    var id: UUID
    var startTime: TimeInterval  // 秒
    var endTime: TimeInterval    // 秒
    var speaker: String?         // 发言人（可选）
    var text: String             // 文本内容

    /// 关联的录音
    var recording: AudioRecording?

    init(startTime: TimeInterval, endTime: TimeInterval, speaker: String? = nil, text: String) {
        self.id = UUID()
        self.startTime = startTime
        self.endTime = endTime
        self.speaker = speaker
        self.text = text
    }
}

// MARK: - 计算属性（@Model 宏要求放在 extension 中）
extension TranscriptSegment {
    /// 格式化的时间范围显示，例如 "01:23 - 02:45" 或 "1:01:23 - 1:02:45"
    var formattedTimeRange: String {
        "\(startTime.formattedAsDuration()) - \(endTime.formattedAsDuration())"
    }

    /// 解密后的文本内容
    var decryptedText: String {
        EncryptionService.decryptSafely(text)
    }
}
