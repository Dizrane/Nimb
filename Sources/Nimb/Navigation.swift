import SwiftUI

/// Which page is open. One for the whole app: the window, the menu bar menu
/// and the buttons that open a page ("Настройки…", "Настроить") all go through it.
@MainActor
final class Navigation: ObservableObject {
    static let shared = Navigation()

    @Published private(set) var page: AppPage = .home

    func select(_ target: AppPage) { page = target }
}
