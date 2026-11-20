import SwiftUI

/// What the window is doing right now.
enum AppMode: Equatable {
    case off, on, probing, busy
}

/// A quiet black-and-white scene with colour reserved for status. The colours are full and clear: green for on and working,
/// amber for caution and the recommended choice, red for failure.
enum Theme {
    static let base = Color.black
    static let accent = Color.white
    static let textPrimary = Color.white.opacity(0.94)
    static let textSecondary = Color.white.opacity(0.68)
    static let hairline = Color.white.opacity(0.11)
    static let ok = Color(red: 0.19, green: 0.82, blue: 0.35)
    static let warn = Color(red: 1.00, green: 0.78, blue: 0.20)
    static let bad = Color(red: 1.00, green: 0.35, blue: 0.32)
}

/// Type: a serif for the one big word, a restrained sans for everything else, monospace for numbers and addresses.
enum Typo {
    /// New York, the system serif. It carries the status word, which is the only large text in the window.
    static let status = Font.system(size: 31, weight: .regular, design: .serif)
    static let name = Font.system(size: 15, weight: .medium)
    static let body = Font.system(size: 13, weight: .regular)
    static let small = Font.system(size: 12, weight: .regular)
    static let mono = Font.system(size: 11.5, weight: .regular, design: .monospaced)
}

/// One scale for every gap in the window.
enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    /// Side margin of every page, and the gap between the blocks of a page.
    static let page: CGFloat = 20
    static let gap: CGFloat = 12
}

/// The meaning of a card: plain, working, to be careful about, broken.
enum Tone {
    case neutral, ok, warn, bad

    var color: Color {
        switch self {
        case .neutral: return .white
        case .ok: return Theme.ok
        case .warn: return Theme.warn
        case .bad: return Theme.bad
        }
    }
}

extension View {
    /// A small tracked caps label above a block, like a section title in a printed report.
    func sectionLabel() -> some View {
        self.font(.system(size: 10, weight: .semibold))
            .tracking(1.8)
            .textCase(.uppercase)
            .foregroundStyle(Theme.textSecondary.opacity(0.9))
            .accessibilityAddTraits(.isHeader)
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
    /// The card of the window: one padding, one radius, a hairline border and a tint for its meaning.
    func card(_ tone: Tone = .neutral) -> some View {
        card(tint: tone.color, strength: tone == .neutral ? 0 : 1)
    }

    /// The same for a colour that is given as it is (the colour of a notice).
    func card(tint: Color, strength: Double = 1) -> some View {
        self
            .padding(Space.l - 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(tint: tint, tintOpacity: 0.02 + 0.02 * strength, borderOpacity: 0.16 + 0.14 * strength, radius: 14)
    }

    /// A card of its own (the settings), or a row of a card that holds several of them (the first set-up): then only a little room above and below.
    @ViewBuilder
    func framedCard(_ framed: Bool) -> some View {
        if framed { card(.neutral) } else { padding(.vertical, 8) }
    }

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

/// Main window with a fixed content size. It can still be moved by its background and minimized.
struct WindowConfigurator: NSViewRepresentable {
    static let contentSize = CGSize(width: 1100, height: 660)

    func makeNSView(context: Context) -> LockView { LockView() }

    func updateNSView(_ view: LockView, context: Context) { view.scheduleConfiguration() }

    final class LockView: NSView {
        private var scheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let notifications = NotificationCenter.default
            notifications.removeObserver(self, name: NSWindow.didResizeNotification, object: nil)
            guard let window else { return }
            // SwiftUI and macOS can restore a stored frame after the first layout pass.
            notifications.addObserver(self, selector: #selector(windowDidResize), name: NSWindow.didResizeNotification, object: window)
            scheduleConfiguration()
        }

        @objc private func windowDidResize(_ notification: Notification) {
            scheduleConfiguration()
        }

        func scheduleConfiguration() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                if let window = self.window { WindowConfigurator.configure(window) }
            }
        }
    }

    private static func configure(_ window: NSWindow) {
        let style = window.styleMask.union(.fullSizeContentView).subtracting(.resizable)
        if window.styleMask != style { window.styleMask = style }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(Theme.base)
        let behavior = window.collectionBehavior.subtracting([.fullScreenPrimary, .fullScreenAuxiliary, .fullScreenAllowsTiling])
            .union([.fullScreenNone, .fullScreenDisallowsTiling])
        if window.collectionBehavior != behavior { window.collectionBehavior = behavior }
        window.standardWindowButton(.zoomButton)?.isEnabled = false

        // Take the system title-bar height into account even though the background draws behind it.
        let content = CGRect(origin: .zero, size: contentSize)
        let frameSize = NSWindow.frameRect(forContentRect: content, styleMask: style.subtracting(.fullSizeContentView)).size
        if window.minSize != frameSize { window.minSize = frameSize }
        if window.maxSize != frameSize { window.maxSize = frameSize }
        let frame = window.frame
        guard frame.size != frameSize else { return }
        let target = CGRect(x: frame.minX, y: frame.maxY - frameSize.height, width: frameSize.width, height: frameSize.height)
        let origin = window.constrainFrameRect(target, to: window.screen).origin
        window.setFrame(CGRect(origin: origin, size: frameSize), display: true)
        AppLog.shared.add("окно", "размер \(frame.size) → \(window.frame.size), рабочая область \(window.contentLayoutRect.size)")
    }
}
