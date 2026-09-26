import ReadAloudKit
import SwiftUI

struct ReaderView: View {
    @Bindable var session: ReadingSession
    @Environment(AppModel.self) private var model
    @Environment(ReaderPreferences.self) private var prefs
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @State private var follow = true
    @State private var showVoices = false
    @State private var showAppearance = false
    @State private var barHeight: CGFloat = 150

    var body: some View {
        let style = prefs.style(isDark: colorScheme == .dark)
        ZStack(alignment: .bottom) {
            ReaderTextView(
                document: session.document,
                style: style,
                configuration: ReaderTextConfiguration(
                    sentenceRange: session.currentSentenceRange,
                    wordRange: session.state == .idle && session.word == nil ? nil : session.currentWordRange,
                    follow: follow && prefs.autoScroll,
                    jumpCounter: session.jumpCounter,
                    bottomInset: barHeight + 12
                ),
                onTapWord: { word in
                    follow = true
                    session.play(fromWord: word)
                },
                onUserScroll: { follow = false }
            )
            .ignoresSafeArea(edges: .bottom)
            .background(Color(style.background))

            VStack(spacing: 10) {
                if let message = session.preparingMessage {
                    Banner(systemImage: "arrow.down.circle", text: message, showsProgress: true)
                } else if let error = session.errorMessage {
                    Banner(systemImage: "exclamationmark.triangle", text: error, showsProgress: false)
                }
                if !follow, prefs.autoScroll {
                    Button {
                        follow = true
                    } label: {
                        Label("Back to reading", systemImage: "text.line.first.and.arrowtriangle.forward")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .background(.thinMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityIdentifier("reader.backToReading")
                }
                PlayerBar(session: session, showVoices: $showVoices)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .frame(maxWidth: 720)
            .animation(.snappy(duration: 0.25), value: follow)
        }
        .preferredColorScheme(prefs.colorSchemeOverride)
        .navigationTitle(session.article.displayHost ?? session.article.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showAppearance = true
                } label: {
                    Label("Appearance", systemImage: "textformat.size")
                }
                .popover(isPresented: $showAppearance) {
                    AppearancePanel()
                        .environment(prefs)
                        .presentationCompactAdaptation(.popover)
                }
                if let url = session.article.sourceURL {
                    Menu {
                        Button("Open Original", systemImage: "safari") { openURL(url) }
                        ShareLink(item: url) { Label("Share Link", systemImage: "square.and.arrow.up") }
                        Button("Reload Article", systemImage: "arrow.clockwise") { model.add(url: url, mode: .article) }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showVoices) {
            VoicePicker(session: session)
                .environment(model)
        }
        .onChange(of: session.jumpCounter) { follow = true }
        .readerKeyboardShortcuts(session: session, prefs: prefs)
    }
}

private struct Banner: View {
    var systemImage: String
    var text: String
    var showsProgress: Bool

    var body: some View {
        HStack(spacing: 10) {
            if showsProgress {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: systemImage).foregroundStyle(Color.signature)
            }
            Text(text).font(.footnote).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Transport controls: scrubber, times, skip buttons, play/pause, speed and voice.
struct PlayerBar: View {
    @Bindable var session: ReadingSession
    @Binding var showVoices: Bool
    @State private var scrubbing: Double?
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(spacing: 6) {
            scrubber
            HStack(spacing: 0) {
                speedMenu
                Spacer(minLength: 4)
                transportButton("backward.end.fill", "Previous paragraph", size: 15) { session.skipBlock(-1) }
                    .accessibilityIdentifier("player.previousParagraph")
                transportButton("gobackward", "Previous sentence", size: 19) { session.skipSentence(-1) }
                    .accessibilityIdentifier("player.previousSentence")
                playButton
                transportButton("goforward", "Next sentence", size: 19) { session.skipSentence(1) }
                    .accessibilityIdentifier("player.nextSentence")
                transportButton("forward.end.fill", "Next paragraph", size: 15) { session.skipBlock(1) }
                    .accessibilityIdentifier("player.nextParagraph")
                Spacer(minLength: 4)
                Button {
                    showVoices = true
                } label: {
                    Image(systemName: "waveform")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Voice")
                .accessibilityIdentifier("player.voice")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.primary.opacity(0.06)))
        .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
    }

    private var scrubber: some View {
        VStack(spacing: 2) {
            Slider(value: Binding(
                get: { scrubbing ?? session.fraction },
                set: { scrubbing = $0 }
            ), in: 0...1) { editing in
                if !editing, let value = scrubbing {
                    session.seek(fraction: value)
                    scrubbing = nil
                }
            }
            .controlSize(.mini)
            .tint(Color.signature)
            .accessibilityLabel("Position")
            .accessibilityValue("\(Int(session.fraction * 100)) percent")
            .accessibilityIdentifier("player.scrubber")
            HStack {
                Text(Self.format(scrubbing.map { $0 * session.totalDuration } ?? session.elapsed))
                Spacer()
                if let scrubbing {
                    Text(preview(scrubbing)).lineLimit(1).truncationMode(.tail).frame(maxWidth: 220)
                    Spacer()
                }
                Text("-" + Self.format(session.remaining))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func preview(_ fraction: Double) -> String {
        let index = session.sentenceIndex(atFraction: fraction)
        let s = session.document.sentences[index]
        return session.document.string(for: s.range)
    }

    private var playButton: some View {
        Button {
            session.togglePlayPause()
        } label: {
            ZStack {
                Circle().fill(Color.signature.gradient).frame(width: 52, height: 52)
                if session.state == .buffering {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: session.isPlaying ? 0 : 2)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 60, height: 56)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(session.isPlaying ? "Pause" : "Play")
        .accessibilityIdentifier("player.playPause")
        .keyboardShortcut(.space, modifiers: [])
    }

    private func transportButton(_ symbol: String, _ label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: sizeClass == .compact ? 42 : 48, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.75, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0], id: \.self) { value in
                Button {
                    session.rate = Float(value)
                } label: {
                    if abs(Double(session.rate) - value) < 0.01 {
                        Label(Self.speedLabel(value), systemImage: "checkmark")
                    } else {
                        Text(Self.speedLabel(value))
                    }
                }
            }
        } label: {
            Text(Self.speedLabel(Double(session.rate)))
                .font(.system(size: 14, weight: .bold).monospacedDigit())
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Speed \(Self.speedLabel(Double(session.rate)))")
        .accessibilityIdentifier("player.speed")
    }

    static func speedLabel(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f×", value) : String(format: "%g×", value)
    }

    static func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Font, size, theme and highlight options.
struct AppearancePanel: View {
    @Environment(ReaderPreferences.self) private var prefs

    var body: some View {
        @Bindable var prefs = prefs
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button { prefs.fontSize = max(13, prefs.fontSize - 1) } label: {
                    Image(systemName: "textformat.size.smaller").frame(width: 44, height: 36)
                }
                .accessibilityLabel("Smaller text")
                Slider(value: $prefs.fontSize, in: 13...34, step: 1)
                Button { prefs.fontSize = min(34, prefs.fontSize + 1) } label: {
                    Image(systemName: "textformat.size.larger").frame(width: 44, height: 36)
                }
                .accessibilityLabel("Larger text")
            }
            Picker("Font", selection: $prefs.typeface) {
                ForEach(ReaderStyle.Typeface.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Theme", selection: $prefs.theme) {
                ForEach(ReaderStyle.Theme.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Highlight", selection: $prefs.highlight) {
                ForEach(ReaderStyle.HighlightMode.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Follow along while reading", isOn: $prefs.autoScroll)
        }
        .padding(20)
        .frame(minWidth: 320)
    }
}

private extension View {
    func readerKeyboardShortcuts(session: ReadingSession, prefs: ReaderPreferences) -> some View {
        background {
            Group {
                Button("") { session.skipSentence(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { session.skipSentence(1) }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { session.skipBlock(-1) }.keyboardShortcut(.leftArrow, modifiers: [.option])
                Button("") { session.skipBlock(1) }.keyboardShortcut(.rightArrow, modifiers: [.option])
                Button("") { session.rate = min(3.5, session.rate + 0.25) }.keyboardShortcut("]", modifiers: [])
                Button("") { session.rate = max(0.5, session.rate - 0.25) }.keyboardShortcut("[", modifiers: [])
                Button("") { prefs.fontSize = min(34, prefs.fontSize + 1) }.keyboardShortcut("+", modifiers: [.command])
                Button("") { prefs.fontSize = min(34, prefs.fontSize + 1) }.keyboardShortcut("=", modifiers: [.command])
                Button("") { prefs.fontSize = max(13, prefs.fontSize - 1) }.keyboardShortcut("-", modifiers: [.command])
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }
}
