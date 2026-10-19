import SwiftUI

/// Which page is open and, in the layout with tabs, which tabs are open. One for the whole app: the window, the menu bar panel
/// and the buttons that open a page ("Настройки…", "Настроить") all go through it.
@MainActor
final class Navigation: ObservableObject {
    static let shared = Navigation()

    @Published private(set) var page: AppPage = .home
    /// The tabs that are open, in order. «Главная» is pinned and always first.
    @Published private(set) var openTabs: [AppPage] = [.home]

    /// Opens a page (and, with tabs, a tab for it) and makes it the current one.
    func select(_ target: AppPage) {
        if !openTabs.contains(target) { openTabs.append(target) }
        page = target
    }

    /// Closes a tab; the neighbour takes its place. «Главная» cannot be closed.
    func close(_ target: AppPage) {
        guard target != .home, let index = openTabs.firstIndex(of: target) else { return }
        openTabs.remove(at: index)
        if page == target { page = openTabs[min(index, openTabs.count) - 1] }
    }

    /// The layout was changed (or chosen at launch): the tabs start again with «Главная» and the page that is open.
    func layoutChanged(to layout: WindowLayout) {
        openTabs = page == .home ? [.home] : [.home, page]
    }

    /// The pages that are not open as tabs yet.
    var closedTabs: [AppPage] { AppPage.allCases.filter { !openTabs.contains($0) } }
}
