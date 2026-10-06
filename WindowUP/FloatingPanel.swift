import AppKit
import SwiftUI
import CoreGraphics

/// Overlay di sistema: una NOSTRA finestra sempre sopra tutto.
///
/// Approccio nuovo (sostituisce CGSSetWindowLevel cross-process, che su
/// macOS 15/26 è no-op verificato):
/// - non tocchiamo mai le finestre altrui: mostriamo pannelli nostri
///   (siti web, terminale integrato, mirror live ScreenCaptureKit)
/// - livello alto: `.screenSaver` di default (1000, sopra app normali,
///   sopra "Mostra Desktop", sopra Spaces), `.maximumWindow` con Extra-sopra
///   (sopra anche i giochi fullscreen)
/// - collection sempre `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]`
///   così il pannello segue ogni Space e appare anche sugli Space fullscreen
/// - style `.nonactivatingPanel`: ordinato davanti SENZA attivare WindowUP,
///   quindi il gioco/app sotto non si minimizza e non perde lo Space;
///   i click sul pannello non arrivano mai alle finestre sotto
///   (`ignoresMouseEvents = false` di default), e i click fuori non lo nascondono
/// - heartbeat passivo ogni 0.5s + osservatori Space/attivazione:
///   solo `orderFrontRegardless`, mai `makeKey`, mai `NSApp.activate`
///   -> non ruba il focus mentre giochi o scrivi altrove.
/// Overlay di sistema: una NOSTRA finestra sempre sopra tutto.
///
/// NOTA BENE: eredita da NSWindow e NON da NSPanel. NSPanel nasconde
/// automaticamente i floating panel al deactivate dell'app (anche con
/// hidesOnDeactivate=false in alcuni casi di sistema): era quello che
/// faceva sparire gli overlay appena si cliccava fuori. NSWindow resta su.
final class FloatingPanel: NSWindow {
    let itemID: UUID
    private var expectedLevel: NSWindow.Level = FloatingPanel.baseLevel
    private var keepFrontTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// Nascondere esplicito dell'utente (Nascondi/X). Il timer non deve
    /// resuscitare questi; quelli di sistema invece vanno sempre riportati su.
    private var userHidden = false

    /// Sopra app normali + Mostra Desktop + Mission Control.
    static var baseLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
    }

    /// Ancora più sopra: fullscreen esclusivo, menu, Dock.
    static var ultraLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
    }

    init(item: PinnedItem, contentView: NSView) {
        self.itemID = item.id
        super.init(
            contentRect: NSRect(x: 200, y: 200, width: CGFloat(item.width), height: CGFloat(item.height)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.title = item.title
        self.contentView = contentView
        self.isReleasedWhenClosed = false
        self.isMovable = true
        self.isMovableByWindowBackground = false
        // NSWindow non ha hidesOnDeactivate/isFloatingPanel/becomesKeyOnlyIfNeeded:
        // non si nasconde mai al deactivate. Lo style .nonactivatingPanel fa sì
        // che il click non attivi WindowUP (il gioco/app sotto non si minimizza).
        self.hasShadow = true
        self.animationBehavior = .none
        self.minSize = NSSize(width: 240, height: 240)
        self.contentMinSize = NSSize(width: 240, height: 240)
        // I click restano sul pannello, non cadono alle finestre sotto.
        self.ignoresMouseEvents = false
        // Mai sotto le altre finestre: ignora il ciclo Cmd+` e resta su.
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        apply(item)
        centerIfNeeded()
        startKeepFrontHeartbeat()
        observeSystemChanges()
    }

    override func close() {
        keepFrontTimer?.invalidate()
        keepFrontTimer = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        super.close()
    }

    deinit {
        keepFrontTimer?.invalidate()
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func apply(_ item: PinnedItem) {
        title = item.title
        alphaValue = CGFloat(max(0.3, min(1.0, item.opacity)))
        // Default = già sopra tutto. Extra-sopra = ancora più alto.
        let lvl = item.levelBoosted ? Self.ultraLevel : Self.baseLevel
        level = lvl
        expectedLevel = lvl
        // Sempre su tutti gli Space + sopra i fullscreen.
        // (Il toggle "Tutti gli Spaces" è tenuto per compatibilità UI,
        // ma il comportamento pin richiede sempre questi flag.)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        var frame = frame
        let newSize = NSSize(width: CGFloat(item.width), height: CGFloat(item.height))
        let deltaH = newSize.height - frame.size.height
        frame.origin.y -= deltaH
        frame.size = newSize
        setFrame(frame, display: true, animate: false)
    }

    /// Mostra senza rubare focus: da usare per ogni show/bring-to-front.
    func orderFrontPassive() {
        userHidden = false
        orderFrontRegardless()
    }

    /// Solo su azione esplicita dell'utente ("Scrivi", click nel campo):
    /// porta davanti E rende scrivibile.
    func focusForTyping() {
        userHidden = false
        orderFrontRegardless()
        makeKeyAndOrderFront(nil)
    }

    /// Nascondimento esplicito dell'utente (bottone Nascondi). Chiamare QUESTO
    /// e non orderOut diretto: il timer deve distinguere "nascosto da te"
    /// (resta giù) da "nascosto dal sistema" (va riportato su).
    func hideByUser() {
        userHidden = true
        super.orderOut(nil)
    }

    private func centerIfNeeded() {
        if let screen = NSScreen.main {
            let r = screen.visibleFrame
            if frame.origin.x == 200 && frame.origin.y == 200 {
                setFrameOrigin(NSPoint(x: r.maxX - frame.width - 40, y: r.maxY - frame.height - 60))
            }
        }
    }

    private func observeSystemChanges() {
        let nc = NotificationCenter.default
        // Cambio Space / Mission Control / fullscreen / Mostra Desktop:
        // ri-asserisci subito, senza aspettare il prossimo tick.
        if let ws = NSWorkspace.shared.notificationCenter as NotificationCenter? {
            observers.append(ws.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil, queue: .main) { [weak self] _ in self?.reassertTopMost() })
        }
        observers.append(nc.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in self?.reassertTopMost() })
        observers.append(nc.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in self?.reassertTopMost() })
        observers.append(nc.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.reassertTopMost() })
    }

    private func startKeepFrontHeartbeat() {
        keepFrontTimer?.invalidate()
        keepFrontTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.reassertTopMost()
        }
        if let t = keepFrontTimer { RunLoop.main.add(t, forMode: .common) }
    }

    /// Passivo: niente focus, niente geometria, salta minimizzati e
    /// nascosti-dall'utente. Se il SISTEMA lo ha nascosto/abbassato (cambio
    /// Space, fullscreen, Mostra Desktop), lo riporta sempre su.
    private func reassertTopMost() {
        guard !userHidden, !isMiniaturized else { return }
        if level != expectedLevel { level = expectedLevel }
        if collectionBehavior != [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle] {
            collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        }
        orderFrontRegardless()
    }
}
