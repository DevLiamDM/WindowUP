import SwiftUI
import AppKit
import CoreGraphics
import ScreenCaptureKit

// MARK: - Modello anteprima live (metodo Floaty: mirror interattivo via passthrough)

struct MirrorPin: Identifiable, Equatable {
    var id: UUID = UUID()
    var windowNumber: UInt32
    var ownerName: String
    var bundleID: String?
    var titleSnapshot: String
    var width: Double
    var height: Double
    var opacity: Double = 1.0
    /// false = interattivo (default: click/scrittura/trascinamento inoltrati);
    /// true = passthrough overlay (mai focus, per i giochi).
    var clickThrough: Bool = false
    var levelBoosted: Bool = false
}

// MARK: - Manager anteprime (mirror Floaty, niente Recovery/SIP)

final class MirrorManager: ObservableObject {
    static let shared = MirrorManager()

    @Published var mirrors: [MirrorPin] = []
    @Published var statuses: [UUID: String] = [:]
    @Published var needsScreenRecording = false
    @Published var lastError: String?
    private var panels: [UUID: FloatyPanel] = [:]
    private var pending: Set<UInt32> = []
    private let pinning = WindowPinning.shared

    /// Crea un mirror stile Floaty della finestra di un'altra app.
    /// - Parameter boosted: se true parte già in Extra-sopra (`.screenSaver`).
    func createMirror(for window: AppWindowInfo, boosted: Bool = false) {
        // Evita duplicati sulla stessa finestra (anche mentre risolve SCWindow)
        if mirrors.contains(where: { $0.windowNumber == window.windowNumber }) {
            if let m = mirrors.first(where: { $0.windowNumber == window.windowNumber }) {
                focus(id: m.id)
            }
            return
        }
        guard !pending.contains(window.windowNumber) else { return }
        pending.insert(window.windowNumber)
        ensurePermissions()

        var w = window.bounds.width
        var h = window.bounds.height
        if w < 10 || h < 10 { w = 480; h = 360 }

        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = title.isEmpty ? window.ownerName : "\(window.ownerName) — \(title)"
        let mirror = MirrorPin(
            windowNumber: window.windowNumber,
            ownerName: window.ownerName,
            bundleID: window.bundleID,
            titleSnapshot: String(label.prefix(80)),
            width: w, height: h,
            // Extra/overlay-gioco = passthrough (mai focus, gioco al sicuro).
            // Normale = interattivo (click/scrittura/trascinamento inoltrati).
            clickThrough: boosted,
            levelBoosted: boosted
        )
        mirrors.append(mirror)
        statuses[mirror.id] = "connessione…"
        objectWillChange.send()

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pending.remove(window.windowNumber) }
            guard let scWin = await self.resolveSCWindow(wid: window.windowNumber) else {
                self.statuses[mirror.id] = "finestra non trovata"
                self.lastError = "Finestra \(window.windowNumber) non esposta a ScreenCaptureKit (chiusa o minimizzata?)."
                return
            }
            self.showFloatyPanel(for: mirror, scWindow: scWin)
        }
    }

    /// Risolve il CGWindowID in SCWindow (serve per SCContentFilter desktopIndependentWindow).
    @MainActor
    private func resolveSCWindow(wid: UInt32) async -> SCWindow? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return content.windows.first(where: { $0.windowID == CGWindowID(wid) })
        } catch {
            let code = (error as NSError).code
            if code == -3801 || code == -3802 {
                needsScreenRecording = true
                lastError = "Abilita Registrazione schermo per WindowUP! e riprova."
            } else {
                lastError = "ScreenCaptureKit: \(error.localizedDescription)"
            }
            return nil
        }
    }

    private func ensurePermissions() {
        // Accessibilità: prompt una tantum (serve per click-to-activate + hide-while-focused).
        if !AXIsProcessTrusted() {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        // Registrazione schermo: il Task di resolveSCWindow mostra il prompt di sistema.
        needsScreenRecording = !CGPreflightScreenCaptureAccess()
    }

    func close(id: UUID) {
        mirrors.removeAll { $0.id == id }
        statuses.removeValue(forKey: id)
        if let p = panels.removeValue(forKey: id) {
            p.onClosed = nil
            p.onStatus = nil
            p.stop()
        }
        objectWillChange.send()
    }

    func closeAll() {
        let all = Array(panels.values)
        panels.removeAll()
        mirrors.removeAll()
        statuses.removeAll()
        pending.removeAll()
        for p in all {
            p.onClosed = nil
            p.onStatus = nil
            p.stop()
        }
        objectWillChange.send()
    }

    func focus(id: UUID) {
        panels[id]?.reveal()
    }

    func goToRealWindow(_ mirror: MirrorPin) {
        // Metodo Floaty: attiva la finestra vera (il mirror è già passthrough,
        // quindi il click sull'immagine arriva alla finestra sotto).
        if let p = panels[mirror.id] {
            p.activateRealWindow()
            return
        }
        let list = pinning.listWindows()
        if let w = list.first(where: { $0.windowNumber == mirror.windowNumber }) {
            pinning.activate(pid: w.ownerPID)
        } else if let bid = mirror.bundleID,
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
            app.activate(options: [.activateAllWindows])
        }
    }

    func update(_ mirror: MirrorPin) {
        guard let idx = mirrors.firstIndex(where: { $0.id == mirror.id }) else { return }
        mirrors[idx] = mirror
        panels[mirror.id]?.apply(opacity: mirror.opacity, boosted: mirror.levelBoosted,
                                 clickThrough: mirror.clickThrough)
    }

    func statusText(for id: UUID) -> String {
        statuses[id] ?? "LIVE"
    }

    private func showFloatyPanel(for mirror: MirrorPin, scWindow: SCWindow) {
        if panels[mirror.id] != nil {
            panels[mirror.id]?.reveal()
            return
        }
        let fp = FloatyPanel(scWindow: scWindow, mirrorID: mirror.id,
                             title: mirror.titleSnapshot,
                             boosted: mirror.levelBoosted, opacity: mirror.opacity,
                             clickThrough: mirror.clickThrough)
        fp.onStatus = { [weak self] text, needsPerm in
            DispatchQueue.main.async {
                self?.statuses[mirror.id] = text
                if needsPerm { self?.needsScreenRecording = true }
            }
        }
        fp.onClosed = { [weak self] in
            DispatchQueue.main.async {
                // Auto-unpin: la finestra vera è stata chiusa altrove.
                self?.panels.removeValue(forKey: mirror.id)
                self?.mirrors.removeAll { $0.id == mirror.id }
                self?.statuses.removeValue(forKey: mirror.id)
                self?.objectWillChange.send()
            }
        }
        panels[mirror.id] = fp
        Task { @MainActor in
            await fp.start()
        }
    }
}

// MARK: - Salto rapido globale tra gioco e chiamata (solo API pubbliche)

/// Su un Mac stock non si può fissare la finestra altrui in modo interattivo,
/// ma si può SALTARE tra app all'istante: ⌃⌥⌘M attiva l'app dell'ultimo overlay
/// (es. la chiamata WhatsApp); ripremuto torna dove eri (es. il gioco).
/// Richiede solo Accessibilità (concessione in Impostazioni, nessun riavvio).
final class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    @Published var monitorInstalled = false
    @Published var accessibilityOK = false

    private var monitor: Any?
    private var returnPID: pid_t?

    private init() {
        DispatchQueue.main.async { [weak self] in self?.start() }
    }

    func start() {
        stop()
        accessibilityOK = AXIsProcessTrusted()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            self?.handle(e)
        }
        monitorInstalled = monitor != nil
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        monitorInstalled = false
    }

    func refreshTrust() {
        accessibilityOK = AXIsProcessTrusted()
    }

    private func handle(_ e: NSEvent) {
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard f == [.control, .option, .command],
              e.charactersIgnoringModifiers?.lowercased() == "m" else { return }
        jump()
    }

    /// App proprietaria dell'ultimo overlay creato (risolta al momento del salto).
    private func currentTarget() -> pid_t? {
        guard let m = MirrorManager.shared.mirrors.last else { return nil }
        let list = WindowPinning.shared.listWindows()
        if let w = list.first(where: { $0.windowNumber == m.windowNumber }) { return w.ownerPID }
        if let bid = m.bundleID,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
            return app.processIdentifier
        }
        return nil
    }

    func jump() {
        guard let target = currentTarget(),
              let targetApp = NSRunningApplication(processIdentifier: target),
              !targetApp.isTerminated else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier == target {
            if let back = returnPID,
               let app = NSRunningApplication(processIdentifier: back),
               !app.isTerminated {
                app.activate(options: [.activateAllWindows])
            }
        } else {
            if let f = front { returnPID = f.processIdentifier }
            targetApp.activate(options: [.activateAllWindows])
        }
    }
}

struct MirrorPanelView: View {
    @ObservedObject var manager: MirrorManager
    let mirrorID: UUID
    @StateObject private var stream = SCMirrorSession()

    private var mirror: MirrorPin? {
        manager.mirrors.first(where: { $0.id == mirrorID })
    }

    private var windowGone: Bool { stream.status == "finestra chiusa" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(windowGone ? .red : (stream.frame == nil ? .orange : .green)).frame(width: 8, height: 8)
                Text(stream.status == "LIVE" ? "LIVE • solo vista" : stream.status).font(.caption.bold())
                Spacer()
                Button("Vai alla finestra") {
                    if let m = mirror { manager.goToRealWindow(m) }
                }.buttonStyle(.link).font(.caption)
                Button("Chiudi") { manager.close(id: mirrorID) }.buttonStyle(.link).font(.caption)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(.bar)
            Divider()
            ZStack {
                if let img = stream.frame {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onTapGesture {
                            if let m = mirror, !(m.clickThrough) { manager.goToRealWindow(m) }
                        }
                } else if windowGone {
                    VStack(spacing: 6) {
                        Image(systemName: "eye.slash").font(.largeTitle).foregroundStyle(.secondary)
                        Text("La finestra originale è stata chiusa.\nChiudi questa anteprima e creane una nuova.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding()
                } else {
                    VStack(spacing: 6) {
                        ProgressView().scaleEffect(0.8)
                        Text(stream.needsPermission || stream.failed
                             ? "Abilita Registrazione schermo per WindowUP! in Impostazioni di Sistema, poi chiudi e ricrea l'anteprima."
                             : "Connessione al flusso live…")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        if stream.needsPermission {
                            Button("Apri Impostazioni") {
                                WindowPinning.shared.openScreenRecordingSettings()
                            }.buttonStyle(.link).font(.caption)
                        }
                    }.padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 10) {
                if let m = mirror {
                    Toggle("Click-through", isOn: Binding(
                        get: { m.clickThrough },
                        set: { v in var u = m; u.clickThrough = v; manager.update(u) }
                    )).font(.caption)
                    Toggle("Extra-sopra", isOn: Binding(
                        get: { m.levelBoosted },
                        set: { v in var u = m; u.levelBoosted = v; manager.update(u) }
                    )).font(.caption)
                    Slider(value: Binding(
                        get: { m.opacity },
                        set: { v in var u = m; u.opacity = v; manager.update(u) }
                    ), in: 0.3...1.0).frame(width: 90)
                }
                Spacer()
                Text("live ~15fps").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.bar)
        }
        .onAppear {
            if let m = mirror { stream.start(wid: m.windowNumber) }
        }
        .onDisappear { stream.stop() }
    }
}
