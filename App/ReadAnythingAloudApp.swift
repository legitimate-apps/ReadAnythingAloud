import AVFoundation
import ReadAloudKit
import SwiftUI

@main
struct ReadAnythingAloudApp: App {
    @State private var model = AppModel()
    @State private var prefs = ReaderPreferences.shared
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #endif

    init() {
        #if os(iOS)
        AudioSessionController.shared.configure()
        #endif
    }

    private var root: some View {
        RootView()
            .environment(model)
            .environment(prefs)
            .tint(.signature)
            .onAppear {
                #if os(iOS)
                AudioSessionController.shared.model = model
                ArticleExtractor.shared.hostView = {
                    UIApplication.shared.connectedScenes
                        .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                        .first
                }
                #endif
            }
    }

    var body: some Scene {
        #if os(macOS)
        // One library window: links opened from other apps land in it instead of spawning duplicates.
        Window("ReadAnythingAloud", id: "main") { root }
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Article…") { model.isPresentingAdd = true }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Add from Clipboard") {
                    if let text = NSPasteboard.general.string(forType: .string) { model.add(input: text) }
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            }
            CommandMenu("Playback") {
                Button("Play / Pause") { model.session?.togglePlayPause() }
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(model.session == nil)
                Divider()
                Button("Next Sentence") { model.session?.skipSentence(1) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Previous Sentence") { model.session?.skipSentence(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Next Paragraph") { model.session?.skipBlock(1) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                Button("Previous Paragraph") { model.session?.skipBlock(-1) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Divider()
                Button("Faster") { model.session.map { $0.rate = min(3.5, $0.rate + 0.25) } }
                    .keyboardShortcut("]", modifiers: .command)
                Button("Slower") { model.session.map { $0.rate = max(0.5, $0.rate - 0.25) } }
                    .keyboardShortcut("[", modifiers: .command)
            }
        }
        #else
        WindowGroup { root }
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(model)
                .environment(prefs)
        }
        #endif
    }
}

#if os(macOS)
import AppKit

/// URL-scheme and file opens reach `RootView.onOpenURL`; the delegate only keeps the app alive windowless.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
#endif

#if os(iOS)
/// Background audio, interruptions (calls, Siri) and route changes (headphones unplugged).
@MainActor
final class AudioSessionController {
    static let shared = AudioSessionController()
    weak var model: AppModel?

    func configure() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        try? session.setActive(true)
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated {
                guard let typeValue, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
                let session = AudioSessionController.shared.model?.session
                if type == .began {
                    session?.pause()
                } else if let optionsValue, AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume) {
                    try? AVAudioSession.sharedInstance().setActive(true)
                    session?.play()
                }
            }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
            let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                if let reasonValue, AVAudioSession.RouteChangeReason(rawValue: reasonValue) == .oldDeviceUnavailable {
                    AudioSessionController.shared.model?.session?.pause()
                }
            }
        }
    }
}
#endif
