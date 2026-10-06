import SwiftUI
import WebKit

/// Holder osservabile: tiene la WKWebView viva e offre back/forward/reload al toolbar SwiftUI.
final class WebViewHolder: NSObject, ObservableObject {
    let webView: WKWebView
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var currentURLString = ""
    private var lastLoadedURLString = ""

    override init() {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        // User-Agent Safari desktop: indispensabile per WhatsApp Web / Gmail / Spotify
        let baseUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)"
        let fullUA = baseUA + " Version/17.4 Safari/605.1.15"

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = fullUA
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsMagnification = true
        self.webView = wv
        super.init()

        wv.addObserver(self, forKeyPath: #keyPath(WKWebView.canGoBack), options: .new, context: nil)
        wv.addObserver(self, forKeyPath: #keyPath(WKWebView.canGoForward), options: .new, context: nil)
        wv.addObserver(self, forKeyPath: #keyPath(WKWebView.isLoading), options: .new, context: nil)
        wv.addObserver(self, forKeyPath: #keyPath(WKWebView.url), options: .new, context: nil)
    }

    deinit {
        webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.canGoBack))
        webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.canGoForward))
        webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.isLoading))
        webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.url))
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async {
            self.canGoBack = self.webView.canGoBack
            self.canGoForward = self.webView.canGoForward
            self.isLoading = self.webView.isLoading
            self.currentURLString = self.webView.url?.absoluteString ?? ""
        }
    }

    func load(_ urlString: String) {
        var s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s) else { return }
        if url.absoluteString == lastLoadedURLString { return }
        lastLoadedURLString = url.absoluteString
        webView.load(URLRequest(url: url))
    }
}

struct FloatingWebView: NSViewRepresentable {
    @ObservedObject var holder: WebViewHolder
    var initialURL: String

    func makeNSView(context: Context) -> WKWebView {
        holder.webView.navigationDelegate = context.coordinator
        holder.webView.uiDelegate = context.coordinator
        holder.load(initialURL)
        return holder.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        // Apri window.open / target=_blank nella stessa vista (evita finestre perse)
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
    }
}

/// Contenuto di ogni pannello flottante: toolbar + webview.
struct FloatingPanelContentView: View {
    @ObservedObject var manager: PanelManager
    let itemID: UUID
    @StateObject private var holder = WebViewHolder()
    @State private var addressText: String = ""
    @State private var showSettings = false

    private var item: PinnedItem {
        manager.items.first(where: { $0.id == itemID })
            ?? PinnedItem(title: "WindowUP", urlString: "https://www.google.com")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: { holder.webView.goBack() }) {
                    Image(systemName: "chevron.left")
                }.disabled(!holder.canGoBack)
                Button(action: { holder.webView.goForward() }) {
                    Image(systemName: "chevron.right")
                }.disabled(!holder.canGoForward)
                Button(action: { holder.webView.reload() }) {
                    Image(systemName: holder.isLoading ? "xmark" : "arrow.clockwise")
                }

                TextField("Indirizzo…", text: $addressText, onCommit: {
                    var updated = item
                    updated.urlString = addressText
                    manager.update(updated, reloadWebView: true)
                    holder.load(addressText)
                })
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))

                Button(action: { showSettings.toggle() }) {
                    Image(systemName: "slider.horizontal.3")
                }.popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    panelSettings
                        .padding(12)
                        .frame(width: 260)
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            FloatingWebView(holder: holder, initialURL: item.urlString)
        }
        .onAppear {
            addressText = item.urlString
            holder.load(item.urlString)
        }
        .onChange(of: holder.currentURLString) { newValue in
            if !newValue.isEmpty { addressText = newValue }
        }
        .onChange(of: item.urlString) { newValue in
            holder.load(newValue)
            addressText = newValue
        }
    }

    private var panelSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pannello: \(item.title)").font(.headline).lineLimit(1)
            VStack(alignment: .leading) {
                Text("Opacità: \(Int(item.opacity * 100))%").font(.caption)
                Slider(value: Binding(
                    get: { item.opacity },
                    set: { v in var u = item; u.opacity = v; manager.update(u) }
                ), in: 0.3...1.0)
            }
            Toggle("Sempre sopratutto (anche su fullscreen)", isOn: Binding(
                get: { item.levelBoosted },
                set: { v in var u = item; u.levelBoosted = v; manager.update(u) }
            )).font(.caption)
                .help("Il pannello resta già sopra Desktop e Spaces. Attivalo per i giochi fullscreen.")
            Toggle("Visibile in tutti gli Spaces", isOn: Binding(
                get: { item.joinAllSpaces },
                set: { v in var u = item; u.joinAllSpaces = v; manager.update(u) }
            )).font(.caption)
                .help("Sempre attivo per gli overlay.")
            Text("Non ruba il focus: gioca o naviga sotto, il pannello resta sopra. Clicca dentro solo per scrivere.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                ForEach(PinSize.allCases) { s in
                    Button(s.rawValue) {
                        var u = item
                        u.width = Double(s.size.width); u.height = Double(s.size.height)
                        manager.update(u)
                    }.buttonStyle(.link).font(.caption)
                }
            }
            Text("Trascina dalla barra del titolo per spostare. Trascina gli angoli per ridimensionare.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
