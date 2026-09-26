import AVFoundation
import ReadAloudKit
import SwiftUI

/// Chooses the voice for the open article (and the default for future ones).
struct VoicePicker: View {
    let session: ReadingSession
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var appleVoices: [VoiceInfo] = []
    @State private var elevenVoices: [VoiceInfo] = []
    @State private var elevenError: String?
    @State private var previewer = VoicePreviewer()
    @State private var showAllAppleVoices = false

    private var settings: VoiceSettings { model.settings }
    private var language: String { session.document.language ?? "en" }
    private var isEnglish: Bool { language.lowercased().hasPrefix("en") }

    var body: some View {
        NavigationStack {
            List {
                if isEnglish, VoiceSettings.isKokoroAvailable {
                    Section {
                        kokoroStatus
                        ForEach(KokoroEngine.catalog, id: \.id) { voice in
                            row(voice)
                        }
                    } header: {
                        Text("Natural voices · on device")
                    } footer: {
                        Text("Kokoro runs entirely on this device. It's free, private and works offline once downloaded.")
                    }
                }
                Section {
                    let voices = filteredAppleVoices
                    ForEach(voices) { row($0) }
                    if voices.count < appleVoices.count {
                        Button(showAllAppleVoices ? "Show voices for this article's language" : "Show all languages") {
                            showAllAppleVoices.toggle()
                        }
                    }
                } header: {
                    Text("Apple voices")
                } footer: {
                    #if os(macOS)
                    Text("Add higher-quality Enhanced and Premium voices in System Settings › Accessibility › Spoken Content › System Voice.")
                    #else
                    Text("For the most natural sound, download an Enhanced or Premium voice in Settings › Accessibility › Spoken Content › Voices.")
                    #endif
                }
                Section {
                    if settings.hasElevenLabsKey {
                        if let elevenError {
                            Text(elevenError).font(.footnote).foregroundStyle(.secondary)
                        } else if elevenVoices.isEmpty {
                            HStack { ProgressView(); Text("Loading voices…").foregroundStyle(.secondary) }
                        }
                        ForEach(elevenVoices) { row($0) }
                    } else {
                        Button("Add an ElevenLabs API key…") {
                            dismiss()
                            model.isPresentingSettings = true
                        }
                    }
                } header: {
                    Text("ElevenLabs · cloud")
                } footer: {
                    Text("Uses your own ElevenLabs account; each sentence is sent to ElevenLabs and billed to your plan.")
                }
            }
            .navigationTitle("Voice")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                appleVoices = await settings.apple.voices()
                if settings.hasElevenLabsKey {
                    do { elevenVoices = try await settings.elevenLabs.fetchVoices() } catch { elevenError = error.localizedDescription }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
    }

    private var filteredAppleVoices: [VoiceInfo] {
        guard !showAllAppleVoices else { return appleVoices }
        let prefix = String(language.prefix(2)).lowercased()
        let matching = appleVoices.filter { $0.language.lowercased().hasPrefix(prefix) }
        return matching.isEmpty ? appleVoices : matching
    }

    @ViewBuilder private var kokoroStatus: some View {
        switch settings.kokoroState {
        case .ready:
            EmptyView()
        case .preparing:
            KokoroPreparingLabel(settings: settings)
        case .notDownloaded:
            Button {
                Task { await settings.prepareKokoro() }
            } label: {
                Label("Download natural voices (\(VoiceSettings.kokoroDownloadSize))", systemImage: "arrow.down.circle")
            }
        case .failed(let message):
            VStack(alignment: .leading) {
                Text("Download failed: \(message)").font(.footnote).foregroundStyle(.red)
                Button("Try Again") { Task { await settings.prepareKokoro() } }
            }
        }
    }

    private func row(_ voice: VoiceInfo) -> some View {
        let selected = session.voice == voice.id
        return HStack {
            Button {
                session.setVoice(voice.id)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(voice.name).foregroundStyle(.primary)
                        if let detail = voice.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark").foregroundStyle(Color.signature).fontWeight(.semibold)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                previewer.preview(voice, engine: settings.engine(for: voice.id.engine))
            } label: {
                Image(systemName: previewer.playing == voice.id ? "stop.circle" : "play.circle")
                    .font(.title3)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Preview \(voice.name)")
            .disabled(voice.id.engine == .kokoro && settings.kokoroState != .ready)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Plays a short sample of a voice.
@MainActor
@Observable
final class VoicePreviewer {
    private(set) var playing: VoiceID?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var task: Task<Void, Never>?

    func preview(_ voice: VoiceInfo, engine: any SpeechEngine) {
        task?.cancel()
        player?.stop()
        if playing == voice.id {
            playing = nil
            return
        }
        playing = voice.id
        let text = "Hi, I'm \(voice.name). This is how I'll sound reading your articles."
        task = Task {
            do {
                let request = SynthesisRequest(text: text, wordRanges: [], voice: voice.id)
                let clip = try await engine.synthesize(request)
                guard !Task.isCancelled else { return }
                let player = try AVAudioPlayer(data: Self.wav(clip.samples, sampleRate: clip.sampleRate))
                self.player = player
                player.play()
                try await Task.sleep(for: .seconds(clip.duration + 0.2))
                if playing == voice.id { playing = nil }
            } catch {
                if playing == voice.id { playing = nil }
            }
        }
    }

    static func wav(_ samples: [Float], sampleRate: Double) -> Data {
        var data = Data()
        func append<T>(_ v: T) { withUnsafeBytes(of: v) { data.append(contentsOf: $0) } }
        let pcm = samples.map { Int16(max(-1, min(1, $0)) * 32767) }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + pcm.count * 2).littleEndian)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16).littleEndian); append(UInt16(1).littleEndian)
        append(UInt16(1).littleEndian); append(UInt32(sampleRate).littleEndian); append(UInt32(sampleRate * 2).littleEndian)
        append(UInt16(2).littleEndian); append(UInt16(16).littleEndian)
        data.append(contentsOf: Array("data".utf8)); append(UInt32(pcm.count * 2).littleEndian)
        pcm.forEach { append($0.littleEndian) }
        return data
    }
}

/// "Downloading natural voices…" with a determinate bar once the engine reports progress.
struct KokoroPreparingLabel: View {
    let settings: VoiceSettings

    var body: some View {
        if let progress = settings.kokoroProgress, progress < 1 {
            VStack(alignment: .leading, spacing: 6) {
                Text("Downloading natural voices… \(Int(progress * 100))%")
                ProgressView(value: progress)
            }
        } else {
            HStack {
                ProgressView().controlSize(.small)
                Text(VoiceSettings.isKokoroDownloaded ? "Loading natural voices…" : "Downloading natural voices…")
            }
        }
    }
}
