import SwiftUI

/// How the window of the Mac is laid out: a list of pages on the left (the default), or tabs like in Safari.
enum WindowLayout: String, CaseIterable {
    case sidebar, tabs

    /// One size for both layouts, wide rather than tall: everything of every page (two columns of cards beside the figure) fits in
    /// it at once, so that nothing in the app has to be scrolled. The window can be made larger, never smaller.
    static let minimumSize = CGSize(width: 1100, height: 660)

    var defaultSize: CGSize { Self.minimumSize }
    var minimumSize: CGSize { Self.minimumSize }

    var title: String { self == .sidebar ? "Боковая панель" : "Вкладки" }
    var detail: String { self == .sidebar ? "Список слева, страница справа" : "Как в Safari: вкладки сверху" }
}

/// The chosen layout of the window, remembered between launches. A change shows at once.
@MainActor
final class WindowLayoutSetting: ObservableObject {
    static let shared = WindowLayoutSetting()
    private static let key = "windowLayout"

    @Published var layout: WindowLayout {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: Self.key) }
    }

    private init() {
        layout = WindowLayout(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .sidebar
    }
}
