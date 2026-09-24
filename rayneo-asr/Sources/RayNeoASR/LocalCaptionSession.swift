import Foundation

@MainActor
public final class LocalCaptionSession {
    public typealias EventHandler = @MainActor (ASREvent) -> Void
    public typealias StateHandler = @MainActor (ASREngineState) -> Void

    public private(set) var state: ASREngineState = .idle {
        didSet { stateHandler?(state) }
    }
    public var eventHandler: EventHandler?
    public var stateHandler: StateHandler?

    private let engine: any RealtimeASREngine
    private var frameStream: AsyncStream<PCMFrame>
    private var frameContinuation: AsyncStream<PCMFrame>.Continuation
    private var audioTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var prepareTask: Task<Void, Error>?
    private var currentUtteranceID: UUID?
    private var previousSequence: UInt64?
    private var streamFinished = false
    private var reducer = SubtitleEventReducer()

    public init(engine: any RealtimeASREngine = FluidAudioASREngine()) {
        self.engine = engine
        let pair = AsyncStream<PCMFrame>.makeStream(bufferingPolicy: .bufferingOldest(48))
        self.frameStream = pair.stream
        self.frameContinuation = pair.continuation
    }

    public func prepare() async {
        guard state != .ready, state != .preparing else { return }
        state = .preparing
        let engine = self.engine
        let task = Task { try await engine.prepare() }
        prepareTask = task
        do {
            try await task.value
            try Task.checkCancellation()
            state = .ready
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
        prepareTask = nil
    }

    public func start(utteranceID: UUID = UUID()) async throws {
        guard state == .ready else { throw LocalCaptionSessionError.engineNotReady }
        await stopWorkers()
        currentUtteranceID = utteranceID
        reducer = SubtitleEventReducer()
        if streamFinished { resetFrameStream() }

        let stream = await engine.eventStream()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                self?.receive(event)
            }
        }

        try await engine.start(utteranceID: utteranceID)
        let input = frameStream
        audioTask = Task { [weak self, engine, input] in
            for await frame in input {
                guard !Task.isCancelled else { return }
                do {
                    try await engine.append(frame)
                } catch {
                    self?.state = .failed(error.localizedDescription)
                    return
                }
            }
        }
        state = .listening
    }

    /// Enqueues a bounded frame without waiting on model inference. If inference
    /// falls behind by more than 5.76 seconds, the utterance is cancelled instead
    /// of retaining unbounded PCM or silently splicing discontinuous audio.
    public func append(_ frame: PCMFrame) {
        guard state == .ready || state == .listening else { return }
        if let previousSequence, frame.sequence != previousSequence &+ 1 {
            state = .failed("本地 ASR 音频帧不连续，已取消本轮以避免错误字幕。")
            Task { await engine.cancel() }
            return
        }
        previousSequence = frame.sequence
        switch frameContinuation.yield(frame) {
        case .enqueued(remaining: _): break
        case .dropped(_):
            state = .failed("本地 ASR 处理速度不足，已取消本轮以避免字幕错位。")
            Task { await engine.cancel() }
        case .terminated:
            state = .failed("本地 ASR 音频队列已关闭。")
        @unknown default:
            state = .failed("本地 ASR 音频队列状态未知。")
        }
    }

    public func finish() async {
        guard let utteranceID = currentUtteranceID else { return }
        let previousState = state
        state = .finishing
        frameContinuation.finish()
        streamFinished = true
        await audioTask?.value
        audioTask = nil
        let workerState = state
        do {
            if let final = try await engine.finish(), final.utteranceID == utteranceID {
                receive(final)
            }
            if case .failed = previousState { state = previousState }
            else if case .failed = workerState { state = workerState }
            else { state = .ready }
        } catch {
            state = .failed(error.localizedDescription)
        }
        currentUtteranceID = nil
        previousSequence = nil
        resetFrameStream()
        eventTask?.cancel()
        eventTask = nil
    }

    public func cancel() async {
        let wasPrepared = state == .ready || state == .listening || state == .finishing
        prepareTask?.cancel()
        prepareTask = nil
        frameContinuation.finish()
        await stopWorkers()
        await engine.cancel()
        streamFinished = true
        resetFrameStream()
        currentUtteranceID = nil
        previousSequence = nil
        reducer = SubtitleEventReducer()
        state = wasPrepared ? .ready : .idle
    }

    private func receive(_ event: ASREvent) {
        guard event.utteranceID == currentUtteranceID,
              let accepted = reducer.reduce(event) else { return }
        eventHandler?(accepted)
    }

    private func stopWorkers() async {
        audioTask?.cancel()
        eventTask?.cancel()
        await audioTask?.value
        audioTask = nil
        eventTask = nil
    }

    private func resetFrameStream() {
        let pair = AsyncStream<PCMFrame>.makeStream(bufferingPolicy: .bufferingOldest(48))
        frameStream = pair.stream
        frameContinuation = pair.continuation
        streamFinished = false
    }
}

public enum LocalCaptionSessionError: Error, Sendable {
    case engineNotReady
}
