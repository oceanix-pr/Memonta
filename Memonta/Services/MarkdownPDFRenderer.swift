import CoreGraphics
import CoreText
import Foundation

/// 把 Markdown 文本排版成分页 PDF（默认 A4），供右键「导出 → .pdf」与单测共用。
///
/// 为什么自己排版，而不是把 SwiftUI 视图截图或交给 WebKit：
/// - `ImageRenderer` 一次只出一张画布，长转写（数万字）会被截断；
/// - `WKWebView.createPDF` 要求视图已挂进窗口、必须回主线程异步等待，而 `fileExporter`
///   只在 `FileDocument.fileWrapper` 里同步要一段 `Data`，套不进这个回调；
/// - 纯 CoreText 排版是同步纯函数，可离线单测，中英日韩靠字形回退自动处理，不引新依赖。
///
/// 只用 `kCT*` 属性键与 `CTParagraphStyle`：AppKit/UIKit 的类型（`NSMutableParagraphStyle`
/// 等）在只 `import Foundation` 时不可用，走 CoreText 原生 API 才能让 macOS / iOS 两侧同源编译。
///
/// 已知取舍：`~~删除线~~` 只去标记不画线（CoreText 无删除线属性）；表格按「首行加粗 + · 串列」
/// 输出而不做列宽对齐（跨语言列宽测量不稳定，优先保证内容不丢）。
enum MarkdownPDFRenderer {

    // MARK: - 错误

    enum RenderError: LocalizedError {
        case consumerUnavailable
        case contextUnavailable

        var errorDescription: String? {
            switch self {
            case .consumerUnavailable:
                return String(localized: "无法创建 PDF 导出通道，请重试或检查磁盘空间。")
            case .contextUnavailable:
                return String(localized: "无法创建 PDF 画布，请重试。")
            }
        }
    }

    // MARK: - 排版参数

    struct Configuration {
        /// A4 纵向（pt）
        var pageWidth: CGFloat = 595
        var pageHeight: CGFloat = 842
        var marginLeading: CGFloat = 56
        var marginTrailing: CGFloat = 56
        var marginTop: CGFloat = 56
        /// 正文下边界，页码画在这片留白里
        var marginBottom: CGFloat = 64
        var bodyFontSize: CGFloat = 11
        var showsPageNumbers: Bool = true
        /// 首页标题 + PDF 元数据 Title，一般传条目名
        var title: String?

        init() {}

        var contentWidth: CGFloat {
            max(1, pageWidth - marginLeading - marginTrailing)
        }

        var contentHeight: CGFloat {
            max(1, pageHeight - marginTop - marginBottom)
        }

        /// 正文区域。PDF 上下文原点左下，`minY` 即正文下沿（其下是页脚带）
        var contentRect: CGRect {
            CGRect(x: marginLeading, y: marginBottom, width: contentWidth, height: contentHeight)
        }
    }

    // MARK: - 入口

    /// 渲染为 PDF 数据。内容为空时也产出一页，保证导出文件永远可打开。
    static func render(markdown: String, configuration: Configuration = Configuration()) throws -> Data {
        let attributed = attributedString(from: markdown, configuration: configuration)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        let ranges = pageRanges(for: attributed, framesetter: framesetter, configuration: configuration)

        let sink = NSMutableData()
        guard let consumer = CGDataConsumer(data: sink as CFMutableData) else {
            throw RenderError.consumerUnavailable
        }
        var mediaBox = CGRect(x: 0, y: 0, width: configuration.pageWidth, height: configuration.pageHeight)

        var metadata: [String: Any] = ["Creator": "Memonta"]
        if let title = configuration.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            metadata["Title"] = title
        }
        // 文档元数据只能在创建 PDF 上下文时通过 auxiliaryInfo 传入，beginPage 之后再设无效
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, metadata as CFDictionary) else {
            throw RenderError.contextUnavailable
        }

        let pageCount = ranges.count
        for (index, range) in ranges.enumerated() {
            context.beginPage(mediaBox: &mediaBox)
            let path = CGPath(rect: configuration.contentRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, range, path, nil)
            CTFrameDraw(frame, context)
            if configuration.showsPageNumbers, pageCount > 1 {
                drawPageNumber(index + 1, total: pageCount, configuration: configuration, context: context)
            }
            context.endPage()
        }
        context.closePDF()
        return sink as Data
    }

    /// 单测与预览入口：只产出排版好的富文本，不落 PDF
    static func attributedString(
        from markdown: String,
        configuration: Configuration = Configuration()
    ) -> NSAttributedString {
        let typography = Typography(bodySize: configuration.bodyFontSize, contentWidth: configuration.contentWidth)
        let output = NSMutableAttributedString()

        if let title = configuration.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            output.append(NSAttributedString(string: title + "\n", attributes: typography.attributes(
                font: typography.titleFont, color: typography.ink, paragraph: typography.titleParagraph
            )))
        }

        for block in blocks(from: markdown) {
            append(block, to: output, typography: typography, configuration: configuration)
        }
        return output
    }

    // MARK: - 块级解析

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(text: String)
        case bullet(text: String, depth: Int)
        case numbered(text: String, marker: String, depth: Int)
        case quote(text: String)
        case code(text: String)
        case table(rows: [[String]])
        case rule
    }

    static func blocks(from markdown: String) -> [Block] {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var blocks: [Block] = []
        var paragraph: [String] = []

        func flushParagraph() {
            var joined = ""
            for line in paragraph {
                joined = joined.isEmpty ? line : softJoin(joined, line)
            }
            paragraph.removeAll()
            if !joined.isEmpty { blocks.append(.paragraph(text: joined)) }
        }

        var index = 0
        while index < lines.count {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            // 围栏代码块：内部按原文保留（含缩进），不做行内解析
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                index += 1
                while index < lines.count {
                    let current = lines[index]
                    if current.trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        index += 1
                        break
                    }
                    code.append(stripCodeLine(current))
                    index += 1
                }
                let body = code.joined(separator: "\n")
                if !body.isEmpty { blocks.append(.code(text: body)) }
                continue
            }

            if let (level, text) = headingMatch(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: level, text: text))
                index += 1
                continue
            }

            if isHorizontalRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            if isTableLine(trimmed) {
                flushParagraph()
                var rows: [[String]] = []
                while index < lines.count {
                    let rowText = lines[index].trimmingCharacters(in: .whitespaces)
                    guard isTableLine(rowText) else { break }
                    let cells = tableCells(rowText)
                    if !cells.isEmpty, !cells.allSatisfy(isTableSeparatorCell) { rows.append(cells) }
                    index += 1
                }
                if !rows.isEmpty { blocks.append(.table(rows: rows)) }
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count {
                    let quoteText = lines[index].trimmingCharacters(in: .whitespaces)
                    guard quoteText.hasPrefix(">") else { break }
                    let content = stripNoise(String(quoteText.dropFirst()).trimmingCharacters(in: .whitespaces))
                    if !content.isEmpty { quoted.append(content) }
                    index += 1
                }
                if !quoted.isEmpty {
                    var text = ""
                    for line in quoted { text = text.isEmpty ? line : softJoin(text, line) }
                    blocks.append(.quote(text: text))
                }
                continue
            }

            if let item = listItem(raw) {
                flushParagraph()
                blocks.append(item)
                index += 1
                continue
            }

            let content = stripNoise(trimmed)
            if !content.isEmpty { paragraph.append(content) }
            index += 1
        }
        flushParagraph()
        return blocks
    }

    /// `#`~`######`；7 个以上 `#` 按普通文本处理
    private static func headingMatch(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard hashes >= 1, hashes <= 6 else { return nil }
        let rest = String(line.dropFirst(hashes))
        guard rest.isEmpty || rest.hasPrefix(" ") || rest.hasPrefix("\t") else { return nil }
        let text = stripNoise(rest)
        return text.isEmpty ? nil : (hashes, text)
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let collapsed = line.replacingOccurrences(of: " ", with: "")
        guard collapsed.count >= 3 else { return false }
        return collapsed.allSatisfy { $0 == "-" } || collapsed.allSatisfy { $0 == "*" } || collapsed.allSatisfy { $0 == "_" }
    }

    private static func isTableLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("|") && trimmed.filter { $0 == "|" }.count >= 2
    }

    private static func tableCells(_ line: String) -> [String] {
        var content = line.trimmingCharacters(in: .whitespaces)
        if content.hasPrefix("|") { content.removeFirst() }
        if content.hasSuffix("|") { content.removeLast() }
        return content.components(separatedBy: "|").map { stripNoise($0) }
    }

    /// `|---|:--:|` 这类分隔行只用于标记表头，本身不出内容
    private static func isTableSeparatorCell(_ cell: String) -> Bool {
        !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
    }

    /// 行首缩进按 2 空格一级折算，最深 4 级（再深按 4 级处理，避免越缩越窄）
    private static func listItem(_ line: String) -> Block? {
        let spaces = line.prefix(while: { $0 == " " }).count
        let tabs = line.prefix(while: { $0 == "\t" }).count
        let depth = min(4, max(0, (spaces + tabs * 2) / 2))
        let body = line.drop(while: { $0 == " " || $0 == "\t" })

        if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
            var text = body.dropFirst(2)
            var checked: Bool?
            if text.hasPrefix("[ ]") {
                checked = false
                text = text.dropFirst(3)
            } else if text.hasPrefix("[x]") || text.hasPrefix("[X]") {
                checked = true
                text = text.dropFirst(3)
            }
            let content = stripNoise(String(text))
            guard !content.isEmpty || checked != nil else { return nil }
            let marker = checked == true ? "☑ " : (checked == false ? "☐ " : "")
            return .bullet(text: marker + content, depth: depth)
        }

        let digits = body.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        let rest = body.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        let content = stripNoise(String(rest.dropFirst(2)))
        guard !content.isEmpty else { return nil }
        return .numbered(text: content, marker: "\(digits).", depth: depth)
    }

    // MARK: - 块 → 富文本

    private static func append(
        _ block: Block,
        to output: NSMutableAttributedString,
        typography: Typography,
        configuration: Configuration
    ) {
        switch block {
        case .heading(let level, let text):
            appendInline(text, to: output, font: typography.headingFont(level), color: typography.ink,
                         paragraph: typography.headingParagraph(level), typography: typography)

        case .paragraph(let text):
            appendInline(text, to: output, font: typography.bodyFont, color: typography.ink,
                         paragraph: typography.bodyParagraph, typography: typography)

        case .bullet(let text, let depth):
            let paragraph = typography.listParagraph(depth)
            let marker = depth.isMultiple(of: 2) ? "•  " : "◦  "
            output.append(NSAttributedString(string: marker, attributes: typography.attributes(
                font: typography.bodyFont, color: typography.secondary, paragraph: paragraph
            )))
            appendInline(text, to: output, font: typography.bodyFont, color: typography.ink,
                         paragraph: paragraph, typography: typography)

        case .numbered(let text, let marker, let depth):
            let paragraph = typography.listParagraph(depth)
            output.append(NSAttributedString(string: marker + "  ", attributes: typography.attributes(
                font: typography.bodyFont, color: typography.secondary, paragraph: paragraph
            )))
            appendInline(text, to: output, font: typography.bodyFont, color: typography.ink,
                         paragraph: paragraph, typography: typography)

        case .quote(let text):
            appendInline(text, to: output, font: typography.bodyFont, color: typography.secondary,
                         paragraph: typography.quoteParagraph, typography: typography)

        case .code(let text):
            output.append(NSAttributedString(string: text + "\n", attributes: [
                keyFont: typography.monoFont,
                keyForeground: typography.secondary,
                keyParagraph: typography.codeParagraph,
                keyBackground: typography.codeBackground
            ]))

        case .table(let rows):
            for (rowIndex, row) in rows.enumerated() {
                let cells = row.filter { !$0.isEmpty }
                guard !cells.isEmpty else { continue }
                let isHeader = rowIndex == 0
                appendInline(cells.joined(separator: "  ·  "), to: output,
                             font: isHeader ? typography.strongBody : typography.bodyFont,
                             color: typography.ink,
                             paragraph: typography.tableParagraph(isHeader: isHeader), typography: typography)
            }

        case .rule:
            // 分隔线用 box-drawing 字符拼：实际绘制会发生字体替换（量到的 advance 偏小），
            // 按整宽拼会多出一小截换行。取约 1/3 宽并居中，当作有意为之的短分隔线
            let advance = glyphAdvance(of: "─", font: typography.bodyFont)
            let count = advance > 0
                ? max(12, min(80, Int(configuration.contentWidth * 0.36 / advance)))
                : 20
            output.append(NSAttributedString(string: String(repeating: "─", count: count) + "\n", attributes: [
                keyFont: typography.bodyFont,
                keyForeground: typography.faint,
                keyParagraph: typography.ruleParagraph
            ]))
        }
    }

    // MARK: - 行内标记

    /// 块级入口：解析行内标记并补段落结束符。
    /// 换行只在块这一层加，递归调用 `appendInlineContent` 不能再加，
    /// 否则 `**粗体**：正文` 会在粗体后被断成两行。
    private static func appendInline(
        _ text: String,
        to output: NSMutableAttributedString,
        font: CTFont,
        color: CGColor,
        paragraph: CTParagraphStyle,
        typography: Typography
    ) {
        appendInlineContent(text, to: output, font: font, color: color, paragraph: paragraph, typography: typography)
        output.append(NSAttributedString(string: "\n", attributes: typography.attributes(
            font: font, color: color, paragraph: paragraph
        )))
    }

    /// 支持 `**粗体**`、`__粗体__`、`*斜体*`、`` `代码` ``、`~~删除线~~`（去标记不画线）、
    /// `[文字](链接)`、`![替代文字](链接)`。
    /// 找不到闭合标记时按原文输出，避免会议文本里一个裸 `*` 把后面整段吞成斜体。
    private static func appendInlineContent(
        _ text: String,
        to output: NSMutableAttributedString,
        font: CTFont,
        color: CGColor,
        paragraph: CTParagraphStyle,
        typography: Typography
    ) {
        var rest = Substring(text)
        while !rest.isEmpty {
            if let link = matchLink(in: rest) {
                appendPlain(rest[..<link.range.lowerBound], to: output, font: font, color: color,
                            paragraph: paragraph, typography: typography)
                let label = String(link.label)
                output.append(NSAttributedString(string: label.isEmpty ? " " : label, attributes: typography.attributes(
                    font: font,
                    color: link.isImage ? typography.secondary : typography.accent,
                    paragraph: paragraph,
                    underline: link.isImage ? nil : true
                )))
                // 链接文字与 URL 不同时补一段灰色 URL，否则导出后链接信息就丢了
                if !link.isImage, !link.url.isEmpty, link.url != label {
                    appendPlain(Substring(" (\(link.url))"), to: output, font: font,
                                color: typography.faint, paragraph: paragraph, typography: typography)
                }
                rest = Substring(rest[link.range.upperBound...])
                continue
            }

            guard let mark = nextMark(in: rest) else {
                appendPlain(rest, to: output, font: font, color: color, paragraph: paragraph, typography: typography)
                return
            }

            appendPlain(rest[..<mark.range.lowerBound], to: output, font: font, color: color,
                        paragraph: paragraph, typography: typography)
            let after = Substring(rest[mark.range.upperBound...])
            guard let closing = after.range(of: mark.token, options: [],
                                            range: after.startIndex..<after.endIndex, locale: nil),
                  closing.lowerBound != after.startIndex else {
                // 无闭合标记：原样输出该标记，继续处理后面的内容
                appendPlain(Substring(mark.token), to: output, font: font, color: color,
                            paragraph: paragraph, typography: typography)
                rest = after
                continue
            }
            let inner = String(after[..<closing.lowerBound])
            switch mark.kind {
            case .code:
                output.append(NSAttributedString(string: inner, attributes: [
                    keyFont: typography.monoFont,
                    keyForeground: typography.secondary,
                    keyParagraph: paragraph,
                    keyBackground: typography.codeBackground
                ]))
            case .bold, .boldAlt:
                appendInlineContent(inner, to: output, font: typography.boldish(font), color: color,
                                    paragraph: paragraph, typography: typography)
            case .italic, .italicAlt:
                appendInlineContent(inner, to: output, font: typography.italicize(font), color: color,
                                    paragraph: paragraph, typography: typography)
            case .strike:
                appendInlineContent(inner, to: output, font: font, color: typography.secondary,
                                    paragraph: paragraph, typography: typography)
            }
            rest = Substring(after[closing.upperBound...])
        }
    }

    private static func appendPlain(
        _ slice: Substring,
        to output: NSMutableAttributedString,
        font: CTFont,
        color: CGColor,
        paragraph: CTParagraphStyle,
        typography: Typography
    ) {
        guard !slice.isEmpty else { return }
        output.append(NSAttributedString(string: String(slice), attributes: typography.attributes(
            font: font, color: color, paragraph: paragraph
        )))
    }

    private enum InlineMark: String, CaseIterable {
        case bold = "**"
        case boldAlt = "__"
        case italic = "*"
        case italicAlt = "_"
        case code = "`"
        case strike = "~~"

        var token: String { rawValue }

        /// 紧贴 ASCII 字母/数字时按原文处理，保护 `snake_case`、`__init__`、`10*5`；
        /// 中日韩字符相邻不算「单词粘连」，`*强调*` 这类要照常生效
        var requiresWordBoundaryGuard: Bool {
            switch self {
            case .italic, .italicAlt, .boldAlt: return true
            case .bold, .code, .strike: return false
            }
        }
    }

    /// 取最先出现的标记；同位置长标记优先（`**` 先于 `*`）
    private static func nextMark(in text: Substring) -> (kind: InlineMark, token: String, range: Range<Substring.Index>)? {
        var best: (kind: InlineMark, token: String, range: Range<Substring.Index>)?
        for mark in InlineMark.allCases {
            var searchFrom = text.startIndex
            while let range = text.range(of: mark.token, options: [], range: searchFrom..<text.endIndex, locale: nil) {
                let blocked = mark.requiresWordBoundaryGuard
                    && (isASCIIWordCharacter(before: range.lowerBound, in: text)
                        || isASCIIWordCharacter(after: range.upperBound, in: text))
                if !blocked {
                    let beatsCurrent: Bool
                    if let current = best {
                        beatsCurrent = range.lowerBound < current.range.lowerBound
                            || (range.lowerBound == current.range.lowerBound && mark.token.count > current.token.count)
                    } else {
                        beatsCurrent = true
                    }
                    if beatsCurrent { best = (mark, mark.token, range) }
                    break
                }
                let next = text.index(after: range.lowerBound)
                if next >= text.endIndex { break }
                searchFrom = next
            }
        }
        return best
    }

    private static func isASCIIWordCharacter(before index: Substring.Index, in text: Substring) -> Bool {
        guard index != text.startIndex else { return false }
        return isASCIIWord(text[text.index(before: index)])
    }

    private static func isASCIIWordCharacter(after index: Substring.Index, in text: Substring) -> Bool {
        guard index < text.endIndex else { return false }
        return isASCIIWord(text[index])
    }

    private static func isASCIIWord(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }

    /// `[文字](URL)`；前缀 `!` 视为图片，只保留替代文字
    private static func matchLink(in text: Substring) -> (label: Substring, url: String, range: Range<Substring.Index>, isImage: Bool)? {
        var searchFrom = text.startIndex
        while let bracket = text.range(of: "[", options: [], range: searchFrom..<text.endIndex, locale: nil)?.lowerBound {
            let isImage = bracket != text.startIndex && text[text.index(before: bracket)] == "!"
            let labelStart = text.index(after: bracket)
            guard let closeBracket = text.range(of: "]", options: [], range: labelStart..<text.endIndex, locale: nil)?.lowerBound else {
                searchFrom = text.index(after: bracket)
                continue
            }
            let parenStart = text.index(after: closeBracket)
            guard parenStart < text.endIndex, text[parenStart] == "(",
                  let closeParen = text.range(of: ")", options: [], range: parenStart..<text.endIndex, locale: nil)?.upperBound else {
                searchFrom = text.index(after: bracket)
                continue
            }
            let rawLabel = text[labelStart..<closeBracket]
            let url = String(text[text.index(after: parenStart)..<text.index(before: closeParen)])
                .trimmingCharacters(in: .whitespaces)
            // 图片的 `!` 一并纳入 range，输出时不留下孤立感叹号
            let start = isImage ? text.index(before: bracket) : bracket
            return (rawLabel.isEmpty ? Substring(" ") : rawLabel, url, start..<closeParen, isImage)
        }
        return nil
    }

    // MARK: - 分页

    private static func pageRanges(
        for attributed: NSAttributedString,
        framesetter: CTFramesetter,
        configuration: Configuration
    ) -> [CFRange] {
        let total = attributed.length
        guard total > 0 else { return [CFRangeMake(0, 0)] }

        let path = CGPath(rect: configuration.contentRect, transform: nil)
        var ranges: [CFRange] = []
        var location = 0
        while location < total {
            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(location, 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length > 0 {
                ranges.append(CFRange(location: location, length: visible.length))
                location += visible.length
                continue
            }
            // 零进展兜底：单个超长不可断词会占满整页并让可见长度归零。
            // 此时按固定步长强制推进（宁可切断），否则该页永远排不下、循环永不退出。
            let step = min(2048, total - location)
            ranges.append(CFRange(location: location, length: step))
            location += step
        }
        return ranges
    }

    private static func drawPageNumber(
        _ page: Int,
        total: Int,
        configuration: Configuration,
        context: CGContext
    ) {
        let typography = Typography(bodySize: configuration.bodyFontSize, contentWidth: configuration.contentWidth)
        // 页码走本地化（含 RTL 语言），不再用 "\(page) / \(total)" 的西方数字硬拼接
        let pageText = String(format: String(localized: "第 %lld 页，共 %lld 页"), page, total)
        let attributed = NSAttributedString(string: pageText, attributes: typography.attributes(
            font: typography.footerFont, color: typography.faint, paragraph: typography.footerParagraph
        ))
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        let rect = CGRect(x: configuration.marginLeading, y: 28, width: configuration.contentWidth, height: 16)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, context)
    }

    // MARK: - 文本清洗与拼接

    /// 清掉导出时只会干扰阅读的残留：BOM、`<br>` 系列标签、首尾空白
    private static func stripNoise(_ line: String) -> String {
        var result = line.replacingOccurrences(of: "\u{feff}", with: "")
        for tag in ["<br/>", "<br />", "<br>", "</br>"] {
            result = result.replacingOccurrences(of: tag, with: " ", options: [.caseInsensitive, .literal])
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// 代码行只去 BOM 与行尾空白：缩进属于内容，不能像正文那样压掉
    private static func stripCodeLine(_ line: String) -> String {
        line.replacingOccurrences(of: "\u{feff}", with: "")
            .replacingOccurrences(of: "[ \t]+$", with: "", options: .regularExpression)
    }

    /// 段落内换行合并：中英混排只在需要空格处补空格，避免中文被排成「的 确」
    private static func softJoin(_ left: String, _ right: String) -> String {
        guard let last = left.last, let first = right.first else { return right }
        let needsSpace = !(last.isCJKLike || first.isCJKLike)
        return left + (needsSpace ? " " : "") + right
    }

    // MARK: - 字体 / 颜色 / 段落样式

    private static let keyFont = NSAttributedString.Key(kCTFontAttributeName as String)
    private static let keyForeground = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
    private static let keyParagraph = NSAttributedString.Key(kCTParagraphStyleAttributeName as String)
    private static let keyUnderline = NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)
    private static let keyBackground = NSAttributedString.Key(kCTBackgroundColorAttributeName as String)

    private static func uiFont(size: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    private static func gray(_ white: CGFloat, _ blueBoost: CGFloat = 0) -> CGColor {
        CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [white, white, white + blueBoost, 1])
            ?? CGColor(gray: white, alpha: 1)
    }

    private static func glyphAdvance(of character: String.Element, font: CTFont) -> CGFloat {
        var utf16 = Array(String(character).utf16)
        var glyph = CGGlyph(0)
        let matched = utf16.withUnsafeMutableBufferPointer { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            return CTFontGetGlyphsForCharacters(font, base, &glyph, 1)
        }
        guard matched else { return 0 }
        var advance = CGSize.zero
        let maxAdvance = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        return max(maxAdvance, advance.width)
    }

    /// 一套排版尺寸与颜色：字号全部相对 bodySize，改一处即可整体缩放；
    /// 段落样式的 `tailIndent` 取正文宽度，否则 CoreText 的居中/右对齐会退化到左边缘
    struct Typography {
        let bodySize: CGFloat

        let ink: CGColor
        let secondary: CGColor
        let faint: CGColor
        let accent: CGColor
        let codeBackground: CGColor

        let bodyFont: CTFont
        let strongBody: CTFont
        let monoFont: CTFont
        let titleFont: CTFont
        let footerFont: CTFont
        let titleParagraph: CTParagraphStyle
        let bodyParagraph: CTParagraphStyle
        let quoteParagraph: CTParagraphStyle
        let codeParagraph: CTParagraphStyle
        let ruleParagraph: CTParagraphStyle
        let footerParagraph: CTParagraphStyle

        private let headingFonts: [CTFont]
        private let headingParagraphs: [CTParagraphStyle]
        private let listParagraphs: [CTParagraphStyle]
        private let tableHeaderParagraph: CTParagraphStyle
        private let tableBodyParagraph: CTParagraphStyle

        init(bodySize: CGFloat, contentWidth: CGFloat) {
            self.bodySize = bodySize

            func style(
                alignment: CTTextAlignment = .left,
                spacingBefore: CGFloat = 0,
                spacingAfter: CGFloat = 0,
                lineSpacing: CGFloat = 0,
                firstLineHeadIndent: CGFloat = 0,
                headIndent: CGFloat = 0
            ) -> CTParagraphStyle {
                MarkdownPDFRenderer.makeParagraphStyle(
                    alignment: alignment,
                    spacingBefore: spacingBefore,
                    spacingAfter: spacingAfter,
                    lineSpacing: lineSpacing,
                    firstLineHeadIndent: firstLineHeadIndent,
                    headIndent: headIndent,
                    tailIndent: contentWidth
                )
            }

            ink = MarkdownPDFRenderer.gray(0.10, 0.02)
            secondary = MarkdownPDFRenderer.gray(0.37, 0.02)
            faint = MarkdownPDFRenderer.gray(0.58)
            accent = CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0.13, 0.36, 0.78, 1])
                ?? MarkdownPDFRenderer.gray(0.35)
            codeBackground = MarkdownPDFRenderer.gray(0.94)

            let base = MarkdownPDFRenderer.uiFont(size: bodySize)
            bodyFont = base
            strongBody = MarkdownPDFRenderer.boldTrait(base, size: bodySize)
            titleFont = MarkdownPDFRenderer.boldTrait(base, size: bodySize + 7)
            footerFont = MarkdownPDFRenderer.uiFont(size: max(6, bodySize - 2))
            monoFont = CTFontCreateWithName("Menlo" as CFString, max(6, bodySize - 0.5), nil)
            headingFonts = (1...6).map { level in
                MarkdownPDFRenderer.boldTrait(base, size: MarkdownPDFRenderer.headingSize(bodySize, level))
            }

            titleParagraph = style(spacingAfter: 10, lineSpacing: 2)
            headingParagraphs = (1...6).map { level in
                style(spacingBefore: level <= 2 ? 16 : 12, spacingAfter: 5, lineSpacing: 2)
            }
            bodyParagraph = style(spacingAfter: 9, lineSpacing: 4)
            quoteParagraph = style(spacingAfter: 9, lineSpacing: 3, firstLineHeadIndent: 14, headIndent: 14)
            codeParagraph = style(spacingBefore: 4, spacingAfter: 10, firstLineHeadIndent: 14, headIndent: 14)
            ruleParagraph = style(alignment: .center, spacingBefore: 8, spacingAfter: 8)
            footerParagraph = style(alignment: .center)
            listParagraphs = (0...4).map { depth in
                style(spacingAfter: 4, lineSpacing: 3, headIndent: 14 + CGFloat(depth) * 14)
            }
            tableHeaderParagraph = style(spacingBefore: 4, spacingAfter: 3, lineSpacing: 2, headIndent: 6)
            tableBodyParagraph = style(spacingAfter: 3, lineSpacing: 2, headIndent: 6)
        }

        func headingFont(_ level: Int) -> CTFont {
            headingFonts[level - 1 < 0 ? 0 : min(headingFonts.count - 1, level - 1)]
        }

        func headingParagraph(_ level: Int) -> CTParagraphStyle {
            headingParagraphs[level - 1 < 0 ? 0 : min(headingParagraphs.count - 1, level - 1)]
        }

        func listParagraph(_ depth: Int) -> CTParagraphStyle {
            listParagraphs[max(0, min(listParagraphs.count - 1, depth))]
        }

        func tableParagraph(isHeader: Bool) -> CTParagraphStyle {
            isHeader ? tableHeaderParagraph : tableBodyParagraph
        }

        /// 标题等本身已是粗体的位置不重复加粗，只提升字重
        func boldish(_ font: CTFont) -> CTFont {
            MarkdownPDFRenderer.boldTrait(font, size: CTFontGetSize(font))
        }

        func italicize(_ font: CTFont) -> CTFont {
            MarkdownPDFRenderer.italicTrait(font, size: CTFontGetSize(font))
        }

        func attributes(
            font: CTFont,
            color: CGColor,
            paragraph: CTParagraphStyle,
            underline: Bool? = nil
        ) -> [NSAttributedString.Key: Any] {
            var attributes: [NSAttributedString.Key: Any] = [
                MarkdownPDFRenderer.keyFont: font,
                MarkdownPDFRenderer.keyForeground: color,
                MarkdownPDFRenderer.keyParagraph: paragraph
            ]
            if underline == true {
                attributes[MarkdownPDFRenderer.keyUnderline] = CTUnderlineStyle.single.rawValue
            }
            return attributes
        }
    }

    private static func headingSize(_ body: CGFloat, _ level: Int) -> CGFloat {
        switch level {
        case 1: return body + 5
        case 2: return body + 3
        case 3: return body + 1.5
        case 4: return body + 0.5
        default: return body
        }
    }

    private static func boldTrait(_ font: CTFont, size: CGFloat) -> CTFont {
        CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitBold, .traitBold)
            ?? CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)
            ?? font
    }

    private static func italicTrait(_ font: CTFont, size: CGFloat) -> CTFont {
        CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitItalic, .traitItalic) ?? font
    }

    /// `CTParagraphStyleCreate` 只在创建那一刻读取设置值，
    /// 因此用一块临时缓冲承载 7 个字段，创建完成后立即释放。
    /// 行距用 `lineSpacingAdjustment`：macOS SDK 已把旧的 `lineSpacing` 标为不可用。
    private static func makeParagraphStyle(
        alignment: CTTextAlignment = .natural,
        spacingBefore: CGFloat = 0,
        spacingAfter: CGFloat = 0,
        lineSpacing: CGFloat = 0,
        firstLineHeadIndent: CGFloat = 0,
        headIndent: CGFloat = 0,
        tailIndent: CGFloat = 0
    ) -> CTParagraphStyle {
        let fieldSize = MemoryLayout<CGFloat>.stride
        let block = UnsafeMutableRawPointer.allocate(
            byteCount: fieldSize * 7 + 1,
            alignment: MemoryLayout<CGFloat>.alignment
        )
        defer { block.deallocate() }

        // CTTextAlignment 在 SDK 里是 uint8_t：写成 Int32 时 valueSize 与类型不符，
        // CTParagraphStyleCreate 会直接丢弃该设置（居中页码会退化成左对齐）
        block.storeBytes(of: UInt8(alignment.rawValue), as: UInt8.self)
        block.storeBytes(of: lineSpacing, toByteOffset: fieldSize, as: CGFloat.self)
        block.storeBytes(of: spacingBefore, toByteOffset: fieldSize * 2, as: CGFloat.self)
        block.storeBytes(of: spacingAfter, toByteOffset: fieldSize * 3, as: CGFloat.self)
        block.storeBytes(of: firstLineHeadIndent, toByteOffset: fieldSize * 4, as: CGFloat.self)
        block.storeBytes(of: headIndent, toByteOffset: fieldSize * 5, as: CGFloat.self)
        block.storeBytes(of: tailIndent, toByteOffset: fieldSize * 6, as: CGFloat.self)
        // 基准书写方向：RTL 语言（阿拉伯语等）下正文按右到左排版。
        // 显式设置它，配合默认的 .natural 对齐，导出的 PDF 不会恒为左对齐
        block.storeBytes(
            of: isRightToLeft ? CTWritingDirection.rightToLeft.rawValue
                              : CTWritingDirection.leftToRight.rawValue,
            toByteOffset: fieldSize * 7, as: Int8.self
        )

        let settings: [CTParagraphStyleSetting] = [
            CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<UInt8>.size, value: block),
            CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: fieldSize, value: block.advanced(by: fieldSize)),
            CTParagraphStyleSetting(spec: .paragraphSpacingBefore, valueSize: fieldSize, value: block.advanced(by: fieldSize * 2)),
            CTParagraphStyleSetting(spec: .paragraphSpacing, valueSize: fieldSize, value: block.advanced(by: fieldSize * 3)),
            CTParagraphStyleSetting(spec: .firstLineHeadIndent, valueSize: fieldSize, value: block.advanced(by: fieldSize * 4)),
            CTParagraphStyleSetting(spec: .headIndent, valueSize: fieldSize, value: block.advanced(by: fieldSize * 5)),
            CTParagraphStyleSetting(spec: .tailIndent, valueSize: fieldSize, value: block.advanced(by: fieldSize * 6)),
            CTParagraphStyleSetting(spec: .baseWritingDirection, valueSize: MemoryLayout<Int8>.size, value: block.advanced(by: fieldSize * 7))
        ]
        return CTParagraphStyleCreate(settings, settings.count)
    }

    /// 当前界面语言是否为 RTL（用于 PDF 导出基准书写方向）
    private static var isRightToLeft: Bool {
        let code = Locale.current.language.languageCode?.identifier ?? ""
        return ["ar", "he", "fa", "ur", "yi"].contains(code)
    }
}

private extension Character {
    /// 中日韩与全角标点：这类字符之间补空格会明显破坏排版
    var isCJKLike: Bool {
        unicodeScalars.contains { scalar in
            (0x2E80...0x9FFF).contains(scalar.value)
                || (0xAC00...0xD7AF).contains(scalar.value)
                || (0x3040...0x30FF).contains(scalar.value)
                || (0xFF00...0xFFEF).contains(scalar.value)
        }
    }
}
