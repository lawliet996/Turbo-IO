import AVFoundation
import CoreML
import FluidAudio
import Foundation

/// Adapter around FluidAudio's multilingual Parakeet TDT v3 sliding-window engine.
public actor FluidAudioASREngine: RealtimeASREngine {
    private var models: AsrModels?
    private var manager: SlidingWindowAsrManager?
    private var updateTask: Task<Void, Never>?
    private var utteranceID: UUID?
    private var revision: UInt64 = 0
    private var eventContinuation: AsyncStream<ASREvent>.Continuation?
    private let eventStreamStorage: AsyncStream<ASREvent>

    public init() {
        let pair = AsyncStream<ASREvent>.makeStream(bufferingPolicy: .bufferingNewest(32))
        eventStreamStorage = pair.stream
        eventContinuation = pair.continuation
    }

    public func eventStream() async -> AsyncStream<ASREvent> { eventStreamStorage }

    public func prepare() async throws {
        guard models == nil else { return }
        // FluidAudio stages downloaded Core ML assets in its cache directory. No
        // model binaries are included in this package or the application bundle.
        models = try await AsrModels.downloadAndLoad(
            version: .v3,
            encoderComputeUnits: .cpuAndNeuralEngine
        )
    }

    public func start(utteranceID: UUID) async throws {
        guard let models else { throw FluidAudioASREngineError.modelsNotPrepared }
        await cancelCurrentStream()
        self.utteranceID = utteranceID
        revision = 0

        let manager = SlidingWindowAsrManager(config: .streaming)
        try await manager.loadModels(models)
        let updates = await manager.transcriptionUpdates
        try await manager.startStreaming(source: .microphone)
        self.manager = manager
        updateTask = Task { [weak self, weak manager] in
            for await update in updates {
                guard !Task.isCancelled else { return }
                guard let manager else { return }
                let confirmed = await manager.confirmedTranscript
                let volatile = await manager.volatileTranscript
                let text = [confirmed, volatile].filter { !$0.isEmpty }.joined(separator: " ")
                await self?.publishPartial(text, timestamp: update.timestamp)
            }
        }
    }

    public func append(_ frame: PCMFrame) async throws {
        guard frame.sampleRate == 16_000, frame.channelCount == 1,
              frame.sampleFormat == .int16, frame.interleaved,
              let manager else { throw PCMFrameError.unsupportedFormat }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(frame.sampleRate),
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frame.samples.count)
        ), let channel = buffer.floatChannelData?[0] else {
            throw FluidAudioASREngineError.audioBufferCreationFailed
        }

        buffer.frameLength = AVAudioFrameCount(frame.samples.count)
        for index in frame.samples.indices {
            channel[index] = Float(frame.samples[index]) / Float(Int16.max)
        }
        await manager.streamAudio(buffer)
    }

    public func finish() async throws -> ASREvent? {
        guard let manager, let utteranceID else { return nil }
        let finalText = try await manager.finish()
        updateTask?.cancel()
        updateTask = nil
        self.manager = nil
        self.utteranceID = nil
        let text = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        revision &+= 1
        let event = ASREvent(
            utteranceID: utteranceID,
            revision: revision,
            kind: .final,
            text: text,
            languageCode: nil
        )
        eventContinuation?.yield(event)
        return event
    }

    public func cancel() async {
        await cancelCurrentStream()
        utteranceID = nil
    }

    private func publishPartial(_ text: String, timestamp: Date) {
        guard let utteranceID else { return }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        revision &+= 1
        eventContinuation?.yield(ASREvent(
            utteranceID: utteranceID,
            revision: revision,
            kind: .partial,
            text: normalized,
            languageCode: nil,
            timestamp: timestamp
        ))
    }

    private func cancelCurrentStream() async {
        updateTask?.cancel()
        updateTask = nil
        if let manager {
            await manager.cancel()
        }
        manager = nil
    }
}

public enum FluidAudioASREngineError: Error, Sendable {
    case modelsNotPrepared
    case audioBufferCreationFailed
}
