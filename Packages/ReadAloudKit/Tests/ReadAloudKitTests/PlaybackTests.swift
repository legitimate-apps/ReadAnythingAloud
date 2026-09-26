import AVFoundation
import Foundation
import Testing
@testable import ReadAloudKit

/// A deterministic engine: every word lasts 0.25 s of low-level noise.
struct FakeEngine: SpeechEngine {
    let kind: EngineKind = .apple
    let modelRevision: String
    var delay: Duration = .zero

    init(revision: String = UUID().uuidString, delay: Duration = .zero) {
        modelRevision = revision
        self.delay = delay
    }

    func voices() async -> [VoiceInfo] { [] }

    func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedClip {
        if delay != .zero { try await Task.sleep(for: delay) }
        let rate = 24_000.0
        let n = request.wordRanges.count
        let samples = (0..<Int(Double(n) * 0.25 * rate)).map { i in Float(sin(Double(i) * 0.05)) * 0.01 }
        let timings = (0..<n).map { WordTiming(start: Double($0) * 0.25, end: Double($0 + 1) * 0.25) }
        return SynthesizedClip(samples: samples, sampleRate: rate, wordTimings: timings, timingSource: .engine)
    }
}

@MainActor
@Suite(.serialized) struct PlaybackTests {
    func document(sentences: Int) -> ReadingDocument {
        let text = (0..<sentences).map { "Alpha beta gamma delta number \($0)." }.joined(separator: " ")
        return DocumentBuilder.build(Article(title: "", language: "en", blocks: [Block(kind: .paragraph, text: text)]))
    }

    func tempCache() -> ClipCache {
        ClipCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    @Test func sessionRateIsClampedWithoutRecursing() {
        let article = Article(title: "T", language: "en", blocks: [Block(kind: .paragraph, text: "One two three.")])
        let session = ReadingSession(article: article, library: nil)
        let saved = VoiceSettings.shared.rate
        defer { VoiceSettings.shared.rate = saved }
        session.rate = 9
        #expect(session.rate == 3.5)
        session.rate = 0.1
        #expect(session.rate == 0.5)
        session.rate = 1.75
        #expect(session.rate == 1.75)
        #expect(VoiceSettings.shared.rate == 1.75)
        session.close()
    }

    @Test func clipCacheRoundTripsSamplesAndTimings() async throws {
        let cache = tempCache()
        let clip = SynthesizedClip(samples: (0..<24_000).map { Float(sin(Double($0) * 0.01)) * 0.5 }, sampleRate: 24_000,
                                   wordTimings: [WordTiming(start: 0.1, end: 0.4)], timingSource: .engine)
        await cache.store(clip, for: "k1")
        let back = try #require(await cache.clip(for: "k1"))
        #expect(back.samples.count == clip.samples.count)
        #expect(back.wordTimings == clip.wordTimings)
        let maxError = zip(back.samples, clip.samples).map { abs($0 - $1) }.max() ?? 1
        #expect(maxError < 0.0002) // 16-bit lossless
        #expect(await cache.clip(for: "missing") == nil)
    }

    @Test func queueCachesAndReusesClips() async throws {
        let doc = document(sentences: 3)
        let cache = tempCache()
        let engine = FakeEngine(revision: "r1")
        let q1 = SynthesisQueue(document: doc, engine: engine, voice: VoiceID(engine: .apple, identifier: "x"), cache: cache, lookahead: 3)
        let a = try await q1.clip(for: 1)
        let q2 = SynthesisQueue(document: doc, engine: FakeEngine(revision: "r1", delay: .seconds(10)),
                                voice: VoiceID(engine: .apple, identifier: "x"), cache: cache, lookahead: 3)
        let started = ContinuousClock.now
        let b = try await q2.clip(for: 1)
        #expect(ContinuousClock.now - started < .seconds(2)) // served from disk, not the slow engine
        #expect(a.samples.count == b.samples.count)
    }

    @Test func silenceTrimShiftsTimings() {
        let rate = 24_000.0
        let silence = [Float](repeating: 0, count: 12_000)
        let tone = (0..<24_000).map { Float(sin(Double($0) * 0.05)) * 0.3 }
        let clip = SynthesizedClip(samples: silence + tone + silence, sampleRate: rate,
                                   wordTimings: [WordTiming(start: 0.5, end: 1.0), WordTiming(start: 1.0, end: 1.5)],
                                   timingSource: .engine)
        let trimmed = SynthesisQueue.trimSilence(clip)
        #expect(abs(trimmed.wordTimings[0].start - 0.03) < 0.002)
        #expect(abs(trimmed.duration - 1.08) < 0.01)
    }

    @Test func wordLookupIsLastStartAtOrBefore() {
        let t = [WordTiming(start: 0, end: 0.2), WordTiming(start: 0.3, end: 0.5), WordTiming(start: 0.6, end: 0.9)]
        #expect(SpeechPlayer.wordIndex(at: 0.1, in: t) == 0)
        #expect(SpeechPlayer.wordIndex(at: 0.3, in: t) == 1)
        #expect(SpeechPlayer.wordIndex(at: 0.59, in: t) == 1)
        #expect(SpeechPlayer.wordIndex(at: 5, in: t) == 2)
    }

    /// Real AVAudioEngine playback at 2× (needs an audio output device): the reported clip time must advance at
    /// twice wall-clock speed, and sentences must progress in order.
    @Test func positionTracksMediaTimeAtDoubleSpeed() async throws {
        let doc = document(sentences: 4)
        let queue = SynthesisQueue(document: doc, engine: FakeEngine(), voice: VoiceID(engine: .apple, identifier: "x"),
                                   cache: tempCache(), lookahead: 4)
        let player = SpeechPlayer()
        player.load(queue)
        player.rate = 2
        var samples: [(wall: Double, pos: SpeechPlayer.Position)] = []
        let clock = ContinuousClock()
        let start = clock.now
        player.play(sentence: 0)
        var finished = false
        player.onStateChange = { if $0 == .finished { finished = true } }
        while clock.now - start < .seconds(6), !finished {
            try await Task.sleep(for: .milliseconds(40))
            if let p = player.position, player.state == .playing {
                let wall = Double((clock.now - start).components.attoseconds) / 1e18 + Double((clock.now - start).components.seconds)
                samples.append((wall, p))
            }
        }
        player.stop()
        #expect(finished)
        // Sentences only move forward and all four were reached.
        let sentences = samples.map(\.pos.sentence)
        #expect(sentences == sentences.sorted())
        #expect(Set(sentences).isSuperset(of: [0, 1, 2, 3]))
        // Within a sentence, clip time advances ~2× wall time. Measured on the sentence with the widest sampled
        // window, because under a loaded test run the main actor can be starved for part of any single sentence.
        let windows = Set(sentences).map { index in
            samples.filter { $0.pos.sentence == index && $0.pos.clipTime > 0.05 && $0.pos.clipTime < 1.3 }
        }
        if let best = windows.max(by: { ($0.last?.wall ?? 0) - ($0.first?.wall ?? 0) < ($1.last?.wall ?? 0) - ($1.first?.wall ?? 0) }),
           let first = best.first, let last = best.last, last.wall - first.wall > 0.2 {
            let ratio = (last.pos.clipTime - first.pos.clipTime) / (last.wall - first.wall)
            #expect(abs(ratio - 2) < 0.25, "media/wall ratio \(ratio)")
        } else {
            Issue.record("Not enough samples within any sentence")
        }
        // Total wall time ≈ (4 × 1.5 s clips + pauses) / 2.
        let total = samples.last?.wall ?? 0
        #expect(total > 2.2 && total < 5)
    }

    @Test func seekJumpsToTheRequestedWord() async throws {
        let doc = document(sentences: 3)
        let queue = SynthesisQueue(document: doc, engine: FakeEngine(), voice: VoiceID(engine: .apple, identifier: "x"),
                                   cache: tempCache(), lookahead: 3)
        let player = SpeechPlayer()
        player.load(queue)
        let target = doc.sentences[2].wordIndices.lowerBound + 3
        player.play(sentence: 2, word: target)
        try await Task.sleep(for: .milliseconds(400))
        let pos = try #require(player.position)
        player.stop()
        #expect(pos.sentence == 2)
        #expect(pos.word.map { $0 >= target - 1 } == true)
        #expect(pos.clipTime >= 0.7)
    }
}
