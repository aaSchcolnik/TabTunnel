import AppKit
import SwiftUI

/// Type scale, spacing and contrast-tested colors. The app uses the system font (SF Pro) and follows the system’s
/// light/dark appearance, accent color and Reduce Transparency. Increase Contrast strengthens every hairline, wash
/// and focus ring. Text never goes below 12 pt; "Large" text size raises everything by about 15%.
struct Theme {
    var large: Bool
    /// System Increase Contrast setting.
    var increased: Bool = false

    var title: CGFloat { large ? 15 : 13 }          // tab titles, row labels
    var secondary: CGFloat { large ? 13.5 : 12 }    // hosts, captions
    var headline: CGFloat { large ? 15.5 : 13.5 }   // window header
    var section: CGFloat { large ? 13 : 12 }        // section headers
    var rowHeight: CGFloat { large ? 46 : 40 }
    var headerRowHeight: CGFloat { large ? 38 : 34 }
    var icon: CGFloat { large ? 18 : 16 }

    /// Quiet separators (cards, group boxes). Not for controls: those use `boundary`.
    var hairline: Double { increased ? 0.55 : 0.3 }
    /// Border of interactive controls (search field, chips): >= 3:1 against their surroundings.
    var boundary: Color { increased ? .boundaryStrong : .boundary }
    /// Hover wash on rows and buttons.
    var wash: Double { increased ? 0.16 : 0.08 }
    /// Fill of resting chips and badges.
    var fill: Double { increased ? 0.12 : 0.06 }
    var focusRing: CGFloat { increased ? 3 : 2 }

    static let gutter: CGFloat = 12   // horizontal padding of the window
    static let radius: CGFloat = 7
    static let popoverWidth: CGFloat = 400
    static let popoverHeight: CGFloat = 580
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme(large: false)
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// Applies the theme for the current text-size setting and the system’s Increase Contrast setting.
struct ThemeProvider: ViewModifier {
    var large: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .environment(\.theme, Theme(large: large, increased: contrast == .increased))
            .controlSize(large ? .large : .regular)
    }
}

extension View {
    func theme(large: Bool) -> some View { modifier(ThemeProvider(large: large)) }
}

private func dynamic(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    })
}

extension Color {
    /// Secondary text that meets 4.5:1 on window and popover backgrounds in both appearances
    /// (the system’s `.secondary` is about 3.8:1 in light mode).
    static let secondaryText = dynamic(light: NSColor(white: 0, alpha: 0.66), dark: NSColor(white: 1, alpha: 0.62))
    /// Status colors: Apple’s increased-contrast variants in light mode (>= 3:1 as icons on light gray, 4.5:1 for text).
    /// Control borders: opaque grays measured at >= 3:1 against window and popover backgrounds.
    static let boundary = dynamic(light: NSColor(white: 0.46, alpha: 1), dark: NSColor(white: 0.60, alpha: 1))
    static let boundaryStrong = dynamic(light: NSColor(white: 0.25, alpha: 1), dark: NSColor(white: 0.80, alpha: 1))
    /// Keyboard focus rings: >= 3:1 against window, popover, field and selected-row fills in both appearances
    /// (the system accent blue is about 2.6:1 on dark fills).
    static let focusRing = dynamic(light: NSColor(srgbRed: 0, green: 0.37, blue: 0.80, alpha: 1),
                                   dark: NSColor(srgbRed: 0.40, green: 0.68, blue: 1.0, alpha: 1))
    static let statusGreen = dynamic(light: NSColor(srgbRed: 0.10, green: 0.50, blue: 0.20, alpha: 1), dark: .systemGreen)
    static let statusOrange = dynamic(light: NSColor(srgbRed: 0.74, green: 0.30, blue: 0.0, alpha: 1), dark: .systemOrange)
    static let statusRed = dynamic(light: NSColor(srgbRed: 0.80, green: 0.0, blue: 0.08, alpha: 1), dark: .systemRed)
}

extension ShapeStyle where Self == Color {
    static var secondaryText: Color { Color.secondaryText }
}

extension Health.Level {
    var symbol: String {
        switch self {
        case .starting: return "arrow.clockwise.icloud"
        case .ok: return "checkmark.icloud"
        case .attention: return "exclamationmark.icloud"
        case .problem: return "icloud.slash"
        }
    }

    /// Colors only reinforce the symbol’s shape; each state is distinguishable without color.
    var tint: Color {
        switch self {
        case .starting: return .secondaryText
        case .ok: return .statusGreen
        case .attention: return .statusOrange
        case .problem: return .statusRed
        }
    }

    var spoken: String {
        switch self {
        case .starting: return "Starting"
        case .ok: return "Working"
        case .attention: return "Needs attention"
        case .problem: return "Not working"
        }
    }
}

extension Issue.Severity {
    var symbol: String { self == .problem ? "xmark.octagon.fill" : "exclamationmark.triangle.fill" }
    var tint: Color { self == .problem ? .statusRed : .statusOrange }
    var spoken: String { self == .problem ? "Problem" : "Warning" }
}

/// Posts a VoiceOver announcement (used for "Copied" confirmations, which are otherwise visual only).
@MainActor
func announce(_ text: String) {
    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                         userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
}

/// Borderless buttons (footer, chips) that show hover, press and a clear keyboard focus ring.
struct QuietButtonStyle: ButtonStyle {
    var shape: AnyShape = AnyShape(RoundedRectangle(cornerRadius: 6))

    func makeBody(configuration: Configuration) -> some View {
        QuietButton(configuration: configuration, shape: shape)
    }

    private struct QuietButton: View {
        let configuration: Configuration
        let shape: AnyShape
        @State private var hovering = false
        @Environment(\.isFocused) private var focused
        @Environment(\.theme) private var theme

        var body: some View {
            configuration.label
                // Chips sit on their own fill, so their hover wash is stronger to stay visible.
                .background(shape.fill(Color.primary.opacity(configuration.isPressed ? theme.wash * 2 : hovering ? theme.wash * 1.5 : 0)))
                // Keyboard focus is an accent ring just outside the control, so it never looks like a border or a
                // selection.
                .overlay(shape.stroke(Color.focusRing, lineWidth: theme.focusRing).padding(-3).opacity(focused ? 1 : 0))
                .contentShape(shape)
                .onHover { hovering = $0 }
        }
    }
}

/// A button label that always takes the width of `reserve`, so swapping to a shorter word ("Copied") never changes
/// the button's size or moves what's next to it.
struct StableLabel: View {
    var text: String
    var reserve: String

    var body: some View {
        ZStack {
            Text(reserve).hidden().accessibilityHidden(true)
            Text(text)
        }
    }
}

extension Button where Label == StableLabel {
    init(stable text: String, reserve: String, action: @escaping () -> Void) {
        self.init(action: action) { StableLabel(text: text, reserve: reserve) }
    }
}
