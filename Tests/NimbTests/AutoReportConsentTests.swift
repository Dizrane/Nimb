import Foundation
import Testing
@testable import Nimb

private actor ConsentCheckpoint {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct AutoReportConsentTests {
    @Test @MainActor func optingOutDuringCollectionCannotSendOrRestoreASnapshotEvenAfterOptingInAgain() async {
        let consent = AutoReportConsent(enabled: true)
        let collecting = ConsentCheckpoint(), collected = ConsentCheckpoint(), finished = ConsentCheckpoint()
        var sent = 0, saved = 0
        consent.run { permit in
            await collecting.release()
            // A system read that does not respond to cancellation may finish later.
            await collected.wait()
            if consent.isCurrent(permit) { sent += 1; saved += 1 }
            await finished.release()
        }
        await collecting.wait()
        consent.setEnabled(false)
        consent.setEnabled(true)
        await collected.release()
        await finished.wait()
        #expect(sent == 0)
        #expect(saved == 0)
    }

    @Test @MainActor func optingOutDuringRetryPreventsTheNextReportAndQueueRecreation() async {
        let consent = AutoReportConsent(enabled: true)
        let sending = ConsentCheckpoint(), answer = ConsentCheckpoint(), finished = ConsentCheckpoint()
        var sent: [Int] = [], saved = false
        consent.run { permit in
            for report in [1, 2] {
                guard consent.isCurrent(permit) else { break }
                sent.append(report)
                await sending.release()
                await answer.wait()
                guard consent.isCurrent(permit) else { break }
                saved = true
            }
            await finished.release()
        }
        await sending.wait()
        consent.setEnabled(false)
        await answer.release()
        await finished.wait()
        #expect(sent == [1])
        #expect(!saved)
    }

    @Test @MainActor func optingOutCancelsAnInFlightTransportTask() async {
        let consent = AutoReportConsent(enabled: true)
        let sending = ConsentCheckpoint(), cancelled = ConsentCheckpoint()
        consent.run { _ in
            await sending.release()
            do { try await Task.sleep(for: .seconds(60)) } catch { await cancelled.release() }
        }
        await sending.wait()
        consent.setEnabled(false)
        await cancelled.wait()
    }
}
