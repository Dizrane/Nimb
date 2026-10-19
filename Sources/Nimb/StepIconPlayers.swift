import SwiftUI

/// One player for each icon, shared by the steps of the first set-up and by the rows of the home page, so that an icon that
/// is playing keeps playing wherever it is shown.
@MainActor
final class StepIconPlayers {
    static let shared = StepIconPlayers()

    private var players: [String: StepIconPlayer] = [:]

    func player(_ kind: StepIconKind) -> StepIconPlayer {
        if let existing = players[kind.folder] { return existing }
        let created = StepIconPlayer(kind: kind)
        players[kind.folder] = created
        return created
    }
}
