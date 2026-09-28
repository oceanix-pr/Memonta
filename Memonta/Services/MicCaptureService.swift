import Foundation
import AVFoundation

/// 麦克风采集服务
///
/// 基于 AVAudioEngine 采集麦克风输入，写入 CAF(PCM) 分片文件。
/// 分片为崩溃安全容器（头部在文件开头、数据线性追加）：异常退出后仅需
/// 修补头部 size 字段即可完整恢复（见 FileSyncService 崩溃恢复），
/// 最终在停止录音时统一导出为 m4a(AAC)（见 MeetingRecorderService）。
/// 支持本地静音/解除静音：静音时移除 tap 不再写入数据，解除时重新安装 tap。
///
/// 线程安全说明：
/// - 本类不是 @MainActor（installTap 闭包在后台音频线程执行，
///   若类为 @MainActor 则闭包会继承主 actor 隔离，导致运行时崩溃）。
/// - 本类是 @unchecked Sendable，内部通过 stateLock 保护跨线程访问的状态。
/// - tap 闭包仅访问 fileBox（内部加锁保护），与主线程无共享可变状态。
final class MicCaptureService: @unchecked Sendable {

    private let engine = AVAudioEngine()
    /// AVAudioFile 的线程安全包装（@unchecked Sendable）
    private let fileBox = FileBox()
    /// 状态锁：保护 isTapInstalled / recordingFormat 的跨线程访问
    private let stateLock = NSLock()
    private var _isTapInstalled = false
    /// 写入格式（首次安装 tap 时确定，保证 unmute 后一致）
    private var _recordingFormat: AVAudioFormat?

    private var isTapInstalled: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isTapInstalled }
        set { stateLock.lock(); defer { stateLock.unlock() }; _isTapInstalled = newValue }
    }

    private var recordingFormat: AVAudioFormat? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _recordingFormat }
        set { stateLock.lock(); defer { stateLock.unlock() }; _recordingFormat = newValue }
    }

    /// 静音状态：tap 保持安装、改写全零缓冲（保持分片时间轴连续，
    /// 混音后与系统音轨对齐；同时消除静音期的零帧空壳分片）
    private let silencedBox = SilencedBox()

    /// 静音写入用的全零缓冲（按需重建；写文件为同步调用，单一音频线程复用安全）
    private let zeroBufferBox = ZeroBufferBox()

    /// 写入错误上报节流（磁盘满/IO 故障时 tap 每 ~21ms 失败一次，不去抖会形成风暴）
    private let writeErrorBox = WriteErrorRateBox()

    /// C-1: 写入错误回调（在后台音频线程触发）
    private var _onWriteError: (@Sendable (Error) -> Void)?
    /// 写入错误回调（tap 闭包内调用，通过 stateLock 保护跨线程访问）
    var onWriteError: (@Sendable (Error) -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _onWriteError }
        set { stateLock.lock(); defer { stateLock.unlock() }; _onWriteError = newValue }
    }

    /// 设备配置变化观察者（录音中切换/拔出输入设备时重建 tap，避免格式不匹配崩溃）
    private var configObserver: NSObjectProtocol?

    /// 当前是否正在采集
    var isCapturing: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _isTapInstalled && engine.isRunning
    }

    /// C-6: 检查麦克风权限是否已授予
    private static func checkMicrophonePermission() -> Bool {
        #if os(macOS)
        if #available(macOS 14.0, *) {
            return AVAudioApplication.shared.recordPermission == .granted
        } else {
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
        #else
        /* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
        return AVAudioSession.sharedInstance().recordPermission == .granted
        */
        #endif
    }

    /// C-6: 确保麦克风权限可用：未决（从未请求过）时发起系统授权请求。
    ///
    /// 旧实现只做只读预检，把「未决」当成「拒绝」直接抛错：系统从未收到过请求，
    /// 应用不会出现在「系统设置 → 隐私与安全性 → 麦克风」列表里，用户也无从授权
    /// （分发到新机器上表现为「麦克风面板里根本没有 Memonta」）。
    /// - Returns: true = 已授权
    private static func ensureMicrophonePermission() async -> Bool {
        if checkMicrophonePermission() { return true }
        #if os(macOS)
        if #available(macOS 14.0, *) {
            // 仅未决时请求：已拒绝时重复调用也不会再次弹窗，避免无谓等待
            guard AVAudioApplication.shared.recordPermission == .undetermined else { return false }
            return await AVAudioApplication.requestRecordPermission()
        } else {
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return false }
            return await AVCaptureDevice.requestAccess(for: .audio)
        }
        #else
        return false
        #endif
    }

    /// 开始采集
    /// - Parameter url: 目标分片文件 URL（caf，PCM 容器）
    func start(to url: URL) async throws {
        guard !isTapInstalled else { return }
        // 新录音从非静音状态开始（上一次会话停止于静音状态时的状态残留兑底）
        silencedBox.set(false)

        // C-6: 麦克风权限：未决时先发起系统请求（首次运行会弹授权框），再判定
        guard await Self.ensureMicrophonePermission() else {
            throw MicCaptureError.microphonePermissionNotGranted
        }

        #if os(macOS)
        // 指定麦克风：绑定到引擎输入节点（必须在读取输入格式之前，格式随设备变化）；
        // 未选择或已拔出则不绑定，保持引擎跟随系统默认输入设备
        if let uid = MicrophoneDeviceRegistry.savedSelectionUID(),
           let deviceID = MicrophoneDeviceRegistry.deviceID(forUID: uid) {
            MicrophoneDeviceRegistry.apply(deviceID, to: engine)
        }
        #endif

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        recordingFormat = format

        // 配置 CAF(PCM Int16) 写入格式：崩溃安全，停止录音时统一导出为 m4a
        guard let settings = Self.fileSettings(for: format) else {
            throw MicCaptureError.inputDeviceLost
        }
        // 处理格式与 tap 缓冲一致（Float32），AVAudioFile 内部转为 Int16 落盘
        fileBox.file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )

        try installTapOnEngine(inputNode: inputNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // 失败回滚：移除刚安装的 tap 并释放文件。
            // 若在此处先把 isTapInstalled 置 true，engine.start() 抛错后会留下
            // “tap 已装、引擎未跑、文件已打开”的不一致状态，之后任何 start() 都会命中
            // 开头的 guard 直接返回“成功”，导致整段录音只有空文件且不上报错误
            engine.inputNode.removeTap(onBus: 0)
            fileBox.file = nil
            throw error
        }
        isTapInstalled = true
        observeConfigurationChanges()
    }

    /// 监听音频设备配置变化（切换/拔出输入设备）
    /// 不处理时旧 tap 格式与硬件不匹配会导致 AVAudioEngine 异常甚至崩溃
    private func observeConfigurationChanges() {
        guard configObserver == nil else { return }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            // queue: nil 使回调在**通知投递线程**（AVAudioEngine 内部线程）执行，
            // 与主线程上的 stop()/ensureCapturing()/unmute() 并发操作同一引擎，
            // 会命中 AVAudioEngine 断言或重复安装 tap。统一跳回主线程，与所有
            // 其它引擎操作串行；tap 闭包本身仍留在音频线程，不受此影响。
            self?.scheduleConfigurationChangeHandling()
        }
    }

    /// 把配置变更处理调度到主线程（引擎操作与 start/stop/ensureCapturing 同线程串行）
    private func scheduleConfigurationChangeHandling() {
        Task { @MainActor [weak self] in
            self?.handleConfigurationChange()
        }
    }

    /// 设备配置变化处理：移除旧 tap，按新输入格式重装并重启引擎继续采集
    /// - Note: 必须在主线程执行（见 scheduleConfigurationChangeHandling）
    @MainActor
    private func handleConfigurationChange() {
        // 通知投递与跳转主线程之间会话可能已结束（stop() 已移除观察者并关闭文件）
        // 或已重新开始：以「写入文件是否存在」为会话存活判据，避免给已停止的会话
        // 重装 tap / 重启引擎，留下无人收尾的采集
        guard fileBox.file != nil else { return }
        let wasTapInstalled = isTapInstalled

        // 配置变化后引擎已自动停止；按“资源是否存在”安全移除旧 tap
        removeTapIfInstalled()

        guard wasTapInstalled else { return }

        #if os(macOS)
        // 重新对齐目标设备：已选麦克风仍在则绑回它，被拔出则明确回退系统默认，
        // 避免引擎停在已消失的设备上继续采集（读到的全是静音）
        if let uid = MicrophoneDeviceRegistry.savedSelectionUID() {
            let target = MicrophoneDeviceRegistry.deviceID(forUID: uid)
                ?? MicrophoneDeviceRegistry.defaultInputDeviceID()
            if let target, MicrophoneDeviceRegistry.currentDeviceID(of: engine) != target {
                MicrophoneDeviceRegistry.apply(target, to: engine)
            }
        }
        #endif

        let newFormat = engine.inputNode.outputFormat(forBus: 0)
        // 无效格式（设备已拔出）：暂停采集，等下次配置变化（插入新设备）时自动恢复
        guard newFormat.sampleRate > 0, newFormat.channelCount > 0 else {
            onWriteError?(MicCaptureError.inputDeviceLost)
            return
        }

        do {
            recordingFormat = newFormat
            try installTapOnEngine(inputNode: engine.inputNode, format: newFormat)
            stateLock.lock()
            _isTapInstalled = true
            stateLock.unlock()
            try engine.start()
        } catch {
            // 回滚：engine.start() 失败时 tap 已装而引擎未跑，必须清标志并移除 tap，
            // 与 start() 的失败回滚一致（否则后续 ensureCapturing/start 会把
            // “tap 已装、引擎未跑”误判成采集正常）
            removeTapIfInstalled()
            onWriteError?(error)
        }
    }

    /// 本地静音：tap 保持安装，改写全零缓冲。
    /// 系统 mute 检测触发或用户手动静音时调用。
    /// 相比旧版移除 tap 的实现：静音期间分片时间轴保持连续（混音模式与系统音轨对齐），
    /// 且轮转产生的分片不再是零帧空壳
    func mute() {
        silencedBox.set(true)
    }

    /// 解除静音：恢复真实音频写入
    func unmute() throws {
        silencedBox.set(false)
        // 引擎停转（如睡眠后未走唤醒兑底路径）时重启
        if isTapInstalled, !engine.isRunning {
            try engine.start()
        }
    }

    /// 唤醒兜底恢复：系统睡眠可能直接停掉引擎且不触发配置变化通知，
    /// 醒来后若引擎停转或 tap 丢失，按当前设备格式重装 tap 并重启。
    /// - Returns: true = 采集已处于活跃状态（本就在跑或恢复成功）
    func ensureCapturing() -> Bool {
        // 无打开的写入文件 = 未在采集：明确返回 false，让上层能区分
        // “无需恢复”与“恢复失败”，而不是把未在录音误报成采集正常
        guard fileBox.file != nil else { return false }
        if isTapInstalled && engine.isRunning { return true }

        // 引擎停转/tap 丢失：清理后重建
        removeTapIfInstalled()

        let newFormat = engine.inputNode.outputFormat(forBus: 0)
        guard newFormat.sampleRate > 0, newFormat.channelCount > 0 else {
            onWriteError?(MicCaptureError.inputDeviceLost)
            return false
        }

        do {
            recordingFormat = newFormat
            try installTapOnEngine(inputNode: engine.inputNode, format: newFormat)
            isTapInstalled = true
            if !engine.isRunning {
                try engine.start()
            }
            return true
        } catch {
            onWriteError?(error)
            return false
        }
    }

    /// 分片轮转：关闭当前文件并打开新文件。
    /// CAF(PCM) 正常关闭后容器完整、立即可播放；即使异常退出未关闭，
    /// 修补头部 size 后仍可完整恢复（见 FileSyncService），最多丢最后几毫秒缓冲。
    /// 先创建新文件再原子替换，写入空窗期近似为零。
    /// - Parameter url: 新分片的目标 URL
    /// - Returns: 是否轮转成功（失败时保留旧文件继续写入）
    func rotateSegment(to url: URL) -> Bool {
        guard isCapturing else { return false }
        guard let format = recordingFormat,
              let settings = Self.fileSettings(for: format) else { return false }
        do {
            let newFile = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            // 原子替换：旧文件引用释放时触发 close → finalize，旧分片即刻可播放
            fileBox.file = newFile
            return true
        } catch {
            onWriteError?(error)
            return false
        }
    }

    /// CAF(PCM Int16) 写入参数（与当前采集格式匹配）。
    /// 分片用 PCM 而非 AAC：PCM 容器头部在文件开头、数据线性追加，
    /// 异常退出后修补头部 size 即可完整恢复；AAC 的 moov 采样表只在关闭时
    /// 写入，崩溃后 mdat 裸帧无边界标记，无法在 App 内恢复
    private static func fileSettings(for format: AVAudioFormat) -> [String: Any]? {
        guard format.sampleRate > 0 else { return nil }
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    /// 安全移除 tap：以“资源是否存在”为判据，避免对未安装 tap 的 bus 调用
    /// `removeTap(onBus:)`（历史上会命中 `required condition is false` 断言），
    /// 并同步清空 `_isTapInstalled`，保证标志与实际状态一致
    private func removeTapIfInstalled() {
        stateLock.lock()
        let wasInstalled = _isTapInstalled
        _isTapInstalled = false
        stateLock.unlock()
        guard wasInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
    }

    /// 停止采集并关闭文件
    func stop() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        removeTapIfInstalled()
        engine.stop()
        silencedBox.set(false)
        fileBox.file = nil
        recordingFormat = nil
    }

    /// 安装 tap（nonisolated：切断与调用方 actor 的隔离关联）
    /// 这样闭包不会被推断为 @MainActor 隔离，可在后台音频线程安全执行。
    /// isTapInstalled 的设置由调用方（start/unmute）在主线程完成。
    nonisolated private func installTapOnEngine(
        inputNode: AVAudioInputNode,
        format: AVAudioFormat
    ) throws {
        if #available(macOS 27.0, iOS 27.0, tvOS 27.0, visionOS 27.0, *) {
            try installModernTap(on: inputNode, format: format)
        } else {
            installLegacyTap(on: inputNode, format: format)
        }
    }

    /// macOS 27 的只读音频 Tap。AVAudioFile 同版本提供只读 buffer 写入，
    /// 可避免为了保存实时输入而复制正常（非静音）采样。
    @available(macOS 27.0, iOS 27.0, tvOS 27.0, visionOS 27.0, *)
    nonisolated private func installModernTap(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat
    ) throws {
        let box = fileBox
        let silenced = silencedBox
        let zeroBox = zeroBufferBox
        let tap: @Sendable (AVReadOnlyAudioPCMBuffer, AVAudioTime) -> Void = { [weak self] buffer, _ in
            guard let self = self else { return }
            if silenced.isSilenced {
                guard let zero = zeroBox.zeroBuffer(
                    matching: buffer.format,
                    frameLength: AVAudioFrameCount(buffer.frameLength)
                ) else { return }
                do {
                    try box.write { file in
                        try file.write(from: AVReadOnlyAudioPCMBuffer(copying: zero))
                    }
                } catch {
                    self.reportWriteError(error)
                }
                return
            }
            do {
                try box.write { file in
                    try file.write(from: buffer)
                }
            } catch {
                self.reportWriteError(error)
            }
        }
        try inputNode.installAudioTap(
            onBus: 0,
            bufferSize: 1024,
            format: format,
            tapProvider: tap
        )
    }

    /// macOS 15–26 / iOS 18–26 兼容路径。
    @available(macOS, deprecated: 27.0)
    @available(iOS, deprecated: 27.0)
    @available(tvOS, deprecated: 27.0)
    @available(visionOS, deprecated: 27.0)
    nonisolated private func installLegacyTap(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat
    ) {
        let box = fileBox
        let silenced = silencedBox
        let zeroBox = zeroBufferBox
        let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { [weak self] buffer, _ in
            guard let self else { return }
            // 静音中：写全零缓冲，保持分片时间轴连续（用户预期静音 = 无真实麦克风数据）
            if silenced.isSilenced {
                guard let zero = zeroBox.zeroBuffer(matching: buffer.format, frameLength: buffer.frameLength) else { return }
                do {
                    try box.write { file in
                        try file.write(from: zero)
                    }
                } catch {
                    self.reportWriteError(error)
                }
                return
            }
            do {
                try box.write { file in
                    try file.write(from: buffer)
                }
            } catch {
                // C-1: 传播写入错误而非静默吞掉，便于上层提示用户磁盘空间不足等问题
                self.reportWriteError(error)
            }
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format, block: tap)
    }

    /// 写入错误上报（去抖）：磁盘满/IO 故障时 tap 每 ~21ms 失败一次，
    /// 不去抖会形成每秒 ~48 次的回调风暴（MainActor Task 创建 + 日志刷屏）
    private func reportWriteError(_ error: Error) {
        guard writeErrorBox.shouldEmit() else { return }
        onWriteError?(error)
    }

    /// 静音补写单次上限（秒）：48kHz/16bit/单声道 ≈ 96KB/s，30 分钟 ≈ 166MB，
    /// 覆盖几乎所有真实间隙（会议小憩/短暂合盖），同时限制异常场景
    ///（录音忘停 + 整夜睡眠）的磁盘消耗与写入耗时
    static let maxSilencePaddingSeconds: TimeInterval = 1800

    /// 向当前分片写入指定秒数的静音。
    /// 用于混音模式下的睡眠间隙补偿：系统音轨 PTS 连续、麦克风轨顺序拼接，
    /// 不补齐则恢复后两轨错位睡眠时长。必须在恢复写入（ensureCapturing）之前调用，
    /// 保证静音先于新数据落盘。
    /// - Returns: 实际写入的秒数（未在录音/格式异常时为 0）
    func writeSilence(for seconds: TimeInterval) async -> TimeInterval {
        let capped = min(max(0, seconds), Self.maxSilencePaddingSeconds)
        guard capped > 0, let format = recordingFormat, fileBox.file != nil,
              format.sampleRate > 0 else { return 0 }
        let framesPerSecond = format.sampleRate
        var written: TimeInterval = 0
        while written < capped {
            let remainSeconds = capped - written
            let frameCount = AVAudioFrameCount(min(framesPerSecond, remainSeconds * framesPerSecond))
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { break }
            buffer.frameLength = frameCount
            if let channels = buffer.floatChannelData {
                for ch in 0..<Int(format.channelCount) {
                    channels[ch].update(repeating: 0, count: Int(frameCount))
                }
            }
            do {
                // 与 tap 回调使用同一把写锁：避免与后台音频线程并发写同一 AVAudioFile
                let didWrite = try fileBox.write { file in
                    try file.write(from: buffer)
                }
                guard didWrite else { break }
            } catch {
                reportWriteError(error)
                break
            }
            written += Double(frameCount) / framesPerSecond
            if Int(written) % 60 == 0 { await Task.yield() } // 长间隙补写时让出执行线程
        }
        return written
    }
}

// MARK: - 线程安全的 AVAudioFile 包装

/// 静音标志（线程安全布尔）：tap 保持安装、写入全零缓冲的静音实现
private final class SilencedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSilenced: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Bool) { lock.lock(); defer { lock.unlock() }; self.value = value }
}

/// 全零 PCM 缓冲池：静音写入按传入缓冲格式/长度复用，每次取出前重新清零
private final class ZeroBufferBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?
    func zeroBuffer(matching format: AVAudioFormat, frameLength: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        lock.lock(); defer { lock.unlock() }
        if let b = buffer, b.format == format, b.frameCapacity >= frameLength {
            b.frameLength = frameLength
        } else {
            guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
            b.frameLength = frameLength
            buffer = b
        }
        guard let b = buffer, let channels = b.floatChannelData else { return nil }
        for ch in 0..<Int(b.format.channelCount) {
            channels[ch].update(repeating: 0, count: Int(b.frameLength))
        }
        return b
    }
}

/// 写入错误上报节流（5 秒冷却）
private final class WriteErrorRateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEmitAt: Date?
    func shouldEmit(now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let last = lastEmitAt, now.timeIntervalSince(last) < 5 { return false }
        lastEmitAt = now
        return true
    }
}

/// 包装非 Sendable 的 AVAudioFile，使其可在后台线程中使用。
/// file 属性通过内部 NSLock 保护，确保 tap 闭包与 start/stop 的并发访问安全。
private final class FileBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _file: AVAudioFile?

    var file: AVAudioFile? {
        get { lock.lock(); defer { lock.unlock() }; return _file }
        set { lock.lock(); defer { lock.unlock() }; _file = newValue }
    }

    /// 串行化对 AVAudioFile 的写入。
    ///
    /// `AVAudioFile.write(from:)` 未声明线程安全：tap 回调在后台音频线程写入，
    /// 睡眠间隙补静音（`writeSilence`）在主线程写入，两者并发会损坏 PCM 数据、
    /// 破坏文件内部状态。此方法用同一把锁把写入串行化。
    /// - Returns: 文件当前存在并完成写入返回 true；文件已关闭返回 false（不执行闭包）
    @discardableResult
    func write(_ body: (AVAudioFile) throws -> Void) rethrows -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let file = _file else { return false }
        try body(file)
        return true
    }
}

// MARK: - 麦克风采集错误类型

/// C-6: 麦克风采集相关错误
enum MicCaptureError: LocalizedError {
    case microphonePermissionNotGranted
    case inputDeviceLost

    var errorDescription: String? {
        switch self {
        case .microphonePermissionNotGranted:
            return String(localized: "麦克风权限未授予。请到「系统设置 → 隐私与安全性 → 麦克风」中开启 Memonta，然后重新开始录音。")
        case .inputDeviceLost:
            return String(localized: "麦克风输入设备已断开，录音已暂停。重新连接设备后会自动恢复采集。")
        }
    }
}
