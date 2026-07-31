import SwiftUI

// Palette from APP_REDESIGN_HANDOFF.md §1 — verbatim. Dark only, warm
// neutrals derived from the brand Ink/Paper, one accent. Red is allowed in
// exactly four places: the primary patch button, the selected session row,
// the `me` speaker tag, and recording state. Nothing else.
extension Color {
    static let ptWindow    = Color(red: 0x1C/255, green: 0x1B/255, blue: 0x17/255) // #1C1B17
    static let ptSidebar   = Color(red: 0x19/255, green: 0x18/255, blue: 0x13/255) // #191813
    static let ptRaised    = Color(red: 0x24/255, green: 0x23/255, blue: 0x1D/255) // #24231D
    static let ptSurface   = Color(red: 0x21/255, green: 0x1E/255, blue: 0x1A/255) // #211E1A  me-turn ground
    static let ptHairline  = Color(red: 0x2C/255, green: 0x2A/255, blue: 0x23/255) // #2C2A23
    static let ptBorder    = Color(red: 0x3A/255, green: 0x37/255, blue: 0x30/255) // #3A3730
    static let ptText      = Color(red: 0xF2/255, green: 0xF0/255, blue: 0xEA/255) // #F2F0EA
    static let ptText2     = Color(red: 0xD8/255, green: 0xD4/255, blue: 0xCA/255) // #D8D4CA
    static let ptText3     = Color(red: 0xA2/255, green: 0x9E/255, blue: 0x93/255) // #A29E93
    static let ptText4     = Color(red: 0x6E/255, green: 0x6B/255, blue: 0x60/255) // #6E6B60
    static let ptSignal    = Color(red: 0xD2/255, green: 0x37/255, blue: 0x1B/255) // #D2371B
    static let ptSignalLit = Color(red: 0xE4/255, green: 0x63/255, blue: 0x3F/255) // #E4633F  on dark text

    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// The Patchthrough mark on its native 24×24 grid, from
/// CLAUDE_CODE_HANDOFF.md — drawn as a Shape so it is crisp at every size
/// and follows the foreground colour.
struct PatchthroughMark: Shape {
    /// Stroke weight in grid units: 1.6 regular, 2.1 heavy.
    var weight: CGFloat = 1.6

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * s, y: rect.minY + (y - 0.45) * s)
        }

        var path = Path()
        path.addEllipse(in: CGRect(
            x: rect.minX + (12 - 6.3) * s,
            y: rect.minY + (12 - 6.3 - 0.45) * s,
            width: 12.6 * s, height: 12.6 * s
        ))
        path.move(to: p(2.8, 19.2))
        path.addCurve(to: p(10.3, 9.6), control1: p(5.2, 14.8), control2: p(7.8, 10.9))
        path.addCurve(to: p(21.2, 6.4), control1: p(12.8, 8.3), control2: p(16.8, 7.2))
        return path
    }
}

struct PatchthroughMarkView: View {
    var weight: CGFloat = 1.6
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 24
            PatchthroughMark(weight: weight)
                .stroke(style: StrokeStyle(lineWidth: weight * s, lineCap: .round))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Destination use counts, so the split button's primary action is whatever
/// you actually use. Keyed by Destination.id ("cli:claude", "gui:claude-cowork").
/// From APP_REDESIGN_HANDOFF.md §3, verbatim.
struct DestinationRanking {
    private static let key = "handoff.useCounts"

    static func counts() -> [String: Int] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
    }
    static func record(_ id: String) {
        var c = counts()
        c[id, default: 0] += 1
        UserDefaults.standard.set(c, forKey: key)
    }
    /// Installed destinations, most-used first; ties keep discovery order.
    static func rank(_ dests: [SessionStore.Destination]) -> [SessionStore.Destination] {
        let c = counts()
        return dests.enumerated()
            .sorted { (c[$0.element.id] ?? 0, -$0.offset) > (c[$1.element.id] ?? 0, -$1.offset) }
            .map(\.element)
    }
}

extension Text {
    /// 10.5pt mono, for turn timestamps.
    func monoCaption() -> some View {
        self.font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(Color.ptText4)
    }
}
