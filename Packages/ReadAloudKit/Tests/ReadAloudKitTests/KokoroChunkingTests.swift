import FluidAudio
import Foundation
import Testing
@testable import ReadAloudKit

struct KokoroChunkingTests {
    func request(_ text: String, singleWord: Bool = false) -> SynthesisRequest {
        let ranges: [TextSpan]
        if singleWord {
            ranges = [TextSpan(location: 0, length: text.utf16.count)]
        } else {
            ranges = text.split(separator: " ").map { part in
                TextSpan(NSRange(part.startIndex..<part.endIndex, in: text))
            }
        }
        return SynthesisRequest(text: text, wordRanges: ranges, voice: VoiceID(engine: .kokoro, identifier: "af_heart"))
    }

    /// Encodes each UTF-16 unit into the waveform. Exact reconstruction proves no missing or duplicate text.
    static func render(_ request: SynthesisRequest) async throws -> SynthesizedClip {
        guard request.text.count <= 10 else { throw KokoroAneError.phonemeSequenceTooLong(600) }
        return SynthesizedClip(samples: request.text.utf16.map { Float($0) / 65_536 }, sampleRate: 24_000,
            wordTimings: request.wordRanges.map { WordTiming(start: Double($0.location) / 24_000,
                                                           end: Double($0.upperBound) / 24_000) }, timingSource: .engine)
    }

    @Test func recursiveChunksPreserveAllAudioAndOriginalWordTimings() async throws {
        let request = request("one two three four five six seven eight nine ten")
        let clip = try await KokoroChunking.synthesize(request, render: Self.render)
        #expect(clip.samples == request.text.utf16.map { Float($0) / 65_536 })
        #expect(clip.wordTimings.count == request.wordRanges.count)
        for (range, timing) in zip(request.wordRanges, clip.wordTimings) {
            #expect(abs(timing.start - Double(range.location) / 24_000) < 0.000001)
            #expect(abs(timing.end - Double(range.upperBound) / 24_000) < 0.000001)
        }
    }

    @Test func aLongUnicodeWordKeepsOneContinuousHighlight() async throws {
        let request = request(String(repeating: "e\u{301}👩🏽‍🚀漢", count: 20), singleWord: true)
        let clip = try await KokoroChunking.synthesize(request, render: Self.render)
        #expect(clip.samples == request.text.utf16.map { Float($0) / 65_536 })
        #expect(clip.wordTimings.count == 1)
        #expect(clip.wordTimings.first?.start == 0)
        #expect(abs((clip.wordTimings.first?.end ?? 0) - clip.duration) < 0.000001)
    }

    @Test func unrelatedErrorsDoNotTriggerChunking() async {
        let error = await #expect(throws: SpeechEngineError.self) {
            try await KokoroChunking.synthesize(request("one two three")) { _ in throw SpeechEngineError.emptyAudio }
        }
        guard case .emptyAudio? = error else { Issue.record("The original error must be preserved"); return }
    }

    @Test func inconsistentAudioRatesAreRejectedInsteadOfChangingSpeed() async {
        await #expect(throws: (any Error).self) {
            try await KokoroChunking.synthesize(request("first second")) { request in
                if request.text.count > 10 { throw KokoroAneError.phonemeSequenceTooLong(600) }
                var clip = try await Self.render(request)
                if request.text.hasPrefix("second") { clip.sampleRate = 48_000 }
                return clip
            }
        }
    }

    @Test func cancellationDoesNotRenderMoreChunks() async {
        let task = Task {
            try await KokoroChunking.synthesize(request("one two three four")) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                throw KokoroAneError.phonemeSequenceTooLong(600)
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
