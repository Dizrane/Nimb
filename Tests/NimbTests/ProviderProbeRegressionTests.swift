import Foundation
import Testing
@testable import Nimb

@Suite struct ProviderProbeRegressionTests {
    @Test func aRetiredProviderCanBeDisabledButCannotBeEnabledAgain() throws {
        let comss = try #require(DNSProvider.all.first { $0.id == "comss" })
        #expect(comss.retired)
        #expect(!DNSProvider.available.contains(comss))
        let state = DNSConfiguration(services: ["Wi-Fi"], servers: ["Wi-Fi": comss.addresses])
        #expect(state.active == comss && state.needsCleanup)
        #expect(throws: DNSError.self) { try DNSManager.apply(comss, to: []) }
    }

    @Test(arguments: [ProbeTarget.Kind.site, .api])
    func aLargeHealthyPoolCannotHideTheOtherTargetFailing(failing: ProbeTarget.Kind) throws {
        let targets = ProbeTarget.all.filter { $0.service == "ChatGPT" }
        var samples: [ProbeSample] = []
        for target in targets {
            if target.kind == failing {
                samples.append(ProbeSample(target: target, address: nil, outcome: .failed))
            } else {
                for n in 1...7 { samples.append(ProbeSample(target: target, address: "192.0.2.\(n)", outcome: .ok(0.2))) }
            }
        }
        let report = ProviderReport(provider: DNSProvider.all[0], samples: samples)
        let result = try #require(report.services.first { $0.name == "ChatGPT" })
        #expect(result.answered == 7 && result.total == 8)
        #expect(result.status == .unstable)
        #expect(report.workingCount == 0)
    }

    @Test func aMissingWebsiteDoesNotCountLikeAnUnauthenticatedAPI() throws {
        let site = try #require(ProbeTarget.all.first { $0.host == "chatgpt.com" })
        let api = try #require(ProbeTarget.all.first { $0.host == "api.openai.com" })
        #expect(ServiceProbe.classify(site, code: 404, seconds: 0.2, bodySize: 10, headers: [:], body: "not found") == .failed)
        #expect(ServiceProbe.classify(api, code: 401, seconds: 0.2, bodySize: 10, headers: [:], body: "no key") == .ok(0.2))
    }

    @Test func retiredDNSAreStillRecognisedAndCanBeCleanedUp() throws {
        let retired = [
            ("magicdns", ["109.120.132.43", "94.249.177.102"]),
            ("geohide-eu", ["143.20.64.192", "45.13.237.213"]),
            ("geohide", ["159.194.200.33", "193.233.112.67"]),
        ]
        for (id, addresses) in retired {
            let provider = try #require(DNSProvider.all.first { $0.id == id })
            #expect(provider.addresses != addresses)
            #expect(provider.matches(addresses))
            let current = ["wifi": DNSServiceSettings(name: "Wi-Fi", servers: addresses)]
            let plan = DNSBackup().restoration(current: current, legacyServices: ["Wi-Fi"])
            #expect(plan["wifi"] == [])
            #expect(DNSConfiguration(services: ["Wi-Fi"], servers: ["Wi-Fi": addresses]).needsCleanup)
        }
    }
}
