import Foundation

/// Identifies a voice within an engine.
public struct VoiceID: Codable, Sendable, Hashable, CustomStringConvertible {
    public var engine: EngineKind
    public var identifier: String

    public init(engine: EngineKind, identifier: String) {
        self.engine = engine
        self.identifier = identifier
    }

    public var description: String { "\(engine.rawValue):\(identifier)" }
}

public enum EngineKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case kokoro
    case apple
    case elevenLabs

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .kokoro: "Kokoro (on-device neural)"
        case .apple: "Apple voices"
        case .elevenLabs: "ElevenLabs (cloud)"
        }
    }
}

/// A voice an engine can speak with.
public struct VoiceInfo: Sendable, Hashable, Identifiable {
    public var id: VoiceID
    public var name: String
    public var language: String
    public var detail: String?

    public init(id: VoiceID, name: String, language: String, detail: String? = nil) {
        self.id = id
        self.name = name
        self.language = language
        self.detail = detail
    }
}

/// One sentence to synthesize.
public struct SynthesisRequest: Sendable, Hashable {
    /// Text to speak. Local word ranges index into it (UTF-16).
    public var text: String
    public var wordRanges: [TextRange]
    public var voice: VoiceID
    /// Engine-side pacing (1.0 = natural). Playback speed is applied separately by time-stretching.
    public var pace: Float
    public var language: String?

    public init(text: String, wordRanges: [TextRange], voice: VoiceID, pace: Float = 1.0, language: String? = nil) {
        self.text = text
        self.wordRanges = wordRanges
        self.voice = voice
        self.pace = pace
        self.language = language
    }

    public var words: [String] {
        let ns = text as NSString
        return wordRanges.map { ns.substring(with: $0.ns) }
    }
}

/// Start/end of a word within a clip, in seconds of media time.
public struct WordTiming: Codable, Sendable, Hashable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}

/// Where a clip's word timings came from.
public enum TimingSource: String, Codable, Sendable {
    /// The engine reported them (Kokoro durations, Apple range callbacks, ElevenLabs alignment).
    case engine
    /// Parakeet word timestamps aligned to the known text.
    case asr
    /// Proportional estimate (last resort).
    case estimated
}

/// Synthesized audio for one sentence: mono Float32 PCM plus one timing per requested word.
public struct SynthesizedClip: Sendable {
    public var samples: [Float]
    public var sampleRate: Double
    public var wordTimings: [WordTiming]
    public var timingSource: TimingSource

    public init(samples: [Float], sampleRate: Double, wordTimings: [WordTiming], timingSource: TimingSource) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.wordTimings = wordTimings
        self.timingSource = timingSource
    }

    public var duration: Double { Double(samples.count) / sampleRate }
}

public enum SpeechEngineError: LocalizedError, Sendable {
    case notReady(String)
    case voiceUnavailable(String)
    case missingAPIKey
    case http(status: Int, message: String)
    case emptyAudio
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .notReady(let why): "The voice isn't ready: \(why)"
        case .voiceUnavailable(let v): "The voice \(v) isn't available on this device."
        case .missingAPIKey: "Add your ElevenLabs API key in Settings to use ElevenLabs voices."
        case .http(let status, let message): "The speech service returned \(status): \(message)"
        case .emptyAudio: "The voice produced no audio for this sentence."
        case .underlying(let message): message
        }
    }
}

/// A text-to-speech engine. Implementations are sentence-granular and must return one `WordTiming` per
/// entry in `request.wordRanges`.
public protocol SpeechEngine: Sendable {
    var kind: EngineKind { get }
    /// Stable identifier for the model revision; part of the audio cache key.
    var modelRevision: String { get }
    func voices() async -> [VoiceInfo]
    func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedClip
}
