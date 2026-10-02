import Foundation
import Testing
@testable import ReadAloudKit

/// A manually released request makes the pause race deterministic, independent of CPU/audio timing.
actor HeldEngine: SpeechEngine {
    nonisolated let kind: EngineKind = .apple
    nonisolated let modelRevision = UUID().uuidString
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var requests = 0

    func voices() async -> [VoiceInfo] { [] }
    func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedClip {
        requests += 1
        await withCheckedContinuation { pending = $0 }
        return try await FakeEngine().synthesize(request)
    }
    func release() { pending?.resume(); pending = nil }
}

actor RecoverableEngine: SpeechEngine {
    nonisolated let kind: EngineKind = .apple
    nonisolated let modelRevision = UUID().uuidString
    var failingText: String
    private var shouldFail = true
    init(failingText: String) { self.failingText = failingText }
    func voices() async -> [VoiceInfo] { [] }
    func recover() { shouldFail = false }
    func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedClip {
        if shouldFail, request.text == failingText { throw SpeechEngineError.emptyAudio }
        return try await FakeEngine().synthesize(request)
    }
}

@MainActor
@Suite(.serialized)
struct PlaybackRecoveryTests {
    func document(_ count: Int = 2) -> ReadingDocument {
        DocumentBuilder.build(Article(title: "", language: "en", blocks: [
            Block(kind: .paragraph, text: (0..<count).map { "Alpha beta gamma number \($0)." }.joined(separator: " "))
        ]))
    }

    func queue(_ doc: ReadingDocument, engine: any SpeechEngine) -> SynthesisQueue {
        SynthesisQueue(document: doc, engine: engine, voice: VoiceID(engine: .apple, identifier: "test"),
                       cache: ClipCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                       lookahead: 0)
    }

    func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await predicate())
    }

    @Test func pauseWhileFirstClipIsSynthesizingStaysPaused() async throws {
        let engine = HeldEngine()
        let player = SpeechPlayer()
        player.load(queue(document(1), engine: engine))
        defer { player.stop() }
        player.play(sentence: 0)
        try await waitUntil { await engine.requests == 1 }
        player.pause()
        await engine.release()
        try await Task.sleep(for: .milliseconds(250))
        #expect(player.state == .paused)
        #expect(player.livePosition() == nil)
        player.resume()
        try await waitUntil { player.state == .playing }
        #expect(await engine.requests == 1)
    }

    @Test func resumeDuringPendingSynthesisDoesNotDuplicateOrLosePlayIntent() async throws {
        let engine = HeldEngine()
        let player = SpeechPlayer()
        player.load(queue(document(1), engine: engine))
        defer { player.stop() }
        player.play(sentence: 0)
        try await waitUntil { await engine.requests == 1 }
        player.pause()
        player.resume()
        await engine.release()
        try await waitUntil { player.state == .playing }
        #expect(await engine.requests == 1)
    }

    @Test func failureAtFinalSentencePausesThereAndCanRetry() async throws {
        let doc = document()
        let engine = RecoverableEngine(failingText: doc.sentences[1].speechText)
        let player = SpeechPlayer()
        player.load(queue(doc, engine: engine))
        defer { player.stop() }
        var errors = 0
        player.onError = { _, _ in errors += 1 }
        player.play(sentence: 0)
        try await waitUntil { player.state == .paused }
        #expect(errors == 1)
        #expect(player.position?.sentence == 1)
        await engine.recover()
        player.resume()
        try await waitUntil { player.state == .finished }
    }

    @Test func firstSentenceFailureDoesNotSilentlySkipUnreadText() async throws {
        let doc = document()
        let engine = RecoverableEngine(failingText: doc.sentences[0].speechText)
        let player = SpeechPlayer()
        player.load(queue(doc, engine: engine))
        defer { player.stop() }
        player.play(sentence: 0)
        try await waitUntil { player.state == .paused }
        #expect(player.position?.sentence == 0)
        await engine.recover()
        player.resume()
        try await waitUntil { player.state == .playing }
        #expect(player.position?.sentence == 0)
    }
    @Test func stoppingDiscardsLateSynthesisAndPlayhead() async throws {
        let engine = HeldEngine()
        let player = SpeechPlayer()
        player.load(queue(document(1), engine: engine))
        player.play(sentence: 0)
        try await waitUntil { await engine.requests == 1 }
        player.stop()
        await engine.release()
        try await Task.sleep(for: .milliseconds(150))
        #expect(player.state == .idle)
        #expect(player.position == nil)
        #expect(player.livePosition() == nil)
    }

    @Test func shortSentencesKeepTheirHighlightWhileLaterAudioIsQueued() async throws {
        let doc = DocumentBuilder.build(Article(title: "", language: "en", blocks:
            (0..<12).map { Block(kind: .paragraph, text: "Word \($0).") }))
        let player = SpeechPlayer()
        player.load(queue(doc, engine: FakeEngine()))
        player.rate = 2
        defer { player.stop() }
        var reached = Set<Int>()
        player.play(sentence: 0)
        let deadline = ContinuousClock.now + .seconds(10)
        while player.state != .finished, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
            if let position = player.livePosition() { reached.insert(position.sentence) }
        }
        #expect(player.state == .finished)
        #expect(reached == Set(doc.sentences.indices), "Every spoken sentence needs its highlight, including short ones")
    }

}
