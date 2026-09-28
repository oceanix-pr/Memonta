import SwiftUI

/// 轻量 Markdown 渲染视图，支持标题、列表、粗体、代码等常见格式
///
/// 性能设计：
/// - 可直接消费预解析的 `TranscriptBlock`（后台线程解析+缓存），
///   避免长转写稿在切换录音时于主线程重复解析
/// - 未传 `blocks` 时走 `MarkdownParseCache` 记忆解析：输入未变直接复用上一次结果，
///   不再每次 body 求值都重排整篇文本（见下方注释）
/// - 使用 LazyVStack 懒渲染，仅构建可视区域的块
struct MarkdownView: View {
    let markdown: String
    /// 预解析块（来自 TranscriptCache）；为 nil 时按 markdown 即时解析（带记忆）
    var blocks: [TranscriptBlock]? = nil
    /// 搜索高亮：大小写不敏感地高亮所有匹配片段（为空时不做任何处理）
    var highlightText: String = ""
    /// 高亮背景色（当前定位的匹配可用不同颜色区分）
    var highlightColor: Color = .yellow

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            let resolvedBlocks = blocks ?? MarkdownParseCache.shared.blocks(for: markdown)
            ForEach(Array(resolvedBlocks.enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 块级渲染

    @ViewBuilder
    private func renderBlock(_ block: TranscriptBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            renderHeading(level: level, text: text)

        case .paragraph(let text):
            renderInlineText(text, font: .title3)
                .textSelection(.enabled)

        case .bulletItem(let text):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .font(.title3)
                renderInlineText(text, font: .title3)
                    .textSelection(.enabled)
            }

        case .numberedItem(let number, let text):
            HStack(alignment: .top, spacing: 6) {
                Text("\(number).")
                    .font(.title3)
                    .frame(width: 28, alignment: .leading)
                renderInlineText(text, font: .title3)
                    .textSelection(.enabled)
            }

        case .codeBlock(let text):
            Text(text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(10)
                .background(.quaternary.opacity(0.5))
                .cornerRadius(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(.secondary)
                    .frame(width: 3)
                renderInlineText(text, font: .title3)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

        case .divider:
            Divider()
        }
    }

    @ViewBuilder
    private func renderHeading(level: Int, text: String) -> some View {
        // 标题直接用 Text + font，不用 AttributedString 避免样式覆盖
        switch level {
        case 1:
            Text(text)
                .font(.largeTitle.bold())
        case 2:
            Text(text)
                .font(.title.bold())
        default:
            Text(text)
                .font(.title2.bold())
        }
    }

    /// 渲染行内格式（粗体、斜体、行内代码），并按需叠加搜索高亮
    private func renderInlineText(_ text: String, font: Font) -> some View {
        Text(attributedInlineText(text))
            .font(font)
    }

    /// 解析行内 Markdown，解析失败回退纯文本，再叠加搜索高亮。
    /// 结果按 (文本, 高亮词, 高亮色) 记忆：块级已有记忆，但行内 `AttributedString(markdown:)`
    /// 与高亮扫描此前在每次 body 求值时对每个可见块重跑，长文档滚动/播放进度刷新时会持续掉帧
    private func attributedInlineText(_ text: String) -> AttributedString {
        MarkdownInlineCache.shared.attributed(
            text: text,
            highlight: highlightText,
            color: highlightColor
        ) {
            var attributed: AttributedString
            if let parsed = try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                attributed = parsed
            } else {
                attributed = AttributedString(text)
            }
            highlightMatches(in: &attributed)
            return attributed
        }
    }

    /// 大小写不敏感高亮所有匹配片段：AttributedString 与 String 的字符索引一一对应，
    /// 先在纯文本上定位字符偏移，再映射回 AttributedString 的 Range 应用背景色
    private func highlightMatches(in attributed: inout AttributedString) {
        let needle = highlightText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return }
        let needleChars = Array(needle.lowercased())
        let hayChars = Array(String(attributed.characters).lowercased())
        guard !needleChars.isEmpty, hayChars.count >= needleChars.count else { return }

        var positions: [Range<Int>] = []
        var i = 0
        while i + needleChars.count <= hayChars.count {
            if hayChars[i..<(i + needleChars.count)].elementsEqual(needleChars) {
                positions.append(i..<(i + needleChars.count))
                i += needleChars.count // 不重叠匹配
            } else {
                i += 1
            }
        }
        guard !positions.isEmpty else { return }

        for range in positions.reversed() {
            let start = attributed.index(attributed.startIndex, offsetByCharacters: range.lowerBound)
            let end = attributed.index(attributed.startIndex, offsetByCharacters: range.upperBound)
            attributed[start..<end].backgroundColor = highlightColor.opacity(0.55)
        }
    }
}

// MARK: - Markdown 解析记忆

/// `MarkdownView` 未收到预解析 `blocks` 时的解析记忆。
///
/// 旧写法在 `body` 里直接 `parseBlocks(markdown)`：SwiftUI 每次求值 body 都会把
/// 整篇文本重新按行切分并重建全部块（选中项变化、动画、父视图失效都会触发），
/// 再叠加流式总结的逐 token 刷新，形成"总结越长越卡、结束时最卡"。
/// 这里记住最近一次的 (输入, 解析结果)：输入未变则复用，输入变化才重解析。
/// 代价是一次字符串比较（O(n) 且无分配），远低于重解析的分配量。
///
/// 说明：块 id 仍用下标而非内容。转写/总结里存在完全相同的行（如重复的
/// 列表项与分隔线），用内容做 id 会产生重复标识符，反而破坏 SwiftUI 的差量更新。
final class MarkdownParseMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var source: String?
    private var parsed: [TranscriptBlock] = []

    func blocks(for markdown: String) -> [TranscriptBlock] {
        lock.lock()
        defer { lock.unlock() }
        if source == markdown { return parsed }
        let result = TranscriptMarkdownBuilder.parseBlocks(markdown)
        source = markdown
        parsed = result
        return result
    }

    /// 内容被就地编辑后强制失效（可选入口，供写路径调用）
    func invalidate() {
        lock.lock()
        source = nil
        parsed = []
        lock.unlock()
    }
}

enum MarkdownParseCache {
    /// 进程级单例：MarkdownView 会被多个页面并发创建，记忆必须共享
    static let shared = MarkdownParseMemo()
}

/// 行内解析 + 高亮的记忆（进程级共享）。
///
/// `MarkdownView` 每次 body 求值都会对每个可见块重跑行内 `AttributedString(markdown:)`
/// 与逐字符高亮扫描（成本随文本长度增长），叠加播放进度/流式刷新时形成持续主线程负载。
/// 这里按 (文本, 高亮词, 高亮色) 缓存结果；超过容量上限时整体清空（可见块数量有限，
/// 不会长期膨胀）。
final class InlineTextMemo: @unchecked Sendable {
    private struct Key: Hashable {
        let text: String
        let highlight: String
        let color: Color
    }

    private let lock = NSLock()
    private var cache: [Key: AttributedString] = [:]
    private let capacity = 512

    func attributed(
        text: String,
        highlight: String,
        color: Color,
        build: () -> AttributedString
    ) -> AttributedString {
        let key = Key(text: text, highlight: highlight, color: color)
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        // 在锁外构建，避免解析期间阻塞其他块；并发重复构建结果一致，可接受
        let value = build()

        lock.lock()
        if cache.count >= capacity { cache.removeAll(keepingCapacity: true) }
        cache[key] = value
        lock.unlock()
        return value
    }
}

enum MarkdownInlineCache {
    /// 进程级单例：与块级解析记忆同理，需跨页面共享
    static let shared = InlineTextMemo()
}
