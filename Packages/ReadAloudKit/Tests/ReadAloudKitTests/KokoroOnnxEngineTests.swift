import FluidAudio
import Foundation
import NaturalLanguage
import Testing
@testable import ReadAloudKit

@Suite struct KokoroOnnxEngineUnitTests {
    @Test func styleRowIsTheFullRowForThePhonemeCount() throws {
        let cols = KokoroAneConstants.voicePackCols
        let pack = try KokoroAneVoicePack(storage: (0..<(KokoroAneConstants.voicePackRows * cols)).map { Float($0 / cols) })
        #expect(KokoroOnnxEngine.styleRow(pack, phonemeCount: 1) == Array(repeating: 0, count: cols))
        #expect(KokoroOnnxEngine.styleRow(pack, phonemeCount: 40) == Array(repeating: 39, count: cols))
        #expect(KokoroOnnxEngine.styleRow(pack, phonemeCount: 0).first == 0)
        #expect(KokoroOnnxEngine.styleRow(pack, phonemeCount: 9_999).first == Float(KokoroAneConstants.voicePackRows - 1))
    }

    @Test func sha256MatchesKnownDigest() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try ModelDownloader.sha256Hex(of: url) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

private var localKokoroOnnxModelPath: String? {
    guard let path = ProcessInfo.processInfo.environment[KokoroOnnxEngine.modelPathEnvironmentKey],
          FileManager.default.fileExists(atPath: path) else { return nil }
    return path
}

/// Runs the real ONNX graph. Enabled only when `READALOUD_KOKORO_ONNX_MODEL` names a local copy of the model, e.g.
/// `READALOUD_KOKORO_ONNX_MODEL=/path/to/kokoro-82m-v1.0-timestamped-int8.onnx swift test --filter KokoroOnnx`.
/// FluidAudio's frontend assets download into its cache on first run.
@Suite(.serialized, .enabled(if: localKokoroOnnxModelPath != nil, "set READALOUD_KOKORO_ONNX_MODEL to a local model file"))
struct KokoroOnnxEngineModelTests {
    static let sentence = "It cost $45 in 2024, according to Dr. Smith's well-known report, and the quick brown fox jumped over the lazy dog."

    static func request(_ text: String, voice: String = "af_heart") -> SynthesisRequest {
        // Same word definition as DocumentBuilder: NLTokenizer words containing a letter or digit.
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var ranges: [TextSpan] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if text[range].contains(where: { $0.isLetter || $0.isNumber }) { ranges.append(TextSpan(NSRange(range, in: text))) }
            return true
        }
        return SynthesisRequest(text: text, wordRanges: ranges, voice: VoiceID(engine: .kokoro, identifier: voice))
    }

    static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    @Test func synthesizesARealSentenceWithOneMonotonicTimingPerWord() async throws {
        let engine = KokoroOnnxEngine()
        try await engine.prepare()
        let request = Self.request(Self.sentence)
        _ = try await engine.synthesize(Self.request("Warm up."))
        let started = Date(), cpuStarted = Self.processCPUSeconds()
        let clip = try await engine.synthesize(request)
        let elapsed = Date().timeIntervalSince(started), cpu = Self.processCPUSeconds() - cpuStarted
        print(String(format: "KokoroOnnx: %.2f s audio in %.2f s wall (RTF %.2f), %.2f CPU-s per audio-s",
                     clip.duration, elapsed, elapsed / clip.duration, cpu / clip.duration))

        #expect(clip.sampleRate == 24_000)
        #expect(clip.duration > 3)
        #expect(clip.samples.contains { abs($0) > 0.05 })
        #expect(clip.samples.allSatisfy { $0.isFinite })
        #expect(clip.timingSource == .engine)
        #expect(clip.wordTimings.count == request.wordRanges.count)
        for (i, t) in clip.wordTimings.enumerated() {
            #expect(t.start >= 0 && t.end >= t.start && t.end <= clip.duration + 1e-6)
            if i > 0 { #expect(t.start >= clip.wordTimings[i - 1].start) }
        }
        // The first word starts after the leading silence, the last ends before the clip does.
        #expect(clip.wordTimings.first!.start > 0.1)
        #expect(clip.wordTimings.last!.end < clip.duration)
    }

    #if os(macOS)
    /// Word boundaries agree with the Core ML engine (same frontend, same voice) to within ~80 ms.
    @Test func wordTimingsAgreeWithCoreMLKokoro() async throws {
        let request = Self.request(Self.sentence, voice: "am_michael")
        let onnx = try await KokoroOnnxEngine().synthesize(request)
        let coreML = try await KokoroEngine().synthesize(request)
        #expect(onnx.wordTimings.count == coreML.wordTimings.count)
        let startDeltas = zip(onnx.wordTimings, coreML.wordTimings).map { abs($0.start - $1.start) }
        let endDeltas = zip(onnx.wordTimings, coreML.wordTimings).map { abs($0.end - $1.end) }
        print("KokoroOnnx vs Core ML: duration \(onnx.duration) vs \(coreML.duration) s; max |Δstart| \(startDeltas.max()!) s, max |Δend| \(endDeltas.max()!) s")
        #expect(startDeltas.max()! <= 0.08)
        #expect(endDeltas.max()! <= 0.08)
        #expect(abs(onnx.duration - coreML.duration) <= 0.1)
    }
    #endif
}
