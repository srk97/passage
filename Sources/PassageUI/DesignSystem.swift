import SwiftUI

enum PassagePalette {
    static let accent = Color(red: 0.28, green: 0.37, blue: 0.95)
    static let violet = Color(red: 0.55, green: 0.31, blue: 0.92)
    static let mint = Color(red: 0.19, green: 0.70, blue: 0.58)
    static let ink = Color(red: 0.10, green: 0.11, blue: 0.15)
    static let warmWhite = Color(red: 0.97, green: 0.965, blue: 0.95)
}

extension CapturePrivacyPresentation.Tone {
    var passageColor: Color {
        switch self {
        case .remembering: PassagePalette.mint
        case .privateContext: PassagePalette.violet
        case .neutral: Color.secondary
        case .sealed: PassagePalette.accent
        case .attention: Color.red
        }
    }
}

struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.easeOut(duration: reduceMotion ? 0 : 0.12), value: configuration.isPressed)
    }
}

struct PrimaryActionStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 14
    @ScaledMetric(relativeTo: .body) private var verticalPadding: CGFloat = 10
    @ScaledMetric(relativeTo: .body) private var minimumHeight: CGFloat = 42

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, verticalPadding)
            .frame(minHeight: minimumHeight)
            .background(
                LinearGradient(
                    colors: [PassagePalette.accent, PassagePalette.violet],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .shadow(color: PassagePalette.accent.opacity(configuration.isPressed ? 0.12 : 0.25), radius: 16, y: 8)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .animation(.easeOut(duration: reduceMotion ? 0 : 0.12), value: configuration.isPressed)
    }
}

extension View {
    func passageCard(radius: CGFloat = 18) -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.white.opacity(0.36), lineWidth: 0.5)
            }
    }
}
