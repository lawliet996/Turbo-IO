import Foundation

/// Adapter boundary between RayNeo PCM/session handling and a concrete ASR engine.
/// Implementations must keep model work off the UI/audio callback thread.
public protocol RealtimeASREngine: Sendable {
    func prepare() async throws
    func start(utteranceID: UUID) async throws
    func append(_ frame: PCMFrame) async throws
    func finish() async throws -> ASREvent?
    func cancel() async
    func eventStream() async -> AsyncStream<ASREvent>
}
