#if os(macOS)
import Foundation
import EventKit
import os.log

/// 一次性诊断：验证 EKReminder.url 能否真正持久化到系统「提醒事项」的 URL 字段。
/// 触发方式：终端执行 defaults write com.oceanix.Memonta reminders_url_diagnostic -bool true 后启动 App，
/// 结果写入 ~/Documents/Memonta/url_diagnostic.txt，随后自行清除触发标记。
enum RemindersURLDiagnostic {

    private static let logger = Logger(subsystem: "com.oceanix.Memonta", category: "URLDiagnostic")
    private static let flagKey = "reminders_url_diagnostic"

    @MainActor
    static func runIfRequested() {
        guard UserDefaults.standard.bool(forKey: flagKey) else { return }
        UserDefaults.standard.removeObject(forKey: flagKey)
        Task { @MainActor in
            var lines = await run()
            lines.append(contentsOf: dumpRecentTodos())
            lines.append(contentsOf: await dumpExportedReminders())
            lines.append(contentsOf: await readManualTestReminder())
            lines.append(contentsOf: await repairExportedReminders())
            let outURL = AudioRecording.storageDirectory.appendingPathComponent("url_diagnostic.txt")
            try? lines.joined(separator: "\n").write(to: outURL, atomically: true, encoding: .utf8)
            logger.notice("URL 字段诊断完成，结果: \(outURL.path)")
        }
    }

    /// dump 最近几个录音文件夹的 todos.json（用应用自身解密），确认提取结果中 url/priority 实际值
    @MainActor
    private static func dumpRecentTodos() -> [String] {
        var lines: [String] = ["=== 最近 todos.json 内容 ==="]
        let storageDir = AudioRecording.storageDirectory
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: storageDir, includingPropertiesForKeys: nil
        ) else { return lines }
        func mtime(_ url: URL) -> Date {
            ((try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date) ?? .distantPast
        }
        let recent = dirs
            .filter { $0.hasDirectoryPath }
            .sorted(by: { mtime($0) > mtime($1) })
            .prefix(3)
        for dir in recent {
            guard let doc = TodoDocument.load(from: dir) else { continue }
            lines.append("-- \(dir.lastPathComponent) (来源:\(doc.source) 模型:\(doc.model))")
            for item in doc.items {
                let dueStr = item.dueDate.map { "\($0)" } ?? "nil"
                lines.append("  title=\(item.title) | url=\(item.url ?? "nil") | dueDate=\(dueStr) | priority=\(item.priority.rawValue) | alarm=\(item.alarmOffsetMinutes.map(String.init) ?? "nil") | status=\(item.status.rawValue) | reminderID=\(item.reminderIdentifier ?? "nil")")
            }
        }
        return lines
    }

    /// 反向实验：回读用户在 UI 手动填过 URL/提前提醒的测试提醒，
    /// 对比 UI 实际存储结构与 EventKit 直接写入的差异
    @MainActor
    private static func readManualTestReminder() async -> [String] {
        var lines: [String] = ["=== 反向实验：回读 UI 手动编辑后的测试提醒 ==="]
        let store = EKEventStore()
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = (try? await store.requestFullAccessToReminders()) ?? false
        } else {
            granted = (try? await store.requestAccess(to: .reminder)) ?? false
        }
        guard granted else { return lines }

        let testID = "7C98FAEA-285C-4985-A652-7036BC3F7759"
        guard let reminder = store.calendarItem(withIdentifier: testID) as? EKReminder else {
            lines.append("测试提醒 \(testID) 不存在（可能已被删除）")
            return lines
        }
        lines.append("title = \(reminder.title ?? "")")
        lines.append("url = \(String(describing: reminder.url))")
        lines.append("notes = \(String(describing: reminder.notes))")
        lines.append("dueDateComponents = \(String(describing: reminder.dueDateComponents))")
        lines.append("priority = \(reminder.priority)")
        if let alarms = reminder.alarms, !alarms.isEmpty {
            for (i, alarm) in alarms.enumerated() {
                lines.append("alarm[\(i)]: relativeOffset=\(alarm.relativeOffset) absoluteDate=\(String(describing: alarm.absoluteDate)) structuredLocation=\(String(describing: alarm.structuredLocation?.title)) proximity=\(alarm.proximity.rawValue) emailAddress=\(String(describing: alarm.emailAddress)) soundName=\(String(describing: alarm.soundName))")
            }
        } else {
            lines.append("alarms = 无")
        }
        return lines
    }

    /// 一次性修复：用最新写入逻辑重写已导出提醒（修正被相对闹钟污染的截止时间、补备注链接）
    @MainActor
    private static func repairExportedReminders() async -> [String] {
        var lines: [String] = ["=== 一次性修复已导出提醒 ==="]
        guard await RemindersService.shared.requestAccess() else {
            lines.append("未授权，跳过")
            return lines
        }
        var repaired = 0
        let storageDir = AudioRecording.storageDirectory
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: storageDir, includingPropertiesForKeys: nil) else { return lines }
        for dir in dirs where dir.hasDirectoryPath {
            guard let doc = TodoDocument.load(from: dir) else { continue }
            for item in doc.items where item.status == .exported {
                guard let rid = item.reminderIdentifier else { continue }
                if await RemindersService.shared.updateReminder(identifier: rid, with: item) {
                    repaired += 1
                    lines.append("已修复: \(item.title)")
                }
            }
        }
        lines.append("共修复 \(repaired) 条")
        return lines
    }

    @MainActor
    private static func dumpExportedReminders() async -> [String] {
        var lines: [String] = ["=== 已导出提醒事项回读 ==="]
        let store = EKEventStore()
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = (try? await store.requestFullAccessToReminders()) ?? false
        } else {
            granted = (try? await store.requestAccess(to: .reminder)) ?? false
        }
        guard granted else { return lines }
        let storageDir = AudioRecording.storageDirectory
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: storageDir, includingPropertiesForKeys: nil) else { return lines }
        for dir in dirs where dir.hasDirectoryPath {
            guard let doc = TodoDocument.load(from: dir) else { continue }
            for item in doc.items where item.status == .exported {
                guard let rid = item.reminderIdentifier else { continue }
                if let reminder = store.calendarItem(withIdentifier: rid) as? EKReminder {
                    lines.append("  [\(dir.lastPathComponent)] \(reminder.title ?? "")")
                    lines.append("    reminder.url = \(String(describing: reminder.url))")
                    lines.append("    reminder.notes = \(String(describing: reminder.notes))")
                    lines.append("    dueDateComponents = \(String(describing: reminder.dueDateComponents))")
                    lines.append("    priority = \(reminder.priority)")
                    if let alarms = reminder.alarms, !alarms.isEmpty {
                        for (i, alarm) in alarms.enumerated() {
                            lines.append("    alarm[\(i)]: relativeOffset=\(alarm.relativeOffset) absoluteDate=\(String(describing: alarm.absoluteDate))")
                        }
                    } else {
                        lines.append("    alarms = 无")
                    }
                } else {
                    lines.append("  [\(dir.lastPathComponent)] \(item.title): 提醒事项 \(rid) 不存在")
                }
            }
        }
        return lines
    }

    @MainActor
    private static func run() async -> [String] {
        let store = EKEventStore()
        var lines: [String] = ["=== Reminders URL 字段诊断 \(Date()) ==="]

        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = (try? await store.requestFullAccessToReminders()) ?? false
        } else {
            granted = (try? await store.requestAccess(to: .reminder)) ?? false
        }
        lines.append("授权: \(granted)")
        guard granted else { return lines }

        let calendar = store.defaultCalendarForNewReminders()
        lines.append("默认列表: \(calendar?.title ?? "nil")")
        lines.append("列表类型: \(calendar?.type.rawValue.description ?? "nil")")
        lines.append("列表来源: \(calendar?.source.title ?? "nil")")

        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = "Memonta-URL诊断-\(Int(Date().timeIntervalSince1970))"
        let testURL = URL(string: "https://teams.microsoft.com/meet/41515892528787?p=VuHQuLe0cO3ymx8SgP")
        reminder.url = testURL
        lines.append("save 前 reminder.url = \(String(describing: reminder.url))")

        do {
            try store.save(reminder, commit: true)
        } catch {
            lines.append("保存失败: \(error)")
            return lines
        }
        let savedID = reminder.calendarItemIdentifier
        lines.append("已保存 identifier=\(savedID)")

        // 同一 store 提交后立即回读
        if let fetched = store.calendarItem(withIdentifier: savedID) as? EKReminder {
            lines.append("回读(same store) reminder.url = \(String(describing: fetched.url))")
        } else {
            lines.append("回读(same store) 失败")
        }
        // 全新 store 回读（排除内存缓存假象）
        let store2 = EKEventStore()
        if let fetched2 = store2.calendarItem(withIdentifier: savedID) as? EKReminder {
            lines.append("回读(fresh store) reminder.url = \(String(describing: fetched2.url))")
        } else {
            lines.append("回读(fresh store) 失败")
        }

        // 清理测试提醒
        if let toDelete = store.calendarItem(withIdentifier: savedID) as? EKReminder {
            try? store.remove(toDelete, commit: true)
            lines.append("已删除测试提醒")
        }
        return lines
    }
}
#endif
