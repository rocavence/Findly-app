import SwiftUI

/// The one way into Findly's icons: Reicon, as template images that take the
/// colour of whatever they sit in.
enum Icon {
    enum Weight: String {
        /// Everyday UI.
        case outline
        /// Selected, or on.
        case filled
    }

    static func nsImage(_ icon: Reicon, weight: Weight = .outline, size: CGFloat = 16) -> NSImage {
        let source = NSImage(named: "Reicon/\(icon.rawValue).\(weight.rawValue)") ?? NSImage()
        let image = source.copy() as! NSImage
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        return image
    }
}

/// A Reicon in SwiftUI, sized in points.
struct IconView: View {
    let icon: Reicon
    var weight: Icon.Weight = .outline
    var size: CGFloat = 16

    init(_ icon: Reicon, weight: Icon.Weight = .outline, size: CGFloat = 16) {
        self.icon = icon
        self.weight = weight
        self.size = size
    }

    var body: some View {
        Image("Reicon/\(icon.rawValue).\(weight.rawValue)")
            .renderingMode(.template)
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
