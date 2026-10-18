import Foundation

/// Coastlines and the outlines of the regions the planet can light up, from Natural Earth (public domain), 110m scale.
/// Each ring is a flat list [lon0, lat0, lon1, lat1, ...] in degrees; see Resources/world.json.
struct WorldMap {
    let land: [[Double]]
    let regions: [String: [[Double]]]

    func rings(for region: Region) -> [[Double]] { regions[region.rawValue] ?? [] }

    static let shared = load()

    private struct Raw: Decodable {
        let land: [[Double]]
        let regions: [String: [[Double]]]
    }

    private static func load() -> WorldMap {
        guard let url = Bundle.main.url(forResource: "world", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode(Raw.self, from: data) else {
            return WorldMap(land: [], regions: [:])
        }
        return WorldMap(land: raw.land, regions: raw.regions)
    }
}

/// Orthographic projection: the globe as seen from above (lon0, lat0), on the unit disc.
struct Orthographic {
    let sinLat0: Double
    let cosLat0: Double
    let lon0: Double

    init(lon0: Double, lat0: Double) {
        self.lon0 = lon0 * .pi / 180
        sinLat0 = sin(lat0 * .pi / 180)
        cosLat0 = cos(lat0 * .pi / 180)
    }

    /// x to the right, y up. Points on the far side are pushed to the rim and flagged invisible.
    func project(lon: Double, lat: Double) -> (x: Double, y: Double, visible: Bool) {
        let phi = lat * .pi / 180
        let dl = lon * .pi / 180 - lon0
        let cosC = sinLat0 * sin(phi) + cosLat0 * cos(phi) * cos(dl)
        var x = cos(phi) * sin(dl)
        var y = cosLat0 * sin(phi) - sinLat0 * cos(phi) * cos(dl)
        if cosC < 0 {
            let length = max((x * x + y * y).squareRoot(), 1e-9)
            x /= length
            y /= length
        }
        return (x, y, cosC >= 0)
    }
}
