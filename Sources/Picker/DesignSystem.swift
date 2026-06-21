import SwiftUI

// MARK: - Design tokens
//
// The vocabulary of the instrument. Ink is the neutral type hierarchy; the only
// saturated color in the product is whatever the user just picked. Spacing rides
// a 4pt grid. Radii step from chip → card → panel so nested corners stay concentric.

enum Ink {
    static let primary = Color.primary
    static let secondary = Color.secondary
    static let tertiary = Color(nsColor: .tertiaryLabelColor)
    static let faint = Color(nsColor: .quaternaryLabelColor)
}

enum Hairline {
    /// Separation that you feel rather than see. Adapts with the material behind it.
    static let soft = Color.primary.opacity(0.07)
    static let medium = Color.primary.opacity(0.12)
    /// Inner edge for filled color surfaces so light swatches don't bleed into glass.
    static let onColor = Color.white.opacity(0.18)
}

enum Space {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
}

enum Radius {
    static let chip: CGFloat = 13
    static let card: CGFloat = 18
    static let panel: CGFloat = 24
    static let pill: CGFloat = 999
}

enum TypeScale {
    static let heroHex = Font.system(size: 30, weight: .semibold, design: .monospaced)
    static let value = Font.system(size: 13, weight: .medium, design: .monospaced)
    static let valueStrong = Font.system(size: 13, weight: .semibold, design: .monospaced)
    static let label = Font.system(size: 11, weight: .semibold)
    static let caption = Font.system(size: 11, weight: .medium)
    static let sectionTitle = Font.system(size: 11, weight: .semibold)
    static let button = Font.system(size: 14, weight: .semibold)
}

enum Motion {
    /// Entering / content settling — eased deceleration, crisp, no bounce.
    static let settle = Animation.smooth(duration: 0.34)
    /// New element arriving — quick with the faintest snap.
    static let arrive = Animation.snappy(duration: 0.3, extraBounce: 0.02)
    /// Micro state (hover / press) — near-instant.
    static let micro = Animation.easeOut(duration: 0.13)
}

// MARK: - Interaction styles

/// Press feedback that never shifts layout bounds: scale + a whisper of dim.
struct PressableStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(Motion.micro, value: configuration.isPressed)
    }
}

extension View {
    /// A standard tactile press for chips and rows.
    func pressable(scale: CGFloat = 0.96) -> some View {
        buttonStyle(PressableStyle(pressedScale: scale))
    }
}
