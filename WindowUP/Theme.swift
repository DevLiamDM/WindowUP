import SwiftUI

// MARK: - Tema WindowUP: blu-nero, moderno

enum UPTheme {
    static let ink = Color(red: 0.016, green: 0.027, blue: 0.06)      // nero-blu
    static let navy = Color(red: 0.04, green: 0.08, blue: 0.19)        // blu notte
    static let accent = Color(red: 0.23, green: 0.51, blue: 0.96)      // blu elettrico
    static let accentDeep = Color(red: 0.12, green: 0.25, blue: 0.69)  // blu profondo
    static let cyan = Color(red: 0.22, green: 0.74, blue: 0.97)        // highlight
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.65)
    static let textTertiary = Color.white.opacity(0.45)

    static var background: some View {
        LinearGradient(colors: [ink, navy], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var cardFill: some ShapeStyle {
        LinearGradient(colors: [Color.white.opacity(0.09), Color.white.opacity(0.03)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var accentGradient: some ShapeStyle {
        LinearGradient(colors: [accent, accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var toolbarFill: some View {
        LinearGradient(colors: [Color(red: 0.05, green: 0.08, blue: 0.18),
                                Color(red: 0.02, green: 0.04, blue: 0.10)],
                       startPoint: .top, endPoint: .bottom)
    }

    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// Badge quadrato con gradiente per icone (header, card).
    static func badge(_ systemName: String, size: CGFloat = 26, fontSize: CGFloat = 12) -> some View {
        Image(systemName: systemName)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(accentGradient, in: RoundedRectangle(cornerRadius: size * 0.32))
            .shadow(color: accent.opacity(0.4), radius: 6, y: 2)
    }
}

// MARK: - Card

struct UPCard<Content: View>: View {
    let title: String
    let icon: String
    let content: Content

    init(_ title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                UPTheme.badge(icon)
                Text(title)
                    .font(UPTheme.display(14, weight: .semibold))
                    .foregroundStyle(UPTheme.textPrimary)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UPTheme.cardFill, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }
}

// MARK: - Bottoni

struct UPPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(UPTheme.accentGradient, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: UPTheme.accent.opacity(configuration.isPressed ? 0.15 : 0.35), radius: 8, y: 2)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct UPGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.white.opacity(configuration.isPressed ? 0.04 : 0.08),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.14), lineWidth: 1))
    }
}

// MARK: - TextField scuro

struct UPDarkTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(.system(size: 12))
            .foregroundStyle(.white)
            .tint(UPTheme.cyan)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
}
