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

    /// The first provider is the default one.
    static let all: [DNSProvider] = [
        DNSProvider(id: "geohide-eu", name: "GeoHide (EU)", addresses: ["143.20.64.192", "45.13.237.213"], region: .eu),
        DNSProvider(id: "comss", name: "Comss.one", addresses: ["83.220.169.155", "212.109.195.93"], region: .ru),
        DNSProvider(id: "geohide", name: "GeoHide (RU)", addresses: ["159.194.200.33", "193.233.112.67"], region: .ru),
        DNSProvider(id: "geohide-us", name: "GeoHide (US)", addresses: ["192.255.159.241", "192.255.159.240"], region: .us),
    ]
}
