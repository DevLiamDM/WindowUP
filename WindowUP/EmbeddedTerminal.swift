import SwiftUI
import AppKit
import Darwin

// MARK: - Sessione PTY (shell vera dentro WindowUP)

final class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()
    @Published var alive = true
    @Published var sizeLabel = ""
    @Published var startError: String?

    var term = VTTerminal(cols: 100, rows: 30)
    private let lock = NSLock()
    private var masterFD: Int32 = -1
    private var stdHandles: [FileHandle] = []
    private var process: Process?
    private var readSource: DispatchSourceRead?
    weak var view: TerminalView?

    init() {
        spawn(cols: term.cols, rows: term.rows)
    }

    private func spawn(cols: Int, rows: Int) {
        let master = posix_openpt(O_RDWR)
        guard master >= 0 else { startError = "posix_openpt fallita"; alive = false; return }
        guard grantpt(master) == 0, unlockpt(master) == 0,
              let slavePath = ptsname(master).map({ String(cString: $0) }) else {
            close(master); startError = "grantpt/unlockpt fallita"; alive = false; return
        }
        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, UInt(bitPattern: Int(TIOCSWINSZ)), &ws)
        guard let slave = open(slavePath, O_RDWR).asValidFD else {
            close(master); startError = "apertura slave fallita"; alive = false; return
        }
        // Tre dup per stdin/stdout/stderr del figlio; la copia padre si chiude dopo il lancio.
        let fds = [dup(slave), dup(slave), dup(slave)]
        close(slave)
        guard !fds.contains(-1) else {
            fds.forEach { if $0 >= 0 { close($0) } }; close(master)
            startError = "dup fallita"; alive = false; return
        }
        let handles = fds.map { FileHandle(fileDescriptor: $0, closeOnDealloc: true) }
        let env = ProcessInfo.processInfo.environment
        let shell = (env["SHELL"]?.isEmpty == false) ? env["SHELL"]! : "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-i"]
        var e = env
        e["TERM"] = "xterm-256color"
        p.environment = e
        p.currentDirectoryURL = URL(fileURLWithPath: env["HOME"] ?? "/tmp")
        p.standardInput = handles[0]
        p.standardOutput = handles[1]
        p.standardError = handles[2]
        do {
            try p.run()
        } catch {
            handles.forEach { try? $0.close() }; close(master)
            startError = "avvio shell fallito: \(error.localizedDescription)"
            alive = false
            return
        }
        // Il figlio ha i suoi dup (dal lancio): chiudo le copie padre per avere EOF naturale sul master.
        // (Non si può toccare p.standardInput dopo run(): "task already launched".)
        handles.forEach { try? $0.close() }
        self.masterFD = master
        self.stdHandles = []
        self.process = p
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.childExited() }
        }
        // Non-blocking + lettura asincrona.
        _ = fcntl(master, F_SETFL, O_NONBLOCK)
        let q = DispatchQueue(label: "windowup.pty.read")
        let src = DispatchSource.makeReadSource(fileDescriptor: master, queue: q)
        src.setEventHandler { [weak self] in self?.drain() }
        src.setCancelHandler { close(master) }
        src.resume()
        self.readSource = src
        updateSizeLabel()
    }

    private func drain() {
        var buf = [UInt8](repeating: 0, count: 8192)
        var gotAny = false
        while true {
            let n = read(masterFD, &buf, buf.count)
            if n > 0 {
                gotAny = true
                let bytes = Array(buf[0..<n])
                lock.lock(); term.feed(bytes); lock.unlock()
                DispatchQueue.main.async { [weak self] in self?.view?.setNeedsDisplay(self?.view?.bounds ?? .zero) }
            } else { break }
        }
        if !gotAny {
            // EOF/errore: il figlio è uscito.
            DispatchQueue.main.async { [weak self] in self?.childExited() }
        }
    }

    private func childExited() {
        guard alive else { return }
        alive = false
        lock.lock()
        term.feed("\r\n[processo terminato — chiudi il pannello]\r\n")
        lock.unlock()
        view?.setNeedsDisplay(view?.bounds ?? .zero)
    }

    func send(_ bytes: [UInt8]) {
        guard masterFD >= 0, alive else { return }
        bytes.withUnsafeBytes { ptr in
            var off = 0
            while off < bytes.count {
                let n = write(masterFD, ptr.baseAddress!.advanced(by: off), bytes.count - off)
                if n <= 0 { break }
                off += n
            }
        }
    }

    func send(_ s: String) { send(Array(s.utf8)) }

    func signal(_ sig: Int32) {
        guard let pid = process?.processIdentifier, alive else { return }
        Darwin.kill(pid, sig)
    }

    func resize(cols: Int, rows: Int) {
        guard cols != term.cols || rows != term.rows else { return }
        lock.lock(); term.resize(cols: cols, rows: rows); lock.unlock()
        if masterFD >= 0 {
            var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(masterFD, UInt(bitPattern: Int(TIOCSWINSZ)), &ws)
            signal(SIGWINCH)
        }
        updateSizeLabel()
        DispatchQueue.main.async { [weak self] in self?.view?.setNeedsDisplay(self?.view?.bounds ?? .zero) }
    }

    private func updateSizeLabel() {
        sizeLabel = "\(term.cols)×\(term.rows)"
    }

    func kill() {
        if let p = process, p.isRunning { p.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            if self.process?.isRunning == true { self.signal(SIGKILL) }
            self.readSource?.cancel()
            self.readSource = nil
            self.stdHandles.forEach { try? $0.close() }
            self.stdHandles.removeAll()
        }
    }

    func withTerm<T>(_ body: (VTTerminal) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(term)
    }
}

private extension Int32 {
    var asValidFD: Int32? { self >= 0 ? self : nil }
}

// MARK: - Vista terminale (disegno griglia + tastiera)

final class TerminalView: NSView {
    let session: TerminalSession
    let font: NSFont = NSFont(name: "Menlo", size: 13) ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var cellW: CGFloat = 8
    private var cellH: CGFloat = 16

    init(session: TerminalSession) {
        self.session = session
        super.init(frame: .zero)
        let sample = ("MMMMMMMMMM" as NSString).size(withAttributes: [.font: font])
        cellW = ceil(sample.width / 10)
        cellH = ceil(font.ascender - font.descender + font.leading)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let cols = max(20, Int(newSize.width / cellW))
        let rows = max(10, Int(newSize.height / cellH))
        session.resize(cols: cols, rows: rows)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
        session.withTerm { term in
            let lines = term.dump()
            for (r, _) in lines.enumerated() {
                let y = bounds.height - CGFloat(r + 1) * cellH
                // Per-cella per colori: ricostruisci da cellAt (semplice, griglia piccola).
                for c in 0..<term.cols {
                    guard let cell = term.cellAt(x: c, y: r) else { continue }
                    let x = CGFloat(c) * cellW
                    let rect = NSRect(x: x, y: y, width: cellW, height: cellH)
                    if cell.bg != 0 {
                        nsColor(cell.bg, bold: false).setFill()
                        rect.fill()
                    }
                    if cell.ch != " " {
                        let s = String(cell.ch) as NSString
                        s.draw(at: NSPoint(x: x, y: y - font.descender),
                               withAttributes: [.font: font, .foregroundColor: nsColor(cell.fg, bold: cell.bold)])
                    }
                }
            }
            if term.isCursorVisible {
                let (cx, cy) = term.cursor
                let rect = NSRect(x: CGFloat(cx) * cellW, y: bounds.height - CGFloat(cy + 1) * cellH,
                                  width: cellW, height: cellH)
                (term.cellAt(x: cx, y: cy).map { nsColor($0.fg, bold: $0.bold) } ?? NSColor.white).setFill()
                rect.fill()
            }
        }
    }

    private func nsColor(_ i: Int, bold: Bool) -> NSColor {
        var (r, g, b) = VTColor.rgb(min(max(0, i), 255))
        if bold && i < 8 { (r, g, b) = VTColor.rgb(i + 8) }
        return NSColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1)
    }

    override func keyDown(with e: NSEvent) {
        if e.modifierFlags.contains(.command) {
            // Cmd+V = incolla; il resto ai menu.
            if e.charactersIgnoringModifiers?.lowercased() == "v",
               let s = NSPasteboard.general.string(forType: .string) {
                session.send(s.replacingOccurrences(of: "\r", with: "\n"))
                return
            }
            super.keyDown(with: e)
            return
        }
        if let sp = e.specialKey {
            switch sp {
            case .upArrow: session.send("\u{1B}[A"); return
            case .downArrow: session.send("\u{1B}[B"); return
            case .rightArrow: session.send("\u{1B}[C"); return
            case .leftArrow: session.send("\u{1B}[D"); return
            case .home: session.send("\u{1B}[H"); return
            case .end: session.send("\u{1B}[F"); return
            case .pageUp: session.send("\u{1B}[5~"); return
            case .pageDown: session.send("\u{1B}[6~"); return
            case .delete: session.send("\u{1B}[3~"); return
            case .f1: session.send("\u{1B}OP"); return
            case .f2: session.send("\u{1B}OQ"); return
            case .f3: session.send("\u{1B}OR"); return
            case .f4: session.send("\u{1B}OS"); return
            case .f5: session.send("\u{1B}[15~"); return
            case .f6: session.send("\u{1B}[17~"); return
            case .f7: session.send("\u{1B}[18~"); return
            case .f8: session.send("\u{1B}[19~"); return
            case .f9: session.send("\u{1B}[20~"); return
            case .f10: session.send("\u{1B}[21~"); return
            case .f11: session.send("\u{1B}[23~"); return
            case .f12: session.send("\u{1B}[24~"); return
            default: break
            }
        }
        guard let chars = e.characters, !chars.isEmpty else { return }
        if e.modifierFlags.contains(.control) {
            let k = (e.charactersIgnoringModifiers ?? "").lowercased()
            if k == "c" { session.signal(SIGINT); return }
            if k == "z" { session.signal(SIGTSTP); return }
            if k == "\\" { session.signal(SIGQUIT); return }
        }
        session.send(chars)
    }
}

// MARK: - Manager + UI SwiftUI

final class TerminalManager: ObservableObject {
    static let shared = TerminalManager()
    @Published var sessions: [TerminalSession] = []
    private var panels: [UUID: FloatingPanel] = [:]

    func openTerminal() {
        let session = TerminalSession()
        sessions.append(session)
        // Extra-sopra di default: il terminale integrato deve restare visibile
        // anche sopra giochi fullscreen e navigazione.
        var geom = PinnedItem(title: "Terminale", urlString: "", width: 640, height: 420,
                              opacity: 1.0, levelBoosted: true)
        geom.joinAllSpaces = true
        let content = EmbeddedTerminalPanelView(manager: self, session: session)
        let hosting = NSHostingView(rootView: content.environmentObject(self))
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 420)
        let panel = FloatingPanel(item: geom, contentView: hosting)
        panels[session.id] = panel
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            session.kill()
            self?.panels[session.id] = nil
            self?.sessions.removeAll { $0.id == session.id }
            self?.objectWillChange.send()
        }
        panels[session.id] = panel
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
    }

    func close(_ session: TerminalSession) {
        // Trova il pannello e chiudilo (willClose fa pulizia).
        for (id, panel) in panels where id == session.id {
            panel.close()
            return
        }
        session.kill()
        sessions.removeAll { $0.id == session.id }
    }

    func focus(_ session: TerminalSession) {
        panels[session.id]?.orderFrontRegardless()
        panels[session.id]?.makeKeyAndOrderFront(nil)
    }
}

struct EmbeddedTerminalNSView: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> TerminalView {
        let v = TerminalView(session: session)
        session.view = v
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            if let win = v.window, win.isKeyWindow {
                win.makeFirstResponder(v)
            }
        }
        DispatchQueue.main.async {
            v.window?.makeFirstResponder(v)
        }
        return v
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}
}

struct EmbeddedTerminalPanelView: View {
    @ObservedObject var manager: TerminalManager
    @ObservedObject var session: TerminalSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(session.alive ? .green : .red).frame(width: 8, height: 8)
                Text("zsh • \(session.sizeLabel)").font(.caption)
                if let err = session.startError {
                    Text(err).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
                Spacer()
                Button("Nuovo") { manager.openTerminal() }.buttonStyle(.link).font(.caption).focusable(false)
                Button("Chiudi") { manager.close(session) }.buttonStyle(.link).font(.caption).focusable(false)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(.bar)
            Divider()
            EmbeddedTerminalNSView(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        }
    }
}
