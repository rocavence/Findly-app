import SwiftUI

/// Findly's type, spacing, radii and colours, shared with Flione, Wunder and Gamely.
/// Views take every measurement from here instead of writing numbers inline.

/// 4pt grid.
enum Spacing {
    static let s2: CGFloat = 2
    static let s4: CGFloat = 4
    static let s8: CGFloat = 8
    static let s12: CGFloat = 12
    static let s16: CGFloat = 16
    static let s20: CGFloat = 20
    static let s24: CGFloat = 24
    static let s32: CGFloat = 32
}

enum Radius {
    /// Buttons, menus, sidebar rows.
    static let ui: CGFloat = 8
    /// Grouped panels such as the corner diagram.
    static let card: CGFloat = 12
}

/// The type scale: the system's own sans (SF, PingFang for Chinese), no serif.
enum TextStyle {
    case title, heading, subheading, body, bodyEmphasis, caption, micro

    var size: CGFloat {
        switch self {
        case .title: 28
        case .heading: 19
        case .subheading: 14
        case .body, .bodyEmphasis: 13
        case .caption: 11
        case .micro: 10
        }
    }

    var weight: Font.Weight {
        switch self {
        case .title, .heading: .semibold
        case .subheading, .bodyEmphasis, .micro: .medium
        case .body, .caption: .regular
        }
    }

    var tracking: CGFloat {
        switch self {
        case .title: -0.6
        case .heading: -0.3
        case .micro: 0.6
        default: 0
        }
    }
}

extension View {
    func textStyle(_ style: TextStyle) -> some View {
        font(.system(size: style.size, weight: style.weight)).tracking(style.tracking)
    }
}

/// Semantic colours; everything but the accent follows the system palette, so
/// light and dark both come for free.
enum Palette {
    static let ink = Color.primary
    /// Secondary text: about 8:1 on the window background in both appearances.
    static let muted = Color.primary.opacity(0.75)
    /// The quietest text still meant to be read: 4.5:1 or better in light and dark
    /// (the system's tertiary label is near 2:1 in dark mode).
    static let faint = Color.primary.opacity(0.6)
    /// Dividers, guides and timeline lanes; visible on dark as well as light.
    static let hairline = Color.primary.opacity(0.14)
    static let background = Color(nsColor: .windowBackgroundColor)
    static let hover = Color.primary.opacity(0.06)
    static let card = Color.primary.opacity(0.035)
    static let good = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let bad = Color(nsColor: .systemRed)
}

enum Motion {
    /// Hover and press.
    static let micro = Animation.easeOut(duration: 0.15)
}
