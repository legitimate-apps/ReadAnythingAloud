import Foundation
import Testing
@testable import ReadAloudKit

/// Real system voices: sequential renders share one synthesizer, and a cancelled render must not disturb the next.
@Suite(.serialized) struct AppleSpeechTests {
    private func request(_ text: String) -> SynthesisRequest {
        let ns = text as NSString
        var ranges: [TextSpan] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { _, r, _, _ in
            ranges.append(TextSpan(r))
        }
        return SynthesisRequest(text: text, wordRanges: ranges, voice: VoiceID(engine: .apple, identifier: ""),
                                language: "en-US")
    }

    @Test func sequentialRendersHaveAudioAndOrderedTimings() async throws {
        let engine = AppleSpeechEngine()
        for text in ["The quick brown fox jumps over the lazy dog.", "A second sentence follows the first one."] {
            let req = request(text)
            let clip = try await engine.synthesize(req)
            #expect(clip.duration > 1)
            #expect(clip.timingSource == .engine)
            #expect(clip.wordTimings.count == req.wordRanges.count)
            #expect(zip(clip.wordTimings, clip.wordTimings.dropFirst()).allSatisfy { $0.start <= $1.start })
            #expect(clip.wordTimings.last!.end <= clip.duration + 0.001)
        }
    }

    @Test func cancelledRenderDoesNotLeakIntoTheNext() async throws {
        let engine = AppleSpeechEngine()
        let long = request(String(repeating: "This sentence is long enough to be interrupted halfway. ", count: 6))
        let task = Task { try await engine.synthesize(long) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        _ = try? await task.value

        let short = request("Short and complete.")
        let clip = try await engine.synthesize(short)
        #expect(clip.duration > 0.5)
        #expect(clip.duration < 5, "audio from the cancelled utterance must not be appended")
        #expect(clip.wordTimings.count == short.wordRanges.count)
    }
}
