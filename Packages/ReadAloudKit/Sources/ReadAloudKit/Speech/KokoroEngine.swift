import FluidAudio
import Foundation

/// Kokoro-82M on-device via FluidAudio's Core ML chain. Word timings come from the model's own predicted
/// phoneme durations, so no alignment pass is needed.
public actor KokoroEngine: SpeechEngine {
    public nonisolated let kind: EngineKind = .kokoro
    public nonisolated let modelRevision = "fluidaudio-0.17.4-kokoro-ane-v1"

    /// Kokoro's padding token id (BOS/EOS) and the id of the space phoneme in its vocab.
    static let boundaryTokenID: Int32 = 0
    static let spaceTokenID: Int32 = 16

    private var manager: KokoroAneManager?
    private var initializing: Task<KokoroAneManager, Error>?

    public init() {}

    /// Whether the models are already on disk (no download needed to start).
    public nonisolated static var isDownloaded: Bool {
        UserDefaults.standard.bool(forKey: "kokoro.ready")
    }

    /// Downloads (first run) and loads the model chain. Safe to call repeatedly.
    public func prepare() async throws {
        _ = try await loadedManager()
    }

    private func loadedManager() async throws -> KokoroAneManager {
        if let manager { return manager }
        if let initializing { return try await initializing.value }
        let task = Task { () throws -> KokoroAneManager in
            let m = KokoroAneManager(variant: .english)
            try await m.initialize()
            return m
        }
        initializing = task
        do {
            let m = try await task.value
            manager = m
            initializing = nil
            UserDefaults.standard.set(true, forKey: "kokoro.ready")
            return m
        } catch {
            initializing = nil
            throw error
        }
    }

    public func voices() async -> [VoiceInfo] { Self.catalog }

    public nonisolated static let catalog: [VoiceInfo] = englishVoices.map { id, name, detail in
        VoiceInfo(id: VoiceID(engine: .kokoro, identifier: id), name: name,
                  language: id.hasPrefix("b") ? "en-GB" : "en-US", detail: detail)
    }

    public func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedClip {
        let manager = try await loadedManager()
        let speakable = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !speakable.isEmpty else {
            return SynthesizedClip(samples: [], sampleRate: 24_000,
                                   wordTimings: request.wordRanges.map { _ in WordTiming(start: 0, end: 0) },
                                   timingSource: .estimated)
        }
        let result = try await manager.synthesizeDetailed(text: Self.prenormalize(request.text), voice: request.voice.identifier,
                                                          speed: request.pace)
        guard !result.samples.isEmpty else { throw SpeechEngineError.emptyAudio }
        let duration = result.durationSeconds
        let spoken = Self.spokenTokens(inputIds: result.inputIds, durations: result.predictedDurations,
                                       phonemes: result.phonemes, normalizedText: result.normalizedText,
                                       duration: duration)
        let timings: [WordTiming]
        let source: TimingSource
        if let spoken, !spoken.isEmpty {
            timings = TimingAligner.align(displayWords: request.words, spoken: spoken, duration: duration)
            source = .engine
        } else {
            timings = TimingAligner.estimate(displayWords: request.words, duration: duration)
            source = .estimated
        }
        return SynthesizedClip(samples: result.samples, sampleRate: Double(result.sampleRate),
                               wordTimings: timings, timingSource: source)
    }

    /// Symbol fixes the NeMo normalizer gets wrong ("31×" is read as "X").
    static func prenormalize(_ text: String) -> String {
        text.replacingOccurrences(of: "×", with: " times ")
            .replacingOccurrences(of: " & ", with: " and ")
    }

    /// Converts per-token frame durations into timed spoken words.
    ///
    /// Tokens are grouped into words at the space phoneme; each group's span is the sum of its token durations,
    /// with a space's duration split between its neighbours (as Kokoro's reference `join_timestamps` does). The
    /// group texts come from the normalized text when its word count matches the phoneme word count, so the
    /// aligner can match "forty five dollars" against a displayed "$45".
    static func spokenTokens(inputIds: [Int32], durations: [Int32], phonemes: String, normalizedText: String?,
                             duration: Double) -> [SpokenToken]? {
        guard inputIds.count == durations.count, !durations.isEmpty else { return nil }
        let totalFrames = durations.reduce(0) { $0 + Int($1) }
        guard totalFrames > 0 else { return nil }
        let secondsPerFrame = duration / Double(totalFrames)

        struct Group { var start: Double; var end: Double; var tokenCount: Int }
        var groups: [Group] = []
        var current: Group?
        var t = 0.0
        for (id, frames) in zip(inputIds, durations) {
            let span = Double(frames) * secondsPerFrame
            if id == boundaryTokenID || id == spaceTokenID {
                if var g = current {
                    // Give the closing word half of the space; the rest precedes the next word.
                    g.end = t + (id == spaceTokenID ? span / 2 : 0)
                    groups.append(g)
                    current = nil
                }
            } else if current == nil {
                current = Group(start: t, end: t + span, tokenCount: 1)
            } else {
                current!.end = t + span
                current!.tokenCount += 1
            }
            t += span
        }
        if let g = current { groups.append(g) }

        // Drop groups that are only punctuation (pause tokens) so both sides count words the same way.
        let phonemeWords = phonemes.split(whereSeparator: { $0 == " " }).map(String.init)
        let punctuation = CharacterSet.punctuationCharacters.union(.symbols)
        var keptGroups: [Group] = []
        var keptPhonemeWords: [String] = []
        let pairsAligned = phonemeWords.count == groups.count
        for (k, g) in groups.enumerated() {
            if pairsAligned, phonemeWords[k].unicodeScalars.allSatisfy({ punctuation.contains($0) }) { continue }
            keptGroups.append(g)
            if pairsAligned { keptPhonemeWords.append(phonemeWords[k]) }
        }

        // The phonemizer splits hyphenated compounds ("well-known" → two words), so split the same way.
        let normalizedWords = (normalizedText ?? "")
            .split(whereSeparator: { $0.isWhitespace || "-‐‑–—/".contains($0) })
            .map(String.init)
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
        let texts: [String]
        if normalizedWords.count == keptGroups.count {
            texts = normalizedWords
        } else if pairsAligned, !normalizedWords.isEmpty {
            texts = pairByLength(words: normalizedWords, phonemeWords: keptPhonemeWords)
        } else {
            texts = Array(repeating: "", count: keptGroups.count)
        }
        return zip(keptGroups, texts).map { SpokenToken(text: $1, start: $0.start, end: $0.end) }
    }

    /// Fallback when the word counts disagree: monotonically pairs normalized words with phoneme words by length
    /// similarity, leaving unpaired phoneme words with empty text (the aligner then interpolates them).
    static func pairByLength(words: [String], phonemeWords: [String]) -> [String] {
        let n = words.count, m = phonemeWords.count
        let skip = 1.0
        func cost(_ i: Int, _ j: Int) -> Double {
            let a = Double(words[i].count), b = Double(phonemeWords[j].unicodeScalars.filter { $0.properties.isAlphabetic }.count)
            return abs(log(max(a, 1) / max(b, 1)))
        }
        var dp = [[Double]](repeating: [Double](repeating: .infinity, count: m + 1), count: n + 1)
        var back = [[UInt8]](repeating: [UInt8](repeating: 0, count: m + 1), count: n + 1)
        dp[0][0] = 0
        for i in 0...n {
            for j in 0...m where dp[i][j] < .infinity {
                if i < n, j < m, dp[i][j] + cost(i, j) < dp[i + 1][j + 1] { dp[i + 1][j + 1] = dp[i][j] + cost(i, j); back[i + 1][j + 1] = 0 }
                if i < n, dp[i][j] + skip < dp[i + 1][j] { dp[i + 1][j] = dp[i][j] + skip; back[i + 1][j] = 1 }
                if j < m, dp[i][j] + skip < dp[i][j + 1] { dp[i][j + 1] = dp[i][j] + skip; back[i][j + 1] = 2 }
            }
        }
        var out = [String](repeating: "", count: m)
        var i = n, j = m
        while i > 0 || j > 0 {
            switch back[i][j] {
            case 0: out[j - 1] = words[i - 1]; i -= 1; j -= 1
            case 1: i -= 1
            default: j -= 1
            }
        }
        return out
    }

    /// Kokoro v1.0 English voices, best-rated first.
    static let englishVoices: [(String, String, String)] = [
        ("af_heart", "Heart", "American English · female · warm (default)"),
        ("af_bella", "Bella", "American English · female · bright"),
        ("af_nicole", "Nicole", "American English · female · soft"),
        ("af_aoede", "Aoede", "American English · female"),
        ("af_kore", "Kore", "American English · female"),
        ("af_sarah", "Sarah", "American English · female"),
        ("af_nova", "Nova", "American English · female"),
        ("af_sky", "Sky", "American English · female"),
        ("af_alloy", "Alloy", "American English · female"),
        ("af_jessica", "Jessica", "American English · female"),
        ("af_river", "River", "American English · female"),
        ("am_michael", "Michael", "American English · male · warm"),
        ("am_fenrir", "Fenrir", "American English · male · deep"),
        ("am_puck", "Puck", "American English · male · lively"),
        ("am_echo", "Echo", "American English · male"),
        ("am_eric", "Eric", "American English · male"),
        ("am_liam", "Liam", "American English · male"),
        ("am_onyx", "Onyx", "American English · male"),
        ("am_adam", "Adam", "American English · male"),
        ("bf_emma", "Emma", "British English · female"),
        ("bf_isabella", "Isabella", "British English · female"),
        ("bf_alice", "Alice", "British English · female"),
        ("bf_lily", "Lily", "British English · female"),
        ("bm_george", "George", "British English · male"),
        ("bm_fable", "Fable", "British English · male"),
        ("bm_lewis", "Lewis", "British English · male"),
        ("bm_daniel", "Daniel", "British English · male"),
    ]
}
