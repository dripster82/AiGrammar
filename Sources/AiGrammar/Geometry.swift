import AppKit

/// Accessibility APIs report bounds in the AX coordinate space (origin at the TOP-left of the
/// primary display, y increasing downward). AppKit windows use the Cocoa space (origin at the
/// BOTTOM-left, y increasing upward). This flips between them so a popover lands on the right word.
enum Geometry {
    static func cocoaRect(fromAX ax: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? ax.maxY
        let flippedY = primaryHeight - ax.origin.y - ax.height
        return CGRect(x: ax.origin.x, y: flippedY, width: ax.width, height: ax.height)
    }
}
