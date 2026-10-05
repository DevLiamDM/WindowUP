import Foundation

struct PinnedItem: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var urlString: String
    var width: Double
    var height: Double
    var opacity: Double // 0.3 ... 1.0
    var levelBoosted: Bool // false = .floating, true = .screenSaver (ancora più sopra)
    var joinAllSpaces: Bool

    init(title: String, urlString: String, width: Double = 420, height: Double = 520,
         opacity: Double = 1.0, levelBoosted: Bool = false, joinAllSpaces: Bool = true) {
        self.title = title
        self.urlString = urlString
        self.width = width
        self.height = height
        self.opacity = opacity
        self.levelBoosted = levelBoosted
        self.joinAllSpaces = joinAllSpaces
    }

    var normalizedURL: URL? {
        var s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.contains("://") { s = "https://" + s }
        return URL(string: s)
    }
}

struct Preset: Identifiable {
    let id = UUID()
    let name: String
    let url: String
    let symbol: String
    let hint: String
}

let builtinPresets: [Preset] = [
    Preset(name: "WhatsApp", url: "https://web.whatsapp.com", symbol: "message.fill", hint: "Quadrato piccolo ideale"),
    Preset(name: "Telegram", url: "https://web.telegram.org/k/", symbol: "paperplane.fill", hint: "Web app completa"),
    Preset(name: "Google", url: "https://www.google.com", symbol: "magnifyingglass", hint: "Ricerca rapida"),
    Preset(name: "Gmail", url: "https://mail.google.com", symbol: "envelope.fill", hint: "Posta sempre visibile"),
    Preset(name: "Calendar", url: "https://calendar.google.com", symbol: "calendar", hint: "Agenda sopra tutto"),
    Preset(name: "YouTube", url: "https://www.youtube.com", symbol: "play.rectangle.fill", hint: "Mini player"),
    Preset(name: "ChatGPT", url: "https://chatgpt.com", symbol: "sparkles", hint: "Assistente laterale"),
    Preset(name: "Spotify", url: "https://open.spotify.com", symbol: "music.note", hint: "Controlli musicali"),
]

enum PinSize: String, CaseIterable, Identifiable {
    case square = "Quadrato"
    case small = "Piccolo"
    case medium = "Medio"
    case large = "Grande"
    var id: String { rawValue }
    var size: CGSize {
        switch self {
        case .square: return CGSize(width: 400, height: 400)
        case .small: return CGSize(width: 360, height: 480)
        case .medium: return CGSize(width: 480, height: 640)
        case .large: return CGSize(width: 720, height: 520)
        }
    }
}
