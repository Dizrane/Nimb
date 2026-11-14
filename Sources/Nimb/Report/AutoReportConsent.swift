import Foundation

/// Work belongs to one uninterrupted opt-in. Turning testing off cancels its tasks; a later opt-in never revives them.
@MainActor
final class AutoReportConsent {
    struct Permit: Equatable, Sendable { fileprivate let id = UUID() }

    private var permit: Permit?
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(enabled: Bool) { permit = enabled ? Permit() : nil }

    func setEnabled(_ enabled: Bool) {
        permit = enabled ? Permit() : nil
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }

    func isCurrent(_ candidate: Permit) -> Bool { permit == candidate && !Task.isCancelled }

    func run(_ operation: @escaping @MainActor (Permit) async -> Void) {
        guard let permit else { return }
        let id = UUID()
        tasks[id] = Task {
            guard isCurrent(permit) else { tasks[id] = nil; return }
            await operation(permit)
            tasks[id] = nil
        }
    }
}
