import Foundation
import AVFoundation
import os.log

/// 麦克风采集服务
///
/// 基于 AVAudioEngine 采集麦克风输入，写入 CAF(PCM) 分片文件。
/// 分片为崩溃安全容器（头部在文件开头、数据线性追加）：异常退出后仅需
/// 修补头部 size 字段即可完整恢复（见 FileSyncService 崩溃恢复），
/// 最终在停止录音时统一导出为 m4a(AAC)（见 MeetingRecorderService）。
/// 支持本地静音/解除静音：tap 保持安装，静音时写入全零缓冲以维持时间轴。
///
/// 线程安全说明：
/// - 本类不是 @MainActor（installTap 闭包在后台音频线程执行，
///   若类为 @MainActor 则闭包会继承主 actor 隔离，导致运行时崩溃）。
/// - 本类是 @unchecked Sendable，内部通过 stateLock 保护跨线程访问的状态。
/// - tap 闭包访问的 fileBox、静音标志和零缓冲均由各自的锁保护。
final class MicCaptureService: @unchecked Sendable {

    @MainActor init() {}

    private let logger = Logger(subsystem: "com.oceanix.Memonta", category: "MicCapture")
    private let engine = AVAudioEngine()
    /// AVAudioFile 的线程安全包装（@unchecked Sendable）
    private let fileBox = FileBox()
    /// 状态锁：保护 isTapInstalled / recordingFormat 的跨线程访问
    private let stateLock = NSLock()
    private var _isTapInstalled = false
    /// 写入格式（首次安装 tap 时确定，保证 unmute 后一致）
    private var _recordingFormat: AVAudioFormat?

    /// 配置变化时由总控分配下一片编号；成功打开后再登记到合并列表。
    /// 这两个闭包只在主线程的配置变更处理里访问。
    @MainActor var nextSegmentForFormatChange: (() -> URL?)?
    @MainActor var onFormatChangeSegmentOpened: ((URL) -> Void)?

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

    /// 采集事件回调（可在后台音频线程触发）。
    /// 事件已区分「设备切换/恢复」与「真实写盘失败」，接收方不得再把可恢复中断统一当成写入失败上报。
    private var _onEvent: (@Sendable (MicCaptureEvent) -> Void)?
    var onEvent: (@Sendable (MicCaptureEvent) -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _onEvent }
        set { stateLock.lock(); defer { stateLock.unlock() }; _onEvent = newValue }
    }

    /// 采集会话代次：start/stop 时递增。事件携带代次，接收方跨 actor 排队后必须复核，
    /// 迟到的旧事件（停止后迅速重录）不得改写新会话状态。
    private var _lastSuccessfulWriteAt: Date?
    var lastSuccessfulWriteAt: Date? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _lastSuccessfulWriteAt
    }
    private var _generation = 0
    var generation: Int { stateLock.lock(); defer { stateLock.unlock() }; return _generation }
    func isCurrentGeneration(_ value: Int) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return value == _generation
    }

    /// 首包确认绑定具体恢复尝试，不能让上一 tap 的迟到缓冲确认新尝试。
    /// tap 线程只在 stateLock 下取走 token；控制流程与 UI 事件均回主线程。
    private var pendingRecoveryAttempt: MicCaptureRecovery.Attempt?

    @MainActor private lazy var recoveryController: MicCaptureRecovery = MicCaptureRecovery(
        attempt: { [weak self] token in
            self?.applyRecoveryAttempt(token: token) ?? false
        },
        onStarted: { [weak self] attempt in
            guard let self else { return }
            self.emit(.recoveryStarted(
                attempt: attempt, maxAttempts: self.recoveryController.maxAttempts,
                generation: self.generation
            ))
        },
        onPacketTimeout: { [weak self] attempt in
            guard let self else { return }
            let failure = self.diagnostics(
                stage: .writeBuffer, attempt: attempt, deviceBound: nil,
                oldFormat: nil, newFormat: self.recordingFormat, error: nil
            )
            self.lastRecoveryFailure = failure
            self.logRecoveryFailure(attempt: attempt)
            self.emit(.deviceUnavailable(failure))
        },
        onFailed: { [weak self] attempt in
            guard let self, let failure = self.lastRecoveryFailure else { return }
            self.logRecoveryFailure(attempt: attempt)
            self.emit(.recoveryFailed(failure))
        },
        onRecovered: { [weak self] in
            guard let self else { return }
            self.logger.info("麦克风采集恢复确认：当前尝试已有音频缓冲成功写入")
            self.emit(.recovered(generation: self.generation))
        }
    )

    /// 开始/停止时取消恢复任务，并在锁内使旧音频回调失效。
    @MainActor private func beginNewSession() {
        recoveryController.cancel()
        stateLock.lock()
        _generation += 1
        _lastSuccessfulWriteAt = nil
        pendingRecoveryAttempt = nil
        stateLock.unlock()
        lastConfigurationChangeAt = nil
    }

    private func setPendingRecoveryAttempt(_ token: MicCaptureRecovery.Attempt?) {
        stateLock.lock()
        pendingRecoveryAttempt = token
        stateLock.unlock()
    }

    /// 最近一次恢复尝试失败的定位信息（供日志与最终失败上报）
    private var lastRecoveryFailure: MicCaptureDiagnostics?
    /// 最近一次处理设备配置变化的时刻：紧随其后的写失败视为切换症状
    /// （路由尚未稳定，此时写失败不是磁盘故障），仅在主线程读写
    private var lastConfigurationChangeAt: Date?

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
    @MainActor func start(to url: URL) async throws {
        guard !isTapInstalled else { return }
        beginNewSession()
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
        let session = generation
        Task { @MainActor [weak self] in
            guard let self, self.isCurrentGeneration(session), self.fileBox.file != nil else { return }
            // 只在这里记录「真实硬件配置变化」的时刻：紧随其后的写失败属于切换症状。
            // 不能在 handleConfigurationChange 里记——写失败转恢复也会走那里，
            // 会不断刷新时间戳，把磁盘/IO 故障永久误判成设备切换而不告警。
            self.lastConfigurationChangeAt = Date()
            self.handleConfigurationChange()
        }
    }

    /// 新配置通知重开有界恢复流程；启动失败和首包超时共用次数与时间预算。
    /// 返回值仅表示引擎已启动，恢复仍以当前尝试成功写入为准。
    @MainActor
    @discardableResult
    private func handleConfigurationChange() -> Bool {
        guard fileBox.file != nil else { return false }
        lastRecoveryFailure = nil
        return recoveryController.start()
    }

    /// 执行一次恢复尝试：重解析设备与格式 → 必要时切分片 → 装 tap → 启动引擎。
    /// 每步都记录失败阶段（供 `-10868` 这类无阶段信息的错误码定位）。
    /// - Returns: 是否已启动成功（成功仍要等首包写入才算真正恢复）
    @MainActor
    private func applyRecoveryAttempt(token: MicCaptureRecovery.Attempt) -> Bool {
        let attempt = token.number
        setPendingRecoveryAttempt(nil)
        let previousFile = fileBox.file
        let wasTapInstalled = isTapInstalled
        let oldFormat = recordingFormat

        // 配置变化后引擎已自动停止；按“资源是否存在”安全移除旧 tap
        removeTapIfInstalled()
        engine.stop()

        // 上次设备断开时 tap 已移除；设备重新出现后仍须尝试恢复。
        // 不能用 wasTapInstalled 拦截，否则“等待自动恢复”永远无法发生。

        // 重新对齐目标设备：已选麦克风仍在则绑回它，被拔出则明确回退系统默认，
        // 避免引擎停在已消失的设备上继续采集（读到的全是静音）
        var deviceBound: Bool?
        #if os(macOS)
        if let uid = MicrophoneDeviceRegistry.savedSelectionUID() {
            let target = MicrophoneDeviceRegistry.deviceID(forUID: uid)
                ?? MicrophoneDeviceRegistry.defaultInputDeviceID()
            if let target, MicrophoneDeviceRegistry.currentDeviceID(of: engine) != target {
                // 绑定结果必须检查：失败后若仍按「已绑定」前提继续恢复，
                // 后续读到的格式与设备都对不上，只会把真实的绑定失败掩盖成格式错误
                deviceBound = MicrophoneDeviceRegistry.apply(target, to: engine)
            }
        }
        #endif

        if deviceBound == false {
            lastRecoveryFailure = diagnostics(
                stage: .bindDevice, attempt: attempt, deviceBound: false,
                oldFormat: oldFormat, newFormat: nil, error: MicCaptureError.inputDeviceLost
            )
            logRecoveryFailure(attempt: attempt)
            if let failure = lastRecoveryFailure { emit(.deviceUnavailable(failure)) }
            return false
        }
        var stage: MicCaptureDiagnostics.Stage = .bindDevice
        let newFormat = engine.inputNode.outputFormat(forBus: 0)
        // 无效格式（设备已拔出）：本次尝试失败，交由有限重试/最终失败上报
        guard newFormat.sampleRate > 0, newFormat.channelCount > 0 else {
            lastRecoveryFailure = diagnostics(
                stage: .startEngine, attempt: attempt, deviceBound: deviceBound,
                oldFormat: oldFormat, newFormat: newFormat, error: MicCaptureError.inputDeviceLost
            )
            logRecoveryFailure(attempt: attempt)
            if let failure = lastRecoveryFailure { emit(.deviceUnavailable(failure)) }
            return false
        }

        let needsNewSegment = oldFormat.map { Self.requiresNewSegment(from: $0, to: newFormat) } ?? true
        var replacement: (url: URL, file: AVAudioFile)?
        var attemptedURL: URL?
        do {
            stage = .openSegmentFile
            if needsNewSegment {
                guard let url = nextSegmentForFormatChange?() else {
                    logger.error("输入格式变化时无法取得下一个麦克风分片路径")
                    throw CocoaError(.fileWriteUnknown)
                }
                attemptedURL = url
                guard let settings = Self.fileSettings(for: newFormat) else {
                    throw MicCaptureError.inputDeviceLost
                }
                replacement = (url, try AVAudioFile(
                    forWriting: url,
                    settings: settings,
                    commonFormat: newFormat.commonFormat,
                    interleaved: newFormat.isInterleaved
                ))
            }
            stage = .installTap
            setPendingRecoveryAttempt(token)
            try installTapOnEngine(inputNode: engine.inputNode, format: newFormat, recoveryAttempt: token)
            stateLock.lock()
            _isTapInstalled = true
            stateLock.unlock()
            // tap 开始回调前换文件；旧文件先由局部强引用保留，以便启动失败回滚。
            if let replacement { fileBox.file = replacement.file }
            stage = .startEngine
            try engine.start()
            recordingFormat = newFormat
            lastRecoveryFailure = nil
            if let replacement {
                onFormatChangeSegmentOpened?(replacement.url)
                logger.info("输入格式变化，已切换麦克风分片: \(replacement.url.lastPathComponent, privacy: .public)，采样率=\(newFormat.sampleRate)，声道=\(newFormat.channelCount)")
            } else if !wasTapInstalled {
                logger.info("麦克风输入设备恢复，继续写入当前分片")
            }
            // 启动调用成功不等于已经录到声音：等新代次首个缓冲写入确认
            return true
        } catch {
            setPendingRecoveryAttempt(nil)
            // 回滚：engine.start() 失败时 tap 已装而引擎未跑，必须清标志并移除 tap，
            // 与 start() 的失败回滚一致（否则后续 ensureCapturing/start 会把
            // “tap 已装、引擎未跑”误判成采集正常）
            removeTapIfInstalled()
            if replacement != nil, let previousFile {
                // 启动失败时继续保留旧片。
                fileBox.file = previousFile
            }
            if let attemptedURL, FileManager.default.fileExists(atPath: attemptedURL.path) {
                // AVAudioFile 初始化也可能先创建空壳再抛错；该片未登记，不留给恢复扫描。
                do { try FileManager.default.removeItem(at: attemptedURL) }
                catch { logger.error("清理未启动的麦克风分片失败: \(error.localizedDescription)") }
            }
            lastRecoveryFailure = diagnostics(
                stage: stage, attempt: attempt, deviceBound: deviceBound,
                oldFormat: oldFormat, newFormat: newFormat, error: error
            )
            logRecoveryFailure(attempt: attempt)
            if let failure = lastRecoveryFailure { emit(.deviceUnavailable(failure)) }
            return false
        }
    }

    /// 仅当前 tap 的非空成功写入可确认恢复（静音的全零缓冲同样有效）。
    private func noteSuccessfulWrite(_ token: MicCaptureRecovery.Attempt?, session: Int) {
        stateLock.lock()
        guard _generation == session else { stateLock.unlock(); return }
        _lastSuccessfulWriteAt = Date()
        let accepted = token != nil && pendingRecoveryAttempt == token
        if accepted { pendingRecoveryAttempt = nil }
        stateLock.unlock()
        guard accepted, let token else { return }
        Task { @MainActor [weak self] in
            guard let self, self.isCurrentGeneration(session) else { return }
            self.recoveryController.confirmWrite(token)
        }
    }

    private func emit(_ event: MicCaptureEvent) {
        onEvent?(event)
    }

    /// 组装失败定位信息（不含任何会议内容）
    private func diagnostics(
        stage: MicCaptureDiagnostics.Stage,
        attempt: Int,
        deviceBound: Bool?,
        oldFormat: AVAudioFormat?,
        newFormat: AVAudioFormat?,
        error: Error?
    ) -> MicCaptureDiagnostics {
        let nsError = error.map { $0 as NSError }
        return MicCaptureDiagnostics(
            stage: stage,
            generation: generation,
            attempt: attempt,
            deviceBound: deviceBound,
            oldSampleRate: oldFormat?.sampleRate,
            newSampleRate: newFormat?.sampleRate,
            oldChannelCount: oldFormat?.channelCount,
            newChannelCount: newFormat?.channelCount,
            errorDomain: nsError?.domain,
            errorCode: nsError?.code,
            detail: error?.localizedDescription,
            lastSuccessfulWriteAt: lastSuccessfulWriteAt
        )
    }

    /// 恢复失败日志：阶段、会话代次、设备绑定结果、新旧采样率/声道、错误域与错误码。
    /// 这些字段是下次定位 `-10868`（kAudioUnitErr_FormatNotSupported）具体发生在哪一步的依据
    private func logRecoveryFailure(attempt: Int) {
        guard let failure = lastRecoveryFailure else { return }
        let summary = "麦克风恢复失败 stage=\(failure.stage.rawValue) 会话代次=\(failure.generation) 尝试=\(attempt) 设备绑定=\(failure.deviceBound.map { String($0) } ?? "-") 采样率=\(failure.oldSampleRate.map { String($0) } ?? "-")→\(failure.newSampleRate.map { String($0) } ?? "-") 声道=\(failure.oldChannelCount.map { String($0) } ?? "-")→\(failure.newChannelCount.map { String($0) } ?? "-") 错误域=\(failure.errorDomain ?? "-") 错误码=\(failure.errorCode.map { String($0) } ?? "-")"
        logger.error("\(summary, privacy: .public) 详情=\(failure.detail ?? "-", privacy: .private)")
    }

    /// 本地静音：tap 保持安装，改写全零缓冲。
    /// 系统 mute 检测触发或用户手动静音时调用。
    /// 相比旧版移除 tap 的实现：静音期间分片时间轴保持连续（混音模式与系统音轨对齐），
    /// 且轮转产生的分片不再是零帧空壳
    func mute() {
        silencedBox.set(true)
    }

    /// 解除静音：恢复真实音频写入。
    /// 引擎停转时可能已换设备或被睡眠停转：启动（幂等的）恢复流程；恢复结果由采集事件上报。
    /// 这里不再抛出——旧实现抛出会把「正在恢复」直接变成一条需要用户「停止后重新录制」的错误。
    @MainActor func unmute() {
        silencedBox.set(false)
        if fileBox.file != nil, !engine.isRunning {
            handleConfigurationChange()
        }
    }

    /// 唤醒兜底恢复：系统睡眠可能直接停掉引擎且不触发配置变化通知，
    /// 醒来后若引擎停转或 tap 丢失，按当前设备格式重装 tap 并重启。
    /// - Returns: true = 采集已处于活跃状态（本就在跑或恢复成功）
    @MainActor func ensureCapturing() -> Bool {
        // 无打开的写入文件 = 未在采集：明确返回 false，让上层能区分
        // “无需恢复”与“恢复失败”，而不是把未在录音误报成采集正常
        guard fileBox.file != nil else { return false }
        if isTapInstalled && engine.isRunning { return true }

        // 与设备配置通知走同一恢复路径：唤醒后格式也可能已经变化。
        handleConfigurationChange()
        return isCapturing
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
            reportWriteError(error)
            return false
        }
    }

    /// CAF(PCM Int16) 写入参数（与当前采集格式匹配）。
    /// 分片用 PCM 而非 AAC：PCM 容器头部在文件开头、数据线性追加，
    /// 异常退出后修补头部 size 即可完整恢复；AAC 的 moov 采样表只在关闭时
    /// 写入，崩溃后 mdat 裸帧无边界标记，无法在 App 内恢复
    static func fileSettings(for format: AVAudioFormat) -> [String: Any]? {
        guard format.sampleRate > 0, format.channelCount > 0 else { return nil }
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    /// AVAudioFile 的处理格式必须与 tap 缓冲一致；输入设备重新配置后不能继续
    /// 往旧采样率/声道布局的文件写入。相同格式的配置通知无需额外切片。
    static func requiresNewSegment(from old: AVAudioFormat, to new: AVAudioFormat) -> Bool {
        old != new
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
    @MainActor func stop() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        removeTapIfInstalled()
        engine.stop()
        silencedBox.set(false)
        fileBox.file = nil
        recordingFormat = nil
        // 会话结束：递增采集代次并作废在途恢复与首包确认，
        // 使停止后迅速重录时旧通知/旧重试不会操作新会话
        beginNewSession()
    }

    /// 安装 tap（nonisolated：切断与调用方 actor 的隔离关联）
    /// 这样闭包不会被推断为 @MainActor 隔离，可在后台音频线程安全执行。
    /// isTapInstalled 的设置由调用方（start/unmute）在主线程完成。
    nonisolated private func installTapOnEngine(
        inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        recoveryAttempt: MicCaptureRecovery.Attempt? = nil
    ) throws {
        if #available(macOS 27.0, iOS 27.0, tvOS 27.0, visionOS 27.0, *) {
            try installModernTap(on: inputNode, format: format, recoveryAttempt: recoveryAttempt)
        } else {
            installLegacyTap(on: inputNode, format: format, recoveryAttempt: recoveryAttempt)
        }
    }

    /// macOS 27 的只读音频 Tap。AVAudioFile 同版本提供只读 buffer 写入，
    /// 可避免为了保存实时输入而复制正常（非静音）采样。
    @available(macOS 27.0, iOS 27.0, tvOS 27.0, visionOS 27.0, *)
    nonisolated private func installModernTap(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        recoveryAttempt: MicCaptureRecovery.Attempt?
    ) throws {
        let session = generation
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
                    let didWrite = try box.write { file in
                        try file.write(from: AVReadOnlyAudioPCMBuffer(copying: zero))
                    }
                    if didWrite, buffer.frameLength > 0 { self.noteSuccessfulWrite(recoveryAttempt, session: session) }
                } catch {
                    self.reportWriteError(error)
                }
                return
            }
            do {
                let didWrite = try box.write { file in
                    try file.write(from: buffer)
                }
                if didWrite, buffer.frameLength > 0 { self.noteSuccessfulWrite(recoveryAttempt, session: session) }
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
        format: AVAudioFormat,
        recoveryAttempt: MicCaptureRecovery.Attempt?
    ) {
        let session = generation
        let box = fileBox
        let silenced = silencedBox
        let zeroBox = zeroBufferBox
        let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { [weak self] buffer, _ in
            guard let self else { return }
            // 静音中：写全零缓冲，保持分片时间轴连续（用户预期静音 = 无真实麦克风数据）
            if silenced.isSilenced {
                guard let zero = zeroBox.zeroBuffer(matching: buffer.format, frameLength: buffer.frameLength) else { return }
                do {
                    let didWrite = try box.write { file in
                        try file.write(from: zero)
                    }
                    if didWrite, buffer.frameLength > 0 { self.noteSuccessfulWrite(recoveryAttempt, session: session) }
                } catch {
                    self.reportWriteError(error)
                }
                return
            }
            do {
                let didWrite = try box.write { file in
                    try file.write(from: buffer)
                }
                if didWrite, buffer.frameLength > 0 { self.noteSuccessfulWrite(recoveryAttempt, session: session) }
            } catch {
                // C-1: 传播写入错误而非静默吞掉，便于上层提示用户磁盘空间不足等问题
                self.reportWriteError(error)
            }
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format, block: tap)
    }

    /// 写失败上报（去抖）：磁盘满/IO 故障时 tap 每 ~21ms 失败一次，
    /// 不去抖会形成每秒 ~48 次的回调风暴（MainActor Task 创建 + 日志刷屏）。
    ///
    /// 上报前必须区分**成因**：
    /// - 磁盘满 / IO 故障 = 真实写入失败，点名「写入失败……建议停止后重新录制」；
    /// - 设备切换、格式变化或引擎停转期间写失败 = 只是**症状**，此时若仍按写入失败上报，
    ///   AirPods 断开这类可恢复中断就会一直显示「麦克风录音写入失败：处理失败，请重试……」。
    ///   这类必须改按设备事件处理并触发恢复流程。
    private func reportWriteError(_ error: Error) {
        guard writeErrorBox.shouldEmit() else { return }
        let failure = diagnostics(
            stage: .writeBuffer, attempt: 0, deviceBound: nil,
            oldFormat: recordingFormat, newFormat: nil, error: error
        )
        logger.error("麦克风写入失败: domain=\(failure.errorDomain ?? "-", privacy: .public) code=\(failure.errorCode ?? -1) stage=\(failure.stage.rawValue, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
        let userSummary = UserFacingError.summary(for: error)
        // 成因判定要看引擎与输入格式的“当下”状态，必须回到主线程做；tap 回调在音频线程
        Task { @MainActor [weak self] in
            guard let self, self.isCurrentGeneration(failure.generation), self.fileBox.file != nil else { return }
            if self.writeFailureIsDeviceTransition() {
                self.logger.error("写失败发生在设备切换/引擎停转期间，按设备事件处理并触发恢复（不报写入失败）")
                self.emit(.deviceUnavailable(failure))
                self.handleConfigurationChange()
            } else {
                self.emit(.writeFailed(userSummary: userSummary, diagnostics: failure))
            }
        }
    }

    /// 写失败是否只是设备切换 / 引擎停转的症状（而不是磁盘或 IO 故障）。
    @MainActor
    private func writeFailureIsDeviceTransition() -> Bool {
        let current = engine.inputNode.outputFormat(forBus: 0)
        return Self.writeFailureIsDeviceTransition(
            engineRunning: engine.isRunning,
            secondsSinceConfigurationChange: lastConfigurationChangeAt.map { Date().timeIntervalSince($0) },
            recordedSampleRate: recordingFormat?.sampleRate,
            recordedChannelCount: recordingFormat?.channelCount,
            currentSampleRate: current.sampleRate,
            currentChannelCount: current.channelCount
        )
    }

    /// 写失败成因判定（纯函数，便于离线回归）。
    ///
    /// 满足任一即判定为设备切换症状：引擎已停、刚处理过设备配置变化（路由尚未稳定）、
    /// 正在写入的分片格式已与输入节点不一致、或尚未建立写入格式。
    /// 真正的磁盘/IO 故障不满足这些条件，因此仍会走「写入失败」告警。
    static func writeFailureIsDeviceTransition(
        engineRunning: Bool,
        secondsSinceConfigurationChange: TimeInterval?,
        recordedSampleRate: Double?,
        recordedChannelCount: UInt32?,
        currentSampleRate: Double,
        currentChannelCount: UInt32
    ) -> Bool {
        if !engineRunning { return true }
        if let since = secondsSinceConfigurationChange, since < deviceTransitionWindow { return true }
        guard let recordedSampleRate, let recordedChannelCount else { return true }
        return currentSampleRate != recordedSampleRate || currentChannelCount != recordedChannelCount
    }

    /// 设备配置变化后视为「路由尚未稳定」的窗口（秒）
    static let deviceTransitionWindow: TimeInterval = 5

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
        guard capped > 0, let format = recordingFormat, let expectedFile = fileBox.file,
              format.sampleRate > 0 else { return 0 }
        let framesPerSecond = format.sampleRate
        var written: TimeInterval = 0
        while written < capped {
            guard !Task.isCancelled else { break }
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
                let didWrite = try fileBox.write(matching: expectedFile) { file in
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
    func write(matching expectedFile: AVAudioFile? = nil, _ body: (AVAudioFile) throws -> Void) rethrows -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let file = _file else { return false }
        if let expectedFile, file !== expectedFile { return false }
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

// MARK: - 麦克风采集事件

/// 一次麦克风采集动作的定位信息（不含任何会议内容）。
/// 存在的理由：日志此前把多个操作汇入同一个出口，`-10868` 这类错误码无法定位到
/// 「重绑设备 / 建分片 / 装 tap / 启动引擎 / 写缓冲」中的哪一步。
struct MicCaptureDiagnostics: Sendable {
    enum Stage: String, Sendable {
        case bindDevice
        case openSegmentFile
        case installTap
        case startEngine
        case writeBuffer
    }

    let stage: Stage
    /// 采集会话代次（start/stop 递增）
    let generation: Int
    /// 恢复尝试序号（非恢复路径为 0）
    let attempt: Int
    /// 设备绑定结果：nil = 本次未尝试绑定
    let deviceBound: Bool?
    let oldSampleRate: Double?
    let newSampleRate: Double?
    let oldChannelCount: UInt32?
    let newChannelCount: UInt32?
    let errorDomain: String?
    let errorCode: Int?
    let detail: String?
    var lastSuccessfulWriteAt: Date? = nil
}

/// 麦克风采集事件：把「可恢复的设备切换/恢复」与「真实写盘失败」分开上报。
///
/// 二者此前共用同一个出口，上层统一包装成「麦克风录音写入失败……建议停止后重新录制」，
/// 于是 AirPods 断开、会议软件释放音频设备等可恢复中断被误报成写盘失败。
/// 事件携带采集会话代次，接收方跨 actor 排队后必须复核，迟到事件不得改写新会话。
enum MicCaptureEvent: Sendable {
    /// 输入设备消失或格式无效：采集暂停，等待有界重试
    case deviceUnavailable(MicCaptureDiagnostics)
    /// 正在按退避重试恢复
    case recoveryStarted(attempt: Int, maxAttempts: Int, generation: Int)
    /// 新代次首个音频缓冲已成功写入，恢复得到确认
    case recovered(generation: Int)
    /// 启动/首包重试预算耗尽：麦克风采集尚未确认恢复
    case recoveryFailed(MicCaptureDiagnostics)
    /// 真实写盘失败（磁盘满 / IO 故障）；`userSummary` 已本地化，可直接展示
    case writeFailed(userSummary: String, diagnostics: MicCaptureDiagnostics)

    /// 事件所属采集会话代次
    var generation: Int {
        switch self {
        case .deviceUnavailable(let diagnostics), .recoveryFailed(let diagnostics),
             .writeFailed(_, let diagnostics):
            return diagnostics.generation
        case .recoveryStarted(_, _, let generation), .recovered(let generation):
            return generation
        }
    }
}
