import SwiftUI

/// The three things Nimb does, one page each.
enum AppTab: String, CaseIterable, Identifiable {
    case home, ai, telegram, media

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Главная"
        case .ai: return "Нейросети"
        case .telegram: return "Telegram"
        case .media: return "YouTube и Discord"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .ai: return "sparkles"
        case .telegram: return "paperplane"
        case .media: return "play.rectangle"
        }
    }
}
