import Foundation
import Observation
import SwiftData
import os.log
#if os(macOS)
import Darwin
#endif

/// 确认框固定所选条目与原件路径，避免确认期间列表选择变化导致误删。
@MainActor
struct MediaCleanupRequest {
    enum Kind: CaseIterable, Hashable {
        case audio, image, video

        var title: String {
            switch self {
            case .audio: String(localized: "清理录音")
            case .image: String(localized: "清理图片")
            case .video: String(localized: "清理视频")
            }
        }

        func originalURL(for item: ListItem) -> URL? {
            guard !item.folderName.isEmpty else { return nil }
            switch (self, item) {
            case (.audio, .recording(let recording)): return recording.fileURL
            case (.image, .quickNote(let note)): return note.sourceImageURL
            case (.video, .recording(let recording)): return recording.videoFileURL
            default: return nil
            }
        }
    }

    struct Target {
        let item: ListItem
        let url: URL
    }

    let kind: Kind
    let targets: [Target]
    let estimatedBytes: Int64

    init?(kind: Kind, items: Set<ListItem>) {
        let targets = items.sorted { $0.id < $1.id }.compactMap { item -> Target? in
            guard let url = kind.originalURL(for: item),
                  MediaCleanupService.isOriginalFile(url, in: item.folderURL) else { return nil }
            return Target(item: item, url: url)
        }
        guard !targets.isEmpty else { return nil }
        self.kind = kind
        self.targets = targets
        estimatedBytes = targets.reduce(0) { total, target in
            let size = (try? target.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        }
    }

    var message: String {
        let format: String
        switch kind {
        case .audio:
            format = String(localized: "只删除所选 %1$lld 个音频原件（约 %2$@），保留条目、转写、总结与待办。此操作无法撤销，清理后无法播放或重新转写。")
        case .image:
            format = String(localized: "只删除所选 %1$lld 个图片原件（约 %2$@），保留条目、文字、OCR、总结与待办。此操作无法撤销，清理后无法查看、标注或重新识别原图。")
        case .video:
            format = String(localized: "只删除所选 %1$lld 个视频原件（约 %2$@），保留关键帧、画面要点、音频、转写、总结与待办。仅清理已有可复用关键帧的条目。此操作无法撤销，清理后无法播放原视频或重新抽帧。")
        }
        return String(format: format, Int64(targets.count),
                      ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .file))
    }
}

/// 媒体清理只删除明确的单个文件；文件夹和全部派生内容均保留。
/// 主 actor 仅处理模型，后台 I/O 只携带 URL 或文本快照。
@MainActor
@Observable
final class MediaCleanupService {
    static let shared = MediaCleanupService()
    private(set) var isRunning = false
    private let isBusy: @MainActor () -> Bool
    private let logger = Logger(subsystem: "com.oceanix.Memonta", category: "MediaCleanup")

    init(isBusy: @escaping @MainActor () -> Bool = MediaCleanupService.hasConflictingWork) {
        self.isBusy = isBusy
    }

    struct Result {
        var cleanedCount = 0
        var freedBytes: Int64 = 0
        var failures: [String] = []

        var message: String {
            var text = String(format: String(localized: "已清理 %1$lld 个文件，释放约 %2$@。"),
                              Int64(cleanedCount), ByteCountFormatter.string(fromByteCount: freedBytes, countStyle: .file))
            if let first = failures.first {
                text += "\n" + String(format: String(localized: "有 %1$lld 个条目未完成清理：%2$@"), Int64(failures.count), first)
            }
            return text
        }
    }

    enum CleanupError: LocalizedError {
        case busy, preservationFailed

        var errorDescription: String? {
            switch self {
            case .busy: String(localized: "请等待录音、处理任务和磁盘同步完成后再清理媒体。")
            case .preservationFailed: String(localized: "条目内容或元数据尚未安全保存，已保留媒体原件。请重试。")
            }
        }
    }

    private static func hasConflictingWork() -> Bool {
        FileSyncService.hasResourcesPreventingUpdate || RecordingMergeActivity.shared.isRunning
            || AppUpdateService.shared.isPreparingToInstall
            || MeetingRecorderService.shared.hasResourcesPreventingUpdate
            || ScreenVideoRecorder.hasResourcesPreventingUpdate
            || ScreenshotManager.shared.hasResourcesPreventingUpdate
            || TaskCenter.shared.hasActiveWork
            || !TaskCenter.shared.stoppingResourceClasses.isEmpty
            || !TaskCenter.shared.restartRequiredResourceClasses.isEmpty
            || BackgroundTaskQueue.hasEntries()
    }

    nonisolated static func isOriginalFile(_ url: URL, in folder: URL) -> Bool {
        guard url.standardizedFileURL.deletingLastPathComponent().path == folder.standardizedFileURL.path,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        // URLResourceValues 会缓存文件类型，不能用于删除前验证（原路径可能刚被替换）。
        return attributes[.type] as? FileAttributeType == .typeRegular
    }

    /// 不递归、不按扩展名批删；路径即使被替换成目录或符号链接也拒绝删除。
    nonisolated static func removeOriginalFile(at url: URL, in folder: URL) async throws -> Int64 {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard isOriginalFile(url, in: folder) else { throw CocoaError(.fileReadNoSuchFile) }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            // unlink 永不递归：即使检查后路径被替换成目录，也只会失败，不会删其内容。
            let status = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { errno = ENOENT; return Int32(-1) }
                return unlink(path)
            }
            guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            return size
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    func cleanup(_ request: MediaCleanupRequest, context: ModelContext, persistence: PersistenceGuard) async throws -> Result {
        if let rejection = persistence.rejection(for: .deleteEntry) { throw rejection }
        guard !isRunning, !isBusy() else { throw CleanupError.busy }
        isRunning = true
        defer { isRunning = false }
        try context.save()
        var result = Result()
        for target in request.targets {
            do {
                try Task.checkCancellation()
                guard !isBusy(), request.kind.originalURL(for: target.item) == target.url else { throw CleanupError.busy }
                switch target.item {
                case .recording(let recording):
                    guard recording.modelContext === context, !recording.isDeleted,
                          recording.transcriptionStatus != .processing, recording.summaryStatus != .processing,
                          recording.visualStatus != .processing, recording.todoStatus != .processing else { throw CleanupError.busy }
                    if request.kind == .video {
                        guard await VideoUnderstandingService.hasReusableFrameCache(in: recording.framesDirectoryURL) else {
                            throw VideoUnderstandingService.VideoUnderstandingError.frameCacheMissing
                        }
                    }
                    try await preserve(recording)
                    // 在删除最后一份媒体物证前把路径、时长、类型与身份写盘，数据库重建仍能恢复。
                    if request.kind == .video { recording.hasVideoSource = true }
                    guard recording.saveMetaToFolder() else { throw CleanupError.preservationFailed }
                    if request.kind == .audio {
                        // 删除意图先落盘：unlink 后即使进程退出，扫描也不会用遗留分片复活原件。
                        try EntryIdentityStore.write(["audioRemovedAt": Date().timeIntervalSince1970],
                                                     id: recording.id, to: recording.folderURL)
                    }
                case .quickNote(let note):
                    guard note.modelContext === context, !note.isDeleted,
                          note.summaryStatus != .processing, note.todoStatus != .processing else { throw CleanupError.busy }
                    try await preserve(note)
                    note.hasImageSource = true
                    guard note.saveMetaToFolder() else { throw CleanupError.preservationFailed }
                }
                try Task.checkCancellation()
                guard !isBusy() else { throw CleanupError.busy }
                let bytes = try await Self.removeOriginalFile(at: target.url, in: target.item.folderURL)
                result.cleanedCount += 1
                result.freedBytes += bytes
                // 只在实际删除成功后更新文件引用；失败保留模型与原件。
                switch target.item {
                case .recording(let recording):
                    if request.kind == .audio { recording.audioRemovedAt = Date() }
                    else { recording.videoFileName = nil }
                case .quickNote(let note):
                    note.sourceImageFileName = nil
                }
                try context.save()
            } catch {
                logger.error("媒体清理未完成：\(error.localizedDescription, privacy: .private)")
                result.failures.append(UserFacingError.summary(for: error))
            }
        }
        return result
    }

    private func preserve(_ recording: AudioRecording) async throws {
        if !recording.segments.isEmpty {
            let items = recording.segments.sorted { $0.startTime < $1.startTime }.map {
                TranscriptMirrorItem(startTime: $0.startTime, endTime: $0.endTime, speaker: $0.speaker, text: $0.decryptedText)
            }
            guard zip(recording.segments.sorted { $0.startTime < $1.startTime }, items)
                .allSatisfy({ $0.text.isEmpty || !$1.text.isEmpty }) else { throw CleanupError.preservationFailed }
            guard await EntryMirrorStore.shared.writeTranscriptNow(items, folderName: recording.folderName,
                                                                   to: recording.transcriptFileURL) else { throw CleanupError.preservationFailed }
        }
        for (raw, kind, url) in [(recording.summary, EntryMirrorStore.Kind.summary, recording.summaryFileURL),
                                 (recording.visualSummary, .visual, recording.visualFileURL)] {
            let text = EncryptionService.decryptSafely(raw)
            if raw?.isEmpty == false && text.isEmpty { throw CleanupError.preservationFailed }
            guard !text.isEmpty else { continue }
            guard await EntryMirrorStore.shared.writeNow(text, kind: kind, folderName: recording.folderName, to: url) else {
                throw CleanupError.preservationFailed
            }
        }
    }

    private func preserve(_ note: QuickNote) async throws {
        let folder = note.folderURL
        let text = note.decryptedTextContent
        let ocr = note.decryptedOcrText
        guard (note.textContent?.isEmpty != false || !text.isEmpty),
              (note.ocrText?.isEmpty != false || !ocr.isEmpty) else { throw CleanupError.preservationFailed }
        try await Task.detached(priority: .utility) {
            if !text.isEmpty { try EncryptionService.encryptAndWrite(text, to: folder.appendingPathComponent("source.txt")) }
            if !ocr.isEmpty { try EncryptionService.encryptAndWrite(ocr, to: folder.appendingPathComponent("ocr.txt")) }
        }.value
        let summary = note.decryptedSummaryText
        if note.summaryText?.isEmpty == false && summary.isEmpty { throw CleanupError.preservationFailed }
        if !summary.isEmpty {
            guard await EntryMirrorStore.shared.writeNow(summary, kind: .summary, folderName: note.folderName,
                                                        to: note.summaryFileURL) else { throw CleanupError.preservationFailed }
        }
    }
}
