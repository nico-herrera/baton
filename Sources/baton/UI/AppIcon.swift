import AppKit

/// The Dock/⌘Tab icon, drawn in code. baton ships as a single binary with no
/// .app bundle, so there's no Assets.car for the system to read — without
/// this, promoting to .regular for the window shows the generic executable
/// icon. `NSApp.applicationIconImage` accepts any NSImage at runtime, so the
/// icon is vector-drawn here: the same baton-in-flight mark as the menu bar,
/// on a macOS-style rounded square.
enum AppIcon {

    static func apply() {
        NSApp.applicationIconImage = image(side: 512)
    }

    static func image(side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let s = side / 1024.0   // design in 1024-space, render at any size

            // Canvas margin: real macOS icons float inside ~10% padding.
            let inset = 100 * s
            let plate = NSRect(x: inset, y: inset,
                               width: side - inset * 2, height: side - inset * 2)

            // Plate: charcoal rounded square (Big Sur squircle approximated
            // with ~22.5% corner radius). Dark plate + light glyph reads well
            // in both light and dark Docks.
            let radius = plate.width * 0.225
            let bg = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)
            NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).setFill()
            bg.fill()

            // Subtle top-edge highlight so the plate doesn't read as a hole.
            let highlight = NSBezierPath(roundedRect: plate.insetBy(dx: 3 * s, dy: 3 * s),
                                         xRadius: radius - 3 * s, yRadius: radius - 3 * s)
            NSColor.white.withAlphaComponent(0.06).setStroke()
            highlight.lineWidth = 6 * s
            highlight.stroke()

            // The mark, scaled up from the 24pt menu bar design:
            //   bar   M8.5 15.5 L19 5
            //   ticks M5 12 l-2 2 · M9 16 l-2 2 · M13 20 l-1.5 1.5
            // Menu-bar viewBox y grows down; AppKit y grows up, so flip y.
            func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                let unit = plate.width / 24.0
                return NSPoint(x: plate.minX + x * unit,
                               y: plate.minY + (24.0 - y) * unit)
            }

            let bar = NSBezierPath()
            bar.move(to: pt(8.5, 15.5))
            bar.line(to: pt(19, 5))
            bar.lineWidth = 2.4 * plate.width / 24.0
            bar.lineCapStyle = .round
            NSColor.white.setStroke()
            bar.stroke()

            // Motion ticks in a warm accent — the one bit of color, echoing
            // the recording state.
            let accent = NSColor(calibratedRed: 0.91, green: 0.45, blue: 0.32, alpha: 1)
            for (from, to) in [((5.0, 12.0), (3.0, 14.0)),
                               ((9.0, 16.0), (7.0, 18.0)),
                               ((13.0, 20.0), (11.5, 21.5))] {
                let tick = NSBezierPath()
                tick.move(to: pt(from.0, from.1))
                tick.line(to: pt(to.0, to.1))
                tick.lineWidth = 2.0 * plate.width / 24.0
                tick.lineCapStyle = .round
                accent.setStroke()
                tick.stroke()
            }
            return true
        }
    }
}
