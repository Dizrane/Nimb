import Foundation

/// Where a provider's DNS servers stand; the planet lights this region up.
enum Region: String {
    case ru, eu, us

    /// Centre of the globe's view, in degrees.
    var view: (lon: Double, lat: Double) {
        switch self {
        case .ru: return (74, 52)
        case .eu: return (14, 50)
        case .us: return (-98, 40)
        }
    }

    /// The city where the signal lands (Moscow, Frankfurt, Buffalo).
    var landing: (lon: Double, lat: Double) {
        switch self {
        case .ru: return (37.6, 55.75)
        case .eu: return (8.7, 50.1)
        case .us: return (-78.9, 42.9)
        }
    }
}

/// A public Smart DNS provider the app can switch the Mac to.
struct DNSProvider: Identifiable, Hashable {
    let id: String
    let name: String
    let addresses: [String]
    let region: Region
    /// Earlier settings, including retired servers: recognise them so disabling or uninstalling can still restore DNS.
    var legacy: [[String]] = []
    /// Kept for cleanup of existing settings, but no longer offered for AI access.
    var retired = false

    /// Whether `servers` are this provider's: the current addresses or an earlier set.
    func matches(_ servers: [String]) -> Bool { servers == addresses || legacy.contains(servers) }

    /// Every address Nimb has ever set for this provider.
    var allAddresses: [String] { addresses + legacy.flatMap { $0 } }

    /// The first provider is the default one.
    static let all: [DNSProvider] = [
        DNSProvider(id: "geohide-eu", name: "GeoHide (EU)", addresses: ["143.20.64.192", "5.175.161.40"], region: .eu,
                    legacy: [["143.20.64.192", "45.13.237.213"]]),
        DNSProvider(id: "comss", name: "Comss.one", addresses: ["94.250.253.55", "212.109.195.93"], region: .ru,
                    legacy: [["83.220.169.155", "212.109.195.93"]], retired: true),
        DNSProvider(id: "magicdns", name: "MagicDNS", addresses: ["217.144.190.216", "109.120.187.249"], region: .eu,
                    legacy: [["109.120.132.43", "94.249.177.102"]]),
        DNSProvider(id: "malwlink", name: "malw.link", addresses: ["179.254.166.171", "164.5.224.81"], region: .eu),
        DNSProvider(id: "geohide", name: "GeoHide (RU)", addresses: ["37.230.192.51", "193.233.112.67"], region: .ru,
                    legacy: [["159.194.200.33", "193.233.112.67"]]),
        DNSProvider(id: "geohide-us", name: "GeoHide (US)", addresses: ["192.255.159.241", "192.255.159.240"], region: .us),
    ]

    static let available: [DNSProvider] = all.filter { !$0.retired }

    /// The order of the selectable providers on the page: by name.
    static let byName: [DNSProvider] = available.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}
