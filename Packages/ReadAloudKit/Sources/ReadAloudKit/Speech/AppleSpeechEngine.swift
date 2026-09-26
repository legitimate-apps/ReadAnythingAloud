@preconcurrency import AVFoundation
import Foundation

/// Apple's system voices. Sentences are rendered offline with `AVSpeechSynthesizer.write`; the delegate's
/// `willSpeakRange` callbacks, which fire interleaved with the rendered buffers, are stamped with the running
/// frame count to give each word its start time.
public final class AppleSpeechEngine: SpeechEngine, @unchecked Sendable {
    public let kind: EngineKind = .apple
    public let modelRevision = "avspeech-1"

    /// AVSpeechSynthesizer is not reentrant for concurrent `write` calls; serialize them.
    private let gate = AsyncGate()

    public init() {}

    public func voices() async -> [VoiceInfo] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { lhs, rhs in
                if lhs.quality != rhs.quality { return lhs.quality.rawValue > rhs.quality.rawValue }
                if lhs.language != rhs.language { return lhs.language < rhs.language }
                return lhs.name < rhs.name
            }
            .map { voice in
                let quality = switch voice.quality {
                case .premium: "Premium"
                case .enhanced: "Enhanced"
                default: "Standard"
                }
                let personal = voice.voiceTraits.contains(.isPersonalVoice) ? " · Personal Voice" : ""
                return VoiceInfo(id: VoiceID(engine: .apple, identifier: voice.identifier), name: voice.name,
                                 language: voice.language, detail: "\(quality)\(personal)")
            }
    }

    public static func voiceLanguage(identifier: String) -> String? {
        AVSpeechSynthesisVoice(identifier: identifier)?.language
    }

    /// Best installed voice for a language: premium, then enhanced, then default.
    public static func bestVoice(for language: String?) -> AVSpeechSynthesisVoice? {
        let lang = language ?? AVSpeechSynthesisVoice.currentLanguageCode()
        let prefix = String(lang.prefix(2))
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix(prefix) && !$0.voiceTraits.contains(.isNoveltyVoice)
        }
        let exact = candidates.filter { $0.language == lang }
        let pool = exact.isEmpty ? candidates : exact
        return pool.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: lang)
    }

    public func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedClip {
        await gate.enter()
        defer { Task { await gate.leave() } }

        let voice = request.voice.identifier.isEmpty
            ? Self.bestVoice(for: request.language)
            : AVSpeechSynthesisVoice(identifier: request.voice.identifier)
        guard let voice else { throw SpeechEngineError.voiceUnavailable(request.voice.identifier) }

        let render = try await Renderer.render(text: request.text, voice: voice, pace: request.pace)
        guard !render.samples.isEmpty else { throw SpeechEngineError.emptyAudio }
        let duration = Double(render.samples.count) / render.sampleRate

        // Map each reported range to the display word it overlaps.
        var starts = [Double?](repeating: nil, count: request.wordRanges.count)
        for (range, frame) in render.marks {
            let t = Double(frame) / render.sampleRate
            // One callback can cover several display words ("well-known"); stamp only the first and let the
            // aligner interpolate the rest.
            if let i = request.wordRanges.indices.first(where: { i in
                starts[i] == nil && (NSIntersectionRange(request.wordRanges[i].ns, range).length > 0
                    || (range.length == 0 && request.wordRanges[i].location == range.location))
            }) {
                starts[i] = t
            }
        }
        let matched = starts.compactMap { $0 }.count
        guard matched > 0 else {
            return SynthesizedClip(samples: render.samples, sampleRate: render.sampleRate,
                                   wordTimings: TimingAligner.estimate(displayWords: request.words, duration: duration),
                                   timingSource: .estimated)
        }
        let words = request.words
        let spoken = starts.enumerated().compactMap { i, start in
            start.map { SpokenToken(text: words[i], start: $0, end: $0) }
        }
        var timings = TimingAligner.align(displayWords: words, spoken: spoken, duration: duration)
        // Ends: each word lasts until the next begins.
        for i in timings.indices {
            timings[i].end = i + 1 < timings.count ? max(timings[i].start, timings[i + 1].start) : duration
        }
        return SynthesizedClip(samples: render.samples, sampleRate: render.sampleRate, wordTimings: timings,
                               timingSource: .engine)
    }

    // MARK: - Rendering

    /// One sentence being rendered. Callbacks for it (buffers, range marks) are routed here by identity, so a
    /// late callback from an earlier, cancelled utterance can never leak into the next one.
    private final class Job: @unchecked Sendable {
        struct Output {
            var samples: [Float]
            var sampleRate: Double
            var marks: [(NSRange, Int)]
        }

        let utterance: AVSpeechUtterance
        private let lock = NSLock()
        private var samples: [Float] = []
        private var sampleRate: Double = 22_050
        private var marks: [(NSRange, Int)] = []
        private var continuation: CheckedContinuation<Output, Error>?
        private var finished = false

        init(utterance: AVSpeechUtterance) {
            self.utterance = utterance
        }

        func attach(_ cont: CheckedContinuation<Output, Error>) {
            let alreadyFinished = lock.withLock {
                continuation = cont
                return finished
            }
            // Cancelled before the continuation existed.
            if alreadyFinished { lock.withLock { continuation = nil }; cont.resume(throwing: CancellationError()) }
        }

        func receive(_ buffer: AVAudioBuffer) {
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                finish(error: nil)
                return
            }
            let chunk = Renderer.floatSamples(pcm)
            lock.withLock {
                guard !finished else { return }
                sampleRate = pcm.format.sampleRate
                samples.append(contentsOf: chunk)
            }
        }

        var isFinished: Bool { lock.withLock { finished } }

        func mark(_ range: NSRange) {
            lock.withLock { if !finished { marks.append((range, samples.count)) } }
        }

        func finish(error: Error?) {
            let (cont, output): (CheckedContinuation<Output, Error>?, Output) = lock.withLock {
                guard !finished else { return (nil, Output(samples: [], sampleRate: 0, marks: [])) }
                finished = true
                defer { continuation = nil }
                return (continuation, Output(samples: samples, sampleRate: sampleRate, marks: marks))
            }
            guard let cont else { return }
            if let error { cont.resume(throwing: error) } else { cont.resume(returning: output) }
        }
    }

    /// Owns the app's single `AVSpeechSynthesizer`. It is created and driven on the main thread and never
    /// released: iOS's TextToSpeech framework keeps dispatching work to the main queue after a `write` completes,
    /// and freeing a per-sentence synthesizer under it crashes (EXC_BAD_ACCESS in `objc_retain`).
    @MainActor
    private final class Renderer: NSObject, AVSpeechSynthesizerDelegate {
        static let shared = Renderer()

        private let synthesizer = AVSpeechSynthesizer()
        /// Jobs by utterance, read from delegate callbacks on whatever thread the framework uses.
        nonisolated(unsafe) private var jobs: [ObjectIdentifier: Job] = [:]
        nonisolated private let lock = NSLock()

        override init() {
            super.init()
            synthesizer.delegate = self
        }

        nonisolated static func render(text: String, voice: AVSpeechSynthesisVoice, pace: Float) async throws -> Job.Output {
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate,
                                 max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * pace))
            utterance.prefersAssistiveTechnologySettings = false
            let job = Job(utterance: utterance)
            let sendableUtterance = SendableBox(utterance)
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Job.Output, Error>) in
                    job.attach(cont)
                    Task { @MainActor in
                        Renderer.shared.start(job, utterance: sendableUtterance.value)
                    }
                    // Safety net: a voice that never delivers its terminating empty buffer.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
                        job.finish(error: SpeechEngineError.underlying("Apple voice timed out"))
                    }
                }
            } onCancel: {
                job.finish(error: CancellationError())
                Task { @MainActor in Renderer.shared.cancel(job) }
            }
        }

        private func start(_ job: Job, utterance: AVSpeechUtterance) {
            guard !job.isFinished else { return } // cancelled while waiting for the main actor
            lock.withLock { jobs[ObjectIdentifier(utterance)] = job }
            synthesizer.write(utterance) { buffer in
                job.receive(buffer)
            }
        }

        private func cancel(_ job: Job) {
            let isQueued = lock.withLock { jobs.removeValue(forKey: ObjectIdentifier(job.utterance)) != nil }
            if isQueued, synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        }

        private nonisolated func job(for utterance: AVSpeechUtterance) -> Job? {
            lock.withLock { jobs[ObjectIdentifier(utterance)] }
        }

        nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                                           utterance: AVSpeechUtterance) {
            job(for: utterance)?.mark(characterRange)
        }

        nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            let job = lock.withLock { jobs.removeValue(forKey: ObjectIdentifier(utterance)) }
            // `write` also reports completion with an empty buffer; give it a moment to arrive first.
            if let job { DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { job.finish(error: nil) } }
        }

        nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            let job = lock.withLock { jobs.removeValue(forKey: ObjectIdentifier(utterance)) }
            job?.finish(error: CancellationError())
        }

        nonisolated static func floatSamples(_ pcm: AVAudioPCMBuffer) -> [Float] {
            let n = Int(pcm.frameLength)
            if let data = pcm.floatChannelData {
                return Array(UnsafeBufferPointer(start: data[0], count: n))
            }
            if let data = pcm.int16ChannelData {
                return UnsafeBufferPointer(start: data[0], count: n).map { Float($0) / 32768 }
            }
            if let data = pcm.int32ChannelData {
                return UnsafeBufferPointer(start: data[0], count: n).map { Float($0) / 2_147_483_648 }
            }
            return []
        }
    }
}

private struct SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// A FIFO async mutex.
actor AsyncGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func leave() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
