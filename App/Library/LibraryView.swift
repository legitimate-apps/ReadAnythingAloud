import ReadAloudKit
import SwiftUI

/// Root: the library beside the reader (split view on Mac and iPad, a stack on iPhone).
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @State private var isDropTargeted = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibraryList()
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        } detail: {
            if let session = model.session {
                ReaderView(session: session)
                    .id(ObjectIdentifier(session))
            } else {
                EmptyReaderView()
            }
        }
        .onDrop(of: [.url, .fileURL, .plainText, .text], isTargeted: $isDropTargeted) { providers in
            model.handleDrop(providers)
        }
        .overlay {
            if isDropTargeted {
                DropHighlight()
            }
        }
        .overlay(alignment: .top) {
            if let adding = model.adding {
                AddingToast(label: adding.label)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.adding)
        .sheet(isPresented: $model.isPresentingAdd) {
            AddArticleSheet()
        }
        .sheet(item: $model.failure) { failure in
            AddFailureSheet(failure: failure)
        }
        .sheet(item: $model.webPage) { request in
            WebPageSheet(request: request)
        }
        #if os(iOS)
        .sheet(isPresented: $model.isPresentingSettings) {
            NavigationStack { SettingsView() }
        }
        #endif
        .onOpenURL { model.handleOpenURL($0) }
        #if os(iOS)
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { model.importSharedPages() }
        }
        #endif
    }
}

struct LibraryList: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var multiSelection = Set<UUID>()

    var body: some View {
        @Bindable var model = model
        let items = filtered
        List(selection: $model.selection) {
            if items.isEmpty, search.isEmpty {
                LibraryEmptyState()
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            ForEach(items) { item in
                LibraryRow(item: item, isCurrent: model.session?.article.id == item.id)
                    .tag(item.id)
                    .contextMenu {
                        if let url = item.sourceURL {
                            ShareLink(item: url)
                            Button("Reload Article", systemImage: "arrow.clockwise") { model.add(url: url, refresh: true) }
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) { model.delete([item.id]) }
                    }
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) { model.delete([item.id]) }
                    }
            }
        }
        .searchable(text: $search, prompt: "Search articles")
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.isPresentingAdd = true
                } label: {
                    Label("Add Article", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityIdentifier("library.add")
            }
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    model.isPresentingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            #endif
            ToolbarItem(placement: .automatic) {
                PasteButton(payloadType: String.self) { strings in
                    if let first = strings.first { model.add(input: first) }
                }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("library.paste")
            }
        }
        #if os(iOS)
        .safeAreaInset(edge: .bottom) {
            if let session = model.session, model.selection == nil {
                MiniPlayer(session: session)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
        }
        #endif
        #if os(macOS)
        .onDeleteCommand { if let id = model.selection { model.delete([id]) } }
        #endif
    }

    private var filtered: [ArticleSummary] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.library.items }
        return model.library.items.filter {
            $0.title.localizedCaseInsensitiveContains(q) || ($0.host?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }
}

struct LibraryRow: View {
    let item: ArticleSummary
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(3)
                HStack(spacing: 6) {
                    if isCurrent {
                        Image(systemName: "waveform").foregroundStyle(Color.signature).symbolEffect(.variableColor.iterative, options: .repeating)
                    }
                    if let host = item.host { Text(host) }
                    Text("·")
                    Text(Self.readingTime(item.wordCount))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let progress = item.progress, progress.fraction > 0.01 {
                    ProgressView(value: min(1, progress.fraction))
                        .tint(item.isFinished ? .green : .signature)
                        .scaleEffect(y: 0.6, anchor: .center)
                        .accessibilityLabel(item.isFinished ? "Finished" : "\(Int(progress.fraction * 100)) percent listened")
                }
            }
            Spacer(minLength: 0)
            if let image = item.leadImageURL {
                RemoteImage(url: image)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// Listening time at 1× (natural speech runs about 160 words per minute).
    static func readingTime(_ words: Int) -> String {
        let minutes = max(1, Int((Double(words) / 160).rounded()))
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }
}

struct LibraryEmptyState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.below.photo")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Color.signature)
            Text("Your library is empty").font(.headline)
            #if os(macOS)
            Text("Drop a link, a web page or a .webloc here, or press ⌘V to paste a URL.")
            #else
            Text("Tap + to add a link, paste one, or share a page from Safari to ReadAnythingAloud.")
            #endif
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

struct EmptyReaderView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .foregroundStyle(Color.signature.opacity(0.6))
                    .frame(width: 220, height: 150)
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Color.signature)
            }
            Text("Drop a link to have it read aloud")
                .font(.title3.weight(.semibold))
            Text("Or paste a URL, or pick an article from your library.")
                .foregroundStyle(.secondary)
            Button {
                model.isPresentingAdd = true
            } label: {
                Label("Add Article", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(.signature)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DropHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.signature, lineWidth: 3)
            .background(Color.signature.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                Label("Drop to read aloud", systemImage: "arrow.down.doc")
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
            }
            .padding(8)
            .allowsHitTesting(false)
    }
}

private struct AddingToast: View {
    let label: String
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Fetching \(label)…").font(.subheadline)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .accessibilityIdentifier("library.fetching")
    }
}

#if os(iOS)
/// Compact player shown over the library on iPhone while an article plays in the background.
struct MiniPlayer: View {
    @Bindable var session: ReadingSession
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.selection = session.article.id
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.article.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(session.document.string(for: session.document.sentences[min(session.sentence, max(session.document.sentences.count - 1, 0))].range))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                session.togglePlayPause()
            } label: {
                Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(session.isPlaying ? "Pause" : "Play")
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
    }
}
#endif
