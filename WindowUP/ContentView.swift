import SwiftUI
import AppKit
import Combine

struct ContentView: View {
    @EnvironmentObject var manager: PanelManager

    var body: some View {
        TabView {
            WebPinsView()
                .environmentObject(manager)
                .tabItem {
                    Label("Siti Web", systemImage: "globe")
                }
            AppWindowsView()
                .tabItem {
                    Label("App e Finestre", systemImage: "app.window.on.rectangle")
                }
        }
        .frame(minWidth: 600, minHeight: 640)
    }
}

struct WebPinsView: View {
    @EnvironmentObject var manager: PanelManager
    @StateObject private var appManager = AppPinManager.shared
    @StateObject private var yabai = YabaiManager.shared
    @State private var customTitle = ""
    @State private var customURL = ""
    @State private var selectedSize: PinSize = .square

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                customAdd
                presets
                activeApps
                openPanels
                footer
            }
            .padding(20)
        }
        .onAppear { appManager.retainRefresh() }
        .onDisappear { appManager.releaseRefresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in appManager.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in appManager.refresh() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 36))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("WindowUP!").font(.largeTitle.bold())
                Text("Fissa WhatsApp, Google, YouTube… sopra tutto. Sposta e ridimensiona liberamente.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            VStack {
                Button("Mostra tutte") { manager.showAll() }.buttonStyle(.link)
                Button("Nascondi tutte") { manager.hideAll() }.buttonStyle(.link)
            }.font(.caption)
        }
    }

    private var customAdd: some View {
        GroupBox("Nuova finestra pinnata") {
            VStack(spacing: 8) {
                HStack {
                    TextField("Titolo (es. WhatsApp)", text: $customTitle)
                        .textFieldStyle(.roundedBorder)
                    Picker("Misura", selection: $selectedSize) {
                        ForEach(PinSize.allCases) { s in Text(s.rawValue).tag(s) }
                    }.pickerStyle(.segmented).frame(width: 320)
                }
                HStack {
                    TextField("https://…  (es. web.whatsapp.com)", text: $customURL)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addCustom)
                    Button("Fissa sopra") { addCustom() }
                        .buttonStyle(.borderedProminent)
                        .disabled(customURL.trimmingCharacters(in: .whitespaces).isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
                Text("Consiglio: per WhatsApp usa il preset qui sotto (quadrato 400×400). Fai login col QR una sola volta: resta memorizzato.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(4)
        }
    }

    private var presets: some View {
        GroupBox("Preset rapidi — un click e restano sopra") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 8) {
                ForEach(builtinPresets) { p in
                    Button {
                        let size: PinSize = (p.name == "WhatsApp" || p.name == "Spotify") ? .square : .medium
                        manager.open(PinnedItem(title: p.name, urlString: p.url,
                                                width: Double(size.size.width), height: Double(size.size.height)))
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: p.symbol).font(.title2)
                            Text(p.name).font(.headline)
                            Text(p.hint).font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 74)
                    }
                    .buttonStyle(.bordered)
                }
            }.padding(4)
        }
    }

    private var activeApps: some View {
        GroupBox("App attive — clicca per fissarle sopra (Floaty)") {
            VStack(alignment: .leading, spacing: 8) {
                if runningApps.isEmpty {
                    Text("Nessuna altra app aperta al momento.")
                        .font(.callout).foregroundStyle(.secondary).padding(4)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 8) {
                        ForEach(runningApps) { app in
                            Button {
                                stickOrPin(app)
                            } label: {
                                VStack(spacing: 4) {
                                    appIcon(for: app)
                                        .frame(width: 32, height: 32)
                                    Text(app.name).font(.headline).lineLimit(1)
                                    Text("Fissa sopra")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 74)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    Text("Un click: mirror live 60fps sempre sopra. Clicca il mirror per usare la finestra vera (senza Recovery/SIP).")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(4)
        }
    }

    private func stickOrPin(_ app: RunningApp) {
        NSRunningApplication(processIdentifier: app.pid)?.activate(options: [.activateAllWindows])
        guard let front = appManager.windows.first(where: { $0.ownerPID == app.pid }) else {
            appManager.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
                if let f = self.appManager.windows.first(where: { $0.ownerPID == app.pid }) {
                    self.stickOrPinWindow(f)
                }
            }
            return
        }
        stickOrPinWindow(front)
    }

    private func stickOrPinWindow(_ w: AppWindowInfo) {
        // Metodo Floaty di default: niente Recovery/SIP.
        MirrorManager.shared.createMirror(for: w)
    }

    private func stickApp(_ app: RunningApp) {
        NSRunningApplication(processIdentifier: app.pid)?.activate(options: [.activateAllWindows])
        if let front = appManager.windows.first(where: { $0.ownerPID == app.pid }) {
            MirrorManager.shared.createMirror(for: front)
        } else {
            appManager.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if let front = appManager.windows.first(where: { $0.ownerPID == app.pid }) {
                    MirrorManager.shared.createMirror(for: front)
                }
            }
        }
    }

    private struct RunningApp: Identifiable {
        var id: pid_t { pid }
        let pid: pid_t
        let name: String
        let icon: NSImage?
    }

    /// App GUI in esecuzione adesso (es. OpenCode, Sublime Text, Cisco Packet Tracer).
    /// Si aggiorna a ogni refresh del timer condiviso (tramite appManager.windows).
    private var runningApps: [RunningApp] {
        _ = appManager.windows
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != ownPID }
            .map { RunningApp(pid: $0.processIdentifier, name: $0.localizedName ?? "App", icon: $0.icon) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func appIcon(for app: RunningApp) -> Image {
        if let ns = app.icon {
            return Image(nsImage: ns)
        }
        return Image(systemName: "app.window.on.rectangle")
    }

    private var openPanels: some View {
        GroupBox("Finestre attive (\(manager.items.count))") {
            if manager.items.isEmpty {
                Text("Nessuna finestra. Aggiungine una sopra: resterà in primo piano anche mentre navighi su Chrome/Safari.")
                    .font(.callout).foregroundStyle(.secondary).padding(4)
            } else {
                VStack(spacing: 8) {
                    ForEach(manager.items) { item in
                        panelRow(item)
                        Divider()
                    }
                }.padding(4)
            }
        }
    }

    private func panelRow(_ item: PinnedItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(manager.isVisible(id: item.id) ? .green : .gray).frame(width: 8, height: 8)
                Text(item.title).font(.headline)
                Text(item.urlString).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(manager.isVisible(id: item.id) ? "Nascondi" : "Mostra") { manager.toggle(id: item.id) }
                Button("In primo piano") { manager.bringToFront(id: item.id) }
                    .help("Riporta sopra senza rubare il focus al gioco/app sotto")
                Button("Scrivi") { manager.focusForTyping(id: item.id) }
                    .help("Porta sopra e attiva la tastiera dentro il pannello")
                Button("Chiudi", role: .destructive) { manager.close(id: item.id) }
            }.buttonStyle(.link).font(.caption)

            HStack {
                VStack(alignment: .leading) {
                    Text("Opacità \(Int(item.opacity * 100))%").font(.caption)
                    Slider(value: Binding(get: { item.opacity },
                                          set: { v in var u = item; u.opacity = v; manager.update(u) }),
                           in: 0.3...1.0).frame(width: 160)
                }
                Stepper("Larghezza \(Int(item.width))", value: Binding(
                    get: { item.width },
                    set: { v in var u = item; u.width = v; manager.update(u) }), in: 240...1400, step: 20)
                    .font(.caption)
                Stepper("Altezza \(Int(item.height))", value: Binding(
                    get: { item.height },
                    set: { v in var u = item; u.height = v; manager.update(u) }), in: 240...1000, step: 20)
                    .font(.caption)
            }
            HStack {
                Toggle("Extra-sopra (fullscreen)", isOn: Binding(
                    get: { item.levelBoosted },
                    set: { v in var u = item; u.levelBoosted = v; manager.update(u) })).font(.caption)
                    .help("Di default resta già sopra Chrome, Desktop e Spaces. Attivalo per i giochi fullscreen.")
                Toggle("Tutti gli Spaces", isOn: Binding(
                    get: { item.joinAllSpaces },
                    set: { v in var u = item; u.joinAllSpaces = v; manager.update(u) })).font(.caption)
                    .help("Sempre attivo: gli overlay seguono ogni Space e desktop.")
                Spacer()
                ForEach(PinSize.allCases) { s in
                    Button(s.rawValue) {
                        var u = item
                        u.width = Double(s.size.width); u.height = Double(s.size.height)
                        manager.update(u)
                    }.font(.caption).buttonStyle(.link)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Chiudi tutto", role: .destructive) { manager.closeAll() }
                Spacer()
                Text("Trascina le finestre dalla barra del titolo • Ridimensiona dagli angoli").font(.caption).foregroundStyle(.secondary)
            }
            Text("Siti web: pannelli interattivi di WindowUP!. Per Terminale, VS Code e altre app native usa il tab App e Finestre.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func addCustom() {
        let url = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        let title = customTitle.trimmingCharacters(in: .whitespaces).isEmpty ? (URL(string: url)?.host() ?? url) : customTitle.trimmingCharacters(in: .whitespaces)
        manager.open(PinnedItem(title: title, urlString: url,
                                width: Double(selectedSize.size.width), height: Double(selectedSize.size.height)))
        customTitle = ""; customURL = ""
    }
}

struct SettingsView: View {
    @EnvironmentObject var manager: PanelManager
    var body: some View {
        Form {
            Section("Comportamento") {
                Text("Gli overlay restano sopra Chrome, Desktop, Spaces e giochi fullscreen. Non rubano il focus: i click fuori non li nascondono, i click dentro non attivano le finestre sotto. Premi Scrivi solo quando vuoi digitare dentro.")
                HStack {
                    Button("Mostra tutte") { manager.showAll() }
                    Button("Nascondi tutte") { manager.hideAll() }
                }
            }
        }
        .padding(20).frame(width: 420)
    }
}
