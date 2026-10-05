import Foundation

// MARK: - Terminale VT100 semplificato (puro, testabile senza GUI)

struct VTCell: Equatable {
    var ch: Character = " "
    var fg: Int = 7
    var bg: Int = 0
    var bold: Bool = false
}

/// Griglia + parser ANSI/VT100 (colori, cursore, scroll, alt-buffer).
struct VTTerminal {
    var cols: Int
    var rows: Int
    // Buffer principale con scrollback + buffer alternativo (fullscreen).
    private var main: [[VTCell]] = []
    private var mainCursor = (x: 0, y: 0) // y assoluto su main
    private var alt: [[VTCell]] = []
    private var altCursor = (x: 0, y: 0)
    private var useAlt = false
    private var saved = (x: 0, y: 0)
    private var curFG = 7, curBG = 0, curBold = false
    private var cursorVisible = true
    var scrollbackLimit = 1000

    // Stato parser
    private enum PState { case ground, esc, csi, osc, charset }
    private var state: PState = .ground
    private var csiParams: [Int] = []
    private var csiCurrent = 0
    private var csiHasNum = false
    private var csiPrivate = false
    private var utf8Rest = 0
    private var utf8Value: UInt32 = 0

    init(cols: Int = 100, rows: Int = 30) {
        self.cols = max(20, cols); self.rows = max(10, rows)
        let blank = Array(repeating: VTCell(), count: self.cols)
        main = Array(repeating: blank, count: self.rows)
        alt = Array(repeating: blank, count: self.rows)
    }

    var isCursorVisible: Bool { cursorVisible }
    var cursor: (x: Int, y: Int) {
        let c = useAlt ? altCursor : mainCursor
        let absY = useAlt ? c.y : c.y
        let base = useAlt ? 0 : max(0, lines.count - rows)
        return (min(max(0, c.x), cols - 1), min(max(0, absY - base), rows - 1))
    }

    private var lines: [[VTCell]] { useAlt ? alt : main }

    /// Righe visibili come stringhe (per test e debug).
    func dump() -> [String] {
        let ls = lines
        let start = useAlt ? 0 : max(0, ls.count - rows)
        return ls[start..<min(ls.count, start + rows)].map { $0.map { String($0.ch) }.joined() }
    }

    func cellAt(x: Int, y: Int) -> VTCell? {
        let ls = lines
        let start = useAlt ? 0 : max(0, ls.count - rows)
        guard y >= 0, y < rows, x >= 0, x < cols, start + y < ls.count else { return nil }
        return ls[start + y][x]
    }

    mutating func resize(cols: Int, rows: Int) {
        self.cols = max(20, cols); self.rows = max(10, rows)
        for i in main.indices { main[i] = fit(main[i]) }
        for i in alt.indices { alt[i] = fit(alt[i]) }
        while alt.count < self.rows { alt.append(Array(repeating: VTCell(), count: self.cols)) }
        if alt.count > self.rows { alt.removeFirst(alt.count - self.rows) }
        clampCursor()
    }

    private func fit(_ line: [VTCell]) -> [VTCell] {
        if line.count == cols { return line }
        if line.count > cols { return Array(line.prefix(cols)) }
        return line + Array(repeating: VTCell(), count: cols - line.count)
    }

    private mutating func clampCursor() {
        if useAlt {
            altCursor.x = min(max(0, altCursor.x), cols - 1)
            altCursor.y = min(max(0, altCursor.y), rows - 1)
        } else {
            mainCursor.x = min(max(0, mainCursor.x), cols - 1)
            mainCursor.y = min(max(0, mainCursor.y), max(0, main.count - 1))
        }
    }

    // MARK: - Scrittura

    private mutating func put(_ ch: Character) {
        if useAlt {
            if altCursor.y >= rows { altCursor.y = rows - 1 }
            alt[altCursor.y][altCursor.x] = VTCell(ch: ch, fg: curFG, bg: curBG, bold: curBold)
            advance()
        } else {
            while mainCursor.y >= main.count { main.append(Array(repeating: VTCell(), count: cols)) }
            main[mainCursor.y][mainCursor.x] = VTCell(ch: ch, fg: curFG, bg: curBG, bold: curBold)
            advance()
            trimScrollback()
        }
    }

    private mutating func advance() {
        if useAlt {
            altCursor.x += 1
            if altCursor.x >= cols { altCursor.x = 0; altCursor.y += 1; if altCursor.y >= rows { scrollAlt() } }
        } else {
            mainCursor.x += 1
            if mainCursor.x >= cols {
                mainCursor.x = 0; mainCursor.y += 1
                if mainCursor.y >= main.count { main.append(Array(repeating: VTCell(), count: cols)) }
            }
        }
    }

    private mutating func trimScrollback() {
        if main.count > rows + scrollbackLimit { main.removeFirst(main.count - (rows + scrollbackLimit)) }
    }

    private mutating func newline() {
        if useAlt {
            altCursor.x = 0; altCursor.y += 1
            if altCursor.y >= rows { scrollAlt() }
        } else {
            mainCursor.x = 0; mainCursor.y += 1
            if mainCursor.y >= main.count { main.append(Array(repeating: VTCell(), count: cols)) }
            trimScrollback()
        }
    }

    private mutating func scrollAlt() {
        alt.removeFirst()
        alt.append(Array(repeating: VTCell(), count: cols))
        altCursor.y = rows - 1
    }

    private mutating func eraseInDisplay(_ n: Int) {
        if useAlt {
            switch n {
            case 2: alt = Array(repeating: Array(repeating: VTCell(), count: cols), count: rows)
            case 1: let (x, y) = (altCursor.x, altCursor.y)
                for r in 0...y { for c in 0..<(r == y ? x + 1 : cols) { alt[r][c] = VTCell() } }
            default: let (x, y) = (altCursor.x, altCursor.y)
                for r in y..<rows { for c in (r == y ? x : 0)..<cols { alt[r][c] = VTCell() } }
            }
        } else {
            while mainCursor.y >= main.count { main.append(Array(repeating: VTCell(), count: cols)) }
            switch n {
            case 2:
                let start = max(0, main.count - rows)
                for r in start..<main.count { main[r] = Array(repeating: VTCell(), count: cols) }
            case 1: let (x, y) = (mainCursor.x, mainCursor.y)
                let start = max(0, main.count - rows)
                for r in start...y { for c in 0..<(r == y ? x + 1 : cols) { main[r][c] = VTCell() } }
            default: let (x, y) = (mainCursor.x, mainCursor.y)
                for r in y..<main.count { for c in (r == y ? x : 0)..<cols { main[r][c] = VTCell() } }
            }
        }
    }

    private mutating func eraseInLine(_ n: Int) {
        func wipe(_ line: inout [VTCell], _ range: Range<Int>) {
            for c in range { if c >= 0 && c < line.count { line[c] = VTCell() } }
        }
        if useAlt {
            switch n {
            case 2: alt[altCursor.y] = Array(repeating: VTCell(), count: cols)
            case 1: wipe(&alt[altCursor.y], 0..<(altCursor.x + 1))
            default: wipe(&alt[altCursor.y], altCursor.x..<cols)
            }
        } else {
            while mainCursor.y >= main.count { main.append(Array(repeating: VTCell(), count: cols)) }
            switch n {
            case 2: main[mainCursor.y] = Array(repeating: VTCell(), count: cols)
            case 1: wipe(&main[mainCursor.y], 0..<(mainCursor.x + 1))
            default: wipe(&main[mainCursor.y], mainCursor.x..<cols)
            }
        }
    }

    private mutating func moveCursor(row: Int?, col: Int?) {
        // 1-based dal protocollo; nil = invariate (H senza params = home)
        if useAlt {
            if let r = row { altCursor.y = min(max(0, r - 1), rows - 1) }
            if let c = col { altCursor.x = min(max(0, c - 1), cols - 1) }
        } else {
            let base = max(0, main.count - rows)
            if let r = row { mainCursor.y = base + min(max(0, r - 1), rows - 1) }
            if let c = col { mainCursor.x = min(max(0, c - 1), cols - 1) }
        }
    }

    // MARK: - Parser

    mutating func feed(_ bytes: [UInt8]) {
        for b in bytes { feedByte(b) }
    }

    mutating func feed(_ s: String) {
        feed(Array(s.utf8))
    }

    private mutating func feedByte(_ b: UInt8) {
        // UTF-8 multibyte in ground
        if state == .ground && utf8Rest > 0 {
            if b & 0xC0 == 0x80 {
                utf8Value = (utf8Value << 6) | UInt32(b & 0x3F)
                utf8Rest -= 1
                if utf8Rest == 0, let s = Unicode.Scalar(utf8Value) { put(Character(s)) }
                return
            } else { utf8Rest = 0 } // sequenza rotta: tratta b da solo
        }
        switch state {
        case .ground:
            if b == 0x1B { state = .esc; return }
            if b >= 0xC2 && b <= 0xF4 { // inizio UTF-8
                if b & 0xE0 == 0xC0 { utf8Rest = 1; utf8Value = UInt32(b & 0x1F) }
                else if b & 0xF0 == 0xE0 { utf8Rest = 2; utf8Value = UInt32(b & 0x0F) }
                else if b & 0xF8 == 0xF0 { utf8Rest = 3; utf8Value = UInt32(b & 0x07) }
                return
            }
            switch b {
            case 0x07: break // bell (gestito dalla view)
            case 0x08: backspace()
            case 0x09: tab()
            case 0x0A, 0x0B, 0x0C: newline()
            case 0x0D: carriageReturn()
            case 0x00...0x1F: break // altri controlli ignorati
            default:
                if let s = Unicode.Scalar(UInt32(b)) { put(Character(s)) }
            }
        case .esc:
            switch b {
            case 0x5B: state = .csi; csiParams = []; csiCurrent = 0; csiHasNum = false; csiPrivate = false
            case 0x5D: state = .osc
            case 0x28, 0x29, 0x23: state = .charset
            case 0x37: saved = currentXY(); state = .ground // DECSC
            case 0x38: restoreSaved(); state = .ground     // DECRC
            case 0x4D: reverseIndex(); state = .ground     // RI
            case 0x63: reset(); state = .ground            // RIS
            case 0x3D, 0x3E, 0x47: state = .ground         // keypad/graphic
            default: state = .ground
            }
        case .charset:
            state = .ground // ignora designazione charset (1 byte)
        case .osc:
            if b == 0x07 { state = .ground } // fine OSC (BEL)
        case .csi:
            if b == 0x3F && !csiHasNum && csiParams.isEmpty { csiPrivate = true; return }
            if b >= 0x30 && b <= 0x39 { csiCurrent = csiCurrent * 10 + Int(b - 0x30); csiHasNum = true; return }
            if b == 0x3B { csiParams.append(csiHasNum ? csiCurrent : -1); csiCurrent = 0; csiHasNum = false; return }
            if b >= 0x40 && b <= 0x7E {
                csiParams.append(csiHasNum ? csiCurrent : -1)
                handleCSI(final: b)
                state = .ground
                return
            }
            state = .ground // byte inatteso: esci
        }
    }

    private func currentXY() -> (x: Int, y: Int) {
        useAlt ? altCursor : mainCursor
    }

    private mutating func restoreSaved() {
        if useAlt { altCursor = saved } else { mainCursor = saved }
        clampCursor()
    }

    private mutating func backspace() {
        if useAlt { altCursor.x = max(0, altCursor.x - 1) }
        else { mainCursor.x = max(0, mainCursor.x - 1) }
    }

    private mutating func tab() {
        let nx: Int
        if useAlt { nx = min(cols - 1, ((altCursor.x / 8) + 1) * 8); altCursor.x = nx }
        else { nx = min(cols - 1, ((mainCursor.x / 8) + 1) * 8); mainCursor.x = nx }
    }

    private mutating func carriageReturn() {
        if useAlt { altCursor.x = 0 } else { mainCursor.x = 0 }
    }

    private mutating func reverseIndex() {
        if useAlt { altCursor.y = max(0, altCursor.y - 1) }
        else { mainCursor.y = max(max(0, main.count - rows), mainCursor.y - 1) }
    }

    private mutating func reset() {
        curFG = 7; curBG = 0; curBold = false; cursorVisible = true
    }

    private func p(_ i: Int, default d: Int) -> Int {
        i < csiParams.count ? (csiParams[i] == -1 ? d : csiParams[i]) : d
    }

    private mutating func handleCSI(final b: UInt8) {
        switch b {
        case 0x41: moveRel(dx: 0, dy: -p(0, default: 1)) // A up
        case 0x42: moveRel(dx: 0, dy: p(0, default: 1))  // B down
        case 0x43: moveRel(dx: p(0, default: 1), dy: 0)  // C right
        case 0x44: moveRel(dx: -p(0, default: 1), dy: 0) // D left
        case 0x45: carriageReturn(); moveRel(dx: 0, dy: p(0, default: 1))  // E
        case 0x46: carriageReturn(); moveRel(dx: 0, dy: -p(0, default: 1)) // F
        case 0x47: moveCursor(row: nil, col: p(0, default: 1))             // G
        case 0x48, 0x66: moveCursor(row: p(0, default: 1), col: p(1, default: 1)) // H/f
        case 0x4A: eraseInDisplay(p(0, default: 0))  // J
        case 0x4B: eraseInLine(p(0, default: 0))    // K
        case 0x64: moveCursor(row: p(0, default: 1), col: nil) // d VPA
        case 0x60: moveCursor(row: nil, col: p(0, default: 1)) // ` HPA
        case 0x6D: applySGR()                        // m
        case 0x73: saved = currentXY()                // s
        case 0x75: restoreSaved()                     // u
        case 0x68, 0x6C: applyMode(enable: b == 0x68) // h/l
        default: break
        }
    }

    private mutating func moveRel(dx: Int, dy: Int) {
        if useAlt {
            altCursor.x = min(max(0, altCursor.x + dx), cols - 1)
            altCursor.y = min(max(0, altCursor.y + dy), rows - 1)
        } else {
            let base = max(0, main.count - rows)
            mainCursor.x = min(max(0, mainCursor.x + dx), cols - 1)
            mainCursor.y = min(max(base, mainCursor.y + dy), max(base, main.count - 1))
        }
    }

    private mutating func applyMode(enable: Bool) {
        guard csiPrivate else { return }
        for raw in csiParams {
            let n = raw == -1 ? 0 : raw
            switch n {
            case 25: cursorVisible = enable
            case 1049:
                if enable && !useAlt {
                    useAlt = true
                    alt = Array(repeating: Array(repeating: VTCell(), count: cols), count: rows)
                    altCursor = (0, 0)
                } else if !enable && useAlt {
                    useAlt = false
                }
            case 1047, 1048: break
            default: break
            }
        }
    }

    private mutating func applySGR() {
        if csiParams.allSatisfy({ $0 == -1 }) { reset(); return }
        var i = 0
        func next() -> Int {
            defer { i += 1 }
            return i < csiParams.count ? (csiParams[i] == -1 ? 0 : csiParams[i]) : 0
        }
        while i < csiParams.count {
            let n = next()
            switch n {
            case 0: reset()
            case 1: curBold = true
            case 22: curBold = false
            case 30...37: curFG = n - 30
            case 90...97: curFG = n - 90 + 8
            case 39: curFG = 7
            case 40...47: curBG = n - 40
            case 100...107: curBG = n - 100 + 8
            case 49: curBG = 0
            case 38, 48:
                let isFG = (n == 38)
                let mode = next()
                if mode == 5 {
                    let c = next()
                    if isFG { curFG = min(max(0, c), 255) } else { curBG = min(max(0, c), 255) }
                } else if mode == 2 {
                    let r = next(), g = next(), bl = next()
                    let c = 16 + min(5, r * 6 / 256) * 36 + min(5, g * 6 / 256) * 6 + min(5, bl * 6 / 256)
                    if isFG { curFG = c } else { curBG = c }
                }
            default: break
            }
        }
    }
}

// MARK: - Colori xterm (indice -> RGB 0...1)

enum VTColor {
    static let base16: [(Double, Double, Double)] = [
        (0,0,0), (0.67,0,0), (0,0.67,0), (0.67,0.33,0),
        (0,0,0.67), (0.67,0,0.67), (0,0.67,0.67), (0.8,0.8,0.8),
        (0.33,0.33,0.33), (1,0.33,0.33), (0.33,1,0.33), (1,1,0.33),
        (0.33,0.33,1), (1,0.33,1), (0.33,1,1), (1,1,1),
    ]
    static func rgb(_ i: Int) -> (Double, Double, Double) {
        if i < 16 { return base16[i] }
        if i < 232 {
            let n = i - 16
            let r = Double(n / 36) / 5.0, g = Double((n % 36) / 6) / 5.0, b = Double(n % 6) / 5.0
            return (r, g, b)
        }
        let g = Double(8 + (i - 232) * 10) / 255.0
        return (g, g, g)
    }
}
