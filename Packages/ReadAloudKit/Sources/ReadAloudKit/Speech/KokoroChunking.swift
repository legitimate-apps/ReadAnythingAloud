import FluidAudio
import Foundation

/// Recover when normalization/phonemization expands a sentence beyond Kokoro's model limit. Written
/// character limits cannot predict this (for example dates, digit strings or spelled-out abbreviations).
/// Each child retains intersections with the original UTF-16 word ranges, including a word split in two.
enum KokoroChunking {
    static func synthesize(
        _ request: SynthesisRequest,
        render: @Sendable (SynthesisRequest) async throws -> SynthesizedClip
    ) async throws -> SynthesizedClip {
        try Task.checkCancellation()
        do {
            return try await render(request)
        } catch let error as KokoroAneError {
            guard case .phonemeSequenceTooLong = error else { throw error }
            let text = request.text
            guard text.count > 1 else { throw error }
            let midpoint = text.index(text.startIndex, offsetBy: text.count / 2)
            // Prefer a word boundary near the midpoint, avoiding tiny pieces at either edge. If the
            // offending text is one enormous token, split on a Character boundary without losing it.
            let candidates = text.indices.filter { index in
                text[index].isWhitespace && index > text.startIndex
                    && text.index(after: index) < text.endIndex
            }
            let whitespace = candidates.min {
                abs(text.distance(from: midpoint, to: $0)) < abs(text.distance(from: midpoint, to: $1))
            }
            let cut = whitespace.map { text.index(after: $0) } ?? midpoint
            let ranges = [text.startIndex..<cut, cut..<text.endIndex]
            var samples: [Float] = []
            var timings = [WordTiming?](repeating: nil, count: request.wordRanges.count)
            var sampleRate: Double?
            var timingSource = TimingSource.engine
            for range in ranges {
                try Task.checkCancellation()
                let span = NSRange(range, in: text)
                var child = request
                child.text = String(text[range])
                child.wordRanges = []
                var originalIndices: [Int] = []
                for (index, word) in request.wordRanges.enumerated() {
                    let intersection = NSIntersectionRange(word.ns, span)
                    if intersection.length > 0 {
                        originalIndices.append(index)
                        child.wordRanges.append(TextSpan(location: intersection.location - span.location,
                                                         length: intersection.length))
                    }
                }
                let clip = try await synthesize(child, render: render)
                guard clip.sampleRate.isFinite, clip.sampleRate > 0,
                      sampleRate == nil || sampleRate == clip.sampleRate,
                      clip.wordTimings.count == originalIndices.count else {
                    throw SpeechEngineError.underlying("The voice returned inconsistent audio while reading a long sentence.")
                }
                sampleRate = clip.sampleRate
                let offset = Double(samples.count) / clip.sampleRate
                for (index, timing) in zip(originalIndices, clip.wordTimings) {
                    let shifted = WordTiming(start: timing.start + offset, end: timing.end + offset)
                    if let previous = timings[index] {
                        timings[index] = WordTiming(start: previous.start, end: shifted.end)
                    } else {
                        timings[index] = shifted
                    }
                }
                samples.append(contentsOf: clip.samples)
                if clip.timingSource == .estimated { timingSource = .estimated }
                else if clip.timingSource == .asr, timingSource != .estimated { timingSource = .asr }
            }
            guard let sampleRate, timings.allSatisfy({ $0 != nil }) else {
                throw SpeechEngineError.underlying("The voice could not align all words in a long sentence.")
            }
            return SynthesizedClip(samples: samples, sampleRate: sampleRate,
                                   wordTimings: timings.compactMap { $0 }, timingSource: timingSource)
        }
    }
}
