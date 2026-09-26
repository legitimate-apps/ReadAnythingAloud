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
            for (i, w) in request.wordRanges.enumerated() where starts[i] == nil {
                if NSIntersectionRange(w.ns, range).length > 0 || (range.length == 0 && w.location == range.location) {
                    starts[i] = t
                }
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

    private final class Renderer: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
        struct Output {
            var samples: [Float]
            var sampleRate: Double
            var marks: [(NSRange, Int)]
        }

        private let synthesizer = AVSpeechSynthesizer()
        private let lock = NSLock()
        private var samples: [Float] = []
        private var sampleRate: Double = 22_050
        private var marks: [(NSRange, Int)] = []
        private var continuation: CheckedContinuation<Output, Error>?
        private var finished = false

        static func render(text: String, voice: AVSpeechSynthesisVoice, pace: Float) async throws -> Output {
            let renderer = Renderer()
            return try await renderer.run(text: text, voice: voice, pace: pace)
        }

        private func run(text: String, voice: AVSpeechSynthesisVoice, pace: Float) async throws -> Output {
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate,
                                 max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * pace))
            utterance.prefersAssistiveTechnologySettings = false
            synthesizer.delegate = self
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Output, Error>) in
                    lock.withLock { continuation = cont }
                    synthesizer.write(utterance) { [weak self] buffer in
                        self?.receive(buffer)
                    }
                    // Safety net: a voice that never delivers its terminating empty buffer.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 60) { [weak self] in
                        self?.finish(error: SpeechEngineError.underlying("Apple voice timed out"))
                    }
                }
            } onCancel: {
                self.synthesizer.stopSpeaking(at: .immediate)
                self.finish(error: CancellationError())
            }
        }

        private func receive(_ buffer: AVAudioBuffer) {
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                finish(error: nil)
                return
            }
            let chunk = Self.floatSamples(pcm)
            lock.withLock {
                sampleRate = pcm.format.sampleRate
                samples.append(contentsOf: chunk)
            }
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                               utterance: AVSpeechUtterance) {
            lock.withLock { marks.append((characterRange, samples.count)) }
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            // `write` also reports completion with an empty buffer; give it a moment to arrive first.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.finish(error: nil) }
        }

        private func finish(error: Error?) {
            let (cont, output): (CheckedContinuation<Output, Error>?, Output) = lock.withLock {
                guard !finished else { return (nil, Output(samples: [], sampleRate: 0, marks: [])) }
                finished = true
                defer { continuation = nil }
                return (continuation, Output(samples: samples, sampleRate: sampleRate, marks: marks))
            }
            guard let cont else { return }
            if let error { cont.resume(throwing: error) } else { cont.resume(returning: output) }
        }

        static func floatSamples(_ pcm: AVAudioPCMBuffer) -> [Float] {
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
