import Foundation
import AVFoundation
import Testing
@testable import Memonta

struct MicCaptureRestartTests {
    private func format(_ rate: Double) throws -> AVAudioFormat {
        try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
    }

    /// 显式启用且已有权限才运行；不弹授权框，只在临时目录写全零音频。
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEMONTA_VERIFY_AUDIO_CAPTURE"] == "1"
                   && AVAudioApplication.shared.recordPermission == .granted))
    func realMicrophoneCanRestartMutedWithFreshEngine() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MicLive-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = MicCaptureService()
        defer { capture.stop() }
        for index in 0..<3 {
            let url = directory.appendingPathComponent("muted-\(index).caf")
            try await capture.start(to: url, initiallyMuted: true)
            #expect(capture.isCapturing)
            capture.stop()
            let audio = try AVAudioFile(forReading: url)
            #expect(audio.length > 0)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 128))
            try audio.read(into: buffer)
            let samples = try #require(buffer.floatChannelData)
            let pointerCount = buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)
            let sampleCount = Int(buffer.frameLength) * (buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1)
            for channel in 0..<pointerCount {
                #expect(UnsafeBufferPointer(start: samples[channel], count: sampleCount).allSatisfy { $0 == 0 })
            }
        }
    }

    @Test func muteBuffersClearInterleavedStereoAndReuseSafely() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000, channels: 2, interleaved: true))
        let pool = MicCaptureZeroBufferBox()
        let first = try #require(pool.zeroBuffer(matching: format, frameLength: 32))
        let samples = try #require(first.floatChannelData)[0]
        samples.update(repeating: 1, count: 64)
        let reused = try #require(pool.zeroBuffer(matching: format, frameLength: 16))
        #expect(reused === first)
        #expect(UnsafeBufferPointer(start: samples, count: 32).allSatisfy { $0 == 0 })
    }

    @Test func staleClientFormatUsesHardwareRateAndWritesPlayableCAF() throws {
        let hardware = try format(24_000)
        let staleClient = try format(48_000)
        let capture = try MicCaptureService.captureFormat(hardware: hardware, client: staleClient)
        #expect(capture.sampleRate == 24_000)
        #expect(MicCaptureService.requiresNewSegment(from: staleClient, to: capture))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MicHardware-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MicCaptureFileStore()
        store.file = try AVAudioFile(forWriting: url,
            settings: #require(MicCaptureService.fileSettings(for: capture)),
            commonFormat: capture.commonFormat, interleaved: capture.isInterleaved)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: capture, frameCapacity: 240))
        buffer.frameLength = 240
        buffer.floatChannelData?[0].update(repeating: 0, count: 240)
        let tap = UUID()
        store.activate(tap)
        #expect(try store.write(tap: tap) { try $0.write(from: buffer) })
        store.invalidateTap()
        store.file = nil
        let saved = try AVAudioFile(forReading: url)
        #expect(saved.fileFormat.sampleRate == 24_000)
        #expect(saved.length == 240)
    }

    @Test func oldTapCannotWriteToRotatedOrNewSessionFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MicTap-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = try format(48_000)
        let settings = try #require(MicCaptureService.fileSettings(for: format))
        let store = MicCaptureFileStore()
        let oldTap = UUID()
        store.activate(oldTap)
        store.file = try AVAudioFile(forWriting: directory.appendingPathComponent("first.caf"),
            settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
        buffer.frameLength = 128
        buffer.floatChannelData?[0].update(repeating: 0, count: 128)
        #expect(try store.write(tap: oldTap) { try $0.write(from: buffer) })
        // 正常分片轮转不撤销当前 tap。
        store.file = try AVAudioFile(forWriting: directory.appendingPathComponent("rotated.caf"),
            settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        #expect(try store.write(tap: oldTap) { try $0.write(from: buffer) })
        store.invalidateTap()
        let newTap = UUID()
        store.file = try AVAudioFile(forWriting: directory.appendingPathComponent("new.caf"),
            settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        store.activate(newTap)
        var staleCallbackRan = false
        #expect(!store.write(tap: oldTap) { _ in staleCallbackRan = true })
        #expect(!staleCallbackRan)
        #expect(store.file?.length == 0)
        #expect(try store.write(tap: newTap) { try $0.write(from: buffer) })
        #expect(store.file?.length == 128)
        store.invalidateTap()
        #expect(!store.write(tap: newTap) { _ in staleCallbackRan = true })
        store.file = nil
    }

    @MainActor
    @Test func startupCleanupPreservesAudioAndUnreadableFilesButNotEmptyCAF() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MicRollback-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sample.caf")
        #expect(!MeetingRecorderService.hasCapturedFrames(in: [url]))
        let format = try format(24_000)
        let store = MicCaptureFileStore()
        store.file = try AVAudioFile(forWriting: url,
            settings: #require(MicCaptureService.fileSettings(for: format)),
            commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        store.file = nil
        #expect(!MeetingRecorderService.hasCapturedFrames(in: [url]))
        store.file = try AVAudioFile(forWriting: url,
            settings: #require(MicCaptureService.fileSettings(for: format)),
            commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240))
        buffer.frameLength = 240
        buffer.floatChannelData?[0].update(repeating: 0, count: 240)
        try store.write { try $0.write(from: buffer) }
        store.file = nil
        #expect(MeetingRecorderService.hasCapturedFrames(in: [url]))
        let unreadable = directory.appendingPathComponent("unknown.caf")
        try Data("unreadable audio".utf8).write(to: unreadable)
        #expect(MeetingRecorderService.hasCapturedFrames(in: [unreadable]))
    }

    @MainActor
    @Test func bindingFailureRollsBackAndNextStartCreatesNewEngines() async throws {
        var engines: [AVAudioEngine] = []
        let capture = MicCaptureService(
            permissionCheck: { true },
            bindInput: { _ in throw MicCaptureError.inputDeviceLost },
            makeEngine: { let engine = AVAudioEngine(); engines.append(engine); return engine }
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MicBind-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        for expectedCount in [5, 10] {
            await #expect(throws: MicCaptureError.self) { try await capture.start(to: url) }
            #expect(engines.count == expectedCount)
            #expect(!capture.isCapturing)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
        #expect(Set(engines.map { ObjectIdentifier($0) }).count == 10)
        capture.stop()
        capture.stop()
    }

    @MainActor
    @Test(arguments: [true, false])
    func stoppedPermissionRequestCannotCreateEngineInNextSession(granted: Bool) async throws {
        let gate = AsyncStream<Bool>.makeStream()
        let permissionEntered = LockedBox(false)
        var engineCount = 0
        let capture = MicCaptureService(permissionCheck: {
            if permissionEntered.value { return false }
            permissionEntered.value = true
            for await value in gate.stream { return value }
            return false
        }, makeEngine: { engineCount += 1; return AVAudioEngine() })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MicPermission-\(UUID()).caf")
        let oldStart = Task { try await capture.start(to: url) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !permissionEntered.value, ContinuousClock.now < deadline { await Task.yield() }
        #expect(permissionEntered.value)
        capture.stop()
        await #expect(throws: MicCaptureError.self) { try await capture.start(to: url) }
        gate.continuation.yield(granted)
        gate.continuation.finish()
        do {
            try await oldStart.value
            Issue.record("停止后的权限结果不能继续启动")
        } catch { #expect(error is CancellationError) }
        #expect(engineCount == 0)
    }
}

@MainActor
struct MicCaptureStartupWaitTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }

    @Test func startupWaitsForCurrentPacketAndCancelInvalidatesLatePacket() async throws {
        var tokens: [MicCaptureRecovery.Attempt] = []
        var recovered = 0
        let recovery = MicCaptureRecovery(backoff: [], packetTimeout: .seconds(1),
            attempt: { tokens.append($0); return true }, onStarted: { _ in },
            onPacketTimeout: { _ in }, onFailed: { _ in }, onRecovered: { recovered += 1 })
        let first = Task { try await recovery.startAndWait() }
        try await waitUntil { tokens.count == 1 }
        #expect(recovery.isActive)
        first.cancel()
        do { try await first.value; Issue.record("应响应取消") }
        catch { #expect(error is CancellationError) }
        let second = Task { try await recovery.startAndWait() }
        try await waitUntil { tokens.count == 2 }
        recovery.confirmWrite(tokens[0])
        #expect(!recovery.isConfirmed)
        recovery.confirmWrite(tokens[1])
        try await second.value
        #expect(recovered == 1)
        #expect(!recovery.isActive)
    }

    @Test func nonRetryableFailureAndPacketTimeoutBothSettleStartup() async throws {
        for retryable in [false, true] {
            var attempts = 0
            var failures = 0
            let recovery = MicCaptureRecovery(backoff: [.milliseconds(1)], packetTimeout: .milliseconds(10),
                attempt: { _ in attempts += 1; return retryable }, onStarted: { _ in },
                onPacketTimeout: { _ in }, onFailed: { _ in failures += 1 }, onRecovered: {},
                shouldRetry: { retryable })
            await #expect(throws: MicCaptureRecovery.Failure.self) { try await recovery.startAndWait() }
            #expect(attempts == (retryable ? 2 : 1))
            #expect(failures == 1)
            #expect(!recovery.isActive)
        }
    }

    @Test func fatalWriteFailureSettlesWaiterAndRejectsLateWrite() async throws {
        var token: MicCaptureRecovery.Attempt?
        var recovered = 0
        var failures = 0
        let recovery = MicCaptureRecovery(attempt: { token = $0; return true },
            onStarted: { _ in }, onPacketTimeout: { _ in }, onFailed: { _ in failures += 1 },
            onRecovered: { recovered += 1 })
        let startup = Task { try await recovery.startAndWait() }
        try await waitUntil { token != nil }
        recovery.fail()
        await #expect(throws: MicCaptureRecovery.Failure.self) { try await startup.value }
        recovery.confirmWrite(try #require(token))
        #expect(recovered == 0)
        #expect(failures == 1)
        #expect(!recovery.isActive)
    }
}
