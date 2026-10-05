import SwiftUI

@main
struct WindowUPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var manager = PanelManager.shared

    var body: some Scene {
        WindowGroup(id: "manager") {
            ContentView()
                .environmentObject(manager)
                .frame(minWidth: 560, minHeight: 620)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nuova finestra pinnata") {
                    PanelManager.shared.open(PinnedItem(
                        title: "Google",
                        urlString: "https://www.google.com",
                        width: 420, height: 520
                    ))
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("WindowUP") {
                Button("Mostra tutte") { PanelManager.shared.showAll() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Nascondi tutte") { PanelManager.shared.hideAll() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(manager)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Riapre le finestre salvate dalla scorsa sessione
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            PanelManager.shared.restorePreviousSession()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Non chiudere l'app se chiudi il gestore: le finestre flottanti restano vive
        return false
    }
}
