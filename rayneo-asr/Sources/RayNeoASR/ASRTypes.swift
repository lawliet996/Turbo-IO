import Foundation

public enum ASREventKind: Sendable, Equatable {
    case partial
    case final
}

public struct ASREvent: Sendable, Equatable, Identifiable {
    public let utteranceID: UUID
    public let revision: UInt64
    public let kind: ASREventKind
    public let text: String
    public let languageCode: String?
    public let timestamp: Date

    public var id: String { "\(utteranceID.uuidString):\(revision)" }

    public init(utteranceID: UUID, revision: UInt64, kind: ASREventKind,
                text: String, languageCode: String? = nil, timestamp: Date = Date()) {
        self.utteranceID = utteranceID
        self.revision = revision
        self.kind = kind
        self.text = text
        self.languageCode = languageCode
        self.timestamp = timestamp
    }
}

public enum ASREngineState: Sendable, Equatable {
    case idle
    case preparing
    case ready
    case loadingModel(progress: Double?)
    case listening
    case finishing
    case failed(String)
}

/// Pure event reducer used by the UI/wire bridge. A final event is always accepted,
/// even when partial events are coalesced or throttled by a downstream consumer.
public struct SubtitleEventReducer: Sendable {
    public private(set) var latest: ASREvent?

    public init() {}

    @discardableResult
    public mutating func reduce(_ event: ASREvent) -> ASREvent? {
        guard let current = latest else { latest = event; return event }
        guard current.utteranceID == event.utteranceID else {
            latest = event
            return event
        }
        guard event.revision > current.revision else { return nil }
        if current.kind == .final && event.kind == .partial { return nil }
        latest = event
        return event
    }
}
