import Foundation
import Observation

/// Everything the reader screen needs for one open article: the document, playback state, the highlighted
/// sentence and word, time estimates, and the controls.
@MainActor
@Observable
public final class ReadingSession {
    public let article: Article
    public let document: ReadingDocument

    public private(set) var voice: VoiceID
    public private(set) var state: SpeechPlayer.State = .idle
    /// Sentence and word under the playhead (highlighted).
    public private(set) var sentence: Int = 0
    public private(set) var word: Int?
    public private(set) var errorMessage: String?
    /// Non-nil while a voice model is downloading or loading.
    public private(set) var preparingMessage: String?
    /// Bumped whenever the playhead jumps (seek/skip) so the view can scroll even if follow mode is off.
    public private(set) var jumpCounter = 0

    /// Playback speed, clamped to 0.5–3.5×. (Computed over `playbackRate` because re-assigning an `@Observable`
    /// property inside its own `didSet` re-enters the observation setter and recurses until the stack overflows.)
    public var rate: Float {
        get { playbackRate }
        set {
            guard newValue.isFinite else { return }
            let clamped = min(max(newValue, 0.5), 3.5)
            playbackRate = clamped
            player.rate = clamped
            settings.rate = clamped
            nowPlaying.update(from: self)
        }
    }
    private var playbackRate: Float
    /// Observable media time; SpeechPlayer itself deliberately does not participate in Observation.
    private var clipTime: Double = 0
    @ObservationIgnored private var queueGeneration = 0
    @ObservationIgnored private var isClosed = false

    @ObservationIgnored private let player = SpeechPlayer()
    @ObservationIgnored private var queue: SynthesisQueue?
    @ObservationIgnored private let library: LibraryStore?
    @ObservationIgnored private let settings: VoiceSettings
    @ObservationIgnored private let nowPlaying = NowPlayingController()
    @ObservationIgnored private var lastSaveTime = Date.distantPast
    @ObservationIgnored private var voiceTask: Task<Void, Never>?
    /// Replaces the settings' engine (tests).
    @ObservationIgnored private let engineOverride: (any SpeechEngine)?

    /// Media-time duration of each synthesized sentence clip, including its trailing pause.
    private var durations: [Double?]
    private var secondsPerUnit = 0.062

    public convenience init(article: Article, library: LibraryStore?, settings: VoiceSettings = .shared) {
        self.init(article: article, library: library, settings: settings, engine: nil)
    }

    init(article: Article, library: LibraryStore?, settings: VoiceSettings, engine: (any SpeechEngine)?) {
        self.engineOverride = engine
        self.article = article
        self.document = DocumentBuilder.build(article)
        self.library = library
        self.settings = settings
        self.playbackRate = settings.rate.isFinite ? min(max(settings.rate, 0.5), 3.5) : 1
        self.voice = settings.voice(forLanguage: document.language)
        self.durations = Array(repeating: nil, count: document.sentences.count)

        if let progress = library?.item(article.id)?.progress, document.sentences.indices.contains(progress.sentence),
           progress.fraction < 1 {
            sentence = progress.sentence
            let words = document.sentences[progress.sentence].wordIndices
            word = progress.word.flatMap { words.contains($0) ? $0 : nil } ?? words.first
        } else {
            word = document.sentences.first?.wordIndices.first
        }

        player.rate = rate
        player.onStateChange = { [weak self] state in self?.playerStateChanged(state) }
        player.onPosition = { [weak self] position in self?.playerMoved(position) }
        player.onError = { [weak self] sentence, error in
            self?.errorMessage = "Couldn't read sentence \(sentence + 1): \(error.localizedDescription) Press Play to retry or choose another voice."
        }
        nowPlaying.attach(self)
        rebuildQueue()
        if (library?.item(article.id)?.progress?.fraction ?? 0) >= 1 {
            state = .finished
            nowPlaying.update(from: self)
        }
    }

    // MARK: - Derived timing

    private func estimatedDuration(_ index: Int) -> Double {
        (durations[index] ?? Double(document.sentences[index].range.length) * secondsPerUnit)
            + player.pauseAfter(sentence: index)
    }

    /// Estimated total listening time at 1×.
    public var totalDuration: Double {
        document.sentences.indices.reduce(0) { $0 + estimatedDuration($1) }
    }

    /// Estimated media time at the playhead (1×).
    public var elapsed: Double {
        guard !document.sentences.isEmpty else { return 0 }
        if state == .finished { return totalDuration }
        let before = (0..<min(sentence, document.sentences.count)).reduce(0) { $0 + estimatedDuration($1) }
        if let word, document.words.indices.contains(word), clipTime == 0 {
            let s = document.sentences[sentence]
            let offset = document.words[word].range.location - s.range.location
            let duration = durations[sentence] ?? Double(s.range.length) * secondsPerUnit
            return before + duration * Double(max(0, offset)) / Double(max(1, s.range.length))
        }
        return before + clipTime
    }

    public var fraction: Double {
        let total = totalDuration
        return total > 0 ? min(1, elapsed / total) : 0
    }

    /// Wall-clock time left at the current speed.
    public var remaining: Double { max(0, totalDuration - elapsed) / Double(rate) }

    public var isPlaying: Bool { state == .playing || state == .buffering }

    public var currentSentenceRange: TextSpan? {
        document.sentences.indices.contains(sentence) ? document.sentences[sentence].range : nil
    }

    public var currentWordRange: TextSpan? {
        guard let word, document.words.indices.contains(word) else { return nil }
        return document.words[word].range
    }

    // MARK: - Controls

    public func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    public func play() {
        guard !isClosed, !isPlaying, !document.sentences.isEmpty else { return }
        errorMessage = nil
        switch state {
        case .paused where player.position != nil:
            player.resume()
        case .finished:
            start(sentence: 0, word: nil)
        default:
            start(sentence: sentence, word: word)
        }
    }

    public func pause() {
        if preparingMessage != nil {
            // Pausing while the voice loads cancels the pending start; the load itself carries on.
            voiceTask?.cancel()
            voiceTask = nil
            preparingMessage = nil
            state = .idle
        }
        player.pause()
        saveProgress(force: true)
    }

    public func skipSentence(_ delta: Int) {
        guard !document.sentences.isEmpty else { return }
        var target = sentence + delta
        // "Back" first restarts the current sentence when we're well into it.
        if delta < 0, let clipTime = player.position?.clipTime, clipTime > 1.2, player.position?.sentence == sentence {
            target = sentence
        }
        jump(sentence: min(max(target, 0), document.sentences.count - 1), word: nil)
    }

    public func skipBlock(_ delta: Int) {
        guard !document.sentences.isEmpty else { return }
        let target = delta > 0
            ? document.nextBlockSentence(after: sentence) ?? document.sentences.count - 1
            : document.previousBlockSentence(before: sentence)
        jump(sentence: target, word: nil)
    }

    /// Jumps by roughly `seconds` of media time (for remote skip commands).
    public func skip(seconds: Double) {
        let target = max(0, min(totalDuration, elapsed + seconds))
        seek(fraction: totalDuration > 0 ? target / totalDuration : 0)
    }

    /// Tap on a word: moves the playhead there. Playback keeps going if it was playing and stays paused (or
    /// stopped) otherwise; the next play starts from the tapped word.
    public func select(word index: Int) {
        guard document.words.indices.contains(index) else { return }
        errorMessage = nil
        jump(sentence: document.words[index].sentenceIndex, word: index)
    }

    public func jump(sentence target: Int, word targetWord: Int?) {
        guard document.sentences.indices.contains(target) else { return }
        sentence = target
        clipTime = 0
        word = targetWord ?? document.sentences[target].wordIndices.first
        jumpCounter += 1
        if preparingMessage != nil {
            // Still waiting for the voice to load: start from the new spot once it's ready.
            start(sentence: target, word: targetWord)
        } else if state != .idle {
            player.seek(sentence: target, word: targetWord)
        }
        saveProgress(force: true)
        nowPlaying.update(from: self)
    }

    /// Scrubber: moves to the sentence at an estimated fraction of the article.
    public func seek(fraction: Double) {
        guard !document.sentences.isEmpty else { return }
        let target = max(0, min(1, fraction)) * totalDuration
        var acc = 0.0
        for i in document.sentences.indices {
            let d = estimatedDuration(i)
            if acc + d > target {
                jump(sentence: i, word: nil)
                return
            }
            acc += d
        }
        jump(sentence: document.sentences.count - 1, word: nil)
    }

    /// Previews the sentence a scrub fraction lands on (for the scrubber label).
    public func sentenceIndex(atFraction fraction: Double) -> Int {
        let target = max(0, min(1, fraction)) * totalDuration
        var acc = 0.0
        for i in document.sentences.indices {
            acc += estimatedDuration(i)
            if acc > target { return i }
        }
        return max(0, document.sentences.count - 1)
    }

    public func setVoice(_ newVoice: VoiceID) {
        guard newVoice != voice else { return }
        let wasPlaying = isPlaying
        voiceTask?.cancel()
        voiceTask = nil
        preparingMessage = nil
        errorMessage = nil
        clipTime = 0
        voice = newVoice
        settings.preferredVoice = newVoice
        durations = Array(repeating: nil, count: document.sentences.count)
        rebuildQueue()
        if wasPlaying { start(sentence: sentence, word: word) }
    }

    /// Stops playback and saves progress. Call when the reader closes.
    public func close() {
        guard !isClosed else { return }
        saveProgress(force: true)
        isClosed = true
        queueGeneration += 1
        voiceTask?.cancel()
        voiceTask = nil
        preparingMessage = nil
        player.stop()
        Task { [queue] in await queue?.cancel() }
        nowPlaying.detach(self)
    }

    // MARK: - Internals

    private func rebuildQueue() {
        queueGeneration += 1
        let generation = queueGeneration
        let old = queue
        Task { await old?.cancel() }
        #if os(macOS)
        let lookahead = 400
        #else
        let lookahead = 60
        #endif
        let q = SynthesisQueue(document: document, engine: engineOverride ?? settings.engine(for: voice.engine), voice: voice,
                               pace: 1, lookahead: lookahead)
        Task { [weak self] in
            await q.setClipObserver { index, duration in
                Task { @MainActor in
                    guard let self, self.queueGeneration == generation, !self.isClosed else { return }
                    self.clipReady(index, duration: duration)
                }
            }
        }
        queue = q
        player.load(q)
    }

    private func clipReady(_ index: Int, duration: Double) {
        guard durations.indices.contains(index) else { return }
        durations[index] = duration
        let known = durations.indices.compactMap { i in durations[i].map { ($0, document.sentences[i].range.length) } }
        let seconds = known.reduce(0) { $0 + $1.0 }
        let units = known.reduce(0) { $0 + $1.1 }
        if units > 200 { secondsPerUnit = seconds / Double(units) }
    }

    private func start(sentence target: Int, word targetWord: Int?) {
        voiceTask?.cancel()
        voiceTask = nil
        preparingMessage = nil
        if voice.engine == .kokoro, settings.kokoroState != .ready {
            preparingMessage = VoiceSettings.isKokoroDownloaded
                ? "Loading the natural voice…"
                : "Downloading the natural voice (\(VoiceSettings.kokoroDownloadSize), first time only)…"
            state = .buffering
            voiceTask = Task {
                await settings.prepareKokoro()
                guard !Task.isCancelled else { return }
                preparingMessage = nil
                if case .failed(let message) = settings.kokoroState {
                    errorMessage = "The natural voice couldn't be prepared (\(message)). Using an Apple voice instead."
                    voice = VoiceID(engine: .apple, identifier: AppleSpeechEngine.bestVoice(for: document.language)?.identifier ?? "")
                    rebuildQueue()
                }
                player.play(sentence: target, word: targetWord)
            }
            return
        }
        if voice.engine == .elevenLabs, !settings.hasElevenLabsKey {
            errorMessage = SpeechEngineError.missingAPIKey.localizedDescription
            return
        }
        player.play(sentence: target, word: targetWord)
    }

    private func playerStateChanged(_ newState: SpeechPlayer.State) {
        state = newState
        if newState == .finished {
            saveProgress(force: true, finished: true)
        }
        nowPlaying.update(from: self)
    }

    private func playerMoved(_ position: SpeechPlayer.Position) {
        let changedSentence = position.sentence != sentence
        sentence = position.sentence
        word = position.word
        clipTime = position.clipTime
        saveProgress(force: false)
        if changedSentence { nowPlaying.update(from: self) }
    }

    private func saveProgress(force: Bool, finished: Bool = false) {
        guard let library, !isClosed else { return }
        let finished = finished || state == .finished
        let now = Date()
        guard force || now.timeIntervalSince(lastSaveTime) > 4 else { return }
        lastSaveTime = now
        library.updateProgress(article.id, ReadingProgress(sentence: finished ? 0 : sentence,
                                                           word: finished ? nil : word,
                                                           fraction: finished ? 1 : fraction))
    }
}
