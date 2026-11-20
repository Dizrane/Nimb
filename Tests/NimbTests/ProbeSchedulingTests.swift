import Foundation
import Testing
@testable import Nimb

@Suite struct ProbeSchedulingTests {
    @Test func requestsStartBeforeTheLastDNSAnswerWithoutLosingSamples() {
        let started = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var overlapped = false
        var progress: [(Int, Int)] = []
        let reports = ServiceProbe.run(providers: [DNSProvider.available[0]], resolver: { host, _ in
            if host == ProbeTarget.all[0].host {
                let result = started.wait(timeout: .now() + 2) == .success
                lock.lock(); overlapped = result; lock.unlock()
                return []
            }
            return ["203.0.113.1", "203.0.113.2"]
        }, requester: { _, _ in
            started.signal()
            return .ok(0.2)
        }, progress: { done, total in
            lock.lock(); progress.append((done, total)); lock.unlock()
        })
        #expect(overlapped)
        #expect(reports.count == 1)
        #expect(reports[0].samples.count == 2 * ProbeTarget.all.count - 1)
        #expect(reports[0].samples.first?.address == nil)
        #expect(reports[0].samples.filter(\.ok).count == 2 * (ProbeTarget.all.count - 1))
        let final = progress.last
        #expect(final?.0 == reports[0].samples.count && final?.1 == reports[0].samples.count)
        for (previous, next) in zip(progress, progress.dropFirst()) {
            #expect(next.0 >= previous.0)
            #expect(previous.1 == 0 || next.1 == previous.1)
        }
    }

    @Test func aFailedHostIsRetriedWithoutSkippingOtherHostsOnItsAddress() {
        let lock = NSLock()
        var calls: [String: Int] = [:]
        let failedHost = ProbeTarget.all[0].host
        let reports = ServiceProbe.run(providers: [DNSProvider.available[0]], resolver: { _, _ in
            ["203.0.113.1", "203.0.113.2"]
        }, requester: { target, address in
            let key = target.host + ":" + address
            lock.lock(); calls[key, default: 0] += 1; lock.unlock()
            return target.host == failedHost && address == "203.0.113.1" ? .failed : .ok(0.2)
        }, progress: { _, _ in })
        #expect(reports[0].samples.count == 2 * ProbeTarget.all.count)
        #expect(reports[0].samples.filter(\.ok).count == 2 * ProbeTarget.all.count - 1)
        #expect(calls[failedHost + ":203.0.113.1"] == 2)
        #expect(calls.values.reduce(0, +) == 2 * ProbeTarget.all.count + 1)
    }

    @Test func requestConcurrencyIsBoundedForEveryProvider() {
        let lock = NSLock()
        var active: [String: Int] = [:], peak: [String: Int] = [:]
        let providers = Array(DNSProvider.available.prefix(2))
        let reports = ServiceProbe.run(providers: providers, resolver: { _, servers in
            // Different address ranges identify providers, with four pool addresses per target.
            (1...4).map { servers[0] + "-\($0)" }
        }, requester: { _, address in
            let provider = String(address.split(separator: "-")[0])
            lock.lock()
            active[provider, default: 0] += 1
            peak[provider] = max(peak[provider, default: 0], active[provider, default: 0])
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.005)
            lock.lock(); active[provider, default: 0] -= 1; lock.unlock()
            return .ok(0.2)
        }, progress: { _, _ in })
        #expect(reports.allSatisfy { $0.samples.count == 4 * ProbeTarget.all.count })
        #expect(peak.count == providers.count)
        #expect(peak.values.allSatisfy { $0 > 1 && $0 <= ServiceProbe.perProvider })
    }
}
