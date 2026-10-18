import SwiftUI

/// What the window is doing right now; drives the colours of the background and the orb.
enum AppMode: Equatable {
    case off, on, probing, busy

    var accent: Color {
        switch self {
        case .off: return Color(red: 0.46, green: 0.70, blue: 0.99)
        case .on: return Color(red: 0.22, green: 0.92, blue: 0.64)
        case .probing, .busy: return Color(red: 0.27, green: 0.80, blue: 1.00)
        }
    }

    var secondary: Color {
        switch self {
        case .off: return Color(red: 0.26, green: 0.44, blue: 0.90)
        case .on: return Color(red: 0.08, green: 0.62, blue: 0.82)
        case .probing, .busy: return Color(red: 0.50, green: 0.38, blue: 1.00)
        }
    }
}

enum Theme {
    static let base = Color(red: 0.035, green: 0.043, blue: 0.075)
    static let textPrimary = Color.white.opacity(0.96)
    static let textSecondary = Color.white.opacity(0.74)
    static let ok = Color(red: 0.30, green: 0.92, blue: 0.62)
    static let warn = Color(red: 1.00, green: 0.74, blue: 0.28)
    static let bad = Color(red: 1.00, green: 0.38, blue: 0.45)
}

/// Frosted card used for providers and notices.
struct GlassCard: ViewModifier {
    var tint: Color = .white
    var tintOpacity: Double = 0.0
    var borderOpacity: Double = 0.14
    var radius: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color(red: 0.03, green: 0.05, blue: 0.12).opacity(0.46))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.white.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(tint.opacity(tintOpacity)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [tint.opacity(borderOpacity * 2.2 + 0.06), Color.white.opacity(0.04)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1
                    )
            )
    }
}

extension View {
    func glassCard(tint: Color = .white, tintOpacity: Double = 0, borderOpacity: Double = 0.14, radius: CGFloat = 18) -> some View {
        modifier(GlassCard(tint: tint, tintOpacity: tintOpacity, borderOpacity: borderOpacity, radius: radius))
    }
}

/// A boolean the view owns. Stands in for @State, whose macro plugin is not shipped with Command Line Tools.
final class Flag: ObservableObject {
    @Published var value = false
}

/// Slight press-down feedback for custom buttons.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Window without a title bar that can be dragged by its background.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.backgroundColor = NSColor(Theme.base)
            window.standardWindowButton(.zoomButton)?.isEnabled = false
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
