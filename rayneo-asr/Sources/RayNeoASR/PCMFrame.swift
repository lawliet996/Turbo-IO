import Foundation

public enum PCMSampleFormat: String, Sendable, Equatable {
    case int16
}

public struct PCMFrame: Sendable, Equatable {
    public let samples: [Int16]
    public let sampleRate: Int
    public let channelCount: Int
    public let sampleFormat: PCMSampleFormat
    public let interleaved: Bool
    public let sequence: UInt64
    public let sampleOffset: UInt64
    public let timestamp: TimeInterval

    public init(
        samples: [Int16], sampleRate: Int, channelCount: Int = 1,
        sampleFormat: PCMSampleFormat = .int16, interleaved: Bool = true,
        sequence: UInt64, sampleOffset: UInt64, timestamp: TimeInterval
    ) throws {
        guard sampleRate > 0, channelCount > 0, !samples.isEmpty,
              samples.count % channelCount == 0, timestamp.isFinite else {
            throw PCMFrameError.invalidFormat
        }
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.sampleFormat = sampleFormat
        self.interleaved = interleaved
        self.sequence = sequence
        self.sampleOffset = sampleOffset
        self.timestamp = timestamp
    }

    public var frameCount: Int { samples.count / channelCount }
    public var duration: TimeInterval { Double(frameCount) / Double(sampleRate) }
}

public enum PCMFrameError: Error, Sendable, Equatable {
    case invalidFormat
    case unsupportedFormat
}
