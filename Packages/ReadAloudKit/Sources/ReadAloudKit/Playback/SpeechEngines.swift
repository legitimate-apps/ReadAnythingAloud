import Foundation
import Observation

/// Shared engine instances and the user's voice preferences.
@MainActor
@Observable
public final class VoiceSettings {
    public static let shared = VoiceSettings()

    @ObservationIgnored public let kokoro = KokoroEngine()
    @ObservationIgnored public let apple = AppleSpeechEngine()
    @ObservationIgnored private var elevenLabsCache: ElevenLabsEngine?

    @ObservationIgnored private let defaults: UserDefaults

    /// The voice chosen for English articles (Kokoro by default) and the fallback for other languages.
    public var preferredVoice: VoiceID {
        didSet { save(preferredVoice, "voice.preferred") }
    }

    public var rate: Float {
        didSet { defaults.set(rate, forKey: "playback.rate") }
    }

    public var elevenLabsModel: String {
        didSet {
            defaults.set(elevenLabsModel, forKey: "elevenlabs.model")
            elevenLabsCache = nil
        }
    }

    /// Kokoro model state for the settings UI.
    public enum ModelState: Equatable {
        case notDownloaded
        case preparing
        case ready
        case failed(String)
    }

    public var kokoroState: ModelState

    public var hasElevenLabsKey: Bool

    /// Whether on-device Kokoro can run on this platform. The Core ML Kokoro graph trips an Apple runtime bug on
    /// iOS 26.4+ (BNNS CPU inference traps; FluidAudio #844/#889, reproduced on an iPad at the first sentence), so
    /// iOS uses Apple voices until the ONNX Runtime executor replaces it there. macOS is unaffected.
    public static var isKokoroAvailable: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// Kokoro's default voice where available, otherwise the best installed Apple voice.
    public static var defaultVoice: VoiceID {
        isKokoroAvailable ? VoiceID(engine: .kokoro, identifier: "af_heart") : VoiceID(engine: .apple, identifier: "")
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved: VoiceID? = defaults.data(forKey: "voice.preferred").flatMap { try? JSONDecoder().decode(VoiceID.self, from: $0) }
        preferredVoice = saved.flatMap { $0.engine == .kokoro && !Self.isKokoroAvailable ? nil : $0 } ?? Self.defaultVoice
        let savedRate = defaults.float(forKey: "playback.rate")
        rate = savedRate == 0 ? 1.0 : savedRate
        elevenLabsModel = defaults.string(forKey: "elevenlabs.model") ?? ElevenLabsEngine.defaultModel
        kokoroState = KokoroEngine.isDownloaded ? .ready : .notDownloaded
        hasElevenLabsKey = !(KeychainStore.string(for: KeychainStore.elevenLabsKey) ?? "").isEmpty
    }

    private func save(_ voice: VoiceID, _ key: String) {
        if let data = try? JSONEncoder().encode(voice) { defaults.set(data, forKey: key) }
    }

    public var elevenLabs: ElevenLabsEngine {
        if let elevenLabsCache, elevenLabsCache.model == elevenLabsModel { return elevenLabsCache }
        let engine = ElevenLabsEngine(model: elevenLabsModel)
        elevenLabsCache = engine
        return engine
    }

    public func engine(for kind: EngineKind) -> any SpeechEngine {
        switch kind {
        case .kokoro: kokoro
        case .apple: apple
        case .elevenLabs: elevenLabs
        }
    }

    public func setElevenLabsKey(_ key: String?) {
        KeychainStore.set(key?.trimmingCharacters(in: .whitespacesAndNewlines), for: KeychainStore.elevenLabsKey)
        hasElevenLabsKey = !(KeychainStore.string(for: KeychainStore.elevenLabsKey) ?? "").isEmpty
        if !hasElevenLabsKey, preferredVoice.engine == .elevenLabs {
            preferredVoice = Self.defaultVoice
        }
    }

    /// Downloads and loads Kokoro. Updates `kokoroState`.
    /// Downloads (first time) and loads the Kokoro models. Concurrent callers share one load and all return once
    /// it finishes, so a play request made during launch warm-up simply waits for it.
    public func prepareKokoro() async {
        guard Self.isKokoroAvailable else {
            kokoroState = .failed("Natural voices aren't available on this device yet.")
            return
        }
        guard kokoroState != .ready else { return }
        kokoroState = .preparing
        do {
            try await kokoro.prepare()
            kokoroState = .ready
        } catch {
            kokoroState = .failed(error.localizedDescription)
        }
    }

    /// The voice to use for a document: the preferred voice when it can speak the language, otherwise the best
    /// Apple voice for that language.
    public func voice(forLanguage language: String?) -> VoiceID {
        let lang = (language ?? "en").lowercased()
        switch preferredVoice.engine {
        case .kokoro where lang.hasPrefix("en") && Self.isKokoroAvailable:
            return preferredVoice
        case .elevenLabs where hasElevenLabsKey:
            return preferredVoice // multilingual models
        case .apple where preferredVoice.identifier.isEmpty || lang.hasPrefix(String(appleVoiceLanguage(preferredVoice).prefix(2))):
            return preferredVoice
        default:
            let best = AppleSpeechEngine.bestVoice(for: language)
            return VoiceID(engine: .apple, identifier: best?.identifier ?? "")
        }
    }

    private func appleVoiceLanguage(_ voice: VoiceID) -> String {
        AppleSpeechEngine.voiceLanguage(identifier: voice.identifier) ?? "en"
    }
}
