@preconcurrency import AVFoundation
import Foundation
import os.log
import Synchronization
import UIKit

/// Owns one warm Apple audio resource and produces isolated audio artifacts for Dictations.
///
/// Ronin upload, App Group mailbox coordination, and UI state remain outside this module.
actor DictationCapture {
    struct DeviceInteractionSettings: Sendable, Equatable {
        var armedDuration: Duration = .seconds(15 * 60)
    }

    struct CapturedAudio: Sendable, Equatable {
        let requestID: UUID
        let fileURL: URL
        let duration: Duration
        let byteCount: Int
        let sampleRate: Int = 16_000
        let channelCount: Int = 1

        /// The caller owns `fileURL` after `finish(requestID:)` returns and must return it
        /// through `removeCapturedAudio(at:)` after use. A later arm retries cleanup of
        /// artifacts abandoned by an interrupted launch or failed unlink.
    }

    enum State: Sendable, Equatable {
        case disarmed
        case armed(expiresAt: Date)
        case recordingSession(requestID: UUID, startedAt: Date, armExpiresAt: Date)
    }

    enum CancellationReason: Sendable, Equatable {
        case requested
        case disarmed
    }

    enum Incident: Sendable, Equatable {
        case expired
        case cancelled(requestID: UUID, reason: CancellationReason)
        case failed(requestID: UUID?, failure: Failure)
    }

    struct Update: Sendable, Equatable {
        let generation: UUID
        let sequence: UInt64
        let occurredAt: Date
        let state: State
        let incident: Incident?
    }

    enum Failure: Error, Sendable, Equatable, LocalizedError {
        case invalidSettings
        case foregroundRequired
        case microphonePermissionDenied
        case notArmed
        case busy(activeRequestID: UUID)
        case stale(expectedRequestID: UUID?, receivedRequestID: UUID)
        case emptyCapture
        case maximumDurationExceeded
        case storageUnavailable
        case audioResourceUnavailable
        case audioInterruption
        case audioRouteChanged
        case mediaServicesReset
        case audioConfigurationChanged
        case protectedDataUnavailable
        case writerBackpressureExceeded

        var errorDescription: String? {
            switch self {
            case .invalidSettings:
                "The armed duration must be greater than zero."
            case .foregroundRequired:
                "Hex must be in the foreground when audio capture is armed."
            case .microphonePermissionDenied:
                "Microphone permission is required."
            case .notArmed:
                "Audio capture is not armed."
            case let .busy(activeRequestID):
                "Dictation \(activeRequestID.uuidString) is already recording."
            case let .stale(expectedRequestID, receivedRequestID):
                if let expectedRequestID {
                    "Ignored stale Dictation \(receivedRequestID.uuidString); \(expectedRequestID.uuidString) is active."
                } else {
                    "Ignored stale Dictation \(receivedRequestID.uuidString); no Dictation is active."
                }
            case .emptyCapture:
                "No audio was captured."
            case .maximumDurationExceeded:
                "The five-minute recording limit was reached."
            case .storageUnavailable:
                "Hex could not store Captured Audio."
            case .audioResourceUnavailable:
                "The microphone audio resource is unavailable."
            case .audioInterruption:
                "The Recording Session was interrupted by iOS."
            case .audioRouteChanged:
                "The microphone route changed during the armed session."
            case .mediaServicesReset:
                "iOS reset its audio resources."
            case .audioConfigurationChanged:
                "The microphone configuration changed during the armed session."
            case .protectedDataUnavailable:
                "Hex stopped keyboard Dictation because the device was locked."
            case .writerBackpressureExceeded:
                "Hex stopped Dictation because audio processing could not keep up."
            }
        }
    }

    nonisolated let updates: AsyncStream<Update>

    private static let maximumRecordingSessionDuration: Duration = .seconds(5 * 60)
    private static let canonicalSampleRate = 16_000.0

    private let updateContinuation: AsyncStream<Update>.Continuation
    private let storage: CapturedAudioStorage
    private var state: State = .disarmed
    private var updateSequence: UInt64 = 0
    private var captureGeneration = UUID()
    private var settings = DeviceInteractionSettings()
    private var activeRequestID: UUID?
    private var recordingSessionStartedAt: Date?
    private var armExpiresAt: Date?
    private var armGeneration = UUID()

    private var engine: AVAudioEngine?
    private var pipeline: AudioTapPipeline?
    private var audioResourceGeneration: UUID?
    private var notificationObservers: [NSObjectProtocol] = []
    private var armExpiryTask: Task<Void, Never>?
    private var recordingSessionLimitTask: Task<Void, Never>?

    init(
        storageDirectory: URL? = nil,
        removeStoredArtifact: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        }
    ) {
        var continuation: AsyncStream<Update>.Continuation?
        updates = AsyncStream(bufferingPolicy: .bufferingNewest(32)) {
            continuation = $0
        }
        guard let continuation else {
            preconditionFailure("Unable to create DictationCapture update stream")
        }
        updateContinuation = continuation

        let resolvedStorageDirectory: URL
        if let storageDirectory {
            resolvedStorageDirectory = storageDirectory
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            resolvedStorageDirectory = applicationSupport
                .appendingPathComponent("Hex", isDirectory: true)
                .appendingPathComponent("CapturedAudio", isDirectory: true)
        }
        let storage = CapturedAudioStorage(
            directoryURL: resolvedStorageDirectory,
            removeItem: removeStoredArtifact
        )
        self.storage = storage
        do {
            try storage.prepareAndRemoveOrphans()
        } catch {
            HexLog.recording.error("Could not clean transient iOS capture storage at launch")
        }

        continuation.yield(
            Update(
                generation: captureGeneration,
                sequence: 0,
                occurredAt: Date(),
                state: .disarmed,
                incident: nil
            )
        )
    }

    deinit {
        armExpiryTask?.cancel()
        recordingSessionLimitTask?.cancel()
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        updateContinuation.finish()
    }

    func arm(
        settings: DeviceInteractionSettings = .init(),
        generation: UUID
    ) async throws -> UInt64 {
        captureGeneration = generation
        guard settings.armedDuration > .zero else {
            throw Failure.invalidSettings
        }

        if let activeRequestID {
            throw Failure.busy(activeRequestID: activeRequestID)
        }

        guard await MainActor.run(body: {
            UIApplication.shared.applicationState == .active
        }) else {
            throw Failure.foregroundRequired
        }
        guard await MainActor.run(body: {
            UIApplication.shared.isProtectedDataAvailable
        }) else {
            throw Failure.protectedDataUnavailable
        }

        guard await microphonePermissionGranted() else {
            throw Failure.microphonePermissionDenied
        }
        guard await MainActor.run(body: {
            UIApplication.shared.applicationState == .active
        }) else {
            throw Failure.foregroundRequired
        }

        self.settings = settings

        // Every arm is a privacy boundary. Retry any artifact whose earlier
        // deletion failed and refuse microphone access until storage is clean.
        try prepareStorage()

        if engine != nil {
            renewArmLease()
            return publish(state: state)
        }

        do {
            try startAudioResource()
            renewArmLease()
            return publish(state: state)
        } catch let failure as Failure {
            tearDownAudioResource()
            publish(state: .disarmed, incident: .failed(requestID: nil, failure: failure))
            throw failure
        } catch {
            tearDownAudioResource()
            let failure = Failure.audioResourceUnavailable
            publish(state: .disarmed, incident: .failed(requestID: nil, failure: failure))
            throw failure
        }
    }

    func begin(requestID: UUID) throws {
        guard engine != nil, let pipeline, let armExpiresAt else {
            throw Failure.notArmed
        }
        if let activeRequestID {
            if activeRequestID == requestID {
                return
            }
            throw Failure.busy(activeRequestID: activeRequestID)
        }

        do {
            try prepareStorage()
        } catch {
            failClosed(.storageUnavailable, requestID: nil)
            throw Failure.storageUnavailable
        }

        let fileURL = storage.artifactURL(requestID: requestID)
        do {
            try pipeline.begin(requestID: requestID, fileURL: fileURL)
        } catch let failure as Failure {
            if failure == .writerBackpressureExceeded
                || failure == .storageUnavailable {
                failClosed(failure, requestID: requestID)
            }
            throw failure
        } catch {
            throw Failure.storageUnavailable
        }

        let startedAt = Date()
        activeRequestID = requestID
        recordingSessionStartedAt = startedAt
        renewArmLease()
        let currentExpiry = self.armExpiresAt ?? armExpiresAt
        state = .recordingSession(
            requestID: requestID,
            startedAt: startedAt,
            armExpiresAt: currentExpiry
        )
        scheduleRecordingLimit(for: requestID)
        publish(state: state)
    }

    func finish(requestID: UUID) throws -> CapturedAudio {
        let pipeline = try activePipeline(for: requestID)
        recordingSessionLimitTask?.cancel()
        recordingSessionLimitTask = nil

        do {
            let result = try pipeline.finish(requestID: requestID)
            activeRequestID = nil
            recordingSessionStartedAt = nil
            renewArmLease()
            publish(state: state)
            return CapturedAudio(
                requestID: requestID,
                fileURL: result.fileURL,
                duration: .seconds(result.durationSeconds),
                byteCount: result.byteCount
            )
        } catch let failure as Failure {
            activeRequestID = nil
            recordingSessionStartedAt = nil
            if failure == .writerBackpressureExceeded
                || failure == .storageUnavailable {
                _ = tearDownAudioResource()
            } else {
                renewArmLease()
            }
            publish(
                state: state,
                incident: .failed(requestID: requestID, failure: failure)
            )
            throw failure
        } catch {
            activeRequestID = nil
            recordingSessionStartedAt = nil
            _ = tearDownAudioResource()
            let failure = Failure.storageUnavailable
            publish(
                state: state,
                incident: .failed(requestID: requestID, failure: failure)
            )
            throw failure
        }
    }

    func cancel(requestID: UUID) throws {
        let pipeline = try activePipeline(for: requestID)
        recordingSessionLimitTask?.cancel()
        recordingSessionLimitTask = nil
        do {
            try pipeline.cancel(requestID: requestID)
        } catch {
            activeRequestID = nil
            recordingSessionStartedAt = nil
            _ = tearDownAudioResource()
            publish(
                state: .disarmed,
                incident: .failed(requestID: requestID, failure: .storageUnavailable)
            )
            throw Failure.storageUnavailable
        }
        activeRequestID = nil
        recordingSessionStartedAt = nil
        renewArmLease()
        publish(
            state: state,
            incident: .cancelled(requestID: requestID, reason: .requested)
        )
    }

    /// Cancels `requestID` only if it is still the active recording.
    ///
    /// A missing active request means a concurrent Finish already won. Treating that as a
    /// successful no-op keeps a late keyboard Cancel from racing a completed transcript.
    @discardableResult
    func cancelIfActive(requestID: UUID) throws -> Bool {
        guard let activeRequestID else { return false }
        guard activeRequestID == requestID else {
            throw Failure.stale(
                expectedRequestID: activeRequestID,
                receivedRequestID: requestID
            )
        }

        let pipeline = try activePipeline(for: requestID)
        recordingSessionLimitTask?.cancel()
        recordingSessionLimitTask = nil
        do {
            try pipeline.cancel(requestID: requestID)
        } catch {
            self.activeRequestID = nil
            recordingSessionStartedAt = nil
            _ = tearDownAudioResource()
            publish(
                state: .disarmed,
                incident: .failed(requestID: requestID, failure: .storageUnavailable)
            )
            throw Failure.storageUnavailable
        }
        self.activeRequestID = nil
        recordingSessionStartedAt = nil
        renewArmLease()
        publish(
            state: state,
            incident: .cancelled(requestID: requestID, reason: .requested)
        )
        return true
    }

    func disarm() {
        let requestID = activeRequestID
        var deletionFailed = false
        if let requestID, let pipeline {
            do {
                try pipeline.cancel(requestID: requestID)
            } catch {
                deletionFailed = true
            }
        }
        activeRequestID = nil
        recordingSessionStartedAt = nil
        deletionFailed = tearDownAudioResource() || deletionFailed
        publish(
            state: .disarmed,
            incident: deletionFailed
                ? .failed(requestID: requestID, failure: .storageUnavailable)
                : requestID.map {
                    .cancelled(requestID: $0, reason: .disarmed)
                }
        )
    }

    func currentState() -> State {
        state
    }

    /// Deletes a completed artifact after its final consumer (normally upload)
    /// has finished. Deletion failure is surfaced and retried before another arm.
    func removeCapturedAudio(at fileURL: URL) throws {
        do {
            try storage.removeArtifact(at: fileURL)
        } catch {
            throw Failure.storageUnavailable
        }
    }

    private func activePipeline(for requestID: UUID) throws -> AudioTapPipeline {
        guard let pipeline, engine != nil else {
            throw Failure.notArmed
        }
        guard activeRequestID == requestID else {
            throw Failure.stale(
                expectedRequestID: activeRequestID,
                receivedRequestID: requestID
            )
        }
        return pipeline
    }

    private func microphonePermissionGranted() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            true
        case .denied:
            false
        case .undetermined:
            await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            false
        }
    }

    private func prepareStorage() throws {
        do {
            try storage.prepareAndRemoveOrphans()
        } catch {
            throw Failure.storageUnavailable
        }
    }

    private func startAudioResource() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            // Arming must not silence music, calls, or other user playback. `playAndRecord`
            // keeps input available in the background, `mixWithOthers` preserves existing
            // playback, HFP permits a selected Bluetooth microphone, and speaker routing
            // prevents this input-only app from unexpectedly selecting the receiver.
            var categoryOptions: AVAudioSession.CategoryOptions = [
                .mixWithOthers,
                .defaultToSpeaker
            ]
#if compiler(>=6.2)
            categoryOptions.insert(.allowBluetoothHFP)
#else
            categoryOptions.insert(.allowBluetooth)
#endif
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: categoryOptions
            )
            try session.setPreferredSampleRate(Self.canonicalSampleRate)
            try session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw Failure.audioResourceUnavailable
            }

            let pipeline = try AudioTapPipeline(
                inputFormat: inputFormat,
                storage: storage,
                onFailure: { [weak self] requestID, failure in
                    Task {
                        await self?.handlePipelineFailure(
                            requestID: requestID,
                            failure: failure
                        )
                    }
                }
            )
            input.installTap(
                onBus: 0,
                bufferSize: 1_024,
                format: inputFormat
            ) { [pipeline] buffer, _ in
                pipeline.receive(buffer)
            }

            engine.prepare()
            try engine.start()
            let resourceGeneration = UUID()
            self.engine = engine
            self.pipeline = pipeline
            audioResourceGeneration = resourceGeneration
            installAudioObservers(for: engine, generation: resourceGeneration)
        } catch let failure as Failure {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw failure
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw Failure.audioResourceUnavailable
        }
    }

    @discardableResult
    private func tearDownAudioResource() -> Bool {
        // Invalidate callbacks before releasing the resources they describe. A
        // cancelled sleep or NotificationCenter callback may already be queued.
        armGeneration = UUID()
        audioResourceGeneration = nil
        armExpiryTask?.cancel()
        armExpiryTask = nil
        recordingSessionLimitTask?.cancel()
        recordingSessionLimitTask = nil
        removeAudioObservers()

        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
        }
        var deletionFailed = false
        do {
            try pipeline?.disarm()
        } catch {
            deletionFailed = true
            HexLog.recording.error(
                "Could not delete transient iOS capture while tearing down audio"
            )
        }
        engine = nil
        pipeline = nil
        armExpiresAt = nil
        state = .disarmed
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        return deletionFailed
    }

    private func renewArmLease() {
        armExpiryTask?.cancel()
        armGeneration = UUID()
        let generation = armGeneration
        let duration = settings.armedDuration
        let expiresAt = Date().addingTimeInterval(duration.timeInterval)
        armExpiresAt = expiresAt

        if let activeRequestID, let recordingSessionStartedAt {
            state = .recordingSession(
                requestID: activeRequestID,
                startedAt: recordingSessionStartedAt,
                armExpiresAt: expiresAt
            )
        } else {
            state = .armed(expiresAt: expiresAt)
        }

        armExpiryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            await self?.expireArm(generation: generation)
        }
    }

    private func expireArm(generation: UUID) {
        guard generation == armGeneration else { return }
        if activeRequestID != nil {
            return
        }
        tearDownAudioResource()
        publish(state: .disarmed, incident: .expired)
    }

    private func scheduleRecordingLimit(for requestID: UUID) {
        recordingSessionLimitTask?.cancel()
        recordingSessionLimitTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.maximumRecordingSessionDuration)
            } catch {
                return
            }
            await self?.recordingLimitReached(requestID: requestID)
        }
    }

    private func recordingLimitReached(requestID: UUID) {
        guard activeRequestID == requestID, let pipeline else { return }
        let failure: Failure
        do {
            try pipeline.cancel(requestID: requestID)
            failure = .maximumDurationExceeded
        } catch {
            failure = .storageUnavailable
        }
        activeRequestID = nil
        recordingSessionStartedAt = nil
        if failure == .storageUnavailable {
            _ = tearDownAudioResource()
        } else {
            renewArmLease()
        }
        publish(
            state: failure == .storageUnavailable ? .disarmed : state,
            incident: .failed(
                requestID: requestID,
                failure: failure
            )
        )
    }

    private func handlePipelineFailure(
        requestID: UUID,
        failure: Failure
    ) {
        guard activeRequestID == requestID else { return }
        failClosed(failure, requestID: requestID)
    }

    private func handleAudioLifecycleFailure(
        _ failure: Failure,
        generation: UUID
    ) {
        guard engine != nil, audioResourceGeneration == generation else { return }
        failClosed(failure, requestID: activeRequestID)
    }

    private func failClosed(_ failure: Failure, requestID: UUID?) {
        HexLog.recording.error("iOS capture failed")
        var reportedFailure = failure
        if let requestID, let pipeline {
            do {
                try pipeline.cancel(requestID: requestID)
            } catch {
                reportedFailure = .storageUnavailable
            }
        }
        activeRequestID = nil
        recordingSessionStartedAt = nil
        if tearDownAudioResource() {
            reportedFailure = .storageUnavailable
        }
        publish(
            state: .disarmed,
            incident: .failed(requestID: requestID, failure: reportedFailure)
        )
    }

    @discardableResult
    private func publish(state: State, incident: Incident? = nil) -> UInt64 {
        self.state = state
        updateSequence &+= 1
        updateContinuation.yield(
            Update(
                generation: captureGeneration,
                sequence: updateSequence,
                occurredAt: Date(),
                state: state,
                incident: incident
            )
        )
        return updateSequence
    }

    private func installAudioObservers(
        for engine: AVAudioEngine,
        generation: UUID
    ) {
        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: nil
            ) { [weak self] notification in
                guard
                    let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey]
                        as? UInt,
                    AVAudioSession.InterruptionType(rawValue: rawType) == .began
                else {
                    return
                }
                Task {
                    await self?.handleAudioLifecycleFailure(
                        .audioInterruption,
                        generation: generation
                    )
                }
            },
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                queue: nil
            ) { [weak self] _ in
                Task {
                    await self?.handleAudioLifecycleFailure(
                        .audioRouteChanged,
                        generation: generation
                    )
                }
            },
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: AVAudioSession.sharedInstance(),
                queue: nil
            ) { [weak self] _ in
                Task {
                    await self?.handleAudioLifecycleFailure(
                        .mediaServicesReset,
                        generation: generation
                    )
                }
            },
            center.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                Task {
                    await self?.handleAudioLifecycleFailure(
                        .audioConfigurationChanged,
                        generation: generation
                    )
                }
            },
            center.addObserver(
                forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task {
                    await self?.handleAudioLifecycleFailure(
                        .protectedDataUnavailable,
                        generation: generation
                    )
                }
            },
        ]
    }

    private func removeAudioObservers() {
        let center = NotificationCenter.default
        for observer in notificationObservers {
            center.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds)
            + TimeInterval(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}

final class AudioTapPipeline: @unchecked Sendable {
    struct Result: Sendable {
        let fileURL: URL
        let durationSeconds: Double
        let byteCount: Int
    }

    private let inputFormat: AVAudioFormat
    private let ring: AudioTapRing
    private let consumerQueue = DispatchQueue(
        label: "com.nmarch213.HexKeyboardTracer.capture-consumer",
        qos: .userInitiated
    )
    private let consumerTimer: DispatchSourceTimer
    private let writer: CaptureWriter
    private let onFailure: @Sendable (UUID, DictationCapture.Failure) -> Void
    private var activeRequestID: UUID?
    private var writerIsReady = false
    private var failureWasReported = false

    init(
        inputFormat: AVAudioFormat,
        storage: CapturedAudioStorage,
        onFailure: @escaping @Sendable (UUID, DictationCapture.Failure) -> Void
    ) throws {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw DictationCapture.Failure.audioResourceUnavailable
        }
        self.inputFormat = inputFormat
        ring = try AudioTapRing(inputFormat: inputFormat)
        consumerTimer = DispatchSource.makeTimerSource(queue: consumerQueue)
        writer = CaptureWriter(storage: storage)
        self.onFailure = onFailure
        consumerTimer.setEventHandler { [weak self] in
            self?.consumeAvailableAudio()
        }
        consumerTimer.schedule(deadline: .distantFuture)
        consumerTimer.resume()
    }

    deinit {
        ring.disarm()
        consumerTimer.cancel()
    }

    func begin(requestID: UUID, fileURL: URL) throws {
        try ring.beginCapture(requestID: requestID)
        do {
            try consumerQueue.sync {
                activeRequestID = requestID
                failureWasReported = false
                try writer.begin(
                    requestID: requestID,
                    fileURL: fileURL,
                    inputFormat: inputFormat
                )
                writerIsReady = true
                consumerTimer.schedule(
                    deadline: .now(),
                    repeating: .milliseconds(2),
                    leeway: .milliseconds(1)
                )
                try consumeAvailableAudioReportingFailure()
            }
        } catch {
            ring.stopCaptureIfMatching(requestID: requestID)
            do {
                try consumerQueue.sync {
                    writerIsReady = false
                    consumerTimer.schedule(deadline: .distantFuture)
                    activeRequestID = nil
                    try writer.cancel(requestID: requestID)
                }
            } catch {
                throw DictationCapture.Failure.storageUnavailable
            }
            if let failure = error as? DictationCapture.Failure {
                throw failure
            }
            throw DictationCapture.Failure.storageUnavailable
        }
    }

    /// Apple invokes this method on the real-time audio thread. Keep this path to a
    /// bounded memcpy and lock-free atomic publication. A timer active only during a
    /// Dictation polls the ring from `consumerQueue`; file I/O, conversion, dispatch,
    /// and allocation stay off this callback.
    func receive(_ buffer: AVAudioPCMBuffer) {
        _ = ring.push(buffer)
    }

    func finish(requestID: UUID) throws -> Result {
        try ring.stopCapture(requestID: requestID)
        do {
            return try consumerQueue.sync {
                defer {
                    writerIsReady = false
                    consumerTimer.schedule(deadline: .distantFuture)
                    activeRequestID = nil
                }
                try consumeAvailableAudioReportingFailure()
                return try writer.finish(requestID: requestID)
            }
        } catch {
            let finishError = error
            do {
                try consumerQueue.sync {
                    writerIsReady = false
                    consumerTimer.schedule(deadline: .distantFuture)
                    activeRequestID = nil
                    try writer.cancel(requestID: requestID)
                }
            } catch {
                ring.disarm()
                throw DictationCapture.Failure.storageUnavailable
            }
            if let failure = finishError as? DictationCapture.Failure {
                if failure == .storageUnavailable {
                    ring.disarm()
                }
                throw failure
            }
            ring.disarm()
            throw DictationCapture.Failure.storageUnavailable
        }
    }

    func cancel(requestID: UUID) throws {
        ring.stopCaptureIfMatching(requestID: requestID)
        do {
            try consumerQueue.sync {
                writerIsReady = false
                consumerTimer.schedule(deadline: .distantFuture)
                activeRequestID = nil
                ring.discardAvailable()
                try writer.cancel(requestID: requestID)
            }
        } catch {
            ring.disarm()
            throw DictationCapture.Failure.storageUnavailable
        }
    }

    func disarm() throws {
        ring.disarm()
        try consumerQueue.sync {
            let requestID = activeRequestID
            writerIsReady = false
            consumerTimer.schedule(deadline: .distantFuture)
            activeRequestID = nil
            ring.discardAvailable()
            if let requestID {
                try writer.cancel(requestID: requestID)
            }
        }
    }

    private func consumeAvailableAudio() {
        guard writerIsReady else { return }
        do {
            try consumeAvailableAudioReportingFailure()
        } catch let failure as DictationCapture.Failure {
            reportFailureOnce(failure)
        } catch {
            reportFailureOnce(.storageUnavailable)
        }
    }

    private func consumeAvailableAudioReportingFailure() throws {
        guard let requestID = activeRequestID else {
            ring.discardAvailable()
            return
        }

        while let buffer = ring.peek() {
            do {
                try writer.appendSynchronously(buffer, requestID: requestID)
                ring.consumePeeked()
            } catch {
                ring.fail(.storageUnavailable)
                ring.discardAvailable()
                throw DictationCapture.Failure.storageUnavailable
            }
        }
        if let failure = ring.pendingFailure() {
            throw failure
        }
    }

    private func reportFailureOnce(_ failure: DictationCapture.Failure) {
        guard !failureWasReported, let requestID = activeRequestID else { return }
        failureWasReported = true
        consumerTimer.schedule(deadline: .distantFuture)
        onFailure(requestID, failure)
    }
}

/// A bounded single-producer/single-consumer ring used at the Core Audio boundary.
///
/// All slot storage is allocated during pipeline construction. The producer is the AVAudio
/// tap and the consumer is `AudioTapPipeline.consumerQueue`. Acquire/release barriers on the
/// published sequence numbers make the copied samples visible without a mutex. Lifecycle
/// methods wait only from non-real-time callers for an in-flight producer to leave a slot.
final class AudioTapRing: @unchecked Sendable {
    enum PushResult: Equatable {
        case enqueued
        case failed
        case ignored
    }

    private enum Phase: Int32 {
        case idle = 0
        case capturing = 1
        case failed = 2
        case disarmed = 3
    }

    private enum FailureCode: Int32 {
        case none = 0
        case backpressure = 1
        case storage = 2
    }

    private static let capacity = 32
    /// `installTap(bufferSize:)` is advisory. Physical iPhones can deliver 4,800-frame
    /// input buffers even when the requested size is 1,024, so preallocate enough room
    /// for the observed hardware callback while keeping the real-time boundary bounded.
    private static let maximumFramesPerTap: AVAudioFrameCount = 8_192

    private let slots: [AVAudioPCMBuffer]
    private let inputDescription: AudioStreamBasicDescription
    private let phase = Atomic<Int32>(Phase.idle.rawValue)
    private let failureCode = Atomic<Int32>(FailureCode.none.rawValue)
    private let producerSequence = Atomic<Int32>(0)
    private let consumerSequence = Atomic<Int32>(0)
    private let producerInFlight = Atomic<Int32>(0)
    private var requestID: UUID?

    init(inputFormat: AVAudioFormat) throws {
        inputDescription = inputFormat.streamDescription.pointee
        var allocated: [AVAudioPCMBuffer] = []
        allocated.reserveCapacity(Self.capacity)
        for _ in 0..<Self.capacity {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: Self.maximumFramesPerTap
            ) else {
                throw DictationCapture.Failure.audioResourceUnavailable
            }
            allocated.append(buffer)
        }
        slots = allocated
    }

    func beginCapture(requestID: UUID) throws {
        waitForProducer()
        guard phase.load(ordering: .acquiring) == Phase.idle.rawValue else {
            if let activeRequestID = self.requestID {
                throw DictationCapture.Failure.busy(activeRequestID: activeRequestID)
            }
            throw DictationCapture.Failure.notArmed
        }
        producerSequence.store(0, ordering: .releasing)
        consumerSequence.store(0, ordering: .releasing)
        failureCode.store(FailureCode.none.rawValue, ordering: .releasing)
        self.requestID = requestID
        phase.store(Phase.capturing.rawValue, ordering: .releasing)
    }

    @inline(__always)
    func push(_ source: AVAudioPCMBuffer) -> PushResult {
        _ = producerInFlight.wrappingAdd(1, ordering: .acquiringAndReleasing)
        defer {
            _ = producerInFlight.wrappingSubtract(
                1,
                ordering: .acquiringAndReleasing
            )
        }

        guard phase.load(ordering: .acquiring) == Phase.capturing.rawValue else {
            return .ignored
        }

        let produced = producerSequence.load(ordering: .relaxed)
        let consumed = consumerSequence.load(ordering: .acquiring)
        guard produced - consumed < Int32(Self.capacity) else {
            failFromProducer(.backpressure)
            return .failed
        }

        guard source.frameLength <= Self.maximumFramesPerTap else {
            failFromProducer(.backpressure)
            return .failed
        }
        let slot = slots[Int(produced % Int32(Self.capacity))]
        guard copy(source, into: slot) else {
            failFromProducer(.storage)
            return .failed
        }

        // Stop may have won while the memcpy was in progress. In that case this slot was
        // never published and the non-real-time stopper waits for this callback to return
        // before resetting or reusing the ring.
        guard phase.load(ordering: .acquiring) == Phase.capturing.rawValue else {
            return .ignored
        }
        producerSequence.store(produced + 1, ordering: .releasing)
        return .enqueued
    }

    func peek() -> AVAudioPCMBuffer? {
        let consumed = consumerSequence.load(ordering: .relaxed)
        guard consumed < producerSequence.load(ordering: .acquiring) else { return nil }
        return slots[Int(consumed % Int32(Self.capacity))]
    }

    func consumePeeked() {
        let consumed = consumerSequence.load(ordering: .relaxed)
        precondition(consumed < producerSequence.load(ordering: .acquiring))
        consumerSequence.store(consumed + 1, ordering: .releasing)
    }

    func discardAvailable() {
        consumerSequence.store(
            producerSequence.load(ordering: .acquiring),
            ordering: .releasing
        )
    }

    func stopCapture(requestID: UUID) throws {
        guard self.requestID == requestID else {
            throw DictationCapture.Failure.stale(
                expectedRequestID: self.requestID,
                receivedRequestID: requestID
            )
        }
        stopCaptureIfMatching(requestID: requestID)
    }

    func stopCaptureIfMatching(requestID: UUID) {
        guard self.requestID == requestID else { return }
        let current = phase.load(ordering: .acquiring)
        if current == Phase.capturing.rawValue || current == Phase.failed.rawValue {
            phase.store(Phase.idle.rawValue, ordering: .releasing)
        }
        waitForProducer()
        self.requestID = nil
    }

    func disarm() {
        phase.store(Phase.disarmed.rawValue, ordering: .releasing)
        waitForProducer()
        requestID = nil
    }

    func fail(_ failure: DictationCapture.Failure) {
        let code: FailureCode = failure == .writerBackpressureExceeded
            ? .backpressure
            : .storage
        _ = failureCode.compareExchange(
            expected: FailureCode.none.rawValue,
            desired: code.rawValue,
            ordering: .acquiringAndReleasing
        )
        phase.store(Phase.failed.rawValue, ordering: .releasing)
    }

    func pendingFailure() -> DictationCapture.Failure? {
        switch FailureCode(rawValue: failureCode.load(ordering: .acquiring)) ?? .storage {
        case .none:
            return nil
        case .backpressure:
            return .writerBackpressureExceeded
        case .storage:
            return .storageUnavailable
        }
    }

    private func failFromProducer(_ failure: FailureCode) {
        _ = failureCode.compareExchange(
            expected: FailureCode.none.rawValue,
            desired: failure.rawValue,
            ordering: .acquiringAndReleasing
        )
        phase.store(Phase.failed.rawValue, ordering: .releasing)
    }

    @inline(__always)
    private func copy(
        _ source: AVAudioPCMBuffer,
        into destination: AVAudioPCMBuffer
    ) -> Bool {
        let sourceDescription = source.format.streamDescription.pointee
        guard source.frameLength > 0,
              source.frameLength <= destination.frameCapacity,
              sourceDescription.mSampleRate == inputDescription.mSampleRate,
              sourceDescription.mFormatID == inputDescription.mFormatID,
              sourceDescription.mFormatFlags == inputDescription.mFormatFlags,
              sourceDescription.mBytesPerFrame == inputDescription.mBytesPerFrame,
              sourceDescription.mChannelsPerFrame == inputDescription.mChannelsPerFrame,
              sourceDescription.mBitsPerChannel == inputDescription.mBitsPerChannel
        else {
            return false
        }
        destination.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            source.mutableAudioBufferList
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            destination.mutableAudioBufferList
        )
        guard sourceBuffers.count == destinationBuffers.count else { return false }
        for index in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[index]
            var destinationBuffer = destinationBuffers[index]
            guard let sourceData = sourceBuffer.mData,
                  let destinationData = destinationBuffer.mData,
                  destinationBuffer.mDataByteSize >= sourceBuffer.mDataByteSize
            else {
                return false
            }
            memcpy(destinationData, sourceData, Int(sourceBuffer.mDataByteSize))
            destinationBuffer.mDataByteSize = sourceBuffer.mDataByteSize
            destinationBuffers[index] = destinationBuffer
        }
        return true
    }

    private func waitForProducer() {
        while producerInFlight.load(ordering: .acquiring) != 0 {
            sched_yield()
        }
    }
}

private final class CaptureWriter: @unchecked Sendable {
    private static var outputSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
    }

    private final class ConverterInput: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var wasSupplied = false

        init(buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }
    }

    private final class Session {
        let requestID: UUID
        let fileURL: URL
        let converter: AVAudioConverter
        let outputFormat: AVAudioFormat
        var file: AVAudioFile?
        var frameCount: AVAudioFramePosition = 0
        var failed = false

        init(
            requestID: UUID,
            fileURL: URL,
            converter: AVAudioConverter,
            outputFormat: AVAudioFormat,
            file: AVAudioFile
        ) {
            self.requestID = requestID
            self.fileURL = fileURL
            self.converter = converter
            self.outputFormat = outputFormat
            self.file = file
        }
    }

    private let storage: CapturedAudioStorage
    private var session: Session?

    init(storage: CapturedAudioStorage) {
        self.storage = storage
    }

    func begin(
        requestID: UUID,
        fileURL: URL,
        inputFormat: AVAudioFormat
    ) throws {
        guard session == nil else {
            throw DictationCapture.Failure.busy(
                activeRequestID: session?.requestID ?? requestID
            )
        }
        let fileManager = FileManager.default
        do {
            try storage.removeArtifact(at: fileURL)
        } catch {
            throw DictationCapture.Failure.storageUnavailable
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw DictationCapture.Failure.audioResourceUnavailable
        }

        do {
            let file = try AVAudioFile(
                forWriting: fileURL,
                settings: Self.outputSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try fileManager.setAttributes(
                [
                    .protectionKey: FileProtectionType.completeUnlessOpen,
                    .posixPermissions: 0o600,
                ],
                ofItemAtPath: fileURL.path
            )
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var protectedURL = fileURL
            try protectedURL.setResourceValues(resourceValues)
            session = Session(
                requestID: requestID,
                fileURL: fileURL,
                converter: converter,
                outputFormat: outputFormat,
                file: file
            )
        } catch {
            do {
                if let session, session.requestID == requestID {
                    try discard(session)
                } else {
                    try storage.removeArtifact(at: fileURL)
                }
            } catch {
                throw DictationCapture.Failure.storageUnavailable
            }
            if let failure = error as? DictationCapture.Failure {
                throw failure
            }
            throw DictationCapture.Failure.storageUnavailable
        }
    }

    func appendSynchronously(
        _ buffer: AVAudioPCMBuffer,
        requestID: UUID
    ) throws {
        do {
            try append(buffer, requestID: requestID)
        } catch {
            session?.failed = true
            throw error
        }
    }

    func finish(requestID: UUID) throws -> AudioTapPipeline.Result {
        guard let session, session.requestID == requestID else {
            throw DictationCapture.Failure.stale(
                expectedRequestID: self.session?.requestID,
                receivedRequestID: requestID
            )
        }
        guard !session.failed else {
            try discard(session)
            throw DictationCapture.Failure.storageUnavailable
        }

        do {
            try drainConverter(session)
        } catch {
            try discard(session)
            throw DictationCapture.Failure.storageUnavailable
        }

        let frameCount = session.frameCount
        let fileURL = session.fileURL
        session.file = nil
        self.session = nil

        guard frameCount > 0 else {
            try storage.removeArtifact(at: fileURL)
            throw DictationCapture.Failure.emptyCapture
        }
        guard frameCount <= 16_000 * 5 * 60 else {
            try storage.removeArtifact(at: fileURL)
            throw DictationCapture.Failure.maximumDurationExceeded
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard
            let byteCount = attributes?[.size] as? NSNumber,
            byteCount.intValue > 0
        else {
            try storage.removeArtifact(at: fileURL)
            throw DictationCapture.Failure.storageUnavailable
        }

        return AudioTapPipeline.Result(
            fileURL: fileURL,
            durationSeconds: Double(frameCount) / 16_000,
            byteCount: byteCount.intValue
        )
    }

    func cancel(requestID: UUID) throws {
        guard let session, session.requestID == requestID else { return }
        try discard(session)
    }

    private func append(
        _ input: AVAudioPCMBuffer,
        requestID: UUID
    ) throws {
        guard
            let session,
            session.requestID == requestID,
            !session.failed,
            let file = session.file
        else {
            return
        }

        let ratio = session.outputFormat.sampleRate / input.format.sampleRate
        let estimatedFrames = ceil(Double(input.frameLength) * ratio) + 64
        let capacity = AVAudioFrameCount(
            min(Double(UInt32.max), max(1, estimatedFrames))
        )
        guard let output = AVAudioPCMBuffer(
            pcmFormat: session.outputFormat,
            frameCapacity: capacity
        ) else {
            throw DictationCapture.Failure.storageUnavailable
        }

        let converterInput = ConverterInput(buffer: input)
        var conversionError: NSError?
        let status = session.converter.convert(
            to: output,
            error: &conversionError
        ) { _, inputStatus in
            if converterInput.wasSupplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            converterInput.wasSupplied = true
            inputStatus.pointee = .haveData
            return converterInput.buffer
        }
        if conversionError != nil || status == .error {
            throw DictationCapture.Failure.storageUnavailable
        }
        if output.frameLength > 0 {
            try file.write(from: output)
            session.frameCount += AVAudioFramePosition(output.frameLength)
        }
    }

    private func drainConverter(_ session: Session) throws {
        guard let file = session.file else { return }
        for _ in 0..<8 {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: session.outputFormat,
                frameCapacity: 1_024
            ) else {
                throw DictationCapture.Failure.storageUnavailable
            }
            var conversionError: NSError?
            let status = session.converter.convert(
                to: output,
                error: &conversionError
            ) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if conversionError != nil || status == .error {
                throw DictationCapture.Failure.storageUnavailable
            }
            if output.frameLength > 0 {
                try file.write(from: output)
                session.frameCount += AVAudioFramePosition(output.frameLength)
            }
            if status == .endOfStream || output.frameLength == 0 {
                break
            }
        }
    }

    private func discard(_ session: Session) throws {
        session.file = nil
        self.session = nil
        try storage.removeArtifact(at: session.fileURL)
    }
}
