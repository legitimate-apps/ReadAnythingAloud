import Foundation

/// Produces sentence clips for one document and voice: cache first, then the engine, rendering ahead of the
/// playhead in order. Concurrent requests for the same sentence share one synthesis.
public actor SynthesisQueue {
    public nonisolated let document: ReadingDocument
    public nonisolated let voice: VoiceID
    public nonisolated let pace: Float
    private let engine: any SpeechEngine
    private let cache: ClipCache
    private let lookahead: Int

    private var clips: [Int: SynthesizedClip] = [:]
    private var inFlight: [Int: Task<SynthesizedClip, Error>] = [:]
    private var failures: [Int: Error] = [:]
    private var isCancelled = false
    private var playhead = 0
    private var worker: Task<Void, Never>?
    /// Called (off the main actor) whenever a sentence clip becomes available, with its duration.
    private var onClip: (@Sendable (Int, Double) -> Void)?

    public init(document: ReadingDocument, engine: any SpeechEngine, voice: VoiceID, pace: Float = 1,
                cache: ClipCache = .shared, lookahead: Int) {
        self.document = document
        self.engine = engine
        self.voice = voice
        self.pace = pace
        self.cache = cache
        self.lookahead = lookahead
    }

    public func setClipObserver(_ observer: @escaping @Sendable (Int, Double) -> Void) {
        guard !isCancelled else { return }
        onClip = observer
    }

    /// The clip for a sentence, synthesizing it now if needed.
    public func clip(for index: Int) async throws -> SynthesizedClip {
        try checkCancellation()
        if let clip = clips[index] { return clip }
        if let task = inFlight[index] {
            let clip = try await task.value
            try checkCancellation()
            return clip
        }
        let task = Task { try await self.produce(index) }
        inFlight[index] = task
        do {
            let clip = try await task.value
            try checkCancellation()
            inFlight[index] = nil
            return clip
        } catch {
            inFlight[index] = nil
            throw error
        }
    }

    /// Returns a clip only if it's already in memory.
    public func readyClip(for index: Int) -> SynthesizedClip? { clips[index] }

    /// Moves the render-ahead window to start at `index` and (re)starts the background worker.
    public func setPlayhead(_ index: Int) {
        guard !isCancelled else { return }
        playhead = index
        for key in failures.keys where key >= index { failures[key] = nil }
        // Free memory far behind the playhead; it stays on disk.
        for key in clips.keys where key < index - 3 || key > index + lookahead + 3 { clips[key] = nil }
        if worker == nil { startWorker() }
    }

    /// Discards this queue permanently. A new document or voice must use a new queue.
    public func cancel() {
        isCancelled = true
        worker?.cancel()
        worker = nil
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        clips.removeAll()
        failures.removeAll()
        onClip = nil
    }

    private func startWorker() {
        worker = Task { [weak self] in
            await self?.workLoop()
        }
    }

    private func workLoop() async {
        defer { worker = nil }
        while !Task.isCancelled {
            guard let next = nextNeeded() else { return }
            do {
                _ = try await clip(for: next)
            } catch is CancellationError {
                return
            } catch {
                failures[next] = error
            }
        }
    }

    private func nextNeeded() -> Int? {
        let end = min(document.sentences.count, playhead + lookahead)
        guard playhead < end else { return nil }
        return (playhead..<end).first { clips[$0] == nil && failures[$0] == nil && inFlight[$0] == nil }
    }

    private func checkCancellation() throws {
        guard !isCancelled else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func produce(_ index: Int) async throws -> SynthesizedClip {
        try checkCancellation()
        let sentence = document.sentences[index]
        let key = ClipCache.key(text: sentence.speechText, voice: voice, modelRevision: engine.modelRevision, pace: pace)
        let cached = await cache.clip(for: key)
        try checkCancellation()
        if let cached, cached.wordTimings.count == sentence.wordIndices.count {
            store(cached, at: index)
            return cached
        }
        let request = SynthesisRequest(text: sentence.speechText, wordRanges: document.localWordRanges(ofSentence: index),
                                       voice: voice, pace: pace, language: document.language)
        var clip = try await engine.synthesize(request)
        try checkCancellation()
        clip = CanonicalAudio.canonicalize(clip)
        clip = Self.trimSilence(clip)
        await cache.store(clip, for: key)
        try checkCancellation()
        store(clip, at: index)
        return clip
    }

    private func store(_ clip: SynthesizedClip, at index: Int) {
        clips[index] = clip
        failures[index] = nil
        onClip?(index, clip.duration)
    }

    /// Engines pad sentences with uneven leading and trailing silence; the player inserts its own consistent
    /// pauses, so cut anything quieter than about -50 dBFS outside the speech (keeping short margins) and shift
    /// the word timings to match.
    static func trimSilence(_ clip: SynthesizedClip) -> SynthesizedClip {
        let samples = clip.samples
        let rate = clip.sampleRate
        let threshold: Float = 0.0032
        guard let first = samples.firstIndex(where: { abs($0) >= threshold }),
              let last = samples.lastIndex(where: { abs($0) >= threshold }) else { return clip }
        let firstWordStart = clip.wordTimings.first.map { Int($0.start * rate) } ?? first
        let lead = max(0, min(first, firstWordStart) - Int(0.03 * rate))
        let lastWordEnd = clip.wordTimings.last.map { Int($0.end * rate) } ?? last
        let end = min(samples.count, max(last, min(lastWordEnd, samples.count)) + Int(0.05 * rate))
        guard lead < end else { return clip }
        var out = clip
        out.samples = Array(samples[lead..<end])
        let shift = Double(lead) / rate
        let duration = out.duration
        out.wordTimings = clip.wordTimings.map {
            WordTiming(start: min(max(0, $0.start - shift), duration), end: min(max(0, $0.end - shift), duration))
        }
        return out
    }
}
