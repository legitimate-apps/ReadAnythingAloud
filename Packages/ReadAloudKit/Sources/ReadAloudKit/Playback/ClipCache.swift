@preconcurrency import AVFoundation
import CryptoKit
import Foundation

/// The sample format every clip is converted to before caching and playback.
public enum CanonicalAudio {
    public static let sampleRate: Double = 24_000
    public static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

    /// Linear-phase resampling through AVAudioConverter.
    public static func resample(_ samples: [Float], from rate: Double) -> [Float] {
        guard rate != sampleRate, !samples.isEmpty,
              let source = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let converter = AVAudioConverter(from: source, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count))
        else { return samples }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        input.frameLength = input.frameCapacity
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let capacity = AVAudioFrameCount(Double(samples.count) * sampleRate / rate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return samples }
        final class Once: @unchecked Sendable { var consumed = false }
        let once = Once()
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if once.consumed {
                status.pointee = .endOfStream
                return nil
            }
            once.consumed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil else { return samples }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    /// Converts a clip to the canonical rate, leaving timings (in seconds) untouched.
    public static func canonicalize(_ clip: SynthesizedClip) -> SynthesizedClip {
        guard clip.sampleRate != sampleRate else { return clip }
        var out = clip
        out.samples = resample(clip.samples, from: clip.sampleRate)
        out.sampleRate = sampleRate
        return out
    }
}

/// Disk cache of synthesized sentences: Apple Lossless audio plus a JSON sidecar with word timings.
///
/// Keys hash the speech text with the engine, model revision, voice and pace, so edits or voice changes never
/// return stale audio. Files live in Caches (purgeable by the system) and are trimmed LRU past a size budget.
public actor ClipCache {
    public static let shared = ClipCache()

    private let directory: URL
    private let budgetBytes: Int64
    private var writesSinceTrim = 0

    public init(directory: URL? = nil, budgetBytes: Int64 = 600 * 1024 * 1024) {
        let base = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpeechClips", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.directory = base
        self.budgetBytes = budgetBytes
    }

    public nonisolated static func key(text: String, voice: VoiceID, modelRevision: String, pace: Float) -> String {
        let material = "\(voice.engine.rawValue)|\(modelRevision)|\(voice.identifier)|\(String(format: "%.2f", pace))|\(text)"
        return SHA256.hash(data: Data(material.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private struct Sidecar: Codable {
        var sampleRate: Double
        var frameCount: Int
        var wordTimings: [WordTiming]
        var timingSource: TimingSource
    }

    public func clip(for key: String) -> SynthesizedClip? {
        let audioURL = directory.appendingPathComponent("\(key).caf")
        let metaURL = directory.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(Sidecar.self, from: data),
              let file = try? AVAudioFile(forReading: audioURL, commonFormat: .pcmFormatFloat32, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              Int(buffer.frameLength) == meta.frameCount
        else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: metaURL.path)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        return SynthesizedClip(samples: samples, sampleRate: meta.sampleRate, wordTimings: meta.wordTimings,
                               timingSource: meta.timingSource)
    }

    public func store(_ clip: SynthesizedClip, for key: String) {
        let audioURL = directory.appendingPathComponent("\(key).caf")
        let metaURL = directory.appendingPathComponent("\(key).json")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: clip.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitDepthHintKey: 16,
        ]
        do {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: clip.sampleRate, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(clip.samples.count))
            else { return }
            buffer.frameLength = buffer.frameCapacity
            clip.samples.withUnsafeBufferPointer {
                buffer.floatChannelData![0].update(from: $0.baseAddress!, count: clip.samples.count)
            }
            do {
                let file = try AVAudioFile(forWriting: audioURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                try file.write(from: buffer)
            }
            let meta = Sidecar(sampleRate: clip.sampleRate, frameCount: clip.samples.count,
                               wordTimings: clip.wordTimings, timingSource: clip.timingSource)
            try JSONEncoder().encode(meta).write(to: metaURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: audioURL)
            try? FileManager.default.removeItem(at: metaURL)
        }
        writesSinceTrim += 1
        if writesSinceTrim >= 50 {
            writesSinceTrim = 0
            trim()
        }
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func sizeInBytes() -> Int64 {
        entries().reduce(0) { $0 + $1.size }
    }

    private func entries() -> [(url: URL, size: Int64, date: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (url, Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast)
        }
    }

    /// Deletes least-recently-used clips until the cache fits the budget.
    func trim() {
        var all = entries()
        var total = all.reduce(0) { $0 + $1.size }
        guard total > budgetBytes else { return }
        // Group audio+sidecar by key; age by the sidecar's date (touched on read).
        all.sort { $0.date < $1.date }
        for entry in all where entry.url.pathExtension == "json" {
            guard total > budgetBytes * 8 / 10 else { break }
            let key = entry.url.deletingPathExtension().lastPathComponent
            let audio = directory.appendingPathComponent("\(key).caf")
            let audioSize = (try? audio.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
            try? FileManager.default.removeItem(at: entry.url)
            try? FileManager.default.removeItem(at: audio)
            total -= entry.size + Int64(audioSize)
        }
    }
}
