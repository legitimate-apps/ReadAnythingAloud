import Foundation
import Testing
@testable import ReadAloudKit

@Suite struct TimingAlignerTests {
    @Test func exactMatchesKeepEngineTimes() {
        let spoken = [("The", 0.3), ("quick", 0.5), ("fox", 0.9)].map { SpokenToken(text: $0.0, start: $0.1, end: $0.1 + 0.2) }
        let t = TimingAligner.align(displayWords: ["The", "quick", "fox"], spoken: spoken, duration: 1.2)
        #expect(t.map(\.start) == [0.3, 0.5, 0.9])
    }

    @Test func expandedNumberSpansAllItsSpokenWords() {
        // Display "It cost $45 in" ↔ spoken "it cost forty five dollars in"
        let spoken = [("it", 0.0), ("cost", 0.2), ("forty", 0.5), ("five", 0.8), ("dollars", 1.0), ("in", 1.4)]
            .map { SpokenToken(text: $0.0, start: $0.1, end: $0.1 + 0.2) }
        let t = TimingAligner.align(displayWords: ["It", "cost", "45", "in"], spoken: spoken, duration: 2)
        #expect(t[2].start == 0.5)
        #expect(abs(t[2].end - 1.2) < 1e-9)
        #expect(t[3].start == 1.4)
    }

    @Test func abbreviationBetweenAnchorsIsMapped() {
        let spoken = [("to", 1.0), ("doctor", 1.2), ("smiths", 1.6)].map { SpokenToken(text: $0.0, start: $0.1, end: $0.1 + 0.3) }
        let t = TimingAligner.align(displayWords: ["to", "Dr", "Smith's"], spoken: spoken, duration: 2)
        #expect(t.map(\.start) == [1.0, 1.2, 1.6])
    }

    @Test func unspokenDisplayWordsAreSqueezedMonotonically() {
        let spoken = [("a", 0.0), ("c", 1.0)].map { SpokenToken(text: $0.0, start: $0.1, end: $0.1 + 0.4) }
        let t = TimingAligner.align(displayWords: ["a", "b", "c"], spoken: spoken, duration: 1.5)
        #expect(t[1].start >= t[0].start && t[1].start <= t[2].start)
        #expect(t[2].start == 1.0)
    }

    @Test func emptyTextTokensFallBackToProportionalWithinSpokenWindow() {
        let spoken = [SpokenToken(text: "", start: 0.3, end: 0.6), SpokenToken(text: "", start: 0.6, end: 1.0)]
        let t = TimingAligner.align(displayWords: ["hi", "there"], spoken: spoken, duration: 1.2)
        #expect(t[0].start == 0.3)
        #expect(t[1].start > 0.3 && t[1].start < 1.0)
    }

    @Test func noSpokenTokensEstimates() {
        let t = TimingAligner.align(displayWords: ["one", "three"], spoken: [], duration: 2)
        #expect(t[0].start == 0)
        #expect(t[1].start > 0.5 && t[1].start < 1.5)
        #expect(abs(t[1].end - 2) < 1e-9)
    }

    @Test func outputIsAlwaysMonotonicAndClamped() {
        let spoken = [("b", 0.9), ("a", 0.1), ("c", 5.0)].map { SpokenToken(text: $0.0, start: $0.1, end: $0.1 + 0.1) }
        let t = TimingAligner.align(displayWords: ["a", "b", "c"], spoken: spoken, duration: 2)
        for i in 1..<t.count { #expect(t[i].start >= t[i - 1].start) }
        #expect(t.allSatisfy { $0.end <= 2 && $0.end >= $0.start })
    }

    @Test func normalizeFoldsCaseDiacriticsAndPunctuation() {
        #expect(TimingAligner.normalize("Café’s!") == "cafes")
    }
}

@Suite struct KokoroTimingTests {
    // Captured from FluidAudio 0.17.4 on 2026-09-25 for:
    // "It cost $45 in 2024, according to Dr. Smith's well-known report."
    static let ids: [Int32] = [0,102,62,16,53,156,76,61,62,16,48,156,76,123,125,51,16,48,156,25,64,16,46,156,69,54,83,123,68,16,102,56,16,62,65,156,86,56,62,51,16,62,65,156,86,56,62,51,16,48,156,76,123,3,16,83,53,156,76,123,46,102,112,16,62,63,16,46,156,69,53,62,83,123,16,61,55,156,102,119,61,16,65,156,86,54,16,56,156,31,56,16,123,83,58,156,76,123,62,4,0]
    static let phonemes = "ɪt kˈɔst fˈɔɹɾi fˈIv dˈɑləɹz ɪn twˈɛnti twˈɛnti fˈɔɹ, əkˈɔɹdɪŋ tu dˈɑktəɹ smˈɪθs wˈɛl nˈOn ɹəpˈɔɹt."
    static let normalized = "It cost forty five dollars in twenty twenty four, according to doctor Smith's well-known report."

    @Test func groupsMatchNormalizedWordsIncludingHyphenSplit() throws {
        let durations = Self.ids.map { _ in Int32(2) }
        let tokens = try #require(KokoroEngine.spokenTokens(inputIds: Self.ids, durations: durations,
                                                            phonemes: Self.phonemes, normalizedText: Self.normalized,
                                                            duration: Double(durations.count * 2) * 0.0125))
        #expect(tokens.count == 16)
        #expect(tokens.map(\.text).prefix(5) == ["It", "cost", "forty", "five", "dollars"])
        #expect(tokens[14].text == "known")
        for i in 1..<tokens.count { #expect(tokens[i].start > tokens[i - 1].start) }
    }

    @Test func endToEndAlignmentPlacesNumberWordsOnTheDisplayNumber() throws {
        let durations = Self.ids.map { _ in Int32(2) }
        let duration = Double(durations.count * 2) * 0.0125
        let tokens = try #require(KokoroEngine.spokenTokens(inputIds: Self.ids, durations: durations, phonemes: Self.phonemes,
                                                            normalizedText: Self.normalized, duration: duration))
        let display = ["It", "cost", "45", "in", "2024", "according", "to", "Dr", "Smith's", "well", "known", "report"]
        let t = TimingAligner.align(displayWords: display, spoken: tokens, duration: duration)
        #expect(t[2].start == tokens[2].start)       // "45" starts at "forty"
        #expect(t[3].start == tokens[5].start)       // "in"
        #expect(t[4].start == tokens[6].start)       // "2024" starts at "twenty"
        #expect(t[7].start == tokens[11].start)      // "Dr" = "doctor"
        #expect(t[10].start == tokens[14].start)     // "known"
    }

    @Test func pairByLengthLeavesUnmatchedPhonemeWordsEmpty() {
        let out = KokoroEngine.pairByLength(words: ["hello", "world"], phonemeWords: ["həlˈO", "ə", "wˈɜɹld"])
        #expect(out.first == "hello")
        #expect(out.last == "world")
        #expect(out.filter(\.isEmpty).count == 1)
    }
}
