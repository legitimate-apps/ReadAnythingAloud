import Foundation
import Synchronization
import Testing
@testable import ReadAloudKit

struct QueueCancellationTests {
    func queue(engine: any SpeechEngine) -> SynthesisQueue {
        let document = DocumentBuilder.build(Article(title: "", language: "en", blocks: [
            Block(kind: .paragraph, text: "Alpha beta gamma delta.")
        ]))
        return SynthesisQueue(document: document, engine: engine,
                              voice: VoiceID(engine: .apple, identifier: "test"),
                              cache: ClipCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                              lookahead: 1)
    }

    @Test func cancelledQueueDropsMemoryAndRejectsFutureRequests() async throws {
        let q = queue(engine: FakeEngine())
        _ = try await q.clip(for: 0)
        #expect(await q.readyClip(for: 0) != nil)
        await q.cancel()
        #expect(await q.readyClip(for: 0) == nil)
        await q.setPlayhead(0)
        do {
            _ = try await q.clip(for: 0)
            Issue.record("A discarded queue must not provide playback or start new work")
        } catch is CancellationError {
            // Expected even when the clip was already synthesized.
        }
    }

    @Test func cancelledQueueNeverStartsFreshSynthesis() async throws {
        let engine = CountingEngine()
        let q = queue(engine: engine)
        await q.cancel()
        await q.setPlayhead(0)
        do {
            _ = try await q.clip(for: 0)
            Issue.record("Cancellation must be terminal even before the first request")
        } catch is CancellationError {}
        #expect(await engine.requests == 0)
    }

    @Test func cancelledQueueRejectsUncooperativeLateEngineResult() async throws {
        let engine = HeldEngine()
        let q = queue(engine: engine)
        let observations = Mutex(0)
        await q.setClipObserver { _, _ in observations.withLock { $0 += 1 } }
        let request = Task { try await q.clip(for: 0) }
        let deadline = ContinuousClock.now + .seconds(5)
        while await engine.requests == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await engine.requests == 1)
        await q.cancel()
        await engine.release()
        do {
            _ = try await request.value
            Issue.record("The canceled request must not return its late result")
        } catch is CancellationError {}
        #expect(await q.readyClip(for: 0) == nil)
        #expect(observations.withLock { $0 } == 0)
    }
}

private actor CountingEngine: SpeechEngine {
    nonisolated let kind: EngineKind = .apple
    nonisolated let modelRevision = UUID().uuidString
    private(set) var requests = 0

    func voices() async -> [VoiceInfo] { [] }
    func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedClip {
        requests += 1
        return try await FakeEngine().synthesize(request)
    }
}
