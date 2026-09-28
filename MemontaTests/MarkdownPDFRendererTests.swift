import CoreGraphics
import Foundation
import Testing

@testable import Memonta

/// `MarkdownPDFRenderer` 的排版回归测试。
///
/// 这些用例对应首轮实现时真实踩到的问题，改动排版时优先看它们是否还成立：
///
/// 1. **产物必须是可打开的多页 PDF**：CoreText 分页靠 `CTFrameGetVisibleStringRange` 推进，
///    写错一步就会产出 0 页或死循环，而这类问题在 UI 上只表现为「导出了个空文件」。
/// 2. **代码块不能丢首行**：围栏扫描里 `index += 1` 与取行顺序一旦写反，
///    第一行代码会被跳过、闭合的 ``` 反被当成正文。
/// 3. **行内标记不能吞掉换行**：递归解析若在每层都补 `\n`，`**已确认**：正文` 会被断成两行。
/// 4. **`*` / `_` 的相邻判定只看 ASCII**：中日韩相邻时按单词粘连处理会让 `*强调*` 全部失效。
struct MarkdownPDFRendererTests {

    // MARK: - 辅助

    private func configuration(title: String? = nil) -> MarkdownPDFRenderer.Configuration {
        var configuration = MarkdownPDFRenderer.Configuration()
        configuration.title = title
        return configuration
    }

    private func pdfPageCount(_ data: Data) -> Int {
        guard let provider = CGDataProvider(data: data as CFData),
              let pdf = CGPDFDocument(provider) else { return -1 }
        return pdf.numberOfPages
    }

    private func lines(_ markdown: String, title: String? = nil) -> [String] {
        MarkdownPDFRenderer.attributedString(from: markdown, configuration: configuration(title: title))
            .string
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    // MARK: - PDF 产物

    @Test func testRenderProducesOpenablePDF() throws {
        let data = try MarkdownPDFRenderer.render(
            markdown: "# 会议总结\n\n- 第一项\n- 第二项",
            configuration: configuration(title: "测试录音")
        )
        #expect(data.count > 1024)
        #expect(String(data: data.prefix(5), encoding: .ascii) == "%PDF-")
        #expect(pdfPageCount(data) == 1)
    }

    @Test func testEmptyContentStillProducesOnePage() throws {
        let data = try MarkdownPDFRenderer.render(markdown: "   \n\n   ", configuration: configuration())
        #expect(!data.isEmpty)
        #expect(pdfPageCount(data) == 1)
    }

    @Test func testLongTranscriptPaginatesAndStaysSingleDocument() throws {
        var markdown = ""
        for index in 0..<300 {
            markdown += "**00:\(String(format: "%02d", index % 60)):00 · 发言人\(index % 3)**\n\n"
            markdown += "第 \(index) 段会议内容，讨论导出格式、排版细节与中英混排的分页边界情况。\n\n---\n\n"
        }
        let data = try MarkdownPDFRenderer.render(markdown: markdown, configuration: configuration(title: "长会议"))
        let pages = pdfPageCount(data)
        #expect(pages > 3)
        // 分页推进必须覆盖全文：页数过少说明有内容被丢掉，过多说明每页没排满
        #expect(pages < 60)
    }

    /// 单个超长不可断词会占满整页并让可见长度归零，必须有步长兜底而不是卡死或产出空文档
    @Test func testUnbreakableTokenDoesNotStallLayout() throws {
        let token = String(repeating: "a", count: 20_000)
        let data = try MarkdownPDFRenderer.render(markdown: "开头\n\n\(token)\n\n结尾", configuration: configuration())
        #expect(pdfPageCount(data) >= 2)
    }

    // MARK: - 块级解析

    @Test func testBlockKindsAreRecognized() {
        let blocks = MarkdownPDFRenderer.blocks(from: """
        # 一级标题
        ## 二级标题

        普通段落。

        - 无序项
        1. 有序项
        > 引用
        ---
        """)
        #expect(blocks.contains(.heading(level: 1, text: "一级标题")))
        #expect(blocks.contains(.heading(level: 2, text: "二级标题")))
        #expect(blocks.contains(.paragraph(text: "普通段落。")))
        #expect(blocks.contains(.bullet(text: "无序项", depth: 0)))
        #expect(blocks.contains(.numbered(text: "有序项", marker: "1.", depth: 0)))
        #expect(blocks.contains(.quote(text: "引用")))
        #expect(blocks.contains(.rule))
    }

    /// 围栏代码块：首行不能丢、闭合 ``` 不能进正文、缩进要原样保留
    @Test func testFencedCodeKeepsEveryLineAndIndentation() {
        let blocks = MarkdownPDFRenderer.blocks(from: """
        ```swift
        let data = try render(markdown: text)
            print("缩进保留")
        ```
        """)
        #expect(blocks == [.code(text: "let data = try render(markdown: text)\n    print(\"缩进保留\")")])
    }

    @Test func testTableSeparatorRowIsDroppedButHeaderKept() {
        let blocks = MarkdownPDFRenderer.blocks(from: """
        | 项目 | 内容 |
        |---|---|
        | 时间 | 10:00 |
        """)
        #expect(blocks == [.table(rows: [["项目", "内容"], ["时间", "10:00"]])])
    }

    @Test func testTaskListMarkersBecomeCheckBoxes() {
        let blocks = MarkdownPDFRenderer.blocks(from: """
        - [x] 已完成
        - [ ] 待办
        """)
        #expect(blocks.contains(.bullet(text: "☑ 已完成", depth: 0)))
        #expect(blocks.contains(.bullet(text: "☐ 待办", depth: 0)))
    }

    // MARK: - 行内标记

    @Test func testInlineMarksAreConsumedWithoutResidue() {
        let text = lines("**粗体**、*斜体*、`代码`、~~删除线~~").joined(separator: "\n")
        #expect(!text.contains("**"))
        #expect(!text.contains("~~"))
        #expect(!text.contains("`"))
        // 粗体后的正文必须留在同一行：递归解析里多补一个 \n 就会在这里断行
        #expect(text.contains("粗体、斜体、代码、删除线"))
    }

    /// 相邻判定只看 ASCII：`snake_case`、`10*5` 保持原样，而中文里的 `*强调*` 要生效
    @Test func testEmphasisGuardsOnlyASCIIWordBoundaries() {
        let protected = lines("注意 snake_case_name 与 10*5=50 不要被打断").joined(separator: "")
        #expect(protected.contains("snake_case_name"))
        #expect(protected.contains("10*5=50"))

        let cjk = lines("这里是*重点*内容").joined(separator: "")
        #expect(cjk == "这里是重点内容")
    }

    @Test func testLinkKeepsURLWhenLabelDiffers() {
        let text = lines("参考 [导出需求](https://example.com/req) 说明").joined(separator: "")
        #expect(text.contains("导出需求"))
        #expect(text.contains("https://example.com/req"))
        #expect(!text.contains("["))
    }

    @Test func testUnbalancedMarkerFallsBackToLiteralText() {
        // 只有一个裸 * 时不能把后面整段吞掉
        let text = lines("占比 50* 以上，后面还有很长的正文内容").joined(separator: "")
        #expect(text.contains("以上，后面还有很长的正文内容"))
    }

    /// 分隔线按整宽拼会因字体替换多出一小截换行，实测要求每条 rule 只占一行且长度一致
    @Test func testHorizontalRuleStaysOnOneLine() {
        let content = lines("---\n\n正文\n\n---")
        let ruleLines = content.filter { $0.contains("─") }
        #expect(ruleLines.count == 2)
        let dashCounts = Set(ruleLines.map { $0.filter { $0 == "─" }.count })
        #expect(dashCounts.count == 1)
    }

    // MARK: - 段落合并

    @Test func testSoftLineJoinDoesNotInsertSpaceBetweenCJK() {
        let text = lines("今天讨论\n排期问题").joined(separator: "")
        #expect(text == "今天讨论排期问题")

        let latin = lines("discuss the\nschedule issue").joined(separator: "")
        #expect(latin == "discuss the schedule issue")
    }

    @Test func testTitleIsRenderedOnceAtTop() {
        let content = lines("# 正文标题\n\n内容", title: "录音条目名")
        #expect(content.first == "录音条目名")
        #expect(content.contains("正文标题"))
    }
}
