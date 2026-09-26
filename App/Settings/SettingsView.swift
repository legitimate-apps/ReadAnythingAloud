import ReadAloudKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(ReaderPreferences.self) private var prefs
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var keyStatus: String?
    @State private var checkingKey = false
    @State private var cacheSize: Int64 = 0

    var body: some View {
        @Bindable var prefs = prefs
        @Bindable var settings = model.settings
        Form {
            Section("Default voice") {
                LabeledContent("Voice", value: voiceName(settings.preferredVoice))
                if VoiceSettings.isKokoroAvailable {
                    switch settings.kokoroState {
                    case .ready:
                        Label("Natural voices downloaded", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    case .preparing:
                        KokoroPreparingLabel(settings: settings)
                    case .notDownloaded:
                        Button("Download natural voices (\(VoiceSettings.kokoroDownloadSize))") { Task { await settings.prepareKokoro() } }
                    case .failed(let message):
                        VStack(alignment: .leading) {
                            Text(message).font(.footnote).foregroundStyle(.red)
                            Button("Try Again") { Task { await settings.prepareKokoro() } }
                        }
                    }
                }
                Text("Pick a voice from the waveform button while reading. Articles that aren't in English use the best Apple voice for their language.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Reading") {
                Picker("Highlight", selection: $prefs.highlight) {
                    ForEach(ReaderStyle.HighlightMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Follow along while reading", isOn: $prefs.autoScroll)
                Picker("Font", selection: $prefs.typeface) {
                    ForEach(ReaderStyle.Typeface.allCases) { Text($0.label).tag($0) }
                }
                Picker("Theme", selection: $prefs.theme) {
                    ForEach(ReaderStyle.Theme.allCases) { Text($0.label).tag($0) }
                }
            }

            Section {
                // Field and its Save button share a row so an empty, disabled button never reads as a second field.
                HStack {
                    SecureField(settings.hasElevenLabsKey ? "New API key" : "API key", text: $apiKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .onSubmit { if canSaveKey { saveKey() } }
                        .accessibilityIdentifier("settings.elevenKey")
                    if checkingKey {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(settings.hasElevenLabsKey ? "Replace" : "Save") { saveKey() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(!canSaveKey)
                    }
                }
                if settings.hasElevenLabsKey {
                    Button("Remove Key", role: .destructive) {
                        settings.setElevenLabsKey(nil)
                        keyStatus = "Key removed."
                    }
                }
                if let keyStatus { Text(keyStatus).font(.footnote).foregroundStyle(.secondary) }
                Picker("Model", selection: $settings.elevenLabsModel) {
                    ForEach(ElevenLabsEngine.models, id: \.id) { Text($0.name).tag($0.id) }
                }
            } header: {
                Text("ElevenLabs (optional)")
            } footer: {
                Text("Your key stays in this device's Keychain. Sentences are sent to ElevenLabs and billed to your account at their per-character rates.")
            }

            Section("Storage") {
                LabeledContent("Cached audio", value: ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                Button("Clear Audio Cache") {
                    Task {
                        await ClipCache.shared.removeAll()
                        cacheSize = await ClipCache.shared.sizeInBytes()
                    }
                }
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                Link("Source code (MIT)", destination: URL(string: "https://github.com/legitimate-apps/ReadAnythingAloud")!)
                Text("Kokoro-82M (Apache-2.0) via FluidAudio (Apache-2.0) and ONNX Runtime (MIT). Article extraction by Mozilla Readability (Apache-2.0).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .modifier(OpaqueTopEdge())
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        #else
        .frame(minWidth: 480, minHeight: 520)
        #endif
        .task { cacheSize = await ClipCache.shared.sizeInBytes() }
    }

    private var canSaveKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespaces).isEmpty && !checkingKey
    }

    private func voiceName(_ voice: VoiceID) -> String {
        switch voice.engine {
        case .kokoro: KokoroEngine.catalog.first { $0.id == voice }?.name.appending(" · Natural") ?? "Natural"
        case .apple: voice.identifier.isEmpty ? "Apple (automatic)" : "Apple"
        case .elevenLabs: "ElevenLabs"
        }
    }

    private func saveKey() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        checkingKey = true
        keyStatus = nil
        Task {
            let probe = ElevenLabsEngine(keyProvider: { key })
            do {
                let voices = try await probe.fetchVoices()
                model.settings.setElevenLabsKey(key)
                keyStatus = "Key saved · \(voices.count) voices available."
                apiKey = ""
            } catch {
                keyStatus = "That key didn't work: \(error.localizedDescription)"
            }
            checkingKey = false
        }
    }
}

#if os(iOS)
/// On iOS 26 the soft scroll-edge effect leaves rows legible behind the sheet's title; a hard edge hides them.
private struct OpaqueTopEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            content
        }
    }
}
#endif
