#if os(macOS)
import FluidAudio
import Foundation
import Testing
@testable import ReadAloudKit

/// Opt in only on a Mac with the Kokoro models already downloaded. No paid speech services are used.
@Suite(.serialized)
struct KokoroCoreMLIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["READALOUD_KOKORO_COREML"] == "1"))
    func numericExpansionRecoversRealModelOverflow() async throws {
        let text = Array(repeating: "2024", count: 60).joined(separator: " ")
        let request = SynthesisRequest(text: text,
                                       wordRanges: (0..<60).map { TextSpan(location: $0 * 5, length: 4) },
                                       voice: VoiceID(engine: .kokoro, identifier: "af_heart"))
        // Prove this input exercises recovery, rather than merely testing an ordinary successful render.
        try await requireRawModelOverflow(text)
        let clip = try await KokoroEngine().synthesize(request)
        #expect(clip.sampleRate == 24_000)
        #expect(clip.duration > 10)
        #expect(clip.samples.contains { abs($0) > 0.001 })
        #expect(clip.wordTimings.count == 60)
        var previousStart = 0.0
        for timing in clip.wordTimings {
            #expect(timing.start >= previousStart)
            #expect(timing.end > timing.start)
            #expect(timing.end <= clip.duration + 0.001)
            previousStart = timing.start
        }
        print("Real Kokoro overflow recovery: \(clip.samples.count) samples, \(clip.duration)s, \(clip.wordTimings.count) word timings")
    }

    private func requireRawModelOverflow(_ text: String) async throws {
        let manager = KokoroAneManager(variant: .english)
        try await manager.initialize()
        do {
            _ = try await manager.synthesizeDetailed(text: text, voice: "af_heart", speed: 1)
            Issue.record("The real-model fixture no longer exceeds the phoneme limit")
        } catch let error as KokoroAneError {
            guard case .phonemeSequenceTooLong = error else { throw error }
        }
    }
}
#endif
