import AppKit
import CoreGraphics
import Darwin
import ApplicationServices
import Combine

// MARK: - Modello finestra di un'altra app

struct AppWindowInfo: Identifiable, Equatable {
    // CGWindowID su 64bit è UInt32
    var id: UInt32 { windowNumber }
    let windowNumber: UInt32
    let ownerPID: pid_t
    let ownerName: String
    let bundleID: String?
    let title: String
    let bounds: CGRect
    let layer: Int
    let currentLevel: Int32
    let isPinnedByUs: Bool
    let looksFloating: Bool
}

// MARK: - Bridge API private CGS (SkyLight) caricate dinamicamente

/// Rende la finestra DI UN'ALTRA APP sempre in primo piano via CGSSetWindowLevel.
/// API private: caricate con dlopen/dlsym + fallback CGS->SLS, mai linkate staticamente.
///
/// LEGACY (non più usato per il pin): su macOS 15/26 il set cross-process è
/// no-op verificato — il window server ignora i cambi di livello da un'altra
/// connessione. Tenuto solo per diagnostica `currentLevel` / `isPinned`.
/// Il pin vero ora è: overlay nostri (FloatingPanel a livello screenSaver/
/// maximum + canJoinAllSpaces + stationary + fullScreenAuxiliary, nonactivating,
/// heartbeat passivo) oppure yabai per l'interattivo nativo.
final class WindowPinning {
    static let shared = WindowPinning()

    typealias MainConnFn = @convention(c) () -> Int32
    typealias GetLevelFn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Int32>) -> Int32
    typealias SetLevelFn = @convention(c) (Int32, UInt32, Int32) -> Int32
    typealias OrderFn = @convention(c) (Int32, UInt32, Int32, UInt32) -> Int32

    private var handle: UnsafeMutableRawPointer?
    private var mainConnFn: MainConnFn?
    private var getLevelFn: GetLevelFn?
    private var setLevelFn: SetLevelFn?
    private var orderFn: OrderFn?
    private var connection: Int32 = 0

    private(set) var available: Bool = false
    private(set) var apiNameUsed: String = "non disponibile"

    var normalLevel: Int32 = 0
    var floatingLevel: Int32 = 3

    // Livelli originali per ripristino + set pinnati da noi
    private var originalLevels: [UInt32: Int32] = [:]
    private(set) var pinnedIDs = Set<UInt32>()

    // Auto-pin: bundleID le cui nuove finestre vanno fissate da sole
    var autoPinNewWindows: Bool {
        didSet { UserDefaults.standard.set(autoPinNewWindows, forKey: "windowup.autopin") }
    }
    var pinnedBundleIDs = Set<String>() {
        didSet { UserDefaults.standard.set(Array(pinnedBundleIDs), forKey: "windowup.pinnedBundles") }
    }

    private init() {
        self.autoPinNewWindows = UserDefaults.standard.bool(forKey: "windowup.autopin")
        if let arr = UserDefaults.standard.array(forKey: "windowup.pinnedBundles") as? [String] {
            self.pinnedBundleIDs = Set(arr)
        }
        loadSymbols()
        resolveLevels()
    }

    // MARK: caricamento simboli

    private func sym(_ handle: UnsafeMutableRawPointer?, _ name: String) -> UnsafeMutableRawPointer? {
        guard let h = handle else { return nil }
        var result: UnsafeMutableRawPointer?
        name.withCString { cstr in
            result = dlsym(h, cstr)
        }
        return result
    }

    private func loadSymbols() {
        // 1) prova SkyLight diretto, 2) fallback handle principale (CoreGraphics ri-esporta)
        let skyPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        var h: UnsafeMutableRawPointer?
        skyPath.withCString { cstr in
            h = dlopen(cstr, RTLD_NOW)
        }
        if h == nil {
            h = dlopen(nil, RTLD_NOW)
        }
        self.handle = h

        let mainNames = ["CGSMainConnectionID", "SLSMainConnectionID"]
        let getNames = ["CGSGetWindowLevel", "SLSGetWindowLevel"]
        let setNames = ["CGSSetWindowLevel", "SLSSetWindowLevel"]
        let orderNames = ["CGSOrderWindow", "SLSOrderWindow"]

        var mainSym: UnsafeMutableRawPointer?
        var getSym: UnsafeMutableRawPointer?
        var setSym: UnsafeMutableRawPointer?
        var orderSym: UnsafeMutableRawPointer?
        var usedPrefix = "CGS"
        for i in 0..<mainNames.count {
            let m = sym(h, mainNames[i])
            let g = sym(h, getNames[i])
            let s = sym(h, setNames[i])
            let o = sym(h, orderNames[i])
            if m != nil && g != nil && s != nil {
                mainSym = m; getSym = g; setSym = s; orderSym = o
                usedPrefix = (i == 0) ? "CGS" : "SLS"
                break
            }
        }
        guard let m = mainSym, let g = getSym, let s = setSym else {
            self.available = false
            return
        }
        self.mainConnFn = unsafeBitCast(m, to: MainConnFn.self)
        self.getLevelFn = unsafeBitCast(g, to: GetLevelFn.self)
        self.setLevelFn = unsafeBitCast(s, to: SetLevelFn.self)
        if let o = orderSym {
            self.orderFn = unsafeBitCast(o, to: OrderFn.self)
        }
        self.connection = self.mainConnFn?() ?? 0
        if self.connection != 0 {
            self.available = true
            self.apiNameUsed = usedPrefix
        }
    }

    private func resolveLevels() {
        // Non hardcodare: chiedi a CoreGraphics i level corretti
        self.normalLevel = CGWindowLevelForKey(.normalWindow)
        self.floatingLevel = CGWindowLevelForKey(.floatingWindow)
        if self.floatingLevel <= self.normalLevel {
            self.floatingLevel = 3
        }
    }

    // MARK: operazioni

    func currentLevel(of wid: UInt32) -> Int32? {
        guard available, let fn = getLevelFn, connection != 0 else { return nil }
        var lvl: Int32 = 0
        let err = fn(connection, wid, &lvl)
        return err == 0 ? lvl : nil
    }

    @discardableResult
    private func setLevel(wid: UInt32, level: Int32) -> Bool {
        guard available, let fn = setLevelFn, connection != 0 else { return false }
        return fn(connection, wid, level) == 0
    }

    @discardableResult
    func pin(_ wid: UInt32, bundleID: String? = nil) -> Bool {
        if originalLevels[wid] == nil {
            originalLevels[wid] = currentLevel(of: wid) ?? normalLevel
        }
        let ok = setLevel(wid: wid, level: floatingLevel)
        if ok {
            pinnedIDs.insert(wid)
            if let b = bundleID, !b.isEmpty {
                pinnedBundleIDs.insert(b)
            }
            bringToFront(wid)
        }
        return ok
    }

    @discardableResult
    func unpin(_ wid: UInt32) -> Bool {
        let restore = originalLevels[wid] ?? normalLevel
        let ok = setLevel(wid: wid, level: restore)
        pinnedIDs.remove(wid)
        originalLevels.removeValue(forKey: wid)
        return ok
    }

    func unpinAll() {
        for wid in pinnedIDs {
            let restore = originalLevels[wid] ?? normalLevel
            _ = setLevel(wid: wid, level: restore)
        }
        pinnedIDs.removeAll()
        originalLevels.removeAll()
    }

    func isPinned(_ wid: UInt32, level: Int32) -> Bool {
        if pinnedIDs.contains(wid) { return true }
        return level != normalLevel
    }

    func reassertPins() {
        guard available else { return }
        for wid in pinnedIDs {
            _ = setLevel(wid: wid, level: floatingLevel)
        }
    }

    func bringToFront(_ wid: UInt32) {
        if let fn = orderFn, connection != 0 {
            _ = fn(connection, wid, 1, 0)
        }
    }

    func removeDeadPins(validIDs: Set<UInt32>) {
        let dead = pinnedIDs.subtracting(validIDs)
        for d in dead {
            pinnedIDs.remove(d)
            originalLevels.removeValue(forKey: d)
        }
    }

    // MARK: elenco finestre

    func listWindows() -> [AppWindowInfo] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let cfInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) else {
            return []
        }
        let list = cfInfo as NSArray as? [[String: Any]] ?? []
        var out: [AppWindowInfo] = []
        out.reserveCapacity(list.count)
        for d in list {
            guard let num = d[kCGWindowNumber as String] as? Int,
                  let pid = d[kCGWindowOwnerPID as String] as? Int32,
                  let layer = d[kCGWindowLayer as String] as? Int else { continue }
            if pid == ownPID { continue } // nascondi le nostre (web panels già sopra)
            if layer != 0 { continue } // solo finestre normali (no menu/dock)
            let ownerName = d[kCGWindowOwnerName as String] as? String ?? "App"
            if ownerName == "Window Server" { continue }
            var bounds = CGRect.zero
            if let b = d[kCGWindowBounds as String] as? [String: Any],
               let x = b["X"] as? Double, let y = b["Y"] as? Double,
               let w = b["Width"] as? Double, let h = b["Height"] as? Double {
                bounds = CGRect(x: x, y: y, width: w, height: h)
            }
            if bounds.width < 40 || bounds.height < 40 { continue }
            let wid = UInt32(num)
            let title = d[kCGWindowName as String] as? String ?? ""
            let lvl = currentLevel(of: wid) ?? Int32(layer)
            let running = NSRunningApplication(processIdentifier: pid)
            let bid = running?.bundleIdentifier
            let pinned = isPinned(wid, level: lvl)
            out.append(AppWindowInfo(
                windowNumber: wid, ownerPID: pid, ownerName: ownerName,
                bundleID: bid, title: title, bounds: bounds,
                layer: layer, currentLevel: lvl,
                isPinnedByUs: pinned, looksFloating: lvl != normalLevel
            ))
        }
        // Fissate prima, poi per app
        out.sort {
            if $0.isPinnedByUs != $1.isPinnedByUs { return $0.isPinnedByUs && !$1.isPinnedByUs }
            if $0.ownerName != $1.ownerName { return $0.ownerName < $1.ownerName }
            return $0.windowNumber < $1.windowNumber
        }
        return out
    }

    func applyAutoPin(_ windows: [AppWindowInfo]) {
        guard available && autoPinNewWindows else { return }
        for w in windows {
            guard let b = w.bundleID, pinnedBundleIDs.contains(b) else { continue }
            if pinnedIDs.contains(w.windowNumber) { continue }
            if w.currentLevel == normalLevel {
                pin(w.windowNumber, bundleID: b)
            } else {
                pinnedIDs.insert(w.windowNumber)
            }
        }
    }

    // MARK: permessi

    func isAccessibilityTrusted() -> Bool {
        return AXIsProcessTrusted()
    }

    @discardableResult
    func promptAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func hasWindowTitles(in windows: [AppWindowInfo]) -> Bool {
        return windows.contains { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: apertura app

    func launchApp(named name: String) {
        NSWorkspace.shared.launchApplication(name)
    }

    func launchApp(bundleID: String, fallbackName: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let cfg = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: url, configuration: cfg, completionHandler: nil)
        } else {
            NSWorkspace.shared.launchApplication(fallbackName)
        }
    }

    func activate(pid: pid_t) {
        let a = NSRunningApplication(processIdentifier: pid)
        // Unhide prima: se l'app è nascosta (⌘H) le sue finestre non sono
        // agganciabili finché non torna visibile.
        a?.unhide()
        a?.activate(options: [.activateAllWindows])
    }

    func icon(forPID pid: pid_t) -> NSImage? {
        return NSRunningApplication(processIdentifier: pid)?.icon
    }

    // MARK: - Raise via Accessibility (una tantum, non "sticky")

    /// Riporta davanti tutte le finestre dell'app. Ritorna un dettaglio leggibile
    /// dell'esito (serve per la diagnostica: senza trust fallisce qui).
    /// NOTA: non rende la finestra "sempre sopra": macOS la ricoprirà appena usi altro.
    func raiseAppWindows(pid: pid_t) -> String {
        let appRef = AXUIElementCreateApplication(pid)
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &raw)
        guard err == .success else { return "lettura finestre: AXError \(err.rawValue)" }
        guard let wins = raw as? [AXUIElement], !wins.isEmpty else { return "nessuna finestra AX esposta" }
        var ok = 0, fail = 0, lastErr: Int32 = 0
        for w in wins {
            let e = AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            if e == .success { ok += 1 } else { fail += 1; lastErr = e.rawValue }
        }
        if fail == 0 { return "raise ok (\(ok) finestre)" }
        return "raise: \(ok) ok, \(fail) falliti (AXError \(lastErr))"
    }

    /// Finestre normali (layer 0) ordinate fronte->retro, INCLUSE le nostre.
    /// Serve per capire se la seguita è davvero in alto o coperta (anche da WindowUP stessa).
    func orderedLayer0Windows() -> [(pid: pid_t, wid: UInt32)] {
        guard let cfInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) else {
            return []
        }
        let list = cfInfo as NSArray as? [[String: Any]] ?? []
        var out: [(pid_t, UInt32)] = []
        for d in list {
            guard let num = d[kCGWindowNumber as String] as? Int,
                  let pid = d[kCGWindowOwnerPID as String] as? Int32,
                  let layer = d[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            out.append((pid, UInt32(num)))
        }
        return out
    }

    /// Rettangolo (coordinate server, origine in alto a sx) della finestra, oppure nil.
    func frameForWindow(_ wid: UInt32) -> CGRect? {
        guard let cfInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) else {
            return nil
        }
        let list = cfInfo as NSArray as? [[String: Any]] ?? []
        for d in list {
            guard let num = d[kCGWindowNumber as String] as? Int, UInt32(num) == wid,
                  let b = d[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? Double, let y = b["Y"] as? Double,
                  let w = b["Width"] as? Double, let h = b["Height"] as? Double else { continue }
            return CGRect(x: x, y: y, width: w, height: h)
        }
        return nil
    }

    /// True se la finestra esiste ancora (anche su altro Space o minimizzata).
    func windowExists(_ wid: UInt32) -> Bool {
        guard let cfInfo = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) else {
            return false
        }
        let list = cfInfo as NSArray as? [[String: Any]] ?? []
        return list.contains { ($0[kCGWindowNumber as String] as? Int).map(UInt32.init) == wid }
    }
}

// MARK: - Watchdog "tieni davanti" (sperimentale, opt-in)

/// Log su file per diagnosi (l'assistente lo legge direttamente).
enum WatchdogLog {
    static let url = FileManager.default.temporaryDirectory.appendingPathComponent("windowup-watchdog.log")

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    static func write(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Ogni secondo: se l'app seguita non è più la più in alto, le invia un raise.
/// Richiede Accessibilità. Può rubare il focus a seconda dell'app: se succede,
/// significa che macOS non permette di meglio senza SIP — spegnilo.
final class WatchdogManager: ObservableObject {
    static let shared = WatchdogManager()

    @Published var watched: [WatchedWindow] = []
    @Published var needsPermission: Bool = false
    @Published var lastResult: String = ""
    @Published var frontmostName: String = ""
    private var timer: Timer?

    var isWatching: Bool { !watched.isEmpty }
    var totalRaises: Int { watched.reduce(0) { $0 + $1.raises } }
    var watchedNames: String { watched.map(\.name).joined(separator: ", ") }

    func isWatching(pid: pid_t, wid: UInt32?) -> Bool {
        watched.contains { $0.pid == pid && $0.wid == wid }
    }

    /// Click sulle card: aggiunge se assente, toglie se già seguita.
    @discardableResult
    func toggle(pid: pid_t, wid: UInt32?, name: String) -> Bool {
        if let idx = watched.firstIndex(where: { $0.pid == pid && $0.wid == wid }) {
            let w = watched[idx]
            watched.remove(at: idx)
            RingOverlay.shared.hide(pid: w.pid, wid: w.wid)
            WatchdogLog.write("untoggle \(w.name)")
            if watched.isEmpty { timer?.invalidate(); timer = nil }
            return false
        }
        return start(pid: pid, wid: wid, name: name)
    }

    @discardableResult
    func start(pid: pid_t, wid: UInt32?, name: String) -> Bool {
        let trusted = WindowPinning.shared.isAccessibilityTrusted()
        if watched.isEmpty { WatchdogLog.clear() }
        WatchdogLog.write("start pid=\(pid) wid=\(wid.map(String.init(describing:)) ?? "-") name=\(name) trusted=\(trusted)")
        guard trusted else {
            needsPermission = true
            lastResult = "trust NO al momento del click"
            WindowPinning.shared.promptAccessibility()
            return false
        }
        needsPermission = false
        if !watched.contains(where: { $0.pid == pid && $0.wid == wid }) {
            watched.append(WatchedWindow(pid: pid, wid: wid, name: name))
            RingOverlay.shared.show(pid: pid, wid: wid)
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
            if let t = timer { RunLoop.main.add(t, forMode: .common) }
        }
        tick()
        return true
    }

    func stopOne(id: String) {
        if let idx = watched.firstIndex(where: { $0.id == id }) {
            let w = watched[idx]
            WatchdogLog.write("stop \(w.name)")
            watched.remove(at: idx)
            RingOverlay.shared.hide(pid: w.pid, wid: w.wid)
        }
        if watched.isEmpty { timer?.invalidate(); timer = nil }
    }

    func stop() {
        WatchdogLog.write("stop all")
        timer?.invalidate()
        timer = nil
        watched.removeAll()
        RingOverlay.shared.hideAll()
    }

    func openLog() {
        NSWorkspace.shared.open(WatchdogLog.url)
    }

    /// Ricontrolla il permesso senza mostrare prompt: serve perché dopo la
    /// concessione in Impostazioni l'app va rilanciata (il trust è per-processo).
    func refreshTrust() {
        if WindowPinning.shared.isAccessibilityTrusted() {
            needsPermission = false
        }
    }

    /// Un singolo raise manuale su tutte le seguite, con esito visibile.
    @discardableResult
    func raiseOnce() -> String {
        guard !watched.isEmpty else {
            lastResult = "nessuna app seguita"
            return lastResult
        }
        var parts: [String] = []
        for i in watched.indices {
            let r = WindowPinning.shared.raiseAppWindows(pid: watched[i].pid)
            parts.append("\(watched[i].name): \(r)")
            if r.hasPrefix("raise ok") { watched[i].raises += 1 }
        }
        lastResult = parts.joined(separator: " | ")
        WatchdogLog.write("raiseOnce -> \(lastResult)")
        return lastResult
    }

    private func doRaise(index i: Int, why: String) {
        let pid = watched[i].pid
        let res = WindowPinning.shared.raiseAppWindows(pid: pid)
        // Verifica reale: la finestra è davvero arrivata in alto?
        var verified = "verifica: n/d"
        if let wid = watched[i].wid {
            let top = WindowPinning.shared.orderedLayer0Windows().first
            verified = (top?.wid == wid) ? "verifica: in alto SÌ" : "verifica: NON in alto (top=\(top.map { String(describing: $0.wid) } ?? "-"))"
        }
        lastResult = "\(res), \(verified)"
        WatchdogLog.write("tick front=\(frontmostName) watched=\(watched[i].name) (\(why)) -> \(lastResult)")
        if res.hasPrefix("raise ok") { watched[i].raises += 1 }
    }

    private func tick() {
        guard !watched.isEmpty else { return }
        let ordered = WindowPinning.shared.orderedLayer0Windows()
        let own = ProcessInfo.processInfo.processIdentifier
        if let top = ordered.first {
            frontmostName = NSRunningApplication(processIdentifier: top.pid)?.localizedName ?? "pid \(top.pid)"
        } else {
            frontmostName = "—"
        }
        var notes: [String] = []
        // Itera su copia degli indici: stopOne muta l'array.
        for i in watched.indices.reversed() {
            guard watched.indices.contains(i) else { continue }
            let w = watched[i]
            if let wid = w.wid {
                if let idx = ordered.firstIndex(where: { $0.wid == wid }) {
                    if idx == 0 { notes.append("\(w.name): già davanti"); continue }
                    if ordered[0].pid == own { notes.append("\(w.name): coperta da WindowUP (pausa)"); continue }
                    doRaise(index: i, why: "wid \(wid) in posizione \(idx)")
                    continue
                }
                if WindowPinning.shared.windowExists(wid) {
                    notes.append("\(w.name): altro Space/nascosta (pausa)")
                    continue
                }
                if let same = ordered.first(where: { $0.pid == w.pid }) {
                    watched[i].wid = same.wid
                    WatchdogLog.write("wid \(wid) sparito, adottato \(same.wid)")
                    doRaise(index: i, why: "adottato wid \(same.wid)")
                    continue
                }
                notes.append("\(w.name): chiusa, rimossa")
                WatchdogLog.write("tick wid \(wid) sparito, nessuna finestra di \(w.name): remove")
                stopOne(id: w.id)
                continue
            }
            // Modalità PID (l'app non aveva finestre layer-0 al click).
            if let top = ordered.first, top.pid == w.pid { notes.append("\(w.name): app davanti"); continue }
            if let top = ordered.first, top.pid == own { notes.append("\(w.name): coperta da WindowUP (pausa)"); continue }
            doRaise(index: i, why: "modalità PID")
        }
        if !lastResult.hasPrefix("raise") { lastResult = notes.joined(separator: " • ") }
    }
}

struct WatchedWindow: Identifiable, Equatable {
    let pid: pid_t
    var wid: UInt32?
    let name: String
    var raises: Int = 0
    var id: String { "\(pid)-\(wid.map(String.init(describing:)) ?? "pid")" }
}

// MARK: - Cerchietto azzurrino attorno alle finestre seguite

/// Overlay proprio (borderless, click-through, mai attivo): disegna un anello
/// azzurro attorno a ogni finestra seguita e la segue se si sposta.
final class RingView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 5, dy: 5)
        let path = NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14)
        NSColor(red: 0.45, green: 0.78, blue: 1.0, alpha: 0.95).setStroke()
        path.lineWidth = 4
        path.stroke()
        NSColor.white.withAlphaComponent(0.5).setStroke()
        let inner = NSBezierPath(roundedRect: r.insetBy(dx: 4, dy: 4), xRadius: 10, yRadius: 10)
        inner.lineWidth = 1
        inner.stroke()
    }
}

final class RingOverlay {
    static let shared = RingOverlay()
    private var panels: [String: NSWindow] = [:] // chiave "pid-wid"
    private var timer: Timer?

    static func key(pid: pid_t, wid: UInt32?) -> String {
        "\(pid)-\(wid.map(String.init(describing:)) ?? "pid")"
    }

    func show(pid: pid_t, wid: UInt32?) {
        let key = RingOverlay.key(pid: pid, wid: wid)
        guard panels[key] == nil else { return }
        // NSWindow (non NSPanel): non si nasconde mai al deactivate.
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        let v = RingView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        v.autoresizingMask = [.width, .height]
        panel.contentView = v
        panels[key] = panel
        startTimer()
        refresh()
    }

    func hide(pid: pid_t, wid: UInt32?) {
        let key = RingOverlay.key(pid: pid, wid: wid)
        panels[key]?.orderOut(nil)
        panels[key]?.close()
        panels.removeValue(forKey: key)
        if panels.isEmpty { stopTimer() }
    }

    func hideAll() {
        for p in panels.values { p.orderOut(nil); p.close() }
        panels.removeAll()
        stopTimer()
    }

    /// Converte coordinate server (origine alto-sx) in coordinate Cocoa.
    static func cocoaFrame(fromServer r: CGRect) -> NSRect {
        let h = NSScreen.screens.first?.frame.height ?? 900
        return NSRect(x: r.origin.x, y: h - r.origin.y - r.height,
                      width: r.width, height: r.height).insetBy(dx: -10, dy: -10)
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        if let t = timer { RunLoop.main.add(t, forMode: .common) }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        if panels.isEmpty { stopTimer(); return }
        for (key, panel) in panels {
            let parts = key.split(separator: "-")
            guard parts.count == 2 else { continue }
            let pid = pid_t(String(parts[0])) ?? 0
            let wid: UInt32? = parts[1] == "pid" ? nil : UInt32(parts[1])
            var rect: CGRect?
            if let w = wid {
                rect = WindowPinning.shared.frameForWindow(w)
            } else {
                // Modalità PID: prima finestra layer-0 dell'app.
                if let match = WindowPinning.shared.orderedLayer0Windows().first(where: { $0.pid == pid }) {
                    rect = WindowPinning.shared.frameForWindow(match.wid)
                }
            }
            guard let r = rect else { panel.orderOut(nil); continue }
            panel.setFrame(RingOverlay.cocoaFrame(fromServer: r), display: true)
            panel.orderFrontRegardless()
        }
    }
}
