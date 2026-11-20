import Foundation
import Testing
@testable import Nimb

@Suite struct PartialDNSTests {
    private let provider = DNSProvider.all[0]

    @Test func partialDetectionUsesTheSameSnapshotAsConfiguration() {
        let servers = ["Wi-Fi": provider.addresses, "Ethernet": ["10.0.0.53"]]
        let state = DNSConfiguration(services: ["Wi-Fi", "Ethernet"], servers: servers)
        let partial = DNSManager.partialProvider(on: ["Wi-Fi", "Ethernet"], servers: state.servers)
        #expect(partial?.provider == provider)
        #expect(partial?.missing == ["Ethernet"])
        #expect(DNSManager.partialProvider(on: ["Wi-Fi", "Ethernet"], servers: ["Wi-Fi": [], "Ethernet": []]) == nil)
    }

    @Test func aPartialProviderStillNeedsCleanup() {
        let state = DNSConfiguration(services: ["Wi-Fi", "Ethernet"], servers: ["Wi-Fi": provider.addresses, "Ethernet": []])
        #expect(state.active == nil)
        #expect(state.needsCleanup)
        #expect(state.managedServices == ["Wi-Fi"])
    }

    @Test func cleanupIncludesMixedProvidersAndLeavesCustomDNSAlone() {
        let state = DNSConfiguration(services: ["Wi-Fi", "Ethernet", "Work"], servers: [
            "Wi-Fi": provider.addresses,
            "Ethernet": DNSProvider.all[1].addresses,
            "Work": ["10.0.0.53"],
        ])
        #expect(state.active == nil)
        #expect(state.managedServices == ["Wi-Fi", "Ethernet"])
        let cleanup = DNSManager.applyScript(nil, to: state.managedServices)
        #expect(cleanup.contains("-setdnsservers 'Wi-Fi' Empty"))
        #expect(cleanup.contains("-setdnsservers 'Ethernet' Empty"))
        #expect(!cleanup.contains("Work"))
    }

    @Test func legacyProviderAddressesAreCleanedUpToo() throws {
        let old = try #require(DNSProvider.all.first { !$0.legacy.isEmpty })
        let state = DNSConfiguration(services: ["Wi-Fi", "Ethernet"], servers: ["Wi-Fi": old.legacy[0], "Ethernet": []])
        #expect(state.needsCleanup)
        #expect(state.managedServices == ["Wi-Fi"])
    }

    @Test func completeAndAutomaticStatesRemainDistinct() {
        let complete = DNSConfiguration(services: ["Wi-Fi"], servers: ["Wi-Fi": provider.addresses])
        #expect(complete.active == provider)
        #expect(complete.needsCleanup)
        let custom = DNSConfiguration(services: ["Wi-Fi"], servers: ["Wi-Fi": ["10.0.0.53"]])
        #expect(custom.active == nil)
        #expect(!custom.needsCleanup)
        #expect(!DNSConfiguration(services: [], servers: [:]).needsCleanup)
    }
}
