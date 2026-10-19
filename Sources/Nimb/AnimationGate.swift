import AppKit
import SwiftUI

/// Whether the animations of the window have anyone to show themselves to. A window that is covered, hidden or not in
/// front (the person works in another program) is not watched, so nothing is drawn for it: this is most of the time of a
/// program that lives in the background, and the difference is the difference between a program that is felt and one that
/// is not.
@MainActor
final class AnimationGate: ObservableObject {
    static let shared = AnimationGate()

    /// The window can be seen at all (not closed, hidden, minimised or fully covered).
    @Published private(set) var isVisible = true
    /// Nimb is the program in front.
    @Published private(set) var isActive = true

    private init() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification, NSApplication.didUnhideNotification,
            NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification, NSWindow.didBecomeKeyNotification,
        ]
        for name in names {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // After the system has finished with the window: its state is read then.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.update() } }
            }
        }
        update()
    }

    private func update() {
        let visible = !NSApp.isHidden && NSApp.windows.contains { $0.canBecomeMain && $0.isVisible && $0.occlusionState.contains(.visible) }
        let active = NSApp.isActive
        if visible != isVisible { isVisible = visible }
        if active != isActive { isActive = active }
    }

    /// Whether a continuous animation should run: only for a window that is seen and in front. A short one (something is
    /// changing right now) may also run while the window is seen but not in front.
    func shouldRun(brief: Bool) -> Bool { isVisible && (isActive || brief) }
}
