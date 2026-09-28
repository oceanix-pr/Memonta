import Foundation

/// 转写 Markdown 的块级结构（渲染无关，可在后台线程解析）
///
/// 从 MarkdownView 的私有解析器抽出，供后台预解析与缓存复用：
/// 切换录音时解密+拼接+解析全部移出主线程，UI 直接消费解析好的块。
enum TranscriptBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case bulletItem(text: String)
    case numberedItem(number: Int, text: String)
    case codeBlock(text: String)
    case quote(text: String)
    case divider

    /// 承载文本的 UTF8 字节数（供 `TranscriptCache` 估算缓存代价）
    var contentByteCount: Int {
        switch self {
        case .heading(_, let text), .paragraph(let text), .bulletItem(let text),
             .numberedItem(_, let text), .codeBlock(let text), .quote(let text):
            return text.utf8.count
        case .divider:
            return 0
        }
    }
}

/// 转写 Markdown 解析与构建（纯函数，可安全用于后台线程）
enum TranscriptMarkdownBuilder {

    /// 按行解析 Markdown 为块序列（原 MarkdownView.parseBlocks 逻辑）
    static func parseBlocks(_ markdown: String) -> [TranscriptBlock] {
        var blocks: [TranscriptBlock] = []
        let lines = markdown.components(separatedBy: "\n")
        var inCodeBlock = false
        var codeLines: [String] = []

        for line in lines {
            if line.hasPrefix("```") {
                if inCodeBlock {
                    blocks.append(.codeBlock(text: codeLines.joined(separator: "\n")))
                    codeLines = []
                    inCodeBlock = false
                } else {
                    inCodeBlock = true
                }
                continue
            }
            if inCodeBlock {
                codeLines.append(line)
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.divider)
            } else if trimmed.hasPrefix("###") {
                blocks.append(.heading(level: 3, text: String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)))
            } else if trimmed.hasPrefix("##") {
                blocks.append(.heading(level: 2, text: String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
            } else if trimmed.hasPrefix("#") {
                blocks.append(.heading(level: 1, text: String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else if trimmed.hasPrefix(">") {
                blocks.append(.quote(text: String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                blocks.append(.bulletItem(text: String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
            } else if let number = parseNumberedItem(trimmed) {
                blocks.append(number)
            } else {
                blocks.append(.paragraph(text: trimmed))
            }
        }

        if inCodeBlock && !codeLines.isEmpty {
            blocks.append(.codeBlock(text: codeLines.joined(separator: "\n")))
        }
        return blocks
    }

    /// 解析 "1. " / "1) " 有序列表项
    private static func parseNumberedItem(_ text: String) -> TranscriptBlock? {
        if let dotIndex = text.firstIndex(of: ".") {
            let prefix = text[..<dotIndex]
            if let num = Int(prefix), text[text.index(after: dotIndex)...].hasPrefix(" ") {
                let content = String(text[text.index(text.index(after: dotIndex), offsetBy: 1)...])
                return .numberedItem(number: num, text: content.trimmingCharacters(in: .whitespaces))
            }
        }
        if let parenIndex = text.firstIndex(of: ")") {
            let prefix = text[..<parenIndex]
            if let num = Int(prefix), text[text.index(after: parenIndex)...].hasPrefix(" ") {
                let content = String(text[text.index(text.index(after: parenIndex), offsetBy: 1)...])
                return .numberedItem(number: num, text: content.trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// 片段渲染数据（解密前的最小信息，Sendable 可跨并发域传递）
    struct SegmentData: Sendable {
        let timeRange: String
        /// 片段起始秒数，用于生成点击播放链接（Memonta://seek/<startTime>）
        let startTime: TimeInterval
        let speaker: String?
        let encryptedText: String
    }

    /// 由片段数据解密并构建转写 Markdown（含解析后的块）。
    /// 与 AudioRecording.transcriptMarkdown 规则一致：
    /// 单片段直接返回其文本（编辑后整体即 Markdown），多片段带时间戳与发言人拼接。
    /// 返回的 markdown 为干净版本（时间行无链接），供复制/编辑使用；
    /// blocks 由带链接版本解析而来：时间行含 Memonta://seek/<秒> 链接，
    /// 渲染层复用 AttributedString 既有链接能力实现"点击时间行播放对应录音段"。
    /// 调用方须保证 segments 已按 startTime 升序传入（主线程侧排序，避免后台线程触碰 SwiftData 模型）。
    static func build(from segments: [SegmentData]) -> (markdown: String, blocks: [TranscriptBlock]) {
        if segments.count == 1, let only = segments.first {
            let text = EncryptionService.decryptSafely(only.encryptedText)
            return (text, parseBlocks(text))
        }
        var cleanParts: [String] = []
        var linkedParts: [String] = []
        cleanParts.reserveCapacity(segments.count)
        linkedParts.reserveCapacity(segments.count)
        for segment in segments {
            let text = EncryptionService.decryptSafely(segment.encryptedText)
            var cleanLine = "**\(segment.timeRange)**"
            var linkedLine = "[**\(segment.timeRange)**](Memonta://seek/\(segment.startTime))"
            if let speaker = segment.speaker, !speaker.isEmpty {
                cleanLine += " · **\(speaker)**"
                linkedLine += " · **\(speaker)**"
            }
            cleanLine += "\n\n\(text)"
            linkedLine += "\n\n\(text)"
            cleanParts.append(cleanLine)
            linkedParts.append(linkedLine)
        }
        let cleanMarkdown = cleanParts.joined(separator: "\n\n---\n\n")
        let linkedMarkdown = linkedParts.joined(separator: "\n\n---\n\n")
        return (cleanMarkdown, parseBlocks(linkedMarkdown))
    }
}

/// 转写渲染缓存条目
struct TranscriptCacheEntry: Sendable {
    let markdown: String
    let blocks: [TranscriptBlock]
}

/// 转写渲染缓存（按录音 ID 缓存"解密+拼接+解析"结果）
///
/// 切换列表条目时避免重复解密全部片段与重新解析长 Markdown；
/// 片段发生增删改的写路径须调用 invalidate 使其失效。
///
/// 容量控制：旧实现 `entries` 只增不减（仅显式 invalidate），且取值写成
/// `await store.entries[id]`——跨 actor 边界会先**拷贝整个字典**再取下标，
/// 每命中一次缓存就复制一次全部已缓存转写。现改为：actor 内按下标取值
/// + LRU 淘汰（按明文/块字节数计费，超限逐出最旧）。
enum TranscriptCache {

    private actor Store {
        /// 明文总缓存上限（约 64MB）：长会议转写单条可达几 MB，无上限时
        /// 浏览过的每条录音的整篇 markdown + 解析块会常驻内存
        static let totalCostLimit = 64 * 1024 * 1024
        /// 条目数上限（次要闸门）：避免大量小转写堆积成几百个字典项
        static let countLimit = 24

        private struct Slot {
            let entry: TranscriptCacheEntry
            let cost: Int
            var usedAt: UInt64
        }

        private var slots: [UUID: Slot] = [:]
        private var totalCost = 0
        private var clock: UInt64 = 0

        /// 按下标在 actor 内取值（不再把整字典拷给调用方）并刷新 LRU 时戳
        func entry(for id: UUID) -> TranscriptCacheEntry? {
            guard let slot = slots[id] else { return nil }
            clock += 1
            slots[id] = Slot(entry: slot.entry, cost: slot.cost, usedAt: clock)
            return slot.entry
        }

        func insert(_ entry: TranscriptCacheEntry, for id: UUID) {
            clock += 1
            let cost = Self.estimateCost(of: entry)
            if let old = slots.removeValue(forKey: id) {
                totalCost -= old.cost
            }
            slots[id] = Slot(entry: entry, cost: cost, usedAt: clock)
            totalCost += cost
            evictIfNeeded()
        }

        func remove(_ id: UUID) {
            guard let old = slots.removeValue(forKey: id) else { return }
            totalCost -= old.cost
        }

        /// 代价估算 = markdown 明文 + 各块文本的 UTF8 字节数（两者内容基本重叠，
        /// 块不另外计入会让上限虚高一倍）
        static func estimateCost(of entry: TranscriptCacheEntry) -> Int {
            let blockBytes = entry.blocks.reduce(0) { $0 + $1.contentByteCount }
            return entry.markdown.utf8.count + blockBytes + 64
        }

        private func evictIfNeeded() {
            // 至少保留一条：当前正在看的录音若被自己刚插入的条目逐出，会变成
            // “每次刷新都重建缓存”的更糟循环
            while slots.count > 1, slots.count > Self.countLimit || totalCost > Self.totalCostLimit {
                // 逐出最久未用；已无条目可逐时停手（单条超大也至少保留一条，
                // 否则当前正在看的录音会反复重建缓存）
                guard let oldest = slots.min(by: { $0.value.usedAt < $1.value.usedAt }) else { return }
                totalCost -= oldest.value.cost
                slots.removeValue(forKey: oldest.key)
            }
        }
    }

    private static let store = Store()

    static func entry(for recordingID: UUID) async -> TranscriptCacheEntry? {
        await store.entry(for: recordingID)
    }

    static func insert(entry: TranscriptCacheEntry, for recordingID: UUID) async {
        await store.insert(entry, for: recordingID)
    }

    /// 写路径失效入口（转写完成/片段编辑/撤销/声纹改名等）
    static func invalidate(recordingID: UUID) async {
        await store.remove(recordingID)
    }
}
