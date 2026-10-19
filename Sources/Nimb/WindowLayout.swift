import SwiftUI

/// How the window of the Mac is laid out: a list of pages on the left (the default), or tabs like in Safari.
enum WindowLayout: String, CaseIterable {
    case sidebar, tabs

    var defaultSize: CGSize {
        switch self {
        case .sidebar: CGSize(width: 720, height: 480)
        case .tabs: CGSize(width: 640, height: 470)
        }
    }

    var minimumSize: CGSize {
        switch self {
        case .sidebar: CGSize(width: 640, height: 420)
        case .tabs: CGSize(width: 480, height: 400)
        }
    }

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
