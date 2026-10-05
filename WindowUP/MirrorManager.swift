import SwiftUI
import AppKit
import CoreGraphics

// MARK: - Modello anteprima live (view-only)

struct MirrorPin: Identifiable, Equatable {
    var id: UUID = UUID()
    var windowNumber: UInt32
    var ownerName: String
    var bundleID: String?
    var titleSnapshot: String
    var width: Double
    var height: Double
    var opacity: Double = 1.0
    var clickThrough: Bool = false
    var levelBoosted: Bool = false
}

// MARK: - Manager anteprime

final class MirrorManager: ObservableObject {
    static let shared = MirrorManager()

    @Published var mirrors: [MirrorPin] = []
    private var panels: [UUID: FloatingPanel] = [:]
    private let pinning = WindowPinning.shared

    /// Crea un overlay live della finestra di un'altra app.
    /// - Parameter boosted: se true parte già in Extra-sopra (`.screenSaver`),
    ///   pensato per restare visibile sopra i giochi fullscreen.
    func createMirror(for window: AppWindowInfo, boosted: Bool = false) {
        // Evita duplicati sulla stessa finestra
        if mirrors.contains(where: { $0.windowNumber == window.windowNumber }) {
            if let m = mirrors.first(where: { $0.windowNumber == window.windowNumber }) {
                focus(id: m.id)
            }
            return
        }
        var w = window.bounds.width
        var h = window.bounds.height
        if w < 10 || h < 10 { w = 480; h = 360 }
        // Scala contenuta per lo schermo
        let maxW = 640.0
        let maxH = 560.0
        let scale = min(1.0, min(maxW / w, maxH / h))
        w *= scale; h *= scale
        w = max(280, min(900, w)); h = max(220, min(750, h))

        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = title.isEmpty ? window.ownerName : "\(window.ownerName) — \(title)"
        let mirror = MirrorPin(
            windowNumber: window.windowNumber,
            ownerName: window.ownerName,
            bundleID: window.bundleID,
            titleSnapshot: String(label.prefix(80)),
            width: w, height: h,
            levelBoosted: boosted
        )
        mirrors.append(mirror)
        showPanel(for: mirror)
    }

    func close(id: UUID) {
        panels[id]?.close()
        panels.removeValue(forKey: id)
        mirrors.removeAll { $0.id == id }
    }

    func closeAll() {
        for id in panels.keys { panels[id]?.close() }
        panels.removeAll()
        mirrors.removeAll()
    }

    func focus(id: UUID) {
        panels[id]?.orderFrontRegardless()
        panels[id]?.makeKeyAndOrderFront(nil)
    }

    func goToRealWindow(_ mirror: MirrorPin) {
        // Trova il PID corrente della finestra e attiva l'app reale
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
        if let panel = panels[mirror.id] {
            var geom = PinnedItem(title: "👁 " + mirror.titleSnapshot, urlString: "",
                                  width: mirror.width, height: mirror.height,
                                  opacity: mirror.opacity, levelBoosted: mirror.levelBoosted)
            geom.joinAllSpaces = true
            panel.apply(geom)
            panel.ignoresMouseEvents = mirror.clickThrough
        }
    }

    private func showPanel(for mirror: MirrorPin) {
        if let existing = panels[mirror.id] {
            existing.orderFrontRegardless()
            existing.makeKeyAndOrderFront(nil)
            return
        }
        var geom = PinnedItem(title: "👁 " + mirror.titleSnapshot, urlString: "",
                              width: mirror.width, height: mirror.height,
                              opacity: mirror.opacity, levelBoosted: mirror.levelBoosted)
        geom.joinAllSpaces = true
        let content = MirrorPanelView(manager: self, mirrorID: mirror.id)
        let hosting = NSHostingView(rootView: content.environmentObject(self))
        hosting.frame = NSRect(x: 0, y: 0, width: CGFloat(mirror.width), height: CGFloat(mirror.height))
        let panel = FloatingPanel(item: geom, contentView: hosting)
        panel.ignoresMouseEvents = mirror.clickThrough
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            self?.panels[mirror.id] = nil
            self?.mirrors.removeAll { $0.id == mirror.id }
            self?.objectWillChange.send()
        }
        panels[mirror.id] = panel
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
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
