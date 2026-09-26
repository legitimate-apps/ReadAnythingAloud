import FluidAudio
import Foundation
import ReadAloudKit

// Developer probe: synthesizes sentences with an engine and prints word timings (and, with --asr, the
// Parakeet v3 word timings of the same audio for comparison). Not shipped.

let args = CommandLine.arguments.dropFirst()
let useASR = args.contains("--asr")
let engineName = args.first(where: { $0.hasPrefix("--engine=") })?.dropFirst("--engine=".count) ?? "kokoro"
let outDir = URL(fileURLWithPath: args.first(where: { $0.hasPrefix("--out=") }).map { String($0.dropFirst(6)) } ?? "/tmp/readaloud-probe")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let sentences = args.filter { !$0.hasPrefix("--") }.isEmpty
    ? [
        "The quick brown fox jumps over the lazy dog.",
        "It cost $45 in 2024, according to Dr. Smith's well-known report [3].",
        "Kokoro — an 82-million-parameter model — runs at 31× real time on an M-series Mac!",
        "“Wait,” she said; “don't go.”",
    ]
    : Array(args.filter { !$0.hasPrefix("--") })

let engine: any SpeechEngine = switch engineName {
case "apple": AppleSpeechEngine()
default: KokoroEngine()
}
let voice: VoiceID = switch engineName {
case "apple": VoiceID(engine: .apple, identifier: "")
default: VoiceID(engine: .kokoro, identifier: "af_heart")
}

var asr: AsrManager?
if useASR {
    let models = try await AsrModels.downloadAndLoad(version: .v3)
    let manager = AsrManager()
    try await manager.loadModels(models)
    asr = manager
}

for (k, sentence) in sentences.enumerated() {
    let article = Article(title: "", blocks: [Block(kind: .paragraph, text: sentence)])
    let doc = DocumentBuilder.build(article)
    guard let s = doc.sentences.first else { continue }
    let request = SynthesisRequest(text: s.speechText, wordRanges: doc.localWordRanges(ofSentence: 0), voice: voice)
    let started = Date()
    let clip = try await engine.synthesize(request)
    let elapsed = Date().timeIntervalSince(started)
    print("\n# \(sentence)")
    print(String(format: "duration %.2fs, synth %.2fs (%.1fx), timing: %@", clip.duration, elapsed, clip.duration / elapsed, clip.timingSource.rawValue))
    var asrWords: [ReadAloudKit.WordTiming] = []
    if let asr {
        let samples16k = resample(clip.samples, from: clip.sampleRate, to: 16_000)
        var state = TdtDecoderState.make()
        let result = try await asr.transcribe(samples16k, decoderState: &state)
        if let tokens = result.tokenTimings {
            let words = buildWordTimings(from: tokens)
            print("asr: \(words.map { $0.word }.joined(separator: " "))")
            let spoken = words.map { SpokenToken(text: $0.word, start: Double($0.startTime), end: Double($0.endTime)) }
            asrWords = TimingAligner.align(displayWords: request.words, spoken: spoken, duration: clip.duration)
        }
    }
    for (i, word) in request.words.enumerated() {
        let t = clip.wordTimings[i]
        var line = String(format: "  %-16@ %6.3f – %6.3f", word as NSString, t.start, t.end)
        if i < asrWords.count {
            line += String(format: "   asr %6.3f (Δ %+.0f ms)", asrWords[i].start, (t.start - asrWords[i].start) * 1000)
        }
        print(line)
    }
    try writeWAV(clip.samples, sampleRate: clip.sampleRate, to: outDir.appendingPathComponent("\(engineName)-\(k).wav"))
}

func resample(_ x: [Float], from: Double, to: Double) -> [Float] {
    guard from != to, !x.isEmpty else { return x }
    let n = Int(Double(x.count) * to / from)
    return (0..<n).map { i in
        let pos = Double(i) * from / to
        let j = Int(pos), f = Float(pos - Double(j))
        let a = x[min(j, x.count - 1)], b = x[min(j + 1, x.count - 1)]
        return a + (b - a) * f
    }
}

func writeWAV(_ samples: [Float], sampleRate: Double, to url: URL) throws {
    var data = Data()
    func append<T>(_ v: T) { withUnsafeBytes(of: v) { data.append(contentsOf: $0) } }
    let pcm = samples.map { Int16(max(-1, min(1, $0)) * 32767) }
    data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + pcm.count * 2).littleEndian)
    data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16).littleEndian); append(UInt16(1).littleEndian)
    append(UInt16(1).littleEndian); append(UInt32(sampleRate).littleEndian); append(UInt32(sampleRate * 2).littleEndian)
    append(UInt16(2).littleEndian); append(UInt16(16).littleEndian)
    data.append(contentsOf: Array("data".utf8)); append(UInt32(pcm.count * 2).littleEndian)
    pcm.forEach { append($0.littleEndian) }
    try data.write(to: url)
}
