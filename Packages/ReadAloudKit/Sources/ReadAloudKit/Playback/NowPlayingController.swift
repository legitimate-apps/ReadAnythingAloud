import Foundation
import MediaPlayer
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Lock screen / Control Center / menu bar Now Playing integration and remote commands (headphone buttons,
/// AirPods, keyboard media keys, CarPlay).
@MainActor
final class NowPlayingController {
    private weak var session: ReadingSession?
    private var targets: [(MPRemoteCommand, Any)] = []
    private var artwork: MPMediaItemArtwork?
    private var artworkURL: URL?

    func attach(_ session: ReadingSession) {
        detachCommands()
        self.session = session
        let center = MPRemoteCommandCenter.shared()

        func add(_ command: MPRemoteCommand, _ handler: @escaping (ReadingSession, MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            command.isEnabled = true
            let target = command.addTarget { [weak self] event in
                MainActor.assumeIsolated {
                    guard let session = self?.session else { return .noActionableNowPlayingItem }
                    return handler(session, event)
                }
            }
            targets.append((command, target))
        }

        add(center.playCommand) { s, _ in s.play(); return .success }
        add(center.pauseCommand) { s, _ in s.pause(); return .success }
        add(center.togglePlayPauseCommand) { s, _ in s.togglePlayPause(); return .success }
        add(center.nextTrackCommand) { s, _ in s.skipSentence(1); return .success }
        add(center.previousTrackCommand) { s, _ in s.skipSentence(-1); return .success }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
        add(center.skipForwardCommand) { s, _ in s.skip(seconds: 15); return .success }
        add(center.skipBackwardCommand) { s, _ in s.skip(seconds: -15); return .success }
        add(center.changePlaybackPositionCommand) { s, event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent, s.totalDuration > 0 else { return .commandFailed }
            s.seek(fraction: e.positionTime / s.totalDuration)
            return .success
        }
        center.changePlaybackRateCommand.supportedPlaybackRates = [0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]
        add(center.changePlaybackRateCommand) { s, event in
            guard let e = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            s.rate = e.playbackRate
            return .success
        }
        loadArtwork(for: session.article)
        update(from: session)
    }

    func detach(_ session: ReadingSession) {
        guard self.session === session else { return }
        detachCommands()
        self.session = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        #endif
    }

    private func detachCommands() {
        for (command, target) in targets { command.removeTarget(target) }
        targets.removeAll()
    }

    func update(from session: ReadingSession) {
        guard self.session === session else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: session.article.title,
            MPMediaItemPropertyArtist: session.article.byline ?? session.article.displayHost ?? "",
            MPMediaItemPropertyAlbumTitle: session.article.displayHost ?? "ReadAnythingAloud",
            MPMediaItemPropertyPlaybackDuration: session.totalDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: session.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: session.state == .playing ? Double(session.rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = switch session.state {
        case .playing, .buffering: .playing
        case .paused: .paused
        default: .stopped
        }
        #endif
    }

    private func loadArtwork(for article: Article) {
        let url = article.leadImageURL ?? article.blocks.lazy.compactMap { block -> URL? in
            if case .image(let url, _) = block.kind { return url }
            return nil
        }.first
        guard let url, url != artworkURL else { return }
        artworkURL = url
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let art = Self.artwork(from: data) else { return }
            guard let self, self.artworkURL == url else { return }
            self.artwork = art
            if let session = self.session { self.update(from: session) }
        }
    }

    /// Built outside the main actor on purpose: MediaPlayer calls the request handler on its own queue, and a
    /// closure formed in a main-actor context would trap on the executor check there.
    private nonisolated static func artwork(from data: Data) -> MPMediaItemArtwork? {
        #if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        #else
        guard let image = NSImage(data: data) else { return nil }
        #endif
        nonisolated(unsafe) let shared = image
        return MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in shared }
    }
}
