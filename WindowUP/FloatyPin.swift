import Cocoa
import ScreenCaptureKit
import AVFoundation
import ApplicationServices
import Darwin

// MARK: - Metodo Floaty (senza Recovery/SIP)
//
// Nessuna API pubblica sposta la finestra DI UN'ALTRA app sopra le altre
// (CGSSetWindowLevel cross-process è no-op). Floaty Lite / PinWindow usano:
//   1. mirror live pixel-perfect via ScreenCaptureKit in un nostro pannello
//      sempre-sopra (level .floating, ignoresMouseEvents = true)
//   2. il pannello sta ESATTAMENTE sopra la finestra reale -> i click
//      passano attraverso al vero contenuto (passthrough)
//   3. un monitor globale dei click: se clicchi dentro il mirror, si attiva
//      l'app reale (così ci interagisci a lag zero)
//   4. il mirror si NASCONDE mentre la finestra reale ha il focus e ricompare
//      quando il focus va altrove (niente lag mentre usi l'app)
// Solo permessi Registrazione schermo + Accessibilità. Niente Recovery, niente SIP.

// MARK: - Cattura 60fps su AVSampleBufferDisplayLayer

final class FloatyCapture: NSObject, SCStreamDelegate, SCStreamOutput {
    let videoLayer = AVSampleBufferDisplayLayer()
    private var stream: SCStream?
    private var width = 0
    private var height = 0
    private var paused = false
    var onError: (() -> Void)?

    func startCapture(window: SCWindow) async throws {
        if stream != nil { return }
        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.capturesAudio = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)

        let filter = SCContentFilter(desktopIndependentWindow: window)
        if #available(macOS 14, *) {
            width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
            height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        } else {
            width = Int(window.frame.width * 2)
            height = Int(window.frame.height * 2)
        }
        // Evita configurazioni degeneri (finestre minimizzate / 0x0)
        width = max(2, width); height = max(2, height)
        config.width = width
        config.height = height

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        stream = s
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
        try await s.startCapture()
    }

    func stopCapture() {
        guard let s = stream else { return }
        stream = nil
        s.stopCapture { _ in }
    }

    func updateCaptureSize(width: Int, height: Int) {
        guard width >= 2, height >= 2 else { return }
        self.width = width
        self.height = height
        applyConfiguration()
    }

    /// Mentre il mirror è nascosto (finestra reale in focus) rallenta a 2fps
    /// invece di stoppare: evita la latenza di restart quando ricompare.
    func setPaused(_ paused: Bool) {
        guard self.paused != paused else { return }
        self.paused = paused
        applyConfiguration()
    }

    private func applyConfiguration() {
        guard let s = stream else { return }
        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.capturesAudio = false
        config.minimumFrameInterval = paused ? CMTime(value: 1, timescale: 2) : CMTime(value: 1, timescale: 60)
        config.width = width
        config.height = height
        s.updateConfiguration(config) { err in
            if let err = err { print("[WindowUP Floaty] updateConfig: \(err)") }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard sampleBuffer.isValid, outputType == .screen else { return }
        // SCK emette frame idle/blank a ogni tick: mostra solo quelli completi.
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let att = arr.first,
              let raw = att[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: raw),
              status == .complete else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if #available(macOS 15, *) {
                self.videoLayer.sampleBufferRenderer.enqueue(sampleBuffer)
            } else {
                self.videoLayer.enqueue(sampleBuffer)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[WindowUP Floaty] capture stopped: \(error)")
        DispatchQueue.main.async { [weak self] in
            self?.stream = nil
            self?.onError?()
        }
    }
}

// MARK: - Coordinate server (origine alto-sx) -> Cocoa

func floatyCgToNS(_ cgRect: CGRect) -> NSRect {
    guard let main = NSScreen.screens.first else { return NSRect(origin: cgRect.origin, size: cgRect.size) }
    return NSRect(x: cgRect.origin.x,
                  y: main.frame.height - cgRect.origin.y - cgRect.height,
                  width: cgRect.width, height: cgRect.height)
}

// MARK: - _AXUIElementGetWindow (privata ma stabile dal 10.5, caricata via dlopen)

private typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
private let _floatyAXGetWindow: AXGetWindowFn? = {
    guard let h = dlopen(nil, RTLD_NOW) else { return nil }
    guard let sym = dlsym(h, "_AXUIElementGetWindow") else { return nil }
    return unsafeBitCast(sym, to: AXGetWindowFn.self)
}()

func floatyAXWindowID(_ el: AXUIElement) -> CGWindowID? {
    guard let fn = _floatyAXGetWindow else { return nil }
    var wid: CGWindowID = 0
    return fn(el, &wid) == .success && wid != 0 ? wid : nil
}

// MARK: - Vista contenuto: riceve i click in modalità interattiva e li inoltra

/// In modalità interattiva (clickThrough=false) il pannello RICEVE i click:
/// il sistema ci attiva (click vero sulla nostra finestra, mai negato),
/// noi attiviamo l'app vera (da frontmost è sempre consentito), nascondiamo
/// il mirror e ripostiamo il click alle coordinate vere. Così scrivere,
/// trascinare e navigare funzionano con un solo click.
final class FloatyClickView: NSView {
    var onMouse: ((NSEvent) -> Void)?

    override func mouseDown(with e: NSEvent) { onMouse?(e) }
    override func rightMouseDown(with e: NSEvent) { onMouse?(e) }
    override func otherMouseDown(with e: NSEvent) { onMouse?(e) }
}

// MARK: - Pannello mirror stile Floaty

final class FloatyPanel {
    let scWindow: SCWindow
    let mirrorID: UUID
    let capture = FloatyCapture()
    // NSWindow e NON NSPanel: NSPanel si nasconde al deactivate dell'app
    // (click fuori = sparisce). Stesso fix già usato in FloatingPanel.swift.
    var panel: NSWindow!
    var onClosed: (() -> Void)?
    var onStatus: ((String, Bool) -> Void)? // (stato, needsPermission)

    private var axApp: AXUIElement?
    private var axObserver: AXObserver?
    private var aliveTimer: Timer?
    private var clickMonitor: Any?
    private var resizeDebounce: DispatchWorkItem?
    private var sysObservers: [NSObjectProtocol] = []
    private var realWindowFocused = false
    private var stopped = false
    private var boosted: Bool
    private var opacity: Double
    /// false = interattivo (default: riceve click e li inoltra alla vera);
    /// true = passthrough overlay (mai focus, per i giochi).
    private var clickThrough: Bool

    private static let hiddenPoll: TimeInterval = 0.25
    private static let visiblePoll: TimeInterval = 1.0

    init(scWindow: SCWindow, mirrorID: UUID, title: String, boosted: Bool, opacity: Double, clickThrough: Bool) {
        self.scWindow = scWindow
        self.mirrorID = mirrorID
        self.boosted = boosted
        self.opacity = opacity
        self.clickThrough = clickThrough

        var nsFrame = floatyCgToNS(scWindow.frame)
        if nsFrame.width < 10 || nsFrame.height < 10 {
            nsFrame.size = NSSize(width: 480, height: 360)
        }
        // .nonactivatingPanel omesso (su NSWindow è ignorato con warning 0x80).
        let p = NSWindow(contentRect: nsFrame,
                         styleMask: [.borderless, .fullSizeContentView],
                         backing: .buffered, defer: false)
        // Normale: sopra le app. Extra-sopra: tenta anche sopra i fullscreen.
        p.level = boosted ? .screenSaver : .floating
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isOpaque = false
        p.isMovableByWindowBackground = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // Passthrough: i click cadono alla finestra sotto (overlay da gioco).
        // Interattivo: il pannello riceve i click e li inoltra (vedi sotto).
        p.ignoresMouseEvents = clickThrough
        p.animationBehavior = .none
        p.alphaValue = CGFloat(max(0.3, min(1.0, opacity)))
        self.panel = p

        let view = FloatyClickView(frame: NSRect(origin: .zero, size: nsFrame.size))
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.masksToBounds = true
        let vl = capture.videoLayer
        vl.frame = view.bounds
        vl.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(vl)
        view.onMouse = { [weak self] e in self?.handleMirrorClick(e) }
        p.contentView = view
        if !title.isEmpty { p.title = title }

        capture.onError = { [weak self] in
            self?.handleCaptureError()
        }
    }

    @MainActor
    func start() async {
        panel.orderFrontRegardless()
        observeSystemChanges()
        onStatus?("connessione…", false)
        do {
            try await capture.startCapture(window: scWindow)
        } catch {
            print("[WindowUP Floaty] capture failed: \(error)")
            handleStartError(error)
            return
        }
        guard !stopped else { return }
        onStatus?("LIVE", false)
        startAXObserver()
        // Il monitor globale serve solo in passthrough (il pannello non riceve
        // eventi): in interattivo i click arrivano alla vista e li inoltriamo.
        if clickThrough { startClickMonitor() }
        updateFocusState()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        aliveTimer?.invalidate(); aliveTimer = nil
        resizeDebounce?.cancel(); resizeDebounce = nil
        for o in sysObservers { NotificationCenter.default.removeObserver(o) }
        sysObservers.removeAll()
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let obs = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        axObserver = nil
        axApp = nil
        capture.stopCapture()
        panel.orderOut(nil)
        panel.close()
        onClosed?()
    }

    func apply(opacity: Double, boosted: Bool, clickThrough: Bool) {
        self.opacity = opacity
        self.boosted = boosted
        self.clickThrough = clickThrough
        panel.alphaValue = CGFloat(max(0.3, min(1.0, opacity)))
        panel.level = boosted ? .screenSaver : .floating
        panel.ignoresMouseEvents = clickThrough
        if clickThrough {
            if clickMonitor == nil { startClickMonitor() }
        } else {
            if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        }
    }

    func reveal() {
        // "Mostra": se la finestra vera è in focus il mirror è giustamente
        // nascosto; altrimenti riportalo sopra e risincronizza la geometria.
        if realWindowFocused { return }
        syncFrame()
        panel.orderFrontRegardless()
    }

    // MARK: - Errori avvio

    @MainActor
    private func handleStartError(_ error: Error) {
        let code = (error as NSError).code
        if code == -3801 || code == -3802 {
            onStatus?("serve Registrazione schermo", true)
        } else {
            onStatus?("errore cattura (\(code))", false)
        }
        // Chiudi dopo un attimo: l'utente legge lo stato nella lista.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.stop()
        }
    }

    private func handleCaptureError() {
        onStatus?("cattura interrotta", false)
        stop()
    }

    // MARK: - AXObserver (sposta/ridimensiona/focus senza polling stretto)

    private func startAXObserver() {
        guard let pid = scWindow.owningApplication?.processID else { return }
        let app = AXUIElementCreateApplication(pid_t(pid))
        AXUIElementSetMessagingTimeout(app, 0.1)
        self.axApp = app
        let axWin = findAXWindow(axApp: app)

        typealias CB = @convention(c) (AXObserver, AXUIElement, CFString, UnsafeMutableRawPointer?) -> Void
        let cb: CB = { _, _, name, ptr in
            guard let ptr else { return }
            let panel = Unmanaged<FloatyPanel>.fromOpaque(ptr).takeUnretainedValue()
            DispatchQueue.main.async { panel.handleAXNotification(name as String) }
        }
        var obs: AXObserver?
        guard AXObserverCreate(pid_t(pid), cb, &obs) == .success, let observer = obs else { return }
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        if let axWin {
            addAXNotification(observer, axWin, kAXWindowMovedNotification as String, ptr)
            addAXNotification(observer, axWin, kAXWindowResizedNotification as String, ptr)
        }
        addAXNotification(observer, app, kAXApplicationActivatedNotification as String, ptr)
        addAXNotification(observer, app, kAXApplicationDeactivatedNotification as String, ptr)
        addAXNotification(observer, app, kAXFocusedWindowChangedNotification as String, ptr)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObserver = observer
    }

    private func addAXNotification(_ obs: AXObserver, _ el: AXUIElement, _ name: String, _ ptr: UnsafeMutableRawPointer) {
        let r = AXObserverAddNotification(obs, el, name as CFString, ptr)
        if r != .success { print("[WindowUP Floaty] AX observe \(name): \(r.rawValue)") }
    }

    private func handleAXNotification(_ name: String) {
        guard !stopped else { return }
        if name == kAXWindowMovedNotification as String || name == kAXWindowResizedNotification as String {
            syncFrame()
        } else {
            checkAlive()
        }
    }

    private func findAXWindow(axApp: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let wins = ref as? [AXUIElement] else { return nil }
        for w in wins {
            if let wid = floatyAXWindowID(w), wid == scWindow.windowID { return w }
        }
        // Fallback senza API privata: prima finestra (meglio di niente).
        return wins.first
    }

    // MARK: - Geometria: il mirror segue la finestra vera pixel-perfect

    func syncFrame() {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], scWindow.windowID) as? [[String: Any]],
              let first = info.first,
              let b = first[kCGWindowBounds as String] as? [String: CGFloat] else { return }
        let cg = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        guard cg.width >= 2, cg.height >= 2 else { return }
        let ns = floatyCgToNS(cg)
        if panel.frame.size != ns.size {
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            let w = Int(ns.width * scale), h = Int(ns.height * scale)
            resizeDebounce?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.capture.updateCaptureSize(width: w, height: h) }
            resizeDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
        if panel.frame != ns {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            panel.setFrame(ns, display: true)
            CATransaction.commit()
        }
    }

    // MARK: - Hide-while-focused + auto-unpin

    private func scheduleAliveCheck() {
        aliveTimer?.invalidate()
        let iv = realWindowFocused ? Self.hiddenPoll : Self.visiblePoll
        aliveTimer = Timer.scheduledTimer(withTimeInterval: iv, repeats: false) { [weak self] _ in
            self?.checkAlive()
        }
    }

    private func checkAlive() {
        guard !stopped else { return }
        let exists = CGWindowListCopyWindowInfo([.optionIncludingWindow], scWindow.windowID) as? [[String: Any]]
        if exists?.isEmpty ?? true {
            stop() // la finestra è stata chiusa -> auto-unpin via onClosed
            return
        }
        updateFocusState()
    }

    /// Vera solo se LA finestra pinnata (non un'altra dello stesso pid) ha il focus.
    private func isRealWindowFocused() -> Bool {
        isRealWindowFocused(frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    /// Overload iniettabile per i test (stessa logica, frontPID finto).
    func isRealWindowFocused(frontPID: pid_t?) -> Bool {
        guard let pid = scWindow.owningApplication?.processID,
              frontPID == pid_t(pid),
              let app = axApp else { return false }
        var ref: CFTypeRef?
        let st = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &ref)
        guard st == .success, let focusedRaw = ref,
              CFGetTypeID(focusedRaw) == AXUIElementGetTypeID() else {
            // App occupata (cannotComplete: tieni lo stato per non far lampeggiare).
            // Focus non-finestra / tipo inatteso (es. desktop): non è la nostra
            // finestra -> NON nascondere (return false qui sotto).
            if st == .cannotComplete { return realWindowFocused }
            return false
        }
        let focused = focusedRaw as! AXUIElement // sicuro dopo il type check
        return isPinnedWindowFocused(focused)
    }

    /// True solo se l'elemento AX focalizzato è proprio la finestra pinnata.
    /// Focus non-finestra (desktop, menu): non mappabile a un windowID ->
    /// NON è la nostra finestra -> il mirror deve restare visibile.
    func isPinnedWindowFocused(_ el: AXUIElement) -> Bool {
        if let wid = floatyAXWindowID(el) {
            return wid == scWindow.windowID
        }
        return false
    }

    private func updateFocusState() {
        let focused = isRealWindowFocused()
        if focused != realWindowFocused {
            realWindowFocused = focused
            if focused {
                capture.setPaused(true)
                panel.orderOut(nil)
            } else {
                capture.setPaused(false)
                syncFrame()
                panel.orderFrontRegardless()
            }
        }
        scheduleAliveCheck()
    }

    // MARK: - Click-to-activate: clicchi il mirror, usi la finestra vera a lag zero

    private func startClickMonitor() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            guard let self else { return }
            // Solo passthrough: il click è già arrivato sotto; se ha colpito
            // il mirror sopra, prova ad attivare l'app vera.
            if self.panel.frame.contains(NSEvent.mouseLocation) && !self.isRealWindowFocused() {
                self.activateRealWindow()
            }
        }
    }

    // MARK: - Inoltro click (modalità interattiva)

    /// Il click è arrivato ALLA NOSTRA finestra: il sistema ci ha attivati e da
    /// frontmost possiamo cedere il focus all'app vera (mai negato). Nascondiamo
    /// il mirror e ripostiamo il click alle coordinate vere: scrivere, trascinare
    /// il titolo per spostare e navigare funzionano con un solo click.
    private func handleMirrorClick(_ event: NSEvent) {
        guard !stopped, !clickThrough else { return }
        let button: CGMouseButton
        let downType, upType: CGEventType
        switch event.type {
        case .rightMouseDown:
            button = .right; downType = .rightMouseDown; upType = .rightMouseUp
        case .otherMouseDown:
            button = CGMouseButton(rawValue: UInt32(event.buttonNumber)) ?? .center
            downType = .otherMouseDown; upType = .otherMouseUp
        default:
            // Ctrl+click = tasto destro; il resto è sinistro.
            if event.modifierFlags.contains(.control) {
                button = .right; downType = .rightMouseDown; upType = .rightMouseUp
            } else {
                button = .left; downType = .leftMouseDown; upType = .leftMouseUp
            }
        }
        // Mirror e finestra vera hanno la stessa geometria (syncFrame): il punto
        // in coordinate finestra vale anche per la finestra vera.
        let inWindow = event.locationInWindow
        let screenCocoa = NSPoint(x: panel.frame.origin.x + inWindow.x,
                                  y: panel.frame.origin.y + inWindow.y)
        guard let realPID = scWindow.owningApplication?.processID else { return }
        let clickCount = max(1, event.clickCount)
        let modifiers = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
        activateRealWindow()
        // Nascondi subito (la vera sta arrivando davanti): evita flash/lag.
        realWindowFocused = true
        capture.setPaused(true)
        panel.orderOut(nil)
        scheduleAliveCheck()
        // La vera impiega un attimo a salire: il raise va fatto QUANDO è
        // davanti (da background è no-op), e il click ripostato solo quando la
        // finestra pinnata è davvero in alto, altrimenti cadrebbe su quella
        // coprente.
        Task { [weak self] in
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, !self.stopped else { return }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid_t(realPID) { break }
            }
            guard let self, !self.stopped else { return }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid_t(realPID) else {
                await self.restoreMirrorAfterFailedClick()
                return
            }
            let realWID = CGWindowID(self.scWindow.windowID)
            for i in 0..<40 {
                // AX va toccata sul main thread: da background, su finestre
                // del nostro stesso processo, AppKit va in trap nella window
                // transaction (EXC_BREAKPOINT verificato). Verso altre app
                // passa per XPC ma resta main-only per correttezza.
                if i % 6 == 0 { await MainActor.run { self.raiseRealWindow() } }
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !self.stopped else { return }
                if Self.topWindowID() == realWID { break }
            }
            guard !self.stopped else { return }
            guard Self.topWindowID() == realWID else {
                // Coperta da altra finestra: non ripostare (misclick), l'utente
                // clicca la vera direttamente. Rimostra il mirror.
                #if DEBUG
                print("[WindowUP Floaty] drop click: top=\(Self.topWindowID().map(String.init(describing:)) ?? "-") want=\(realWID)")
                #endif
                await self.restoreMirrorAfterFailedClick()
                return
            }
            #if DEBUG
            print("[WindowUP Floaty] repost click at \(screenCocoa) button=\(button.rawValue) count=\(clickCount)")
            #endif
            self.repostClick(at: screenCocoa, button: button,
                             down: downType, up: upType,
                             count: clickCount, flags: modifiers)
        }
    }

    @MainActor
    private func restoreMirrorAfterFailedClick() {
        realWindowFocused = false
        capture.setPaused(false)
        syncFrame()
        panel.orderFrontRegardless()
    }

    /// WindowNumber della finestra layer-0 più in alto, oppure nil.
    private static func topWindowID() -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as NSArray? as? [[String: Any]] else { return nil }
        for d in list {
            guard let layer = d[kCGWindowLayer as String] as? Int, layer == 0,
                  let num = d[kCGWindowNumber as String] as? Int else { continue }
            return CGWindowID(num)
        }
        return nil
    }

    /// Converte un punto schermo Cocoa (origine basso-sx) in coordinate server
    /// (origine alto-sx) e riposta down/up con clickCount e modificatori.
    private func repostClick(at cocoa: NSPoint, button: CGMouseButton,
                             down: CGEventType, up: CGEventType,
                             count: Int, flags: CGEventFlags) {
        let h = NSScreen.screens.first?.frame.height ?? 1000
        let pt = CGPoint(x: cocoa.x, y: h - cocoa.y)
        let src = CGEventSource(stateID: .hidSystemState)
        for i in 1...max(1, count) {
            guard let d = CGEvent(mouseEventSource: src, mouseType: down,
                                   mouseCursorPosition: pt, mouseButton: button),
                  let u = CGEvent(mouseEventSource: src, mouseType: up,
                                   mouseCursorPosition: pt, mouseButton: button) else { return }
            d.flags = flags
            u.flags = flags
            d.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            u.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            d.post(tap: .cghidEventTap)
            u.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Resta sopra dopo cambio Space / deactivate / Mission Control

    private func observeSystemChanges() {
        let nc = NotificationCenter.default
        if let ws = NSWorkspace.shared.notificationCenter as NotificationCenter? {
            sysObservers.append(ws.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil, queue: .main) { [weak self] _ in self?.reassertTopMost() })
        }
        sysObservers.append(nc.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in self?.reassertTopMost() })
        sysObservers.append(nc.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in self?.reassertTopMost() })
        sysObservers.append(nc.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.reassertTopMost() })
    }

    /// Non nascondere mai per deactivate/click-fuori: l'unico hide lecito è
    /// "la finestra vera è in focus" (gestito da updateFocusState).
    private func reassertTopMost() {
        guard !stopped, !realWindowFocused else { return }
        let want: NSWindow.Level = boosted ? .screenSaver : .floating
        if panel.level != want { panel.level = want }
        syncFrame()
        panel.orderFrontRegardless()
    }

    func activateRealWindow() {
        guard let bundleID = scWindow.owningApplication?.bundleIdentifier,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return }
        app.activate(options: [.activateAllWindows])
        raiseRealWindow()
    }

    /// Solleva la finestra pinnata via AX (efficace solo ad app già davanti).
    private func raiseRealWindow() {
        guard let pid = scWindow.owningApplication?.processID else { return }
        let axApp = AXUIElementCreateApplication(pid_t(pid))
        if let axWin = findAXWindow(axApp: axApp) {
            #if DEBUG
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &t)
            print("[WindowUP Floaty] raise wid=\(scWindow.windowID) axTitle=\(t as? String ?? "?")")
            #endif
            AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)
        } else {
            #if DEBUG
            print("[WindowUP Floaty] raise: AX window non trovata per wid=\(scWindow.windowID)")
            #endif
        }
    }
}
