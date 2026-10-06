import AppKit
import SwiftUI
import Combine

/// Sorgente unica di verità: tiene items + NSPanel reali.
final class PanelManager: ObservableObject {
    static let shared = PanelManager()

    @Published var items: [PinnedItem] = []
    private var panels: [UUID: FloatingPanel] = [:]
    private let storeKey = "windowup.items.v1"
    private var firstRestoreDone = false

    private init() {
        load()
    }

    // MARK: - CRUD

    func open(_ item: PinnedItem) {
        var newItem = item
        // Evita duplicati con stesso URL: riusa
        if let existing = items.first(where: { $0.urlString == newItem.urlString }) {
            bringToFront(id: existing.id)
            return
        }
        if items.contains(where: { $0.id == newItem.id }) {
            newItem.id = UUID()
        }
        items.append(newItem)
        save()
        showPanel(for: newItem)
    }

    func update(_ item: PinnedItem, reloadWebView: Bool = false) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx] = item
        save()
        if let panel = panels[item.id] {
            panel.apply(item)
            // La webview si aggiorna da sola via onChange di item.urlString
        }
    }

    func close(id: UUID) {
        panels[id]?.close()
        panels.removeValue(forKey: id)
        items.removeAll { $0.id == id }
        save()
    }

    func closeAll() {
        for id in panels.keys { panels[id]?.close() }
        panels.removeAll()
        items.removeAll()
        save()
    }

    func isVisible(id: UUID) -> Bool {
        panels[id]?.isVisible ?? false
    }

    func toggle(id: UUID) {
        guard let panel = panels[id] else {
            if let item = items.first(where: { $0.id == id }) { showPanel(for: item) }
            return
        }
        if panel.isVisible { panel.hideByUser() } else { bringToFront(id: id) }
    }

    func bringToFront(id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if let panel = panels[id] {
            panel.apply(item)
            // Passivo: resta sopra senza rubare focus al gioco/app sotto.
            // Per scrivere dentro: click nel campo (nonactivating -> diventa
            // key solo lì) oppure usa focusForTyping() dal bottone "Scrivi".
            panel.orderFrontPassive()
        } else {
            showPanel(for: item)
        }
    }

    /// Azione esplicita "voglio scriverci": porta davanti + rende key.
    func focusForTyping(id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if let panel = panels[id] {
            panel.apply(item)
            panel.focusForTyping()
        } else {
            showPanel(for: item, takeKey: true)
        }
    }

    func showAll() {
        for item in items { bringToFront(id: item.id) }
    }

    func hideAll() {
        for panel in panels.values { panel.hideByUser() }
    }

    // MARK: - Pannelli

    private func showPanel(for item: PinnedItem, takeKey: Bool = false) {
        if let existing = panels[item.id] {
            existing.apply(item)
            if takeKey { existing.focusForTyping() } else { existing.orderFrontPassive() }
            return
        }
        let content = FloatingPanelContentView(manager: self, itemID: item.id)
        // Usiamo un hosting view con environment
        let hosting = NSHostingView(rootView: content.environmentObject(self))
        hosting.frame = NSRect(x: 0, y: 0, width: CGFloat(item.width), height: CGFloat(item.height))
        let panel = FloatingPanel(item: item, contentView: hosting)
        // Quando l'utente chiude con la X rossa: rimuovi dai dati
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            self?.panels[item.id] = nil
            self?.items.removeAll { $0.id == item.id }
            self?.save()
            self?.objectWillChange.send()
        }
        panels[item.id] = panel
        if takeKey { panel.focusForTyping() } else { panel.orderFrontPassive() }
    }

    private func binding(for id: UUID) -> PinnedItem? {
        items.first(where: { $0.id == id })
    }

    // MARK: - Persistenza

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode([PinnedItem].self, from: data) else {
            // Prima apertura: esempio WhatsApp in quadrato piccolo
            items = [PinnedItem(title: "WhatsApp", urlString: "https://web.whatsapp.com", width: 400, height: 400)]
            return
        }
        items = decoded
    }

    /// Riapre le finestre della sessione precedente (chiamato da AppDelegate).
    func restorePreviousSession() {
        guard !firstRestoreDone else { return }
        firstRestoreDone = true
        // Se è il primo avvio con l'esempio di default, aprilo subito
        for item in items { showPanel(for: item) }
    }
}
