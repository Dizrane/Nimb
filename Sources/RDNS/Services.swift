import Foundation

/// A public Smart DNS provider the app can switch the Mac to.
struct DNSProvider: Identifiable, Hashable {
    let id: String
    let name: String
    let addresses: [String]
    let note: String

    static let all: [DNSProvider] = [
        DNSProvider(
            id: "comss",
            name: "Comss.one",
            addresses: ["83.220.169.155", "212.109.195.93"],
            note: "ChatGPT, Claude, Gemini, ElevenLabs"
        ),
        DNSProvider(
            id: "geohide",
            name: "GeoHide",
            addresses: ["159.194.200.33", "193.233.112.67"],
            note: "Gemini, ElevenLabs; ChatGPT и Claude — через раз"
        ),
        DNSProvider(
            id: "geohide-eu",
            name: "GeoHide EU",
            addresses: ["143.20.64.192", "45.13.237.213"],
            note: "ChatGPT, Claude, Gemini, ElevenLabs"
        ),
    ]
}
