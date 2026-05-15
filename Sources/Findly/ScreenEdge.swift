import CoreGraphics

enum ScreenEdge: String, CaseIterable {
    case top, bottom, left, right

    /// Top/bottom edges span horizontally; left/right span vertically.
    var isHorizontal: Bool {
        switch self {
        case .top, .bottom: return true
        case .left, .right: return false
        }
    }

    /// Final on-screen frame for the panel on this edge.
    func panelFrame(on screen: CGRect, thickness: CGFloat) -> CGRect {
        switch self {
        case .top:    return CGRect(x: screen.minX, y: screen.maxY - thickness, width: screen.width, height: thickness)
        case .bottom: return CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: thickness)
        case .left:   return CGRect(x: screen.minX, y: screen.minY, width: thickness, height: screen.height)
        case .right:  return CGRect(x: screen.maxX - thickness, y: screen.minY, width: thickness, height: screen.height)
        }
    }

    /// Off-screen frame, fully past the visible area.
    /// `buffer` adds extra distance beyond the screen edge so any decorations
    /// (e.g. glow overlay) that extend outside the window can also fully hide.
    func offscreenFrame(on screen: CGRect, thickness: CGFloat, buffer: CGFloat = 0) -> CGRect {
        switch self {
        case .top:    return CGRect(x: screen.minX, y: screen.maxY + buffer,                       width: screen.width, height: thickness)
        case .bottom: return CGRect(x: screen.minX, y: screen.minY - thickness - buffer,           width: screen.width, height: thickness)
        case .left:   return CGRect(x: screen.minX - thickness - buffer, y: screen.minY,           width: thickness, height: screen.height)
        case .right:  return CGRect(x: screen.maxX + buffer,             y: screen.minY,           width: thickness, height: screen.height)
        }
    }
}
