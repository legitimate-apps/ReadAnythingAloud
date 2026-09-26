import ReadAloudKit
import SwiftUI
import WebKit

/// URL / text entry.
struct AddArticleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…", text: $input, axis: .vertical)
                        .lineLimit(1...8)
                        .focused($focused)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .onSubmit(submit)
                        .accessibilityIdentifier("add.input")
                } footer: {
                    Text("Paste a web address, or paste the text of an article to read it as-is.")
                }
                Section {
                    PasteButton(payloadType: String.self) { strings in
                        if let first = strings.first {
                            input = first
                            submit()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Article")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: submit)
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("add.confirm")
                }
            }
            .onAppear { focused = true }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 260)
        #endif
    }

    private func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        dismiss()
        model.add(input: text)
    }
}

/// Explains why an article couldn't be read and offers the ways forward.
struct AddFailureSheet: View {
    let failure: AppModel.AddFailure
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.signature)
            Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text(failure.error.localizedDescription)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) {
                if failure.canOpenPage, let url = failure.url {
                    Button {
                        dismiss()
                        model.webPage = .init(url: url)
                    } label: {
                        Label("Open the page to sign in or verify", systemImage: "safari").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.signature)
                    .accessibilityIdentifier("failure.openPage")
                }
                if failure.canReadWholePage, let url = failure.url {
                    Button {
                        dismiss()
                        model.add(url: url, mode: .wholePage)
                    } label: {
                        Label("Read the whole page anyway", systemImage: "doc.plaintext").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("failure.wholePage")
                }
                Button {
                    dismiss()
                    model.isPresentingAdd = true
                } label: {
                    Label("Paste the text instead", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button("Cancel", role: .cancel) { dismiss() }
                    .padding(.top, 4)
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(maxWidth: 440)
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("failure.sheet")
    }

    private var title: String {
        switch failure.error as? ExtractionError {
        case .notReadable(let reason, _, _): reason == nil ? "No article found" : "This page is blocked"
        case .httpStatus(let code) where code == 401 || code == 403: "This page is blocked"
        case .httpStatus(let code) where code == 404 || code == 410: "Page not found"
        case .timedOut: "The page took too long"
        case .invalidURL: "That's not a link"
        default: "Couldn't load the page"
        }
    }

    private var icon: String {
        switch failure.error as? ExtractionError {
        case .notReadable(let reason, _, _): reason == nil ? "doc.text.magnifyingglass" : "lock.doc"
        case .invalidURL: "link"
        case .httpStatus(let code) where code == 404 || code == 410: "questionmark.circle"
        default: "wifi.exclamationmark"
        }
    }
}

/// Shows the real page so the user can log in or pass a check, then reads what's on screen.
struct WebPageSheet: View {
    let request: AppModel.WebPageRequest
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var box = WKWebViewBox(ArticleExtractor.makeWebView())
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            WebViewRepresentable(webView: box.webView, url: request.url)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottom) {
                    if let error {
                        Text(error)
                            .font(.footnote)
                            .padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .padding()
                    }
                }
                .navigationTitle(request.url.host() ?? "Page")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            working = true
                            Task {
                                let failure = await model.addFromWebView(box, url: box.webView.url ?? request.url)
                                working = false
                                if let failure { error = failure.localizedDescription } else { dismiss() }
                            }
                        } label: {
                            if working { ProgressView() } else { Text("Read This Page") }
                        }
                        .disabled(working)
                        .accessibilityIdentifier("webpage.read")
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 800, minHeight: 700)
        #endif
    }
}

#if os(iOS)
struct WebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        webView.load(URLRequest(url: url))
        return webView
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#else
struct WebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView
    let url: URL
    func makeNSView(context: Context) -> WKWebView {
        webView.load(URLRequest(url: url))
        return webView
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#endif
