import Foundation

/// One startup owns its cancellation marker until the worker has stopped and removed its routes.
/// The privileged script only reads this marker; no user-writable content is executed as root.
final class TunnelStartAttempt: @unchecked Sendable {
    private let folder: URL
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    var marker: String { folder.appendingPathComponent("cancel").path }

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("Nimb-start-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func cancel() throws {
        lock.lock(); defer { lock.unlock() }
        try Data().write(to: URL(fileURLWithPath: marker), options: .atomic)
        cancelled = true
    }
    /// Process waits must not occupy Swift's cooperative executor while cancellation/UI work needs to resume.
    static func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async -> Result<T, Error> {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread { continuation.resume(returning: Result { try work() }) }
        }
    }

    static func cancellationWasClean(_ result: Result<String, Error>) -> Bool {
        switch result {
        case .success(let output): return output.split(whereSeparator: \.isNewline).contains("NIMB-CANCELLED-CLEAN")
        case .failure(DNSError.cancelled): return true // Authorization was refused before the start script ran.
        default: return false
        }
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }

    /// Supervise the whole start, including setup and authorization delays. A down waits for the starter to exit before cleanup.
    func script(up: String, down: String, preparation: [String] = [], timeout: Int = 120) -> String {
        let marker = DNSManager.shellQuote(marker)
        // Finish the short, already-authorized file installation before honouring stop; never leave half-written helper/config files.
        let preparing = preparation.isEmpty ? "" : "trap '' TERM INT\n" + preparation.joined(separator: "\n")
        return """
        clean_cancel() { echo 'NIMB-CANCELLED-CLEAN'; exit 0; }
        cleanup() { \(down); }
        [ ! -e \(marker) ] || clean_cancel
        set -m
        ( set -e
          trap 'exit 130' TERM INT
          \(preparing)
          [ ! -e \(marker) ] || exit 130
          if [ -n "${stage:-}" ]; then /bin/rm -rf "$stage"; trap - EXIT; fi
          trap - TERM INT
          exec \(up)
        ) &
        starter=$!
        ticks=0
        while kill -0 "$starter" 2>/dev/null; do
            if [ -e \(marker) ] || [ "$ticks" -ge \(timeout * 5) ]; then
                kill -TERM -- "-$starter" 2>/dev/null || true
                wait "$starter" 2>/dev/null || true
                if [ -e \(marker) ]; then
                    if cleanup; then clean_cancel; else exit 1; fi
                fi
                cleanup
                echo 'Время подключения истекло. Проверьте сеть и попробуйте ещё раз.' >&2
                exit 1
            fi
            sleep 0.2
            ticks=$((ticks + 1))
        done
        wait "$starter"; result=$?
        if [ -e \(marker) ]; then
            if cleanup; then clean_cancel; else exit 1; fi
        fi
        if [ "$result" -ne 0 ]; then cleanup; fi
        exit "$result"
        """
    }
}
