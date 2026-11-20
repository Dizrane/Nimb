import Testing
@testable import Nimb

@Suite struct ProbeFailureTests {
    @Test func DNSFailuresAreSeparateFromHTTPSFailuresAndServiceRefusals() {
        let target = ProbeTarget.all[0]
        let report = ProviderReport(provider: DNSProvider.available[0], samples: [
            ProbeSample(target: target, address: nil, outcome: .failed),
            ProbeSample(target: target, address: "203.0.113.1", outcome: .failed, failureReason: "TLS: ошибка проверки сертификата"),
            ProbeSample(target: target, address: "203.0.113.2", outcome: .blocked("403: доступ закрыт")),
        ])
        #expect(report.failures.count == 2)
        #expect(report.failures.contains { $0.hasPrefix("DNS:") })
        #expect(report.failures.contains { $0.hasPrefix("TLS:") })
        #expect(!report.failures.contains { $0.contains("403") })
        #expect(report.refusals.count == 1)
        #expect(report.details.contains("DNS:") && report.details.contains("TLS:"))
    }

    @Test(arguments: [(Int32(7), 0, "HTTPS:"), (28, 0, "HTTPS:"), (35, 0, "TLS:"), (60, 0, "TLS:"), (56, 0, "HTTPS:"), (0, 503, "HTTP: ответ 503")])
    func failedRequestsKeepTheirActualStage(input: (Int32, Int, String)) {
        #expect(ServiceProbe.failureReason(exitStatus: input.0, httpCode: input.1).hasPrefix(input.2))
    }
}
