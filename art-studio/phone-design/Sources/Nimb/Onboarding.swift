import SwiftUI

/// The first-launch walk-through: one step for each thing Nimb does, then the two switches that make it work without
/// the person. It can be gone through again from the settings.
@MainActor
final class Onboarding: ObservableObject {
    static let shared = Onboarding()
    private static let doneKey = "onboardingDone"
    static let lastStep = 4

    @Published var isShown = false
    @Published var step = 0

    /// A Mac that already has something switched on was set up by hand before the walk-through existed: not shown there.
    func showIfFresh(existingSetup: Bool) {
        guard !UserDefaults.standard.bool(forKey: Self.doneKey) else { return }
        if existingSetup {
            UserDefaults.standard.set(true, forKey: Self.doneKey)
        } else {
            start()
        }
    }

    func start() {
        step = 0
        isShown = true
    }

    func next() {
        if step >= Self.lastStep { finish() } else { withAnimation(.easeInOut(duration: 0.25)) { step += 1 } }
    }

    func finish() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        withAnimation(.easeInOut(duration: 0.3)) { isShown = false }
    }
}
