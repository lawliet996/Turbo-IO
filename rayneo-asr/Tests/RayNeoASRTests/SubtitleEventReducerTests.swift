import Foundation
import XCTest
@testable import RayNeoASR

final class SubtitleEventReducerTests: XCTestCase {
    func testPCMFrameRetainsRayNeoFormatAndOffsets() throws {
        let frame = try PCMFrame(
            samples: Array(repeating: 1, count: 1_920),
            sampleRate: 16_000,
            channelCount: 1,
            sampleFormat: .int16,
            interleaved: true,
            sequence: 7,
            sampleOffset: 9_600,
            timestamp: 12.5
        )
        XCTAssertEqual(frame.frameCount, 1_920)
        XCTAssertEqual(frame.duration, 0.12, accuracy: 0.0001)
        XCTAssertEqual(frame.sampleRate, 16_000)
        XCTAssertEqual(frame.channelCount, 1)
        XCTAssertEqual(frame.sampleFormat, .int16)
        XCTAssertTrue(frame.interleaved)
        XCTAssertEqual(frame.sequence, 7)
        XCTAssertEqual(frame.sampleOffset, 9_600)
    }

    func testPCMFrameRejectsInvalidChannelShape() {
        XCTAssertThrowsError(try PCMFrame(
            samples: [1, 2, 3], sampleRate: 16_000, channelCount: 2,
            sequence: 0, sampleOffset: 0, timestamp: 0
        ))
    }

    func testPartialThenFinalReplacesPartial() {
        let id = UUID()
        var reducer = SubtitleEventReducer()
        let partial = event(id, revision: 1, kind: .partial, text: "Guten Tag")
        let final = event(id, revision: 2, kind: .final, text: "Guten Tag!")
        XCTAssertEqual(reducer.reduce(partial), partial)
        XCTAssertEqual(reducer.reduce(final), final)
        XCTAssertEqual(reducer.latest, final)
    }

    func testFinalIsNotDroppedAfterPartialThrottleWindow() {
        let id = UUID()
        var reducer = SubtitleEventReducer()
        let partial = event(id, revision: 1, kind: .partial, text: "Hallo")
        let final = event(id, revision: 2, kind: .final, text: "Hallo Welt")
        _ = reducer.reduce(partial)
        XCTAssertEqual(reducer.reduce(final), final)
        XCTAssertEqual(reducer.latest?.kind, .final)
    }

    func testCancelPropagatesToEngine() async throws {
        let engine = FakeASREngine()
        let session = await MainActor.run { LocalCaptionSession(engine: engine) }
        await session.prepare()
        try await session.start()
        await session.cancel()
        let cancelled = await engine.wasCancelled
        XCTAssertTrue(cancelled)
    }

    private func event(_ id: UUID, revision: UInt64, kind: ASREventKind, text: String) -> ASREvent {
        ASREvent(utteranceID: id, revision: revision, kind: kind, text: text, timestamp: Date(timeIntervalSince1970: 1))
    }
}

private actor FakeASREngine: RealtimeASREngine {
    private let stream: AsyncStream<ASREvent>
    private let continuation: AsyncStream<ASREvent>.Continuation
    private(set) var wasCancelled = false

    init() {
        let pair = AsyncStream<ASREvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
        stream = pair.stream
        continuation = pair.continuation
    }

    func prepare() async throws {}
    func start(utteranceID: UUID) async throws {}
    func append(_ frame: PCMFrame) async throws {}
    func finish() async throws -> ASREvent? { nil }
    func cancel() async { wasCancelled = true }
    func eventStream() async -> AsyncStream<ASREvent> { stream }
}
