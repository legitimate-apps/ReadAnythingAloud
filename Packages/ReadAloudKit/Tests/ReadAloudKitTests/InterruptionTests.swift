import Foundation
import Testing
@testable import ReadAloudKit

@MainActor
@Suite(.serialized)
struct InterruptionTests {
    func session(engine: any SpeechEngine = FakeEngine()) -> ReadingSession {
        let settings = VoiceSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.preferredVoice = VoiceID(engine: .apple, identifier: "")
        return ReadingSession(article: Article(title: "", language: "en", blocks: [
            Block(kind: .paragraph, text: "Alpha beta gamma delta.")
        ]), library: nil, settings: settings, engine: engine)
    }

    @Test func interruptionDoesNotStartAnIdleOrPreviouslyPausedArticle() {
        let s = session()
        defer { s.close() }
        s.interruptionBegan()
        s.interruptionEnded(shouldResume: true)
        #expect(s.state == .idle)
        s.play()
        s.pause()
        s.interruptionBegan()
        s.interruptionEnded(shouldResume: true)
        #expect(s.state == .paused)
    }

    @Test func interruptedBufferingResumesOnlyOnce() {
        let s = session()
        defer { s.close() }
        s.play()
        #expect(s.state == .buffering)
        s.interruptionBegan()
        s.interruptionBegan() // A repeated begin must not overwrite the original intent.
        #expect(s.state == .paused)
        s.interruptionEnded(shouldResume: true)
        #expect(s.isPlaying)
        s.pause()
        s.interruptionEnded(shouldResume: true)
        #expect(s.state == .paused)
    }

    @Test func explicitPauseOrNoResumeRevokesPendingPlayIntent() {
        let s = session()
        defer { s.close() }
        s.play()
        s.interruptionBegan()
        s.pause() // Includes headphone unplug and remote pause during the interruption.
        s.interruptionEnded(shouldResume: true)
        #expect(s.state == .paused)
        s.play()
        s.interruptionBegan()
        s.interruptionEnded(shouldResume: false)
        s.interruptionEnded(shouldResume: true)
        #expect(s.state == .paused)
    }

    @Test func interruptedAudioResumesFromItsPausedPosition() async throws {
        let s = session()
        defer { s.close() }
        s.play()
        let deadline = ContinuousClock.now + .seconds(8)
        while s.elapsed < 0.2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(s.state == .playing)
        let elapsed = s.elapsed
        s.interruptionBegan()
        #expect(s.state == .paused)
        try await Task.sleep(for: .milliseconds(100))
        #expect(s.elapsed == elapsed)
        s.interruptionEnded(shouldResume: true)
        #expect(s.state == .playing)
        #expect(s.elapsed >= elapsed)
    }

    @Test func replacementArticleDoesNotInheritInterruptedPlayback() {
        let old = session()
        old.play()
        old.interruptionBegan()
        old.close()
        let replacement = session()
        defer { replacement.close() }
        replacement.interruptionEnded(shouldResume: true)
        old.interruptionEnded(shouldResume: true)
        #expect(replacement.state == .idle)
        #expect(old.state == .idle)
    }
}
