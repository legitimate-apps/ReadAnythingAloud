import Foundation
import Observation

/// Shared engine instances and the user's voice preferences.
@MainActor
@Observable
public final class VoiceSettings {
    public static let shared = VoiceSettings()

    /// On-device Kokoro. macOS runs FluidAudio's Core ML graph; iOS runs the same model on ONNX Runtime's CPU
    /// provider, because the Core ML graph trips an Apple BNNS bug on iOS 26.4+ (FluidAudio #844/#889).
    #if os(iOS)
    @ObservationIgnored public let kokoro = KokoroOnnxEngine()
    #else
    @ObservationIgnored public let kokoro = KokoroEngine()
    #endif
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
    /// Download progress (0…1) while the natural voice's model is being fetched, when the engine reports it.
    public var kokoroProgress: Double?

    public var hasElevenLabsKey: Bool

    /// Whether on-device Kokoro can run on this platform.
    public static var isKokoroAvailable: Bool { true }

    /// Whether the natural voice's models are already on disk.
    public static var isKokoroDownloaded: Bool {
        #if os(iOS)
        KokoroOnnxEngine.isDownloaded
        #else
        KokoroEngine.isDownloaded
        #endif
    }

    /// First-run download size, for the UI. (iOS fetches the ONNX graph plus FluidAudio's frontend assets.)
    public static var kokoroDownloadSize: String {
        #if os(iOS)
        "about 250 MB"
        #else
        "about 150 MB"
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
        kokoroState = Self.isKokoroDownloaded ? .ready : .notDownloaded
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
            #if os(iOS)
            try await kokoro.prepare { fraction in
                Task { @MainActor [weak self] in self?.kokoroProgress = fraction }
            }
            #else
            try await kokoro.prepare()
            #endif
            kokoroState = .ready
        } catch {
            kokoroState = .failed(error.localizedDescription)
        }
        kokoroProgress = nil
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
