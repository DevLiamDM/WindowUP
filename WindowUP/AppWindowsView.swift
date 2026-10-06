import SwiftUI
import AppKit

final class AppPinManager: ObservableObject {
    static let shared = AppPinManager()

    @Published var windows: [AppWindowInfo] = []
    @Published var lastError: String?
    @Published var accessibilityOK: Bool = false
    @Published var screenRecordingOK: Bool = false

    private var timer: Timer?
    private var retainCount = 0
    private let pinning = WindowPinning.shared

    /// Timer condiviso tra i tab: parte con il primo retain, si ferma all'ultimo release.
    func retainRefresh() {
        retainCount += 1
        if timer == nil { startAutoRefresh() }
        else { refresh() }
    }

    func releaseRefresh() {
        retainCount = max(0, retainCount - 1)
        if retainCount == 0 { stopAutoRefresh() }
    }

    func startAutoRefresh() {
        stopAutoRefresh()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        if let t = timer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        accessibilityOK = pinning.isAccessibilityTrusted()
        screenRecordingOK = CGPreflightScreenCaptureAccess()
        WatchdogManager.shared.refreshTrust()
        HotkeyManager.shared.refreshTrust()
        let list = pinning.listWindows()
        self.windows = list
        // Nota onesta: il vero always-on-top interattivo cross-process è bloccato da macOS 15/26
        // (CGSSetWindowLevel no-op verificato su 26.2). Offriamo sticker live via ScreenCaptureKit.
    }

    // MARK: - Apertura app

    func openTerminal() { pinning.launchApp(bundleID: "com.apple.Terminal", fallbackName: "Terminal") }
    func openVSCode() { pinning.launchApp(bundleID: "com.microsoft.VSCode", fallbackName: "Visual Studio Code") }
    func openNotes() { pinning.launchApp(bundleID: "com.apple.Notes", fallbackName: "Notes") }
    func openActivityMonitor() { pinning.launchApp(bundleID: "com.apple.ActivityMonitor", fallbackName: "Activity Monitor") }

    func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedFileTypes = ["app"]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Apri"
        if panel.runModal() == .OK, let url = panel.url {
            let cfg = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: url, configuration: cfg, completionHandler: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.refresh()
            }
        }
    }

    func activate(_ w: AppWindowInfo) {
        pinning.activate(pid: w.ownerPID)
    }

    func preview(_ w: AppWindowInfo) {
        MirrorManager.shared.createMirror(for: w)
    }

    /// Overlay già in Extra-sopra per i giochi fullscreen.
    func previewBoosted(_ w: AppWindowInfo) {
        MirrorManager.shared.createMirror(for: w, boosted: true)
    }

    func openWhatsApp() { pinning.launchApp(named: "WhatsApp") }
}

struct AppWindowsView: View {
    @StateObject private var manager = AppPinManager.shared
    @StateObject private var mirrors = MirrorManager.shared
    @StateObject private var terminals = TerminalManager.shared
    @StateObject private var yabai = YabaiManager.shared
    @StateObject private var hotkey = HotkeyManager.shared
    private var pinning: WindowPinning { WindowPinning.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                honestBanner
                permissions
                callOverlayGuide
                quickLaunch
                embeddedTerminalSection
                yabaiPinSection
                yabaiGuide
                activeMirrors
                windowList
            }
            .padding(20)
        }
        .onAppear { manager.retainRefresh() }
        .onDisappear { manager.releaseRefresh() }
    }

    private var honestBanner: some View {
        GroupBox("App native: come funziona (metodo Floaty, senza Recovery)") {
            VStack(alignment: .leading, spacing: 4) {
                Text("macOS non lascia spostare la finestra di un'altra app sopra le altre. WindowUP usa il metodo Floaty: mirror live 60fps sopra tutto + click passthrough alla finestra vera.")
                    .font(.callout)
                Text("Clicchi il mirror e usi la finestra vera: il click arriva a lei, poi scrivi, trascini la barra per spostarla e navighi normalmente. Quando clicchi altrove, il mirror ricompare sopra. Richiede solo Registrazione schermo + Accessibilità. Niente SIP, niente Recovery.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(4)
        }
    }

    private var callOverlayGuide: some View {
        GroupBox("Videochiamate sopra i giochi (WhatsApp, Meet…)") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Le videochiamate NON vivono nei pannelli web: WKWebView su macOS non ha accesso a camera/microfono (limite Apple). Procedura corretta: chiamata nell'app nativa + overlay live sopra il gioco.")
                    .font(.callout)
                HStack(spacing: 8) {
                    Button("Apri WhatsApp") { manager.openWhatsApp() }.buttonStyle(.borderedProminent)
                    Button("Aggiorna lista") { manager.refresh() }.font(.caption)
                }
                HStack(spacing: 8) {
                    Text("Tasto globale ⌃⌥⌘M: salta tra gioco e chiamata").font(.caption)
                    Spacer()
                    if hotkey.accessibilityOK {
                        Text(hotkey.monitorInstalled ? "attivo ✓" : "in attesa…").font(.caption).foregroundStyle(.green)
                    } else {
                        Button("Abilita…") { pinning.promptAccessibility() }.buttonStyle(.link).font(.caption)
                    }
                }
                Text("Premi una volta: vai alla chiamata. Ripremi: torni al gioco. Funziona anche a tutto schermo, senza riavvii né SIP.")
                    .font(.caption2).foregroundStyle(.secondary)
                ForEach([
                    "1. Avvia la videochiamata nell'app WhatsApp nativa (camera e microfono funzionano lì).",
                    "2. Qui sotto, sulla finestra della chiamata, premi “Fissa sopra”.",
                    "3. Il mirror resta sopra il gioco: cliccalo e si apre la chiamata vera (a lag zero); quando torni al gioco, il mirror ricompare.",
                    "4. Audio e microfono passano dall'app nativa; per chiudere usa “Sblocca”."
                ], id: \.self) { step in
                    Text(step).font(.caption).foregroundStyle(.secondary)
                }
                Text("Nota: i giochi in fullscreen esclusivo (display-capture) non ammettono overlay di nessuno — usa la modalità finestra senza bordi.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(4)
        }
    }

    private var yabaiGuide: some View {
        GroupBox("Pin vero di qualsiasi app — via yabai (avanzato)") {
            VStack(alignment: .leading, spacing: 6) {
                Text("L'unico modo per tenere davvero sopra una finestra altrui e interattiva (VS Code, Packet Tracer…) è yabai, che si inietta nel Dock: richiede di allentare parzialmente SIP. Procedura:")
                    .font(.callout)
                ForEach([
                    "1. Installa: brew install koekeishiya/formulae/yabai",
                    "2. Riavvia in Recovery (tieni premuto il tasto di accensione), apri Terminale e dai: csrutil enable --without fs --without debug --without nvram",
                    "3. Riavvia normale e dai: nvram boot-args=-arm64e_preview_abi (Apple Silicon) + sudo yabai --load-sa",
                    "4. Avvia il servizio: yabai --start-service (oppure tienilo aperto in un Terminale)",
                    "5. Fissa la finestra: selezionala qui sopra e premi Fissa davvero (yabai: sub-layer above)"
                ], id: \.self) { step in
                    Text(step).font(.caption).textSelection(.enabled)
                }
                Text("Contro: va rifatto/ricontrollato a ogni aggiornamento macOS e abbassa una protezione di sistema. Guida ufficiale: github.com/koekeishiya/yabai/wiki")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(4)
        }
    }

    private var permissions: some View {
        GroupBox("Permessi") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Circle().fill(manager.screenRecordingOK ? .green : .red).frame(width: 8, height: 8)
                    Text(manager.screenRecordingOK ? "Registrazione schermo: OK (sticker live attivi)" : "Registrazione schermo: da abilitare (serve per gli sticker live)")
                        .font(.caption)
                    Spacer()
                    Button("Apri Impostazioni") { pinning.openScreenRecordingSettings() }.buttonStyle(.link).font(.caption)
                }
                if !manager.windows.isEmpty && !pinning.hasWindowTitles(in: manager.windows) {
                    Text("Titoli nascosti: abilita Registrazione schermo per WindowUP! e premi Aggiorna.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let err = manager.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                Text("Accessibilità non più richiesta: il watchdog è stato rimosso (macOS lo rende inefficace).")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(4)
        }
    }

    private var quickLaunch: some View {
        GroupBox("Apri app") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button("Terminale") { manager.openTerminal(); later() }.buttonStyle(.bordered)
                    Button("VS Code") { manager.openVSCode(); later() }.buttonStyle(.bordered)
                    Button("Note") { manager.openNotes(); later() }.buttonStyle(.bordered)
                    Button("Monitoraggio Attività") { manager.openActivityMonitor(); later() }.buttonStyle(.bordered)
                    Button("Scegli app…") { manager.chooseApp() }
                    Spacer()
                    Button("Aggiorna lista") { manager.refresh() }.font(.caption)
                }
                Text("Apri l'app, poi premi Anteprima live dalla lista qui sotto. L'anteprima resta sopra Chrome/Safari; per scriverci premi Vai alla finestra.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(4)
        }
    }

    private var embeddedTerminalSection: some View {
        GroupBox("Terminale integrato — resta sopra davvero") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button("Apri terminale") { terminals.openTerminal() }.buttonStyle(.borderedProminent)
                    Text("\(terminals.sessions.count) aperti").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                if !terminals.sessions.isEmpty {
                    ForEach(terminals.sessions) { s in
                        HStack {
                            Circle().fill(s.alive ? .green : .gray).frame(width: 8, height: 8)
                            Text("zsh • \(s.sizeLabel)").font(.caption)
                            Spacer()
                            Button("Mostra") { terminals.focus(s) }.buttonStyle(.link)
                            Button("Chiudi", role: .destructive) { terminals.close(s) }.buttonStyle(.link)
                        }.font(.caption)
                    }
                }
                Text("Shell vera dentro WindowUP: resta sopra garantito perché è finestra nostra. Spostabile, ridimensionabile, Ctrl+C / Ctrl+Z funzionano.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(4)
        }
    }

    private var yabaiPinSection: some View {
        GroupBox("Pin vero — via yabai") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(yabai.isInstalled ? .green : .gray).frame(width: 8, height: 8)
                    Text(yabai.isInstalled ? "yabai installato" : "yabai non installato").font(.caption.bold())
                    Spacer()
                    Button("Ricontrolla") {
                        yabai.locate()
                        yabai.fetchSIPStatus()
                    }.buttonStyle(.link).font(.caption)
                    if !yabai.pinnedIDs.isEmpty {
                        Button("Sblocca tutte", role: .destructive) { yabai.unpinAll() }.buttonStyle(.link).font(.caption)
                    }
                }
                HStack(spacing: 6) {
                    Circle().fill(saColor).frame(width: 8, height: 8)
                    Text(saText).font(.caption)
                }
                HStack(spacing: 6) {
                    Circle().fill(.gray).frame(width: 8, height: 8)
                    Text("SIP: \(yabai.sipStatus)").font(.caption).textSelection(.enabled)
                }
                if yabai.saOK == false {
                    HStack(spacing: 8) {
                        Button("Copia comando di sblocco") { yabai.copySALoadCommand() }.buttonStyle(.borderedProminent)
                        Text("Incollalo nel Terminale, Invio, password del Mac. Se fallisce: passo Recovery nella guida sotto.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !yabai.lastMessage.isEmpty {
                    Text(yabai.lastMessage).font(.caption).foregroundStyle(yabai.lastOK ? .green : .red)
                }
                if !yabai.isInstalled {
                    Text("Installazione in corso o mancante: vedi guida sotto.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if yabai.pinnedIDs.isEmpty {
                    Text("Usa il bottone Fissa a fianco di una finestra qui sotto: resta sopra davvero finché non la sblocchi.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(4)
        }
    }

    private var saColor: Color {
        guard let ok = yabai.saOK else { return .orange }
        return ok ? .green : .red
    }

    private var saText: String {
        switch yabai.saOK {
        case nil: return "Scripting-addition: non verificata — premi “Fissa davvero” su una finestra per testarla"
        case true?: return "Scripting-addition: attiva ✓ — il pin vero funziona"
        case false?: return "Scripting-addition: MANCANTE — “Fissa davvero” fallisce finché non la carichi"
        }
    }

    private var activeMirrors: some View {
        GroupBox("Finestre fissate sopra (\(mirrors.mirrors.count))") {
            VStack(spacing: 6) {
                if mirrors.mirrors.isEmpty {
                    Text("Nessuna finestra fissata. Premi “Fissa sopra” su una finestra qui sotto: resta visibile mentre usi altre app, cliccala per usarla vera.")
                        .font(.callout).foregroundStyle(.secondary).padding(4)
                } else {
                    ForEach(mirrors.mirrors) { m in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("📌 \(m.titleSnapshot)").font(.headline).lineLimit(1)
                                    Text(mirrors.statusText(for: m.id)).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Mostra") { mirrors.focus(id: m.id) }.buttonStyle(.link)
                                Button("Usa vera") { mirrors.goToRealWindow(m) }.buttonStyle(.link)
                                Button("Sblocca", role: .destructive) { mirrors.close(id: m.id) }.buttonStyle(.link)
                            }.font(.caption)
                            Toggle(m.clickThrough ? "Solo vista (click passanti, per giochi)" : "Interattivo (click/scrittura sul mirror)",
                                   isOn: Binding(
                                    get: { m.clickThrough },
                                    set: { v in var u = m; u.clickThrough = v; mirrors.update(u) }
                                   )).font(.caption2)
                                .help("Interattivo: clicchi il mirror e usi la finestra vera (scrivere, trascinare, navigare). Solo vista: i click passano oltre, mai focus (per overlay sui giochi).")
                        }
                        Divider()
                    }
                    HStack {
                        Button("Sblocca tutte", role: .destructive) { mirrors.closeAll() }.font(.caption)
                        Spacer()
                    }
                }
                if mirrors.needsScreenRecording {
                    Text("Abilita Registrazione schermo per WindowUP! in Impostazioni di Sistema, poi riprova.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let err = mirrors.lastError {
                    Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }.padding(4)
        }
    }

    private var windowList: some View {
        GroupBox("Finestre sullo schermo (\(manager.windows.count))") {
            VStack(spacing: 0) {
                if manager.windows.isEmpty {
                    Text("Nessuna finestra trovata. Apri Terminale o VS Code e premi Aggiorna lista.")
                        .font(.callout).foregroundStyle(.secondary).padding()
                } else {
                    ForEach(manager.windows) { w in
                        windowRow(w)
                        Divider()
                    }
                }
            }.padding(4)
        }
    }

    private func windowRow(_ w: AppWindowInfo) -> some View {
        HStack(spacing: 10) {
            appIcon(pid: w.ownerPID)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(w.ownerName).font(.headline)
                Text(windowSubtitle(w)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text("\(Int(w.bounds.width))×\(Int(w.bounds.height)) • id \(w.windowNumber)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(spacing: 4) {
                if w.bundleID == "com.apple.Terminal" {
                    Button("Terminale sempre sopra") { terminals.openTerminal() }.buttonStyle(.borderedProminent)
                        .help("Apre il terminale integrato di WindowUP (vera shell zsh): resta sopra a tutto ed è interattivo, come il mini player dei siti")
                }
                if isMirrored(w) {
                    Button("Fissata ✓") { if let m = mirrors.mirrors.first(where: { $0.windowNumber == w.windowNumber }) { mirrors.close(id: m.id) } }.buttonStyle(.bordered)
                        .help("Premi per sbloccare")
                } else {
                    Button("Fissa sopra") { manager.preview(w) }.buttonStyle(.borderedProminent)
                        .help("Mirror live 60fps sempre sopra (metodo Floaty). Cliccalo per usare la finestra vera, senza Recovery/SIP.")
                }
                Button("Fissa + Extra") { manager.previewBoosted(w) }.buttonStyle(.bordered)
                    .help("Come sopra ma già in Extra-sopra (tenta anche sopra i giochi fullscreen)")
                if yabai.isInstalled {
                    let yid = yabai.match(w).map(\.id)
                    if let yid = yid, yabai.isPinned(yabaiID: yid) {
                        Button("Fissata ✓") { yabai.toggle(w) }.buttonStyle(.bordered)
                    } else {
                        Button(yid == nil ? "Fissa (n/d)" : "Fissa davvero") { yabai.toggle(w) }.buttonStyle(.borderedProminent)
                    }
                }
                Button("Attiva") { manager.activate(w) }.buttonStyle(.link)
            }.font(.caption)
        }
        .padding(.vertical, 6)
    }

    private func isMirrored(_ w: AppWindowInfo) -> Bool {
        mirrors.mirrors.contains { $0.windowNumber == w.windowNumber }
    }

    private func windowSubtitle(_ w: AppWindowInfo) -> String {
        let t = w.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        if let b = w.bundleID { return b }
        return "pid \(w.ownerPID)"
    }

    private func appIcon(pid: pid_t) -> Image {
        if let ns = pinning.icon(forPID: pid) {
            return Image(nsImage: ns)
        }
        return Image(systemName: "app.window.on.rectangle")
    }

    private func later() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            manager.refresh()
        }
    }
}
