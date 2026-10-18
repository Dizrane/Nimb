import SwiftUI

/// What the window is doing right now.
enum AppMode: Equatable {
    case off, on, probing, busy
}

/// A quiet black-and-white scene with colour reserved for status. The colours are muted on purpose: sage for on and
/// working, champagne for caution and the recommended choice, a dusty red for failure.
enum Theme {
    static let base = Color.black
    static let accent = Color.white
    static let textPrimary = Color.white.opacity(0.94)
    static let textSecondary = Color.white.opacity(0.68)
    static let hairline = Color.white.opacity(0.11)
    static let ok = Color(red: 0.46, green: 0.80, blue: 0.67)
    static let warn = Color(red: 0.86, green: 0.72, blue: 0.47)
    static let bad = Color(red: 0.86, green: 0.46, blue: 0.46)
}

/// Type: a serif for the one big word, a restrained sans for everything else, monospace for numbers and addresses.
enum Typo {
    /// New York, the system serif. It carries the status word, which is the only large text in the window.
    static let status = Font.system(size: 31, weight: .regular, design: .serif)
    static let name = Font.system(size: 15, weight: .medium)
    static let body = Font.system(size: 12.5, weight: .regular)
    static let small = Font.system(size: 11.5, weight: .regular)
    static let mono = Font.system(size: 11.5, weight: .regular, design: .monospaced)
}

extension View {
    /// A small tracked caps label above a block, like a section title in a printed report.
    func sectionLabel() -> some View {
        self.font(.system(size: 10, weight: .semibold))
            .tracking(1.8)
            .textCase(.uppercase)
            .foregroundStyle(Theme.textSecondary.opacity(0.9))
    }
}

/// Dark card used for providers and notices: a hairline border instead of a glossy edge.
struct GlassCard: ViewModifier {
    var tint: Color = .white
    var tintOpacity: Double = 0.0
    var borderOpacity: Double = 0.11
    var radius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.black.opacity(0.68))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.white.opacity(0.03)))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(tint.opacity(tintOpacity)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(tint.opacity(borderOpacity), lineWidth: 1)
            )
    }
}

extension View {
    func glassCard(tint: Color = .white, tintOpacity: Double = 0, borderOpacity: Double = 0.11, radius: CGFloat = 12) -> some View {
        modifier(GlassCard(tint: tint, tintOpacity: tintOpacity, borderOpacity: borderOpacity, radius: radius))
    }
}

/// A boolean the view owns. Stands in for @State, whose macro plugin is not shipped with Command Line Tools.
final class Flag: ObservableObject {
    @Published var value = false
}

/// Press feedback without any bounce: a barely visible, quick dip.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
