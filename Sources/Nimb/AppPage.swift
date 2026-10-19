import Foundation

/// The pages of the window: the home page, one page for each of the three services, and the settings.
enum AppPage: String, CaseIterable, Identifiable {
    case home, ai, telegram, media, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Главная"
        case .ai: "Нейросети"
        case .telegram: "Telegram"
        case .media: "YouTube и Discord"
        case .settings: "Настройки"
        }
    }

    /// The pages of the three services.
    static let services: [AppPage] = [.ai, .telegram, .media]

    var isService: Bool { self != .home && self != .settings }
}
