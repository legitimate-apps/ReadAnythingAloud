#if os(iOS)
import FluidAudio
import Foundation
import OnnxRuntimeBindings

/// Kokoro-82M v1.0 executed by ONNX Runtime's CPU execution provider.
///
/// Same voices and word-timing path as `KokoroEngine`, but the acoustic graph never touches Core ML, so it avoids the
/// Apple BNNS crash FluidAudio's Core ML chain hits on iOS/iPadOS 26.4+ (FluidAudio #844/#889). FluidAudio still
/// supplies the text frontend: NeMo normalization, the Misaki-lexicon phonemizer, the vocab and the voice packs.
///
/// The graph is `onnx-community/Kokoro-82M-v1.0-ONNX-timestamped` (int8), which outputs the per-token frame
/// durations alongside the waveform, so word timings still come from the model itself.
public actor KokoroOnnxEngine: SpeechEngine {
    public nonisolated let kind: EngineKind = .kokoro
    public nonisolated let modelRevision = "ort-kokoro-v1.0-int8"

    // MARK: - Model asset

    /// Where the ONNX graph is downloaded from on first use: the onnx-community export at a pinned revision (hash-checked).
    public nonisolated static let modelDownloadURL = URL(
        string: "https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX-timestamped/resolve/dd4401a9add81ac692d20e240d22ec9dda82cc29/onnx/model_quantized.onnx")!
    static let modelSHA256 = "c0c02b3299fd97c34ea92a98e6d41eaa1a739c8f77bf685aac34bd7b34c1132c"
    static let modelByteCount: Int64 = 92_361_055
    static let modelFileName = "kokoro-82m-v1.0-timestamped-int8.onnx"
    /// Points at a local model file instead of the download (development and tests).
    public nonisolated static let modelPathEnvironmentKey = "READALOUD_KOKORO_ONNX_MODEL"

    /// Application Support location of the downloaded graph.
    public nonisolated static var installedModelURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Models/kokoro-onnx", isDirectory: true).appendingPathComponent(modelFileName)
    }

    /// The model file this process uses: the environment override when it names an existing file, else the installed copy.
    nonisolated static var resolvedModelURL: URL {
        if let path = ProcessInfo.processInfo.environment[modelPathEnvironmentKey], !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return installedModelURL
    }

    private static let readyKey = "kokoro.onnx.ready"

    /// Whether everything is already on disk (graph plus FluidAudio's frontend assets), so no download is needed.
    public nonisolated static var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: resolvedModelURL.path) && UserDefaults.standard.bool(forKey: readyKey)
    }

    // MARK: - State

    private struct Loaded: Sendable {
        let graph: KokoroOnnxGraph
        let frontend: KokoroAneManager
        let vocab: KokoroAneVocab
        let repoDirectory: URL
    }

    private var loaded: Loaded?
    private var voicePacks: [String: KokoroAneVoicePack] = [:]
    private var initializing: Task<Loaded, Error>?
    private let intraOpThreads: Int

    /// - Parameter intraOpThreads: CPU threads ONNX Runtime may use per synthesis.
    public init(intraOpThreads: Int = KokoroOnnxEngine.defaultIntraOpThreads) {
        self.intraOpThreads = max(1, intraOpThreads)
    }

    /// Leaves headroom for the UI and audio threads.
    public nonisolated static var defaultIntraOpThreads: Int {
        min(4, max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
    }

    /// Downloads (first run) and loads the graph and frontend. Safe to call repeatedly.
    /// - Parameter progress: Download progress of the graph, 0…1 (not called when it is already on disk).
    public func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        _ = try await load(progress: progress)
    }

    public func prepare() async throws {
        try await prepare(progress: nil)
    }

    private func load(progress: (@Sendable (Double) -> Void)? = nil) async throws -> Loaded {
        if let loaded { return loaded }
        if let initializing { return try await initializing.value }
        let threads = intraOpThreads
        let task = Task { () throws -> Loaded in
            let modelURL = Self.resolvedModelURL
            if !FileManager.default.fileExists(atPath: modelURL.path) {
                try await ModelDownloader.fetch(Self.modelDownloadURL, to: modelURL, sha256: Self.modelSHA256,
                                                expectedBytes: Self.modelByteCount, progress: progress)
            }
            // FluidAudio builds its English phonemizer only through the manager, which loads the whole Core ML chain
            // first. Build the phonemizer once (the manager caches it), then release the chain — it is never
            // executed here and holds hundreds of MB — and read the vocab and voice packs from disk directly.
            let store = KokoroAneModelStore(computeUnits: .cpuOnly, variant: .english)
            let frontend = KokoroAneManager(variant: .english, computeUnits: .cpuOnly, modelStore: store)
            try await frontend.initialize()
            _ = try await frontend.phonemes(for: "Hello there.")
            let repoDirectory = try await KokoroAneResourceDownloader.ensureModels(variant: .english)
            let vocab = try KokoroAneVocab.load(from: repoDirectory.appendingPathComponent(ModelNames.KokoroAne.vocab))
            await store.cleanup()
            let graph = try KokoroOnnxGraph(modelPath: modelURL.path, intraOpThreads: threads)
            return Loaded(graph: graph, frontend: frontend, vocab: vocab, repoDirectory: repoDirectory)
        }
        initializing = task
        do {
            let value = try await task.value
            loaded = value
            initializing = nil
            UserDefaults.standard.set(true, forKey: Self.readyKey)
            return value
        } catch {
            initializing = nil
            throw error
        }
    }

    public func voices() async -> [VoiceInfo] { KokoroEngine.catalog }

    // MARK: - Synthesis

    public func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedClip {
        let speakable = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !speakable.isEmpty else {
            return SynthesizedClip(samples: [], sampleRate: Self.sampleRate,
                                   wordTimings: request.wordRanges.map { _ in WordTiming(start: 0, end: 0) },
                                   timingSource: .estimated)
        }
        let loaded = try await load()
        let text = KokoroEngine.prenormalize(request.text)
        // Same frontend as the Core ML engine: `phonemes(for:)` normalizes with NeMo and phonemizes.
        let normalizedText = NemoTextNormalizer.normalize(text, language: .english)
        let phonemes = try await loaded.frontend.phonemes(for: text)
        let inputIds = try loaded.vocab.encode(phonemes)
        let pack = try await voicePack(request.voice.identifier, in: loaded.repoDirectory)
        let style = Self.styleRow(pack, phonemeCount: KokoroAneVocab.phonemeLength(phonemes))

        let output = try await loaded.graph.run(inputIds: inputIds, style: style, speed: request.pace)
        guard !output.samples.isEmpty else { throw SpeechEngineError.emptyAudio }
        let duration = Double(output.samples.count) / Self.sampleRate
        let frames = output.durations.map { Int32(max(0, $0.rounded())) }
        let spoken = KokoroEngine.spokenTokens(inputIds: inputIds, durations: frames, phonemes: phonemes,
                                               normalizedText: normalizedText, duration: duration)
        let timings: [WordTiming]
        let source: TimingSource
        if let spoken, !spoken.isEmpty {
            timings = TimingAligner.align(displayWords: request.words, spoken: spoken, duration: duration)
            source = .engine
        } else {
            timings = TimingAligner.estimate(displayWords: request.words, duration: duration)
            source = .estimated
        }
        return SynthesizedClip(samples: output.samples, sampleRate: Self.sampleRate, wordTimings: timings,
                               timingSource: source)
    }

    static let sampleRate: Double = 24_000

    private func voicePack(_ voice: String, in repoDirectory: URL) async throws -> KokoroAneVoicePack {
        if let cached = voicePacks[voice] { return cached }
        let url = try await KokoroAneResourceDownloader.ensureVoicePack(voice, repoDirectory: repoDirectory)
        let pack = try KokoroAneVoicePack.load(from: url)
        voicePacks[voice] = pack
        return pack
    }

    /// The graph's `style` input: the voice pack's full 256-float row for this phoneme count (timbre half first,
    /// prosody half second — the order of Kokoro's `ref_s`, which is how FluidAudio's `.bin` packs are stored).
    static func styleRow(_ pack: KokoroAneVoicePack, phonemeCount: Int) -> [Float] {
        let cols = KokoroAneConstants.voicePackCols
        let row = max(min(phonemeCount - 1, KokoroAneConstants.voicePackRows - 1), 0)
        return Array(pack.storage[(row * cols)..<((row + 1) * cols)])
    }
}

/// One ONNX Runtime session for the Kokoro graph. ORT sessions are thread-safe for `run`, but runs are serialized
/// on a private queue so a long synthesis blocks neither the actor nor Swift's cooperative thread pool.
final class KokoroOnnxGraph: @unchecked Sendable {
    struct Output: Sendable {
        var samples: [Float]
        /// Predicted frames per input token (25 ms each at speed 1).
        var durations: [Float]
    }

    enum Failure: LocalizedError {
        case missingOutput(String)
        var errorDescription: String? {
            switch self {
            case .missingOutput(let name): "The Kokoro model returned no \(name) output."
            }
        }
    }

    private let env: ORTEnv
    private let session: ORTSession
    private let queue = DispatchQueue(label: "ReadAloudKit.KokoroOnnxGraph", qos: .userInitiated)

    init(modelPath: String, intraOpThreads: Int) throws {
        env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(.all)
        try options.setIntraOpNumThreads(Int32(intraOpThreads))
        // Don't busy-wait between sentences; it costs battery for no throughput on a sentence-at-a-time workload.
        try options.addConfigEntry(withKey: "session.intra_op.allow_spinning", value: "0")
        session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: options)
    }

    func run(inputIds: [Int32], style: [Float], speed: Float) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                continuation.resume(with: Result { try runSync(inputIds: inputIds, style: style, speed: speed) })
            }
        }
    }

    private func runSync(inputIds: [Int32], style: [Float], speed: Float) throws -> Output {
        let ids = inputIds.map(Int64.init)
        let idsValue = try ORTValue(tensorData: NSMutableData(data: ids.withUnsafeBufferPointer { Data(buffer: $0) }),
                                    elementType: .int64, shape: [1, NSNumber(value: ids.count)])
        let styleValue = try ORTValue(tensorData: NSMutableData(data: style.withUnsafeBufferPointer { Data(buffer: $0) }),
                                      elementType: .float, shape: [1, NSNumber(value: style.count)])
        var speedScalar = speed
        let speedValue = try ORTValue(tensorData: NSMutableData(bytes: &speedScalar, length: MemoryLayout<Float>.size),
                                      elementType: .float, shape: [1])
        let outputs = try session.run(withInputs: ["input_ids": idsValue, "style": styleValue, "speed": speedValue],
                                      outputNames: ["waveform", "durations"], runOptions: nil)
        guard let waveform = outputs["waveform"] else { throw Failure.missingOutput("waveform") }
        guard let durations = outputs["durations"] else { throw Failure.missingOutput("durations") }
        return Output(samples: try Self.floats(waveform), durations: try Self.floats(durations))
    }

    private static func floats(_ value: ORTValue) throws -> [Float] {
        let data = try value.tensorData() as Data
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
#endif
