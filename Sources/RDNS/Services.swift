import Foundation

/// A public Smart DNS provider the app can switch the Mac to.
struct DNSProvider: Identifiable, Hashable {
    let id: String
    let name: String
    let addresses: [String]

    /// The first provider is the default one.
    static let all: [DNSProvider] = [
        DNSProvider(id: "geohide-eu", name: "GeoHide EU", addresses: ["143.20.64.192", "45.13.237.213"]),
        DNSProvider(id: "comss", name: "Comss.one", addresses: ["83.220.169.155", "212.109.195.93"]),
        DNSProvider(id: "geohide", name: "GeoHide", addresses: ["159.194.200.33", "193.233.112.67"]),
        DNSProvider(id: "geohide-us", name: "GeoHide US", addresses: ["192.255.159.241", "192.255.159.240"]),
    ]
}
