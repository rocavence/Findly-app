import CoreGraphics

enum ScreenEdge: String, CaseIterable, Sendable {
    case top, bottom, left, right

    /// Top and bottom drawers span the screen's width.
    var isHorizontal: Bool { self == .top || self == .bottom }

    /// The drawer's size along its depth, kept between a usable minimum and 85% of the screen.
    static func clamp(_ size: CGFloat, for edge: ScreenEdge, in screen: CGRect) -> CGFloat {
        let depth = edge.isHorizontal ? screen.height : screen.width
        let minimum: CGFloat = edge.isHorizontal ? 260 : 420
        return min(max(size, min(minimum, depth * 0.85)), depth * 0.85)
    }

    /// Where the drawer sits when open.
    func panelFrame(on screen: CGRect, thickness: CGFloat) -> CGRect {
        switch self {
        case .top:    CGRect(x: screen.minX, y: screen.maxY - thickness, width: screen.width, height: thickness)
        case .bottom: CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: thickness)
        case .left:   CGRect(x: screen.minX, y: screen.minY, width: thickness, height: screen.height)
        case .right:  CGRect(x: screen.maxX - thickness, y: screen.minY, width: thickness, height: screen.height)
        }
    }

    /// Just past the screen's edge, `buffer` further so the shadow is hidden too.
    func offscreenFrame(on screen: CGRect, thickness: CGFloat, buffer: CGFloat = 0) -> CGRect {
        switch self {
        case .top:    CGRect(x: screen.minX, y: screen.maxY + buffer, width: screen.width, height: thickness)
        case .bottom: CGRect(x: screen.minX, y: screen.minY - thickness - buffer, width: screen.width, height: thickness)
        case .left:   CGRect(x: screen.minX - thickness - buffer, y: screen.minY, width: thickness, height: screen.height)
        case .right:  CGRect(x: screen.maxX + buffer, y: screen.minY, width: thickness, height: screen.height)
        }
    }
}
