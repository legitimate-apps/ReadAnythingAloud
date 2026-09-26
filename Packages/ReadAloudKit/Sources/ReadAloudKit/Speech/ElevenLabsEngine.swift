import Foundation
import Security

/// ElevenLabs cloud voices (bring your own API key). Uses the `with-timestamps` endpoint, whose character-level
/// alignment gives exact word starts; audio is requested as raw 24 kHz PCM so no decoding is needed.
public final class ElevenLabsEngine: SpeechEngine, @unchecked Sendable {
    public let kind: EngineKind = .elevenLabs
    public var modelRevision: String { "elevenlabs-\(model)" }

    public static let defaultModel = "eleven_flash_v2_5"
    public static let models: [(id: String, name: String)] = [
        ("eleven_flash_v2_5", "Flash v2.5 · fastest, half price"),
        ("eleven_multilingual_v2", "Multilingual v2 · most stable long-form"),
        ("eleven_v3", "v3 · most expressive"),
    ]

    private let session: URLSession
    private let keyProvider: @Sendable () -> String?
    public let model: String

    public init(model: String = ElevenLabsEngine.defaultModel, session: URLSession = .shared,
                keyProvider: @escaping @Sendable () -> String? = { KeychainStore.string(for: KeychainStore.elevenLabsKey) }) {
        self.model = model
        self.session = session
        self.keyProvider = keyProvider
    }

    public var hasKey: Bool { !(keyProvider() ?? "").isEmpty }

    public func voices() async -> [VoiceInfo] {
        (try? await fetchVoices()) ?? []
    }

    public func fetchVoices() async throws -> [VoiceInfo] {
        guard let key = keyProvider(), !key.isEmpty else { throw SpeechEngineError.missingAPIKey }
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/voices")!)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data)
        struct VoicesResponse: Decodable {
            struct Voice: Decodable {
                var voice_id: String
                var name: String
                var category: String?
                var labels: [String: String]?
            }
            var voices: [Voice]
        }
        let decoded = try JSONDecoder().decode(VoicesResponse.self, from: data)
        return decoded.voices.map { v in
            let detail = [v.labels?["accent"], v.labels?["gender"], v.labels?["description"] ?? v.labels?["descriptive"], v.category]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return VoiceInfo(id: VoiceID(engine: .elevenLabs, identifier: v.voice_id), name: v.name, language: "multi",
                             detail: detail.isEmpty ? nil : detail)
        }
    }

    public func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedClip {
        guard let key = keyProvider(), !key.isEmpty else { throw SpeechEngineError.missingAPIKey }
        var components = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(request.voice.identifier)/with-timestamps")!
        components.queryItems = [URLQueryItem(name: "output_format", value: "pcm_24000")]
        var http = URLRequest(url: components.url!)
        http.httpMethod = "POST"
        http.timeoutInterval = 60
        http.setValue(key, forHTTPHeaderField: "xi-api-key")
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["text": request.text, "model_id": model]
        if request.pace != 1 {
            body["voice_settings"] = ["speed": min(1.2, max(0.7, Double(request.pace)))]
        }
        http.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: http)
        try Self.check(response, data)
        return try Self.decodeClip(data, request: request)
    }

    struct TimestampResponse: Decodable {
        struct Alignment: Decodable {
            var characters: [String]
            var character_start_times_seconds: [Double]
            var character_end_times_seconds: [Double]
        }
        var audio_base64: String
        var alignment: Alignment?
        var normalized_alignment: Alignment?
    }

    static func decodeClip(_ data: Data, request: SynthesisRequest) throws -> SynthesizedClip {
        let decoded = try JSONDecoder().decode(TimestampResponse.self, from: data)
        guard let audio = Data(base64Encoded: decoded.audio_base64), audio.count >= 2 else {
            throw SpeechEngineError.emptyAudio
        }
        let samples: [Float] = audio.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 }
        }
        let duration = Double(samples.count) / 24_000
        let timings: [WordTiming]
        if let alignment = decoded.alignment {
            timings = wordTimings(alignment: alignment, request: request, duration: duration)
        } else {
            timings = TimingAligner.estimate(displayWords: request.words, duration: duration)
        }
        return SynthesizedClip(samples: samples, sampleRate: 24_000, wordTimings: timings,
                               timingSource: decoded.alignment == nil ? .estimated : .engine)
    }

    /// Maps character timings onto the request's word ranges. The alignment echoes the input text character by
    /// character, so walk it accumulating UTF-16 offsets; if it doesn't match the input, fall back to grouping
    /// the characters into words and running the general aligner.
    static func wordTimings(alignment: TimestampResponse.Alignment, request: SynthesisRequest, duration: Double) -> [WordTiming] {
        let chars = alignment.characters
        let starts = alignment.character_start_times_seconds
        let ends = alignment.character_end_times_seconds
        guard chars.count == starts.count, chars.count == ends.count else {
            return TimingAligner.estimate(displayWords: request.words, duration: duration)
        }
        if chars.joined() == request.text {
            var startAt: [Int: Double] = [:]
            var endAt: [Int: Double] = [:]
            var offset = 0
            for (i, c) in chars.enumerated() {
                let len = c.utf16.count
                for k in 0..<max(len, 1) {
                    startAt[offset + k] = starts[i]
                    endAt[offset + k] = ends[i]
                }
                offset += len
            }
            let raw = request.wordRanges.map { r in
                WordTiming(start: startAt[r.location] ?? 0, end: endAt[r.upperBound - 1] ?? startAt[r.location] ?? 0)
            }
            return TimingAligner.monotonic(raw, duration: duration)
        }
        var spoken: [SpokenToken] = []
        var current = ""
        var start = 0.0, end = 0.0
        for (i, c) in chars.enumerated() {
            if c.allSatisfy(\.isWhitespace) {
                if !current.isEmpty { spoken.append(SpokenToken(text: current, start: start, end: end)) }
                current = ""
            } else {
                if current.isEmpty { start = starts[i] }
                current += c
                end = ends[i]
            }
        }
        if !current.isEmpty { spoken.append(SpokenToken(text: current, start: start, end: end)) }
        return TimingAligner.align(displayWords: request.words, spoken: spoken, duration: duration)
    }

    static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            struct ErrorBody: Decodable {
                struct Detail: Decodable { var message: String?; var status: String? }
                var detail: Detail?
            }
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.detail?.message
                ?? String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw SpeechEngineError.http(status: http.statusCode, message: message)
        }
    }
}

/// Minimal Keychain wrapper for the user's own API keys.
public enum KeychainStore {
    public static let elevenLabsKey = "elevenlabs.api-key"
    static let service = "com.legitimateapps.readanythingaloud"

    public static func string(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func set(_ value: String?, for account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
