import Foundation

/// What is really set on the connections. A partially applied provider still needs to be turned off, even though no one provider is active
/// everywhere. Connections with somebody else's DNS must not be included in that cleanup.
struct DNSConfiguration {
    let servers: [String: [String]]
    let active: DNSProvider?
    let managedServices: [String]
    let hasLegacyHosts: Bool

    private let pendingRestoration: Bool
    var needsCleanup: Bool { hasLegacyHosts || !managedServices.isEmpty || pendingRestoration }

    init(services: [String], servers: [String: [String]], pendingRestoration: Bool = false, restoredServices: Set<String> = [], hasLegacyHosts: Bool = false) {
        self.servers = servers
        self.hasLegacyHosts = hasLegacyHosts
        self.pendingRestoration = pendingRestoration
        managedServices = services.filter { service in
            !restoredServices.contains(service) && DNSProvider.all.contains { $0.matches(servers[service] ?? []) }
        }
        active = services.isEmpty || !restoredServices.isDisjoint(with: services) ? nil : DNSProvider.all.first { provider in
            services.allSatisfy { provider.matches(servers[$0] ?? []) }
        }
    }
}
