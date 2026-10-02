import Foundation
import Observation
import Synchronization
import Testing
@testable import ReadAloudKit

@MainActor
@Suite(.serialized)
struct SessionProgressTests {
    func settings() -> VoiceSettings {
        let settings = VoiceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.preferredVoice = VoiceID(engine: .apple, identifier: "")
        return settings
    }

    func article() -> Article {
        Article(title: "", language: "en", blocks: [Block(kind: .paragraph, text: "Alpha beta gamma delta.")])
    }

    func library() -> LibraryStore {
        LibraryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    @Test func completionSurvivesCloseAndReopen() async throws {
        let article = article()
        let library = library()
        library.add(article)
        let session = ReadingSession(article: article, library: library, settings: settings(), engine: FakeEngine())
        session.rate = 3
        session.play()
        let deadline = ContinuousClock.now + .seconds(5)
        while session.state != .finished, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(session.state == .finished)
        #expect(session.fraction == 1)
        #expect(session.remaining == 0)
        #expect(library.item(article.id)?.isFinished == true)
        session.close()
        #expect(library.item(article.id)?.isFinished == true)
        let restored = ReadingSession(article: article, library: library, settings: settings(), engine: FakeEngine())
        defer { restored.close() }
        #expect(restored.sentence == 0)
        #expect(restored.word == 0)
        #expect(restored.state == .finished)
        restored.close()
        #expect(library.item(article.id)?.isFinished == true)
    }

    @Test func nearEndIsNotCompletionAndRestoresTheWord() {
        let article = article()
        let library = library()
        library.add(article)
        library.updateProgress(article.id, ReadingProgress(sentence: 0, word: 3, fraction: 0.99))
        #expect(library.item(article.id)?.isFinished == false)
        let session = ReadingSession(article: article, library: library, settings: settings(), engine: FakeEngine())
        defer { session.close() }
        #expect(session.word == 3)
        #expect(session.elapsed > 0)
    }

    @Test func repeatedPlayDoesNotRestartTheCurrentSentence() async throws {
        let session = ReadingSession(article: article(), library: nil, settings: settings(), engine: FakeEngine())
        defer { session.close() }
        session.play()
        let deadline = ContinuousClock.now + .seconds(5)
        while session.elapsed < 0.4, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(session.elapsed >= 0.4)
        let elapsed = session.elapsed
        session.play()
        #expect(session.state == .playing)
        #expect(session.elapsed >= elapsed)
    }

    @Test func invalidRateNeverEntersTheAudioGraphOrSettings() {
        let settings = settings()
        let session = ReadingSession(article: article(), library: nil, settings: settings, engine: FakeEngine())
        defer { session.close() }
        session.rate = 1.5
        session.rate = .nan
        #expect(session.rate == 1.5)
        session.rate = .infinity
        #expect(session.rate == 1.5)
        #expect(settings.rate == 1.5)
    }
    @Test func elapsedTimeNotifiesTheReaderBetweenWordChanges() async throws {
        let session = ReadingSession(article: article(), library: nil, settings: settings(), engine: FakeEngine())
        defer { session.close() }
        session.rate = 0.5
        session.play()
        let deadline = ContinuousClock.now + .seconds(5)
        while session.elapsed < 0.05, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(session.state == .playing)
        let changed = Mutex(false)
        let word = session.word
        withObservationTracking { _ = session.elapsed } onChange: { changed.withLock { $0 = true } }
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.word == word)
        #expect(changed.withLock { $0 })
    }

    @Test(arguments: [false, true])
    func voiceChangePreservesCompletedArticle(restored: Bool) async throws {
        let article = article()
        let library = library()
        library.add(article)
        if restored {
            library.updateProgress(article.id, ReadingProgress(sentence: 0, word: nil, fraction: 1))
        }
        let session = ReadingSession(article: article, library: library, settings: settings(), engine: FakeEngine())
        defer { session.close() }
        if !restored {
            session.rate = 3
            session.play()
            let deadline = ContinuousClock.now + .seconds(5)
            while session.state != .finished, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(session.state == .finished)
        }
        session.setVoice(VoiceID(engine: .apple, identifier: "other"))
        #expect(session.state == .finished)
        #expect(session.fraction == 1)
        session.close()
        #expect(library.item(article.id)?.isFinished == true)
    }

}
