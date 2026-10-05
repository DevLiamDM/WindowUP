import AppKit
import SwiftUI

/// Pannello flottante sempre in primo piano: spostabile + ridimensionabile come una normale finestra.
///
/// Tiene la posizione sopra in due modi combinati (approccio misto):
/// 1. livello finestra alto (`.floating`, o `.screenSaver` con Extra-sopra);
/// 2. heartbeat ogni 2.5s che ri-asserisce livello e ordine in modo passivo
///    (`orderFrontRegardless`, mai `makeKey`: non ruba il focus e non disturba
///    la digitazione). Il timer si ferma alla chiusura del pannello.
final class FloatingPanel: NSPanel {
    let itemID: UUID
    private var expectedLevel: NSWindow.Level = .floating
    private var keepFrontTimer: Timer?

    init(item: PinnedItem, contentView: NSView) {
        self.itemID = item.id
        super.init(
            contentRect: NSRect(x: 200, y: 200, width: CGFloat(item.width), height: CGFloat(item.height)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.title = item.title
        self.contentView = contentView
        self.isReleasedWhenClosed = false
        self.isMovable = true
        self.isMovableByWindowBackground = false
        self.hidesOnDeactivate = false
        self.isFloatingPanel = true
        self.becomesKeyOnlyIfNeeded = false
        self.animationBehavior = .default
        self.minSize = NSSize(width: 240, height: 240)
        self.collectionBehavior = [.fullScreenAuxiliary]
        // Mantiene l'aspect sbloccato: l'utente ridimensiona liberamente
        self.contentMinSize = NSSize(width: 240, height: 240)
        apply(item)
        centerIfNeeded()
        startKeepFrontHeartbeat()
    }

    override func close() {
        keepFrontTimer?.invalidate()
        keepFrontTimer = nil
        super.close()
    }

    deinit {
        keepFrontTimer?.invalidate()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func apply(_ item: PinnedItem) {
        title = item.title
        alphaValue = CGFloat(max(0.3, min(1.0, item.opacity)))
        level = item.levelBoosted ? .screenSaver : .floating
        expectedLevel = level
        var behavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary]
        if item.joinAllSpaces {
            behavior.insert(.canJoinAllSpaces)
            behavior.insert(.stationary)
        } else {
            behavior.insert(.managed)
        }
        collectionBehavior = behavior
        // Ridimensiona mantenendo l'origine in alto (evita salti strani)
        var frame = frame
        let newSize = NSSize(width: CGFloat(item.width), height: CGFloat(item.height))
        let deltaH = newSize.height - frame.size.height
        frame.origin.y -= deltaH
        frame.size = newSize
        setFrame(frame, display: true, animate: true)
    }

    private func centerIfNeeded() {
        if let screen = NSScreen.main {
            let r = screen.visibleFrame
            if frame.origin.x == 200 && frame.origin.y == 200 {
                setFrameOrigin(NSPoint(x: r.maxX - frame.width - 40, y: r.maxY - frame.height - 60))
            }
        }
    }

    /// Riporta sopra il pannello se il sistema lo ha abbassato (es. cambio
    /// Space, fullscreen altrui, dialoghi). Passivo: niente focus, niente
    /// geometria, salta i pannelli nascosti/minimizzati.
    private func startKeepFrontHeartbeat() {
        keepFrontTimer?.invalidate()
        keepFrontTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            self?.reassertTopMost()
        }
        if let t = keepFrontTimer { RunLoop.main.add(t, forMode: .common) }
    }

    private func reassertTopMost() {
        guard isVisible, !isMiniaturized else { return }
        if level != expectedLevel { level = expectedLevel }
        orderFrontRegardless()
    }
}
