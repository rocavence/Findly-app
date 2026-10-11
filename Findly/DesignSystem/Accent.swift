import SwiftUI

/// The one colour Findly chooses: the accent. It marks what's chosen and
/// what's on, and nothing else. Findly blue, taken from the app icon, by
/// default; or the system's own accent, or one of the seven named colours
/// shared with Wunder and Gamely.
enum Accent: String, CaseIterable, Sendable {
    case findly, system, orange, red, pink, purple, blue, glacier, green

    static let key = "Findly.accent"

    static var current: Accent {
        UserDefaults.standard.string(forKey: key).flatMap(Accent.init) ?? .findly
    }

    var title: String {
        switch self {
        case .findly: String(localized: "Findly Blue")
        case .system: String(localized: "System")
        case .orange: String(localized: "Rams Orange")
        case .red: String(localized: "Matisse Red")
        case .pink: String(localized: "Barragán Pink")
        case .purple: String(localized: "Iris Purple")
        case .blue: String(localized: "Klein Blue")
        case .glacier: String(localized: "Hockney Blue")
        case .green: String(localized: "Monet Green")
        }
    }

    /// The app icon's blue; then Braun's orange, Matisse's red studio,
    /// Barragán's pink walls, Van Gogh's irises, Klein's blue, Hockney's pools,
    /// Monet's bridge at Giverny.
    var color: Color { Color(nsColor: nsColor) }

    var nsColor: NSColor {
        switch self {
        case .findly: Self.rgb(0x298CFF)
        case .system: .controlAccentColor
        case .orange: Self.rgb(0xED3F1C)
        case .red: Self.rgb(0xD21F3C)
        case .pink: Self.rgb(0xE5508F)
        case .purple: Self.rgb(0x7C5CF5)
        case .blue: Self.rgb(0x2147E0)
        case .glacier: Self.rgb(0x23A6DA)
        case .green: Self.rgb(0x2AA572)
        }
    }

    /// Text and icons on an accent fill: near-black on light accents like jade, white on dark ones.
    var onAccent: Color {
        Self.luminance(nsColor) > 0.4 ? Color(red: 0.05, green: 0.16, blue: 0.13) : .white
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// WCAG relative luminance.
    static func luminance(_ color: NSColor) -> CGFloat {
        guard let c = color.usingColorSpace(.sRGB) else { return 0.5 }
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }
}

/// The accent as text on the window background. A light accent (jade) is
/// darkened on light backgrounds and a dark one (Klein blue) lightened on dark
/// ones, until it reads at 4.5:1 or better.
struct AccentText: ShapeStyle {
    /// 4.5:1 for text; 3:1 is enough for graphics such as timeline dots (WCAG 1.4.11).
    var minimumContrast: CGFloat = 4.5

    func resolve(in environment: EnvironmentValues) -> Color {
        let base = Accent.current.nsColor
        let dark = environment.colorScheme == .dark
        let background: CGFloat = dark ? 0.015 : 0.95
        var color = base.usingColorSpace(.sRGB) ?? base
        for _ in 0..<10 {
            let l = Accent.luminance(color)
            let contrast = (max(l, background) + 0.05) / (min(l, background) + 0.05)
            if contrast >= minimumContrast { break }
            color = color.blended(withFraction: 0.15, of: dark ? .white : .black) ?? color
        }
        return Color(nsColor: color)
    }
}

extension ShapeStyle where Self == AccentText {
    static var accentText: AccentText { AccentText() }
    static var accentGraphic: AccentText { AccentText(minimumContrast: 3) }
}
