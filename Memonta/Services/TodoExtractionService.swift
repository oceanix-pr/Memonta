import Foundation
import os.log

/// AI 待办拆解服务：把总结 / 文本 / OCR 文本拆解为结构化待办列表
///
/// 复用 LLMService 的网络请求与重试约定，但使用独立的 system prompt
/// 强制 LLM 返回严格 JSON。本地模型（LM Studio / Ollama）也走同一管线。
enum TodoExtractionService {

    private static let logger = Logger(subsystem: "com.oceanix.Memonta", category: "TodoExtraction")

    /// 网络重试次数（与 LLMService 一致）
    private static let maxRetries = 3

    /// 输入文本最大字符数（防止超出模型上下文/请求体过大）
    private static let maxInputCharacters = 100_000

    /// 拆解待办（非流式，要求 LLM 返回完整 JSON）
    /// - Parameters:
    ///   - content: 输入文本（总结 / 快捷笔记文字 / OCR 文本）
    ///   - config: LLM 配置快照
    ///   - source: 来源标识，用于持久化
    static func extract(
        from content: String,
        config: LLMConfigSnapshot,
        source: String,
        isMeeting: Bool? = nil,
        piiScrubbed: Bool = false
    ) async throws -> TodoDocument {
        guard let url = URL(string: config.chatCompletionsURL) else {
            throw LLMError.invalidURL
        }
        // 云端配置必须 HTTPS；本地模型（含局域网 IP）允许明文 HTTP
        try LLMService.validateSecureURL(for: config)

        // 限制输入长度
        let cappedContent = content.count > maxInputCharacters
            ? String(content.prefix(maxInputCharacters))
            : content

        // 提示词经 PromptTemplateStore 解析：用户可在「设置 → 提示词」自定义，未自定义时用内置默认
        let baseSystemPrompt = PromptTemplateStore.resolved(.todoExtraction)
        // 已确认非会议（课程/讲座/演示）时追加内容类型条款，
        // 防止把知识要点硬包装成会议式行动项；未判定/会议维持原行为
        let basePrompt = isMeeting == false
            ? baseSystemPrompt + "\n\n" + nonMeetingClause
            : baseSystemPrompt

        let requestBody: [String: Any] = [
            "model": config.modelName,
            "messages": [
                ["role": "system", "content": piiScrubbed
                    ? basePrompt + "\n\n" + LLMService.piiPlaceholderRule
                    : basePrompt],
                ["role": "user", "content": userPrompt(content: cappedContent)]
            ],
            "stream": false,
            "temperature": 0.3,
            "max_tokens": 65536
        ]

        // 本地模型不重试
        if config.isLocal {
            return try await performRequest(url: url, config: config, body: requestBody, source: source)
        }

        // 云端 API 带重试
        var lastError: Error?
        for attempt in 1...maxRetries {
            do {
                return try await performRequest(url: url, config: config, body: requestBody, source: source)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if case LLMError.apiError(let statusCode, _) = error,
                   statusCode >= 400 && statusCode < 500 {
                    throw error
                }
                if attempt < maxRetries {
                    let delay = UInt64(attempt) * 1_000_000_000
                    try await Task.sleep(nanoseconds: delay)   // 取消上抛：旧写法退避后仍重发剩余请求
                }
            }
        }
        throw lastError ?? LLMError.invalidResponse
    }

    /// 从图片拆解待办（多模态：图片直发支持视觉的 LLM）
    /// - Parameters:
    ///   - imageData: PNG 图片数据
    ///   - config: LLM 配置快照（需 supportsVision == true）
    ///   - source: 来源标识
    static func extractFromImage(
        imageData: Data,
        config: LLMConfigSnapshot,
        source: String
    ) async throws -> TodoDocument {
        guard config.supportsVision else {
            // 不支持视觉：降级到 Vision OCR → 文本拆解
            logger.info("LLM 不支持视觉输入，降级到 Vision OCR")
            let ocrText = try await VisionOCRService.recognizeText(from: imageData)
            guard !ocrText.isEmpty else {
                throw TodoExtractionError.emptyResult
            }
            return try await extract(from: ocrText, config: config, source: source)
        }

        guard let url = URL(string: config.chatCompletionsURL) else {
            throw LLMError.invalidURL
        }
        // 云端配置必须 HTTPS；本地模型（含局域网 IP）允许明文 HTTP
        try LLMService.validateSecureURL(for: config)

        // 图片准备（解码 + 降采样 + base64 + JSON 序列化）显式移到后台执行器：
        // 1) nonisolated async 函数在第一个挂起点之前**沿用调用方执行器**（这里通常是
        //    MainActor），旧写法等于把 4K 截图的整张 base64 编码压在主线程上；
        // 2) 旧版完全不做降采样，且原图 + base64 + dataURL 三份并存再被
        //    JSONSerialization 复制一份，批量拆解时几百 MB 级峰值内存。
        //    现在复用 LLMService 的 2048px JPEG 降采样（与总结路径同一实现）。
        let model = config.modelName
        let prompt = PromptTemplateStore.resolved(.todoExtraction)
        let bodyData = try await Task.detached(priority: .userInitiated) { () throws -> Data in
            let payload = LLMService.downsampleForLLM(imageData: imageData)
            let dataURL = "data:image/\(payload.format);base64,\(payload.data.base64EncodedString())"
            // OpenAI 多模态消息格式：content 为数组
            let requestBody: [String: Any] = [
                "model": model,
                "messages": [
                    ["role": "system", "content": prompt],
                    ["role": "user", "content": [
                        ["type": "text", "text": "请从以下图片中提取待办事项："],
                        ["type": "image_url", "image_url": ["url": dataURL]]
                    ]]
                ],
                "stream": false,
                "temperature": 0.3,
                "max_tokens": 65536
            ]
            return try JSONSerialization.data(withJSONObject: requestBody)
        }.value

        // 视觉请求不重试（图片大，避免超时重复）
        return try await performRequest(url: url, config: config, bodyData: bodyData, source: source)
    }

    // MARK: - 请求执行

    private static func performRequest(
        url: URL,
        config: LLMConfigSnapshot,
        body: [String: Any],
        source: String
    ) async throws -> TodoDocument {
        try await performRequest(
            url: url,
            config: config,
            bodyData: try JSONSerialization.data(withJSONObject: body),
            source: source
        )
    }

    /// 已序列化请求体入口：图片待办用它在后台完成解码/降采样/base64/序列化，
    /// 避免这段重活落在调用方（MainActor）的执行器上
    private static func performRequest(
        url: URL,
        config: LLMConfigSnapshot,
        bodyData: Data,
        source: String
    ) async throws -> TodoDocument {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 120

        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.apiError(statusCode: httpResponse.statusCode, message: msg)
        }

        // 解析 OpenAI 兼容响应：choices[0].message.content
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let contentStr = message["content"] as? String else {
            logger.error("LLM 响应解析失败：无法找到 choices[0].message.content")
            throw LLMError.parseError
        }

        return try parseTodoItems(from: contentStr, model: config.modelName, source: source)
    }

    // MARK: - JSON 解析

    /// 解析 LLM 返回的 JSON 文本为 TodoDocument
    /// 兼容多种格式：{"items":[...]} / {"todos":[...]} / [...]
    private static func parseTodoItems(
        from contentStr: String,
        model: String,
        source: String
    ) throws -> TodoDocument {
        // 移除可能的 markdown 代码块包裹（```json ... ``` 或 ``` ... ```）
        // 以及前后多余的解释文字，提取首个 JSON 对象/数组
        let cleaned = stripMarkdownCodeFence(contentStr)

        guard let data = cleaned.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else {
            // 退一步：尝试从原始内容中提取首个 {...} 或 [...] 片段
            if let extracted = extractFirstJSON(from: contentStr),
               let extractedData = extracted.data(using: .utf8),
               let parsedFallback = try? JSONSerialization.jsonObject(with: extractedData) {
                return try buildTodoDocument(from: parsedFallback, model: model, source: source)
            }
            logger.error("LLM 返回内容不是合法 JSON：\(contentStr.prefix(200))")
            throw TodoExtractionError.invalidJSON
        }

        return try buildTodoDocument(from: parsed, model: model, source: source)
    }

    /// 剥离 markdown 代码块围栏，保留代码块内部内容
    private static func stripMarkdownCodeFence(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            // 移除开头的 ```json / ```{ 等（到第一个换行）
            if let firstNewline = cleaned.firstIndex(of: "\n") {
                cleaned = String(cleaned[cleaned.index(after: firstNewline)...])
            }
            // 移除结尾的 ```
            if cleaned.hasSuffix("```") {
                cleaned = String(cleaned.dropLast(3))
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }

    /// 从可能包含解释文字的字符串中提取首个 JSON 对象或数组
    private static func extractFirstJSON(from raw: String) -> String? {
        let chars = Array(raw)
        let startChars: [Character] = ["{", "["]
        for (index, ch) in chars.enumerated() where startChars.contains(ch) {
            let open = ch
            let close: Character = (open == "{") ? "}" : "]"
            var depth = 0
            var inString = false
            var escaped = false
            for j in index..<chars.count {
                let c = chars[j]
                if escaped {
                    escaped = false
                    continue
                }
                if c == "\\" {
                    escaped = true
                    continue
                }
                if c == "\"" {
                    inString.toggle()
                    continue
                }
                if inString { continue }
                if c == open { depth += 1 }
                else if c == close {
                    depth -= 1
                    if depth == 0 {
                        return String(chars[index...j])
                    }
                }
            }
        }
        return nil
    }

    /// 把解析后的 JSON 对象构造为 TodoDocument
    private static func buildTodoDocument(
        from parsed: Any,
        model: String,
        source: String
    ) throws -> TodoDocument {
        var rawItems: [[String: Any]] = []

        if let array = parsed as? [[String: Any]] {
            rawItems = array
        } else if let dict = parsed as? [String: Any] {
            if let arr = dict["items"] as? [[String: Any]] {
                rawItems = arr
            } else if let arr = dict["todos"] as? [[String: Any]] {
                rawItems = arr
            } else if let arr = dict["tasks"] as? [[String: Any]] {
                rawItems = arr
            } else if dict["title"] as? String != nil {
                // 单个待办对象
                rawItems = [dict]
            }
        }

        if rawItems.isEmpty {
            logger.warning("LLM 返回的待办列表为空")
            throw TodoExtractionError.emptyResult
        }

        let items: [TodoItem] = rawItems.compactMap { item in
            guard let title = (item["title"] as? String ?? item["task"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !title.isEmpty else {
                return nil
            }
            let notes = item["notes"] as? String ?? item["note"] as? String ?? item["description"] as? String
            // 相关链接：优先 url，兼容模型可能返回的别名字段
            let urlString = (item["url"] as? String
                ?? item["link"] as? String
                ?? item["relatedUrl"] as? String
                ?? item["related_url"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // 优先级默认不设：仅当模型明确返回 high/medium/low 时采用
            let priority = (item["priority"] as? String)
                .flatMap { TodoPriority(rawValue: $0.lowercased()) } ?? .none
            let dueDate = parseDate(from: item["dueDate"] ?? item["due_date"] ?? item["deadline"])
            // 提前提醒分钟数：仅当模型明确返回且存在截止时间（提前量需要锚点）时采用，否则不设置
            let alarmOffsetMinutes = parseAlarmOffset(
                from: item["alarmOffsetMinutes"] ?? item["alarm_offset_minutes"]
                    ?? item["earlyReminderMinutes"] ?? item["early_reminder_minutes"],
                requiresDueDate: dueDate
            )

            return TodoItem(
                title: title,
                notes: notes,
                url: (urlString?.isEmpty == false) ? urlString : nil,
                dueDate: dueDate,
                alarmOffsetMinutes: alarmOffsetMinutes,
                priority: priority,
                status: .pending
            )
        }

        guard !items.isEmpty else {
            throw TodoExtractionError.emptyResult
        }

        return TodoDocument(source: source, model: model, generatedAt: Date(), items: items)
    }

    /// ISO 8601 解析器复用容器：`ISO8601DateFormatter` / `DateFormatter` 构造极重，
    /// 旧实现每解析一条待办的日期就要新建 10 个实例（50 条待办 = 500 次构造），故提为 static 复用。
    ///
    /// 两者的并发承诺并不相同：`DateFormatter` 自 iOS 7 / macOS 10.9 起线程安全，SDK 亦标注为
    /// Sendable，可直接共享（见 plainDateFormatters）；`ISO8601DateFormatter` 在 SDK 中被显式标注为
    /// non-Sendable、头文件也未承诺线程安全，因此在此包一层锁：实例在 init 中构造完即冻结配置，
    /// `date(from:)` 串行访问——复用的性能收益与数据安全同时成立。
    private final class ISO8601DateParsers: @unchecked Sendable {
        private let lock = NSLock()
        private let formatters: [ISO8601DateFormatter]

        init(optionSets: [ISO8601DateFormatter.Options]) {
            formatters = optionSets.map { options in
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = options
                return formatter
            }
        }

        /// 依次尝试各配置，返回第一个解析成功的日期
        func date(from text: String) -> Date? {
            lock.lock()
            defer { lock.unlock() }
            for formatter in formatters {
                if let date = formatter.date(from: text) { return date }
            }
            return nil
        }
    }

    /// `Options` 是 OptionSet：每个元素本身就是一组配置，不能声明成 `[[Options]]`
    private static let isoDateParsers = ISO8601DateParsers(optionSets: [
        [.withInternetDateTime],
        [.withInternetDateTime, .withFractionalSeconds],
    ])

    /// 复用的常见日期格式解析器（按优先级顺序尝试）
    private static let plainDateFormatters: [DateFormatter] = {
        let patterns = [
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy/MM/dd HH:mm:ss",
            "yyyy/MM/dd HH:mm",
            "yyyy-MM-dd",
            "yyyy/MM/dd",
            "yyyy.MM.dd",
        ]
        return patterns.map { pattern in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = pattern
            return formatter
        }
    }()

    /// 尝试解析多种日期格式（含带时区的 ISO 8601、常见中文环境下的日期时间写法）
    private static func parseDate(from value: Any?) -> Date? {
        guard let value = value else { return nil }
        if let date = value as? Date { return date }
        if let timestamp = value as? TimeInterval, timestamp > 0 {
            // 兼容毫秒/秒级时间戳
            return timestamp > 1e12 ? Date(timeIntervalSince1970: timestamp / 1000) : Date(timeIntervalSince1970: timestamp)
        }
        if let str = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty {
            // 带时区/毫秒的 ISO 8601（如 2026-08-10T09:00:00Z、2026-08-10T09:00:00.000+08:00）
            if let d = isoDateParsers.date(from: str) { return d }
            for f in plainDateFormatters {
                if let d = f.date(from: str) { return d }
            }
        }
        return nil
    }

    /// 解析提前提醒分钟数：接受数字或数字字符串，有效范围 1 分钟～30 天（43_200 分钟）；
    /// 超范围、无法解析，或无截止时间（提前量没有锚点）时返回 nil
    private static func parseAlarmOffset(from value: Any?, requiresDueDate: Date?) -> Int? {
        guard requiresDueDate != nil else { return nil }
        let minutes: Int?
        switch value {
        case let n as NSNumber: minutes = n.intValue
        case let s as String: minutes = Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default: minutes = nil
        }
        guard let m = minutes, (1...43_200).contains(m) else { return nil }
        return m
    }

    // MARK: - Prompt

    /// 非会议内容的待办约束条款（追加在 systemPrompt 后，输出格式与安全要求沿用同一套）
    static let nonMeetingClause = """
    ## 内容类型特别说明
    本次内容已确认不是会议（可能是课程、讲座、培训演示等）：只提取其中明确提到的个人任务、练习或后续事项；
    禁止把知识点、章节或讨论要点包装成行动项，禁止虚构负责人与决议式表述；
    没有明确可执行事项时按格式返回空 items 数组。
    """

    /// 待办拆解内置提示词（保留给「恢复默认」对照）。
    /// 运行期实际使用 `PromptTemplateStore.resolved(.todoExtraction)`，可能被用户自定义覆盖。
    static var systemPrompt: String { PromptTemplateKind.todoExtraction.defaultText }

    private static func userPrompt(content: String) -> String {
        // 注入当前时间，供 LLM 将「明天/下周五」等相对时间换算为具体日期
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm EEEE"
        let now = formatter.string(from: Date())
        return "当前时间：\(now)\n\n请从以下内容中提取待办事项，并把其中提到的截止日期/时间解析为 dueDate：\n\n<<<待处理内容开始>>>\n\(content)\n<<<待处理内容结束>>>"
    }
}

// MARK: - 错误类型

enum TodoExtractionError: LocalizedError {
    case invalidJSON
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .invalidJSON:   return String(localized: "LLM 返回的内容无法解析为待办列表，请稍后重试或更换模型")
        case .emptyResult:   return String(localized: "未能从内容中提取到待办事项")
        }
    }
}
