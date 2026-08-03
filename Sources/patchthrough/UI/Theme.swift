import AppKit
import SwiftUI

// Design tokens. Per design/DESIGN_RULES.md rule 1, this file is the ONLY place
// raw values may appear. Views reference PT.C / PT.F / PT.M and nothing else.
//
// Generated from "Patchthrough App Redesign.dc.html" rounds 11a / 10d / 10e and
// the handoff's swift/Theme.swift. Every number is deliberate; fractional sizes
// (14.5, 12.5, 10.5) must not be rounded.

enum PT {

    // MARK: - Colour

    enum C {
        // Grounds, darkest to lightest
        static let sunken   = hex(0x17160F)  // text inputs in settings
        static let sidebar  = hex(0x191813)  // sidebar column
        static let window   = hex(0x1C1B17)  // detail pane, window body
        static let chrome   = hex(0x201F1A)  // titlebar, settings sheet
        static let surface  = hex(0x211E1A)  // "me" turn ground (NOT raised)
        static let raised   = hex(0x24231D)  // search field, toggle cards, menus
        static let chip     = hex(0x2A2822)  // Choose… / Cancel chips

        // Lines
        static let hairline = hex(0x2C2A23)  // pane dividers
        static let border2  = hex(0x302E27)  // quieter control borders
        static let border   = hex(0x3A3730)  // control borders
        static let menuEdge = hex(0x454138)  // popover border
        static let menuRule = hex(0x35322A)  // divider inside the destination menu

        // Text, brightest to dimmest
        static let text     = hex(0xF2F0EA)  // primary
        static let text2    = hex(0xD8D4CA)  // "them" body, secondary controls
        static let textSel  = hex(0xC9C4B9)  // subtitle inside a selected row
        static let text3    = hex(0xA29E93)  // captions, icons
        static let label    = hex(0x7E7A70)  // settings section labels, detail stats
        static let text4    = hex(0x6E6B60)  // placeholders, sidebar section headers
        static let text5    = hex(0x57544C)  // transcript timestamps
        static let glyphDim = hex(0x4A473E)  // sidebar footer folder glyph

        static let speakerThem = hex(0x8C887E)  // THEM label, repo chip

        // Accent: Signal red. Permitted on exactly the five uses in rule 2.
        static let signal    = hex(0xD2371B)  // fills: primary button, record dot
        static let signalDim = hex(0xB72E14)  // split-button chevron half
        static let signalLit = hex(0xE4633F)  // signal-on-dark TEXT and icons
        static let signalInk = hex(0xC08A78)  // mono caption inside a selected row
        static let signalWarn = hex(0xC98872)  // inline permission-warning text
        static let onSignal  = hex(0xFFF9F4)  // text on a signal fill

        /// Selected row: fill + ring. Never a leading edge bar (rule 4).
        static let selectFill   = signal.opacity(0.15)
        static let selectStroke = signal.opacity(0.32)
        static let warnFill     = signal.opacity(0.10)
        static let menuSelectFill = signal.opacity(0.16)
        /// Divider between the split button's two halves.
        static let onSignalRule = onSignal.opacity(0.22)
        static let menuShadow = Color.black.opacity(0.60)

        private static func hex(_ v: UInt32) -> Color {
            Color(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
        }
    }

    // MARK: - Type
    //
    // Sizes are fractional on purpose (rule 7). Rounding them to integers is the
    // single most common way this design drifts.

    enum F {
        static let transcript   = Font.system(size: 14.5)
        static let sheetTitle   = Font.system(size: 15, weight: .semibold)
        static let settingRow   = Font.system(size: 13.5)
        static let sessionTime  = Font.system(size: 13, weight: .semibold)
        static let sessionTime2 = Font.system(size: 13, weight: .medium)   // unselected
        static let button       = Font.system(size: 13, weight: .semibold)
        static let wordmark     = Font.system(size: 13, weight: .semibold)
        static let control      = Font.system(size: 12.5, weight: .medium)
        static let field        = Font.system(size: 12.5)
        static let sessionLine  = Font.system(size: 12)
        static let caption      = Font.system(size: 11.5)
        static let speaker      = Font.system(size: 10.5, weight: .semibold)
        static let sectionHead  = Font.system(size: 10.5, weight: .semibold)
        static let menuItem     = Font.system(size: 12.5)
        static let menuItemStrong = Font.system(size: 12.5, weight: .medium)
        /// Split-button chevron. The mock's `#i-chev` sits in a 13pt box but its
        /// path only spans 6.8 of 16 grid units: 5.5pt of centreline plus a
        /// 1.3pt stroke, so ~6.8pt wide overall. SF `chevron.down` renders about
        /// 0.83pt of width per point of font size, hence 8.
        static let chevron      = Font.system(size: 8, weight: .medium)
        /// The arrow in the primary half. The mock's `#i-arrow` is drawn in a
        /// 14pt box but its stroke only spans 9.4 of 16 grid units, about 8pt
        /// wide at a 1.3 stroke, so it is smaller and lighter than the label.
        static let buttonGlyph  = Font.system(size: 10.5, weight: .medium)

        // SF Symbol sizes, matching the mock's SVG boxes. These are icons, not
        // text. Never size a glyph with a mono or body token.
        static let icon         = Font.system(size: 13)    // drag, search, footer folder
        static let iconSmall    = Font.system(size: 12)    // detail-header folder, status
        static let gear         = Font.system(size: 15)
        /// Centred glyph in the undesigned placeholder panes (rule 12).
        static let placeholder  = Font.system(size: 38, weight: .light)

        // Monospaced ramp
        static let mono         = Font.system(size: 13, design: .monospaced)
        static let monoField    = Font.system(size: 12.5, design: .monospaced)
        static let monoRepo     = Font.system(size: 11.5, design: .monospaced)
        static let monoSmall    = Font.system(size: 11, design: .monospaced)
        static let monoTiny     = Font.system(size: 10.5, design: .monospaced)

        /// Tracking for uppercase micro-labels: 0.09em at 10.5pt.
        static let labelTracking: CGFloat = 0.95

        /// The mock's transcript line box is 14.5 × 1.62 = 23.49pt; the system
        /// font's own line height at 14.5pt is 17.08, so lineSpacing carries the
        /// 6.41 difference. SwiftUI adds it per line rather than between lines,
        /// so an N-line block measures N × 23.49, exactly the CSS box. Do not
        /// also pad vertically; that double-counts the leading.
        ///
        /// NOTE: the handoff's swift/Theme.swift says 4 here. Measured against
        /// screenshots/01-window-11a.png, 4 yields a 132pt me-bubble where the
        /// mock's is 143pt; 6.41 yields 143. The mock is the stated design source
        /// of truth, so it wins over the sample file.
        static let transcriptLineSpacing: CGFloat = 6.41
    }

    // MARK: - Metrics

    enum M {
        static let sidebarWidth: CGFloat = 252
        static let titleBarHeight: CGFloat = 52
        static let windowMin = CGSize(width: 860, height: 660)
        static let settingsWidth: CGFloat = 560

        /// Clears the traffic lights in the custom titlebar strip.
        static let titleBarLeading: CGFloat = 88
        static let titleBarTrailing: CGFloat = 14

        /// Transcript column padding, and the gap between turns.
        static let transcriptPad: CGFloat = 22
        static let turnGap: CGFloat = 22

        /// LOAD-BEARING (rule from SPEC.md). Trailing alignment can only offset
        /// an element narrower than its line. At 1.0 both speakers span the
        /// column and the me-right / them-left structure silently disappears.
        static let turnMaxWidthFraction: CGFloat = 0.78

        static let bubbleRadius: CGFloat = 11
        static let bubblePadV: CGFloat = 13
        static let bubblePadH: CGFloat = 16

        static let rowRadius: CGFloat = 7
        static let rowPad: CGFloat = 9
        /// Sidebar rows inset from the column edges, with this gap between them.
        static let rowInset: CGFloat = 8
        static let rowGap: CGFloat = 3

        static let controlRadius: CGFloat = 7
        static let splitButtonHeight: CGFloat = 32
        static let splitChevronWidth: CGFloat = 28
        static let fieldRadius: CGFloat = 6
        static let cardRadius: CGFloat = 8
        static let menuRadius: CGFloat = 9
        static let menuRowRadius: CGFloat = 5

        static let sidebarPad: CGFloat = 12
        static let sheetPadH: CGFloat = 20
        static let sheetSectionGap: CGFloat = 22

        // Ranked destination menu. It is drawn in-app because macOS's native
        // Menu owns its material, metrics, separators, and glyph treatment.
        static let menuWidth: CGFloat = 300
        static let menuPadding: CGFloat = 6
        static let menuGap: CGFloat = 1
        static let menuTextInset: CGFloat = 10
        static let menuSectionTopPad: CGFloat = 8
        static let menuSectionBottomPad: CGFloat = 6
        static let menuRowPadV: CGFloat = 7
        static let menuFrequentRowPadV: CGFloat = 8
        static let menuRowGap: CGFloat = 9
        static let menuIconSize: CGFloat = 14
        static let menuRuleInset: CGFloat = 8
        static let menuRulePadV: CGFloat = 5
        static let menuBorderWidth: CGFloat = 1
        static let menuRuleWidth: CGFloat = 1
        static let menuTop: CGFloat = 61
        static let menuTrailing: CGFloat = 20
        static let menuShadowRadius: CGFloat = 20
        static let menuShadowY: CGFloat = 18

        /// Icon sizes.
        static let markSize: CGFloat = 17
        static let iconSmall: CGFloat = 12
        static let iconTiny: CGFloat = 10.5
        // Menu bar status item
        static let statusItemSize: CGFloat = 18
        static let recordDotSize: CGFloat = 7
        static let menuGlyphSize: CGFloat = 10
        /// The dot pulses 1.6s ease-in-out. The pulse is the app's only
        /// animation (rule 14). It autoreverses, so each half is 0.8s.
        static let pulseHalfPeriod: CFTimeInterval = 0.8
    }

    // MARK: - AppKit bridge
    //
    // The status item and its menu are NSMenu/NSImage, which cannot take a
    // SwiftUI Color. Same tokens, AppKit types. Do not re-enter raw hex here.

    enum NS {
        /// sRGB, not `calibratedRed:`. Generic RGB renders #D2371B as #DD4D22,
        /// a visibly brighter red than the rest of the app's Signal.
        static let signal = NSColor(srgbRed: 0xD2 / 255, green: 0x37 / 255,
                                    blue: 0x1B / 255, alpha: 1)
        static let onSignal = NSColor(srgbRed: 0xFF / 255, green: 0xF9 / 255,
                                      blue: 0xF4 / 255, alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// The Patchthrough mark on its native 24×24 grid, from
/// logo/CLAUDE_CODE_HANDOFF.md. A Shape draws the mark, so the mark stays crisp
/// at every size and follows the foreground colour.
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

/// Destination use counts rank the menu; the last-used id drives the split
/// button's primary action. Both are keyed by Destination.id
/// ("cli:claude", "gui:claude-cowork").
struct DestinationRanking {
    private static let countsKey = "handoff.useCounts"
    private static let lastUsedKey = "handoff.lastUsedDestination"

    static func counts() -> [String: Int] {
        UserDefaults.standard.dictionary(forKey: countsKey) as? [String: Int] ?? [:]
    }

    static func lastUsedID() -> String? {
        UserDefaults.standard.string(forKey: lastUsedKey)
    }

    static func record(_ id: String) {
        var c = counts()
        c[id, default: 0] += 1
        UserDefaults.standard.set(c, forKey: countsKey)
        UserDefaults.standard.set(id, forKey: lastUsedKey)
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
    /// Transcript turn timestamp.
    func monoCaption() -> some View {
        self.font(PT.F.monoTiny).foregroundStyle(PT.C.text5)
    }
}
