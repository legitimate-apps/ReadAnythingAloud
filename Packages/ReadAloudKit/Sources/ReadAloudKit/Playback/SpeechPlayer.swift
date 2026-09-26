@preconcurrency import AVFoundation
import Foundation

/// Plays a document sentence by sentence through AVAudioEngine and reports the current sentence and word.
///
/// Graph: `AVAudioPlayerNode → AVAudioUnitTimePitch → mainMixer`. Speed is the time-pitch rate, so clips never
/// need re-synthesis and word timings stay in media time: the player node's sample time counts source frames
/// regardless of rate, and each scheduled segment remembers where it starts in that timeline. The highlight is
/// therefore a lookup of (segment, offset) → clip time → word.
@MainActor
public final class SpeechPlayer {
    public enum State: Equatable, Sendable {
        case idle
        case buffering
        case playing
        case paused
        case finished
    }

    public struct Position: Equatable, Sendable {
        public var sentence: Int
        public var word: Int?
        /// Seconds into the sentence clip.
        public var clipTime: Double
    }

    public private(set) var state: State = .idle { didSet { if state != oldValue { onStateChange?(state) } } }
    public private(set) var position: Position?
    public var onStateChange: ((State) -> Void)?
    public var onPosition: ((Position) -> Void)?
    public var onError: ((Int, Error) -> Void)?

    public var rate: Float = 1 {
        didSet { timePitch.rate = rate }
    }

    /// Pauses inserted after a sentence, after the last sentence of a block, and after a heading.
    public var sentencePause: Double = 0.16
    public var blockPause: Double = 0.5
    public var headingPause: Double = 0.65

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let format = CanonicalAudio.format

    private var queue: SynthesisQueue?
    private var document: ReadingDocument?

    private struct Segment {
        var sentence: Int
        var playerStart: AVAudioFramePosition
        var clipStart: Int
        var clipFrames: Int
        var totalFrames: Int
        var timings: [WordTiming]
    }

    private var generation = 0
    private var segments: [Segment] = []
    private var scheduledEnd: AVAudioFramePosition = 0
    private var nextToSchedule = 0
    private var fetching = false
    private var lastSampleTime: AVAudioFramePosition = 0
    private var ticker: Timer?
    private var configObserver: NSObjectProtocol?
    /// Seconds of audio to keep scheduled ahead of the playhead.
    private let scheduleAhead: Double = 6

    public init() {
        engine.attach(node)
        engine.attach(timePitch)
        engine.connect(node, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        timePitch.rate = rate
        engine.prepare()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }
    }

    // `deinit` can't touch main-actor state; the owner calls `stop()` before releasing the player.

    /// Attaches a document's synthesis queue. Stops current playback.
    public func load(_ queue: SynthesisQueue) {
        stop()
        self.queue = queue
        self.document = queue.document
    }

    public var isActive: Bool { state == .playing || state == .buffering }

    /// Starts (or restarts) playback at a sentence, optionally at a word within it.
    public func play(sentence: Int, word: Int? = nil) {
        guard let document, document.sentences.indices.contains(sentence) else { return }
        restart(at: sentence, word: word, autoplay: true)
    }

    /// Moves the playhead; keeps playing if playing, stays paused otherwise.
    public func seek(sentence: Int, word: Int? = nil) {
        guard let document, document.sentences.indices.contains(sentence) else { return }
        let autoplay = isActive
        restart(at: sentence, word: word, autoplay: autoplay)
    }

    public func pause() {
        guard isActive else { return }
        node.pause()
        state = .paused
        stopTicker()
    }

    public func resume() {
        switch state {
        case .paused:
            if segments.isEmpty, let position {
                restart(at: position.sentence, word: position.word, autoplay: true)
                return
            }
            startEngineIfNeeded()
            node.play()
            state = scheduledEnd > lastSampleTime ? .playing : .buffering
            startTicker()
            fillAhead()
        case .idle, .finished:
            play(sentence: position?.sentence ?? 0, word: position?.word)
        default:
            break
        }
    }

    public func stop() {
        generation += 1
        node.stop()
        segments.removeAll()
        scheduledEnd = 0
        fetching = false
        stopTicker()
        if engine.isRunning { engine.pause() }
        state = .idle
    }

    // MARK: - Scheduling

    private func restart(at sentence: Int, word: Int?, autoplay: Bool) {
        generation += 1
        let gen = generation
        node.stop()
        segments.removeAll()
        scheduledEnd = 0
        lastSampleTime = 0
        fetching = false
        nextToSchedule = sentence
        position = Position(sentence: sentence, word: word ?? document?.sentences[sentence].wordIndices.first, clipTime: 0)
        if let position { onPosition?(position) }
        state = autoplay ? .buffering : .paused
        guard let queue else { return }
        fetching = true
        Task {
            await queue.setPlayhead(sentence)
            do {
                let clip = try await queue.clip(for: sentence)
                guard gen == self.generation else { return }
                self.fetching = false
                let offset = self.clipOffset(for: word, in: sentence, clip: clip)
                self.schedule(clip, sentence: sentence, fromFrame: offset)
                if autoplay {
                    self.startEngineIfNeeded()
                    self.node.play()
                    self.state = .playing
                    self.startTicker()
                }
                self.fillAhead()
            } catch {
                guard gen == self.generation else { return }
                self.fetching = false
                self.handleFailure(sentence: sentence, error: error)
            }
        }
    }

    private func clipOffset(for word: Int?, in sentence: Int, clip: SynthesizedClip) -> Int {
        guard let word, let document else { return 0 }
        let local = word - document.sentences[sentence].wordIndices.lowerBound
        guard clip.wordTimings.indices.contains(local), local > 0 else { return 0 }
        // Start a hair before the word so its onset isn't clipped.
        return max(0, Int((clip.wordTimings[local].start - 0.04) * clip.sampleRate))
    }

    private func pauseAfter(sentence: Int) -> Double {
        guard let document else { return sentencePause }
        let s = document.sentences[sentence]
        guard s.endsBlock else { return sentencePause }
        if case .heading = document.blocks[s.blockIndex].kind { return headingPause }
        return blockPause
    }

    private func schedule(_ clip: SynthesizedClip, sentence: Int, fromFrame: Int) {
        let clipFrames = max(0, clip.samples.count - fromFrame)
        let pauseFrames = Int(pauseAfter(sentence: sentence) * format.sampleRate)
        let total = clipFrames + pauseFrames
        guard total > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)) else { return }
        buffer.frameLength = AVAudioFrameCount(total)
        let out = buffer.floatChannelData![0]
        clip.samples.withUnsafeBufferPointer { src in
            if clipFrames > 0 { out.update(from: src.baseAddress! + fromFrame, count: clipFrames) }
        }
        (out + clipFrames).update(repeating: 0, count: pauseFrames)

        // After an underrun the node has kept running in silence, so the new segment starts "now".
        let start = max(scheduledEnd, currentSampleTime(compensatingLatency: false) ?? scheduledEnd)
        segments.append(Segment(sentence: sentence, playerStart: start, clipStart: fromFrame, clipFrames: clipFrames,
                                totalFrames: total, timings: clip.wordTimings))
        scheduledEnd = start + AVAudioFramePosition(total)
        nextToSchedule = sentence + 1
        let gen = generation
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.segmentFinished(sentence: sentence, generation: gen) }
            }
        }
    }

    private func segmentFinished(sentence: Int, generation gen: Int) {
        guard gen == generation else { return }
        guard let document else { return }
        if sentence == document.sentences.count - 1, segments.last?.sentence == sentence {
            state = .finished
            stopTicker()
            node.stop()
            segments.removeAll()
            scheduledEnd = 0
            return
        }
        fillAhead()
    }

    /// Keeps `scheduleAhead` seconds queued, fetching clips as needed.
    private func fillAhead() {
        guard let queue, let document, !fetching, state != .idle, state != .finished else { return }
        guard nextToSchedule < document.sentences.count else { return }
        let now = currentSampleTime() ?? lastSampleTime
        let queuedSeconds = Double(scheduledEnd - now) / format.sampleRate
        guard queuedSeconds < scheduleAhead else { return }
        let index = nextToSchedule
        let gen = generation
        fetching = true
        Task {
            await queue.setPlayhead(max(index - 1, 0))
            do {
                let clip = try await queue.clip(for: index)
                guard gen == self.generation else { return }
                self.fetching = false
                self.schedule(clip, sentence: index, fromFrame: 0)
                if self.state == .buffering {
                    self.state = .playing
                }
                self.fillAhead()
            } catch {
                guard gen == self.generation else { return }
                self.fetching = false
                self.handleFailure(sentence: index, error: error)
            }
        }
    }

    private func handleFailure(sentence: Int, error: Error) {
        if error is CancellationError { return }
        onError?(sentence, error)
        // Skip the sentence that failed so one bad sentence doesn't stall the article.
        if let document, sentence + 1 < document.sentences.count, isActive {
            nextToSchedule = sentence + 1
            if segments.isEmpty {
                restart(at: sentence + 1, word: nil, autoplay: true)
            } else {
                fillAhead()
            }
        } else if segments.isEmpty {
            state = .paused
            stopTicker()
        }
    }

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            onError?(position?.sentence ?? 0, error)
        }
    }

    private func handleConfigurationChange() {
        // Output route or format changed (headphones, AirPlay). The engine stopped; rebuild from the current word.
        guard let position else { return }
        let wasActive = isActive
        engine.stop()
        engine.prepare()
        restart(at: position.sentence, word: position.word, autoplay: wasActive)
    }

    // MARK: - Position tracking

    private func currentSampleTime(compensatingLatency: Bool = true) -> AVAudioFramePosition? {
        guard let nodeTime = node.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else { return nil }
        guard compensatingLatency else { return playerTime.sampleTime }
        // lastRenderTime runs ahead of what's audible by the output latency (scaled by rate, since the
        // player's timeline is in source frames).
        let latency = engine.outputNode.presentationLatency + (engine.outputNode.outputPresentationLatencyGuess)
        let lag = AVAudioFramePosition(latency * format.sampleRate * Double(rate))
        return max(0, playerTime.sampleTime - lag)
    }

    private func startTicker() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 40.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    /// Playhead derived from the audio clock right now (not the last tick); used by `tick` and by tests.
    func livePosition() -> Position? {
        currentSampleTime().flatMap(position(atSampleTime:))
    }

    private func position(atSampleTime t: AVAudioFramePosition) -> Position? {
        guard let segment = segments.last(where: { $0.playerStart <= t }) else { return nil }
        let intoSegment = Int(t - segment.playerStart)
        let clipFrame = segment.clipStart + min(intoSegment, max(segment.clipFrames - 1, 0))
        let clipTime = Double(clipFrame) / format.sampleRate
        var word: Int?
        if let document {
            let range = document.sentences[segment.sentence].wordIndices
            if let local = Self.wordIndex(at: clipTime, in: segment.timings) {
                word = range.lowerBound + local
            } else {
                word = range.first
            }
        }
        return Position(sentence: segment.sentence, word: word, clipTime: clipTime)
    }

    private func tick() {
        guard let t = currentSampleTime() else { return }
        lastSampleTime = t
        if t >= scheduledEnd, state == .playing, let document, nextToSchedule < document.sentences.count {
            state = .buffering
            fillAhead()
        }
        // Drop segments that finished long ago.
        if segments.count > 4 { segments.removeFirst(segments.count - 4) }
        guard let newPosition = position(atSampleTime: t) else { return }
        if newPosition.sentence != position?.sentence || newPosition.word != position?.word {
            position = newPosition
            onPosition?(newPosition)
        } else {
            position = newPosition
        }
        fillAhead()
    }

    /// Index of the last word whose start is at or before `time`.
    nonisolated static func wordIndex(at time: Double, in timings: [WordTiming]) -> Int? {
        guard !timings.isEmpty else { return nil }
        var lo = 0, hi = timings.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if timings[mid].start <= time + 0.001 {
                found = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return found ?? 0
    }
}

private extension AVAudioOutputNode {
    /// Hardware IO buffer duration, a reasonable proxy for the render-ahead not covered by presentationLatency.
    var outputPresentationLatencyGuess: Double {
        #if os(iOS)
        AVAudioSession.sharedInstance().ioBufferDuration
        #else
        0.01
        #endif
    }
}
