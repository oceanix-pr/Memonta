import Foundation

/// 设备切换后的启动与首包确认共用一个预算。只在主线程协调引擎操作，
/// 音频回调用 Attempt 值回传写入确认，不把 AVAudioEngine 带入回调。
@MainActor
final class MicCaptureRecovery {
    struct Attempt: Equatable, Sendable {
        let recoveryID: UUID
        let number: Int
    }

    private let backoff: [Duration]
    private let totalBudget: Duration
    private let packetTimeout: Duration
    private let attempt: (Attempt) -> Bool
    private let onStarted: (Int) -> Void
    private let onPacketTimeout: (Int) -> Void
    private let onFailed: (Int) -> Void
    private let onRecovered: () -> Void
    private var task: Task<Void, Never>?
    private var recoveryID: UUID?
    private var activeAttempt: Attempt?
    private(set) var isConfirmed = false

    var maxAttempts: Int { backoff.count + 1 }

    init(
        backoff: [Duration] = [.milliseconds(200), .milliseconds(500), .seconds(1), .seconds(2)],
        totalBudget: Duration = .seconds(15),
        packetTimeout: Duration = .seconds(3),
        attempt: @escaping (Attempt) -> Bool,
        onStarted: @escaping (Int) -> Void,
        onPacketTimeout: @escaping (Int) -> Void,
        onFailed: @escaping (Int) -> Void,
        onRecovered: @escaping () -> Void
    ) {
        self.backoff = backoff
        self.totalBudget = totalBudget
        self.packetTimeout = packetTimeout
        self.attempt = attempt
        self.onStarted = onStarted
        self.onPacketTimeout = onPacketTimeout
        self.onFailed = onFailed
        self.onRecovered = onRecovered
    }

    /// 立即尝试一次，返回引擎是否启动；真正恢复仍由当前尝试的写入确认决定。
    @discardableResult
    func start() -> Bool {
        cancel()
        let id = UUID()
        recoveryID = id
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: totalBudget)
        let started = startAttempt(id: id, number: 1)
        task = Task { [weak self] in
            await self?.run(id: id, started: started, deadline: deadline)
        }
        return started
    }

    func cancel() {
        task?.cancel()
        task = nil
        recoveryID = nil
        activeAttempt = nil
        isConfirmed = false
    }

    /// 最后一次首包超时后仍接受同一尝试的迟到写入，让真实恢复自动结算告警。
    /// 新通知、停止、重录或下一次尝试均使旧 token 无效。
    func confirmWrite(_ token: Attempt) {
        guard token == activeAttempt, recoveryID == token.recoveryID, !isConfirmed else { return }
        isConfirmed = true
        task?.cancel()
        task = nil
        onRecovered()
    }

    private func startAttempt(id: UUID, number: Int) -> Bool {
        let token = Attempt(recoveryID: id, number: number)
        activeAttempt = token // 在启动前布防，首包可能早于 engine.start() 返回。
        onStarted(number)
        let started = attempt(token)
        if !started { activeAttempt = nil }
        return started
    }

    private func run(id: UUID, started: Bool, deadline: ContinuousClock.Instant) async {
        let clock = ContinuousClock()
        var started = started
        var number = 1
        while recoveryID == id, !Task.isCancelled, !isConfirmed {
            if started {
                let packetDeadline = min(clock.now.advanced(by: packetTimeout), deadline)
                // 写入确认取消此任务；短轮询不阻塞主线程，也不等待硬件回调返回。
                while clock.now < packetDeadline, !Task.isCancelled, !isConfirmed {
                    do { try await clock.sleep(until: min(clock.now.advanced(by: .milliseconds(20)), packetDeadline)) }
                    catch { return }
                }
                guard recoveryID == id, !Task.isCancelled, !isConfirmed else { return }
                onPacketTimeout(number)
            }
            guard number < maxAttempts, clock.now < deadline else {
                onFailed(number)
                return // 保留 activeAttempt，允许最终超时后迟到的真实写入解除告警。
            }
            do { try await clock.sleep(until: min(clock.now.advanced(by: backoff[number - 1]), deadline)) }
            catch { return }
            guard recoveryID == id, !Task.isCancelled, !isConfirmed else { return }
            guard clock.now < deadline else { onFailed(number); return }
            number += 1
            started = startAttempt(id: id, number: number)
        }
    }
}
