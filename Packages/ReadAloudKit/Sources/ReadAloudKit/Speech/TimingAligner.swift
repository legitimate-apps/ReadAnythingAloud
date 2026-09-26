import Foundation

/// A token the engine (or ASR) actually spoke, with its time span in the clip.
public struct SpokenToken: Sendable, Hashable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Maps spoken tokens onto the display words of a sentence.
///
/// Engines normalize text before speaking ("$45" → "forty five dollars", "Dr." → "doctor"), and ASR output
/// differs from the source in spelling and segmentation. The aligner runs a global (Needleman–Wunsch)
/// alignment on normalized forms, then resolves the unmatched stretches between anchors: a run of display
/// words spans the run of spoken tokens between the same anchors, split by character length. The result is
/// one monotonic timing per display word.
public enum TimingAligner {
    public static func align(displayWords: [String], spoken: [SpokenToken], duration: Double) -> [WordTiming] {
        let n = displayWords.count
        guard n > 0 else { return [] }
        let tokens = spoken.filter { !normalize($0.text).isEmpty || $0.text.isEmpty }
        guard !tokens.isEmpty else { return estimate(displayWords: displayWords, duration: duration) }

        let d = displayWords.map(normalize)
        let s = tokens.map { normalize($0.text) }
        let pairs = globalAlignment(d, s)

        // Anchors: display index → spoken index (strictly increasing in both).
        var timings = [WordTiming?](repeating: nil, count: n)
        var anchors: [(di: Int, si: Int)] = []
        for (di, si) in pairs {
            anchors.append((di, si))
            timings[di] = WordTiming(start: tokens[si].start, end: tokens[si].end)
        }

        // Resolve gaps between consecutive anchors (plus the leading and trailing stretches).
        let bounded = [(di: -1, si: -1)] + anchors + [(di: n, si: tokens.count)]
        for k in 0..<(bounded.count - 1) {
            let a = bounded[k], b = bounded[k + 1]
            let displayGap = Array((a.di + 1)..<b.di)
            let spokenGap = Array((a.si + 1)..<b.si)
            guard !displayGap.isEmpty else {
                // Spoken tokens with no display word (e.g. "dollars" after an anchored "five"): extend the
                // previous anchor so the highlight stays put while they're spoken.
                if !spokenGap.isEmpty, a.di >= 0, var t = timings[a.di] {
                    t.end = max(t.end, tokens[spokenGap.last!].end)
                    timings[a.di] = t
                }
                continue
            }
            let windowStart: Double
            let windowEnd: Double
            if let first = spokenGap.first, let last = spokenGap.last {
                windowStart = tokens[first].start
                windowEnd = tokens[last].end
            } else {
                // Display words nobody spoke (blanked or dropped): squeeze them into the boundary between anchors.
                windowStart = a.si >= 0 ? tokens[a.si].end : 0
                windowEnd = b.si < tokens.count ? tokens[b.si].start : max(windowStart, duration)
            }
            distribute(displayGap, words: displayWords, from: windowStart, to: max(windowStart, windowEnd), into: &timings)
        }
        return monotonic(timings.map { $0 ?? WordTiming(start: 0, end: 0) }, duration: duration)
    }

    /// Evenly spreads a sentence's words over its duration, weighted by character count.
    public static func estimate(displayWords: [String], duration: Double) -> [WordTiming] {
        var timings = [WordTiming?](repeating: nil, count: displayWords.count)
        distribute(Array(displayWords.indices), words: displayWords, from: 0, to: duration, into: &timings)
        return timings.map { $0 ?? WordTiming(start: 0, end: 0) }
    }

    static func distribute(_ indices: [Int], words: [String], from start: Double, to end: Double,
                           into timings: inout [WordTiming?]) {
        let weights = indices.map { Double(max(1, words[$0].count)) + 1 }
        let total = weights.reduce(0, +)
        var t = start
        for (k, i) in indices.enumerated() {
            let span = (end - start) * weights[k] / total
            timings[i] = WordTiming(start: t, end: t + span)
            t += span
        }
    }

    /// Clamps to [0, duration] and makes starts non-decreasing and ends ≥ starts.
    static func monotonic(_ timings: [WordTiming], duration: Double) -> [WordTiming] {
        var out = timings
        var floor = 0.0
        for i in out.indices {
            out[i].start = min(max(out[i].start, floor), duration)
            out[i].end = min(max(out[i].end, out[i].start), duration)
            floor = out[i].start
        }
        return out
    }

    // MARK: - Global alignment

    /// Returns matched (displayIndex, spokenIndex) pairs, strictly increasing in both coordinates.
    static func globalAlignment(_ d: [String], _ s: [String]) -> [(Int, Int)] {
        let n = d.count, m = s.count
        let gap = -0.45
        var score = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        var move = [[UInt8]](repeating: [UInt8](repeating: 0, count: m + 1), count: n + 1) // 0 diag 1 up 2 left
        for i in 1...n { score[i][0] = Double(i) * gap; move[i][0] = 1 }
        if m > 0 { for j in 1...m { score[0][j] = Double(j) * gap; move[0][j] = 2 } }
        if m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let sim = similarity(d[i - 1], s[j - 1])
                    let diag = score[i - 1][j - 1] + (sim >= 0.5 ? sim * 2 : -1.2)
                    let up = score[i - 1][j] + gap
                    let left = score[i][j - 1] + gap
                    if diag >= up, diag >= left {
                        score[i][j] = diag; move[i][j] = 0
                    } else if up >= left {
                        score[i][j] = up; move[i][j] = 1
                    } else {
                        score[i][j] = left; move[i][j] = 2
                    }
                }
            }
        }
        var pairs: [(Int, Int)] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, move[i][j] == 0 {
                if similarity(d[i - 1], s[j - 1]) >= 0.5 { pairs.append((i - 1, j - 1)) }
                i -= 1; j -= 1
            } else if i > 0, j == 0 || move[i][j] == 1 {
                i -= 1
            } else {
                j -= 1
            }
        }
        return pairs.reversed()
    }

    /// 1 − normalized Levenshtein distance.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return a.isEmpty ? 0 : 1 }
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }

    /// Lowercased letters and digits with diacritics folded ("Café’s" → "cafes").
    public static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}
