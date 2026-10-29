import Foundation

/// A way to look at the window of the update (its design, its animations, a failure at a chosen stage) without a release on GitHub:
/// `NIMB_PREVIEW_UPDATE=ok` offers an update that does not exist and runs a pretend installation that downloads nothing and
/// replaces nothing; `long` does the same with a long list of what is new; `NIMB_PREVIEW_UPDATE=<stage>` (`prepare`, `download`, `signature`, `files`, `install`) fails at that stage.
/// Without the variable nothing here is used.
enum UpdatePreview {
    static var mode: String? {
        guard let value = ProcessInfo.processInfo.environment["NIMB_PREVIEW_UPDATE"], !value.isEmpty else { return nil }
        return value
    }

    static let release = Release(
        version: "0.9.21", assetName: "Nimb-0.9.21.zip", zipURL: URL(string: "https://github.com/Dizrane/Nimb")!, sha256: nil,
        pageURL: URL(string: "https://github.com/Dizrane/Nimb/releases")!,
        notes: """
        - **Обновления подписаны.** Nimb ставит новое обновление, только если оно подписано автором.
        - **Помощник туннеля защищён от подмены.** «Без пароля» не включится, если кто-то, кроме администратора, может подменить помощника.
        - **Честно про туннель.** Туннель нужен для доступа, а не для анонимности.

        Остальное, как в 0.9.20.
        """)

    /// The offered release: with `NIMB_PREVIEW_UPDATE=long` its list of what is new is long, to see how the window holds it.
    static func offered(for mode: String) -> Release {
        guard mode == "long" else { return release }
        var longer = release
        let extra = (1...6).map { "- **Ещё один пункт \($0).** Пример длинного описания, чтобы увидеть, как окно держит много изменений и что оно не растёт." }
        longer.notes = (release.notes ?? "") .replacingOccurrences(of: "\nОстальное", with: "\n" + extra.joined(separator: "\n") + "\n\nОстальное")
        return longer
    }

    /// The stage at which the pretend installation fails, if the mode names one.
    static func failingStage(_ mode: String) -> UpdateStage? {
        UpdateStage.allCases.first { stage in
            switch stage {
            case .prepare: mode == "prepare"
            case .download: mode == "download"
            case .signature: mode == "signature"
            case .files: mode == "files"
            case .install: mode == "install"
            }
        }
    }

    /// Goes through the stages one after another, `pause` seconds each (the download longer, with the bytes coming in), and fails at the
    /// stage the mode names (if it names one).
    static func simulate(mode: String, pause: Double, progress: (UpdateStage, UpdateStageState) -> Void,
                         downloaded: (Int64, Int64) -> Void = { _, _ in }) async throws {
        let failing = failingStage(mode)
        for stage in UpdateStage.allCases {
            progress(stage, .running)
            if stage == .download {
                let total: Int64 = 10_700_000
                let steps = 24
                for step in 1...steps {
                    try? await Task.sleep(nanoseconds: UInt64(pause * 2.6 / Double(steps) * 1_000_000_000))
                    // A failure of the download comes part-way, as a real one does.
                    if failing == .download && step == steps / 2 { throw UpdateFailure(stage: stage, message: "Это пример ошибки: на самом деле ничего не скачивалось.") }
                    downloaded(total * Int64(step) / Int64(steps), total)
                }
            } else {
                try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
            }
            if stage == failing { throw UpdateFailure(stage: stage, message: "Это пример ошибки: на самом деле ничего не скачивалось и не проверялось.") }
            progress(stage, .done)
        }
    }
}
