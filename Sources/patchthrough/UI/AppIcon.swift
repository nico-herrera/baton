import AppKit

/// The Dock/⌘Tab/title-bar icon. When running from patchthrough.app the
/// bundle's .icns (generated from the approved appiconset) is authoritative;
/// this code covers bare-binary dev runs and the 16pt title-bar image.
///
/// Geometry is the design system's Signal treatment (packaging/design):
/// squircle at 22.4% corner radius filled #D2371B, the mark at 64% of the
/// tile in Paper (#FFF9F4), heavy weight (2.1), flat — no bevel, no gradient.
enum AppIcon {

    static func apply() {
        NSApp.applicationIconImage = image(side: 512)
    }

    /// Prefer the installed bundle's icon (matches Finder exactly); fall back
    /// to drawing the Signal treatment from its vector geometry.
    static func titlebarImage() -> NSImage {
        if Bundle.main.bundlePath.hasSuffix(".app") {
            let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
            icon.size = NSSize(width: 16, height: 16)
            return icon
        }
        return image(side: 16)
    }

    static func image(side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let s = side / 1024.0

            // Squircle ground: rx 229.4 at 1024 (22.4%), Signal red.
            let radius = 229.4 * s
            let plate = NSRect(x: 0, y: 0, width: side, height: side)
            NSColor(calibratedRed: 0xD2 / 255, green: 0x37 / 255, blue: 0x1B / 255, alpha: 1).setFill()
            NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius).fill()

            // Art: translate(184,184) scale(27.333) on the 24-grid — i.e. the
            // mark occupies the central 64%. SVG y grows down, AppKit up, so
            // flip within the 24-unit box (art y = 24 − (y − 0.45)).
            let unit = 27.333 * s
            let originX = 184 * s
            let originY = 184 * s
            func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(x: originX + x * unit, y: originY + (24 - (y - 0.45)) * unit)
            }

            let paper = NSColor(calibratedRed: 0xFF / 255, green: 0xF9 / 255, blue: 0xF4 / 255, alpha: 1)
            paper.setStroke()
            let lineWidth = 2.1 * unit

            // Socket ring: centre (12,12) on the grid, r 6.3.
            let c = pt(12, 12)
            let r = 6.3 * unit
            let ring = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ring.lineWidth = lineWidth
            ring.stroke()

            // Patch cord: M2.8 19.2 C 5.2 14.8 7.8 10.9 10.3 9.6
            //                         C 12.8 8.3 16.8 7.2 21.2 6.4
            let cord = NSBezierPath()
            cord.move(to: pt(2.8, 19.2))
            cord.curve(to: pt(10.3, 9.6), controlPoint1: pt(5.2, 14.8), controlPoint2: pt(7.8, 10.9))
            cord.curve(to: pt(21.2, 6.4), controlPoint1: pt(12.8, 8.3), controlPoint2: pt(16.8, 7.2))
            cord.lineWidth = lineWidth
            cord.lineCapStyle = .round
            cord.stroke()

            return true
        }
    }
}
