import SwiftUI
import AppKit
import Darwin

// MARK: - Pin vero via yabai (richiede yabai + scripting addition + SIP parziale)

/// yabai cambia il layer DENTRO il Dock (unico con connessione al window server):
/// è l'unico pin vero e interattivo possibile. WindowUP fa da telecomando.
///
/// REGOLA D'ORO (crash 05-10-2026, SIGABRT in AttributeGraph): qui dentro MAI
/// bloccare il main thread e MAI mutare @Published durante il render SwiftUI.
/// Prima `match()` lanciava `Process.waitUntilExit()` dentro `windowRow` (body
/// di view) → abort. Ora tutto l'I/O gira su una coda seriale di background e
/// le view leggono solo la cache (`match`, `isPinned`, `pinnedIDs`).
final class YabaiManager: ObservableObject {
    static let shared = YabaiManager()

    struct YabWin {
        let id: UInt32
        let pid: pid_t
        let app: String
        let title: String
        let frame: CGRect
        let subLayer: String
    }

    @Published var isInstalled = false
    @Published var yabaiPath: String = ""
    @Published var pinnedIDs = Set<UInt32>() // yabai window id con sub-layer=above
    @Published var lastMessage = ""
    @Published var lastOK = true
    /// Stato scripting-addition: nil = mai verificato, true = funziona,
    /// false = manca (il pin vero fallisce). Verificato solo provando.
    @Published var saOK: Bool? = nil
    @Published var sipStatus: String = "lettura…"

    /// Cache letta dalle view: scritta e letta solo dal main thread.
    private var cache: [YabWin] = []
    private var cacheDate = Date.distantPast

    /// Tutto il lavoro bloccante (spawn + wait) gira qui, MAI sul main.
    private let workQueue = DispatchQueue(label: "windowup.yabai", qos: .utility)
    private var refreshTimer: Timer?

    private init() {
        locate()
        fetchSIPStatus()
        DispatchQueue.main.async { [weak self] in self?.startAutoRefresh() }
    }

    // MARK: - Rilevamento (async, non blocca il chiamante)

    /// Rileva l'eseguibile yabai in background. Sicuro da chiamare dal main.
    func locate() {
        workQueue.async { [weak self] in
            guard let self else { return }
            let found = Self.findYabaiBinary()
            DispatchQueue.main.async {
                if let found {
                    self.yabaiPath = found
                    self.isInstalled = true
                } else {
                    self.yabaiPath = ""
                    self.isInstalled = false
                }
                self.refreshCacheAsync()
            }
        }
    }

    private static func findYabaiBinary() -> String? {
        for c in ["/opt/homebrew/bin/yabai", "/usr/local/bin/yabai"]
        where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        // Fallback PATH: gira in background, qui waitUntilExit è lecito.
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/bin/zsh")
        t.arguments = ["-lc", "command -v yabai"]
        let pipe = Pipe()
        t.standardOutput = pipe
        t.standardError = FileHandle.nullDevice
        try? t.run()
        t.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !out.isEmpty && FileManager.default.isExecutableFile(atPath: out) {
            return out
        }
        return nil
    }

    // MARK: - Diagnostica (async)

    /// Legge `csrutil status` in background (non richiede sudo).
    func fetchSIPStatus() {
        workQueue.async { [weak self] in
            let t = Process()
            t.executableURL = URL(fileURLWithPath: "/usr/bin/csrutil")
            t.arguments = ["status"]
            let pipe = Pipe()
            t.standardOutput = pipe
            t.standardError = FileHandle.nullDevice
            try? t.run()
            t.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let first = out.split(separator: "\n").first.map(String.init) ?? "sconosciuto"
            DispatchQueue.main.async { [weak self] in self?.sipStatus = first }
        }
    }

    /// Copia negli appunti il comando per caricare lo scripting-addition.
    func copySALoadCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("sudo yabai --load-sa", forType: .string)
        note("comando copiato: incollalo nel Terminale e dai Invio", ok: true)
    }

    // MARK: - Refresh periodico (async)

    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.refreshCacheAsync()
        }
        if let t = refreshTimer { RunLoop.main.add(t, forMode: .common) }
        refreshCacheAsync()
    }

    /// Accoda un refresh della cache e ritorna subito. Chiamare dal main:
    /// fotografa lo stato pubblicato prima di andare in background (niente
    /// letture cross-thread). Il refresh silenzioso non tocca `lastMessage`.
    func refreshCacheAsync() {
        let path = yabaiPath
        guard isInstalled, !path.isEmpty else { return }
        workQueue.async { [weak self] in
            let wins = Self.queryWindowsSync(yabaiPath: path)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.cache = wins
                self.cacheDate = Date()
                self.pinnedIDs = Set(wins.filter { $0.subLayer == "above" }.map(\.id))
            }
        }
    }

    // MARK: - I/O sincrono (SOLO su workQueue, mai sul main)

    private static func runSync(yabaiPath: String, _ args: [String]) -> (out: String, err: String, code: Int32) {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: yabaiPath)
        t.arguments = args
        let o = Pipe(), e = Pipe()
        t.standardOutput = o
        t.standardError = e
        do { try t.run() } catch {
            return ("", "lancio fallito: \(error.localizedDescription)", 126)
        }
        t.waitUntilExit()
        let outs = String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errs = String(data: e.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (outs, errs, t.terminationStatus)
    }

    /// Tutte le finestre viste da yabai (id propri di yabai). Solo background.
    private static func queryWindowsSync(yabaiPath: String) -> [YabWin] {
        let r = runSync(yabaiPath: yabaiPath, ["-m", "query", "--windows"])
        guard r.code == 0, let data = r.out.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        var out: [YabWin] = []
        for d in arr {
            guard let id = (d["id"] as? Int).map(UInt32.init),
                  let pid = (d["pid"] as? Int).map({ pid_t($0) }) else { continue }
            let app = d["app"] as? String ?? ""
            let title = d["title"] as? String ?? ""
            var frame = CGRect.zero
            if let f = d["frame"] as? [String: Any],
               let x = (f["x"] as? Double) ?? (f["x"] as? Int).map(Double.init),
               let y = (f["y"] as? Double) ?? (f["y"] as? Int).map(Double.init),
               let w = (f["w"] as? Double) ?? (f["w"] as? Int).map(Double.init),
               let h = (f["h"] as? Double) ?? (f["h"] as? Int).map(Double.init) {
                frame = CGRect(x: x, y: y, width: w, height: h)
            }
            out.append(YabWin(id: id, pid: pid, app: app, title: title, frame: frame,
                            subLayer: d["sub-layer"] as? String ?? ""))
        }
        return out
    }

    // MARK: - Letture pure (sicure nei body delle view)

    /// Abbina la nostra AppWindowInfo alla finestra yabai (stesso pid + frame più vicino).
    /// Puro: legge solo la cache, nessun I/O, nessun side effect.
    func match(_ w: AppWindowInfo) -> YabWin? {
        let h = NSScreen.screens.first?.frame.height ?? 900
        return match(w, in: cache, screenHeight: h)
    }

    private func match(_ w: AppWindowInfo, in list: [YabWin], screenHeight h: CGFloat) -> YabWin? {
        let cands = list.filter { $0.pid == w.ownerPID }
        guard !cands.isEmpty else { return nil }
        func dist(_ f: CGRect) -> Double {
            let d1 = abs(f.origin.x - w.bounds.origin.x) + abs(f.origin.y - w.bounds.origin.y)
                + abs(f.width - w.bounds.width) + abs(f.height - w.bounds.height)
            let fy = h - f.origin.y - f.height
            let d2 = abs(f.origin.x - w.bounds.origin.x) + abs(fy - w.bounds.origin.y)
                + abs(f.width - w.bounds.width) + abs(f.height - w.bounds.height)
            return min(d1, d2)
        }
        return cands.min(by: { dist($0.frame) < dist($1.frame) })
    }

    func isPinned(yabaiID: UInt32) -> Bool { pinnedIDs.contains(yabaiID) }

    // MARK: - Azioni (async, esito in lastMessage)

    /// Fissa/sblocca davvero la finestra (sub-layer above/auto). Ritorna subito.
    func toggle(_ w: AppWindowInfo) {
        let path = yabaiPath
        let screenH = NSScreen.screens.first?.frame.height ?? 900
        guard isInstalled, !path.isEmpty else {
            note("yabai non installato", ok: false)
            return
        }
        workQueue.async { [weak self] in
            guard let self else { return }
            let wins = Self.queryWindowsSync(yabaiPath: path)
            guard let m = self.match(w, in: wins, screenHeight: screenH) else {
                self.note("finestra non trovata da yabai (il server yabai gira?)", ok: false)
                return
            }
            let pinning = !self.pinnedIDs.contains(m.id)
            let r = Self.runSync(yabaiPath: path, ["-m", "window", "\(m.id)",
                                                 "--sub-layer", pinning ? "above" : "auto"])
            if r.code == 0 {
                let fresh = Self.queryWindowsSync(yabaiPath: path)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.cache = fresh
                    self.cacheDate = Date()
                    self.pinnedIDs = Set(fresh.filter { $0.subLayer == "above" }.map(\.id))
                    self.saOK = true // il comando sub-layer ha funzionato
                    if self.pinnedIDs.contains(m.id) {
                        RingOverlay.shared.show(pid: w.ownerPID, wid: w.windowNumber)
                        self.note("\(w.ownerName): FISSATA davvero sopra ✓", ok: true)
                    } else {
                        RingOverlay.shared.hide(pid: w.ownerPID, wid: w.windowNumber)
                        self.note("\(w.ownerName): sbloccata", ok: true)
                    }
                }
                return
            }
            let msg = r.err.isEmpty ? r.out : r.err
            if msg.contains("System Integrity Protection") || msg.contains("scripting-addition") {
                self.saOK = false
                self.note("Serve lo scripting-addition (passo SIP in Recovery): \(msg.prefix(140))", ok: false)
            } else {
                self.note("yabai: \(msg.prefix(160))", ok: false)
            }
        }
    }

    func unpinAll() {
        let path = yabaiPath
        let ids = pinnedIDs
        guard isInstalled, !path.isEmpty else {
            note("yabai non installato", ok: false)
            return
        }
        guard !ids.isEmpty else { return }
        workQueue.async { [weak self] in
            for id in ids {
                _ = Self.runSync(yabaiPath: path, ["-m", "window", "\(id)", "--sub-layer", "auto"])
            }
            let fresh = Self.queryWindowsSync(yabaiPath: path)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.cache = fresh
                self.cacheDate = Date()
                self.pinnedIDs = Set(fresh.filter { $0.subLayer == "above" }.map(\.id))
                RingOverlay.shared.hideAll()
                self.note("tutte sbloccate", ok: true)
            }
        }
    }

    private func note(_ m: String, ok: Bool) {
        DispatchQueue.main.async {
            self.lastMessage = m
            self.lastOK = ok
        }
    }
}
