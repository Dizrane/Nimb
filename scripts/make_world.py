"""Builds a compact world.json (land rings + highlightable regions) from Natural Earth GeoJSON.

usage: python3 -I make_world.py <land.geojson> <countries.geojson> <out.json>
Output: {"land": [ring, ...], "regions": {"ru": [ring, ...], "eu": [...], "us": [...]}}
Every ring is a flat list [lon0, lat0, lon1, lat1, ...] rounded to 0.1 degree; holes are dropped.
Regions: ru = Russia, eu = the European continent except Russia (no overseas territories), us = United States.
"""
import json
import sys


def rings_of(geometry):
    if geometry["type"] == "Polygon":
        polygons = [geometry["coordinates"]]
    elif geometry["type"] == "MultiPolygon":
        polygons = geometry["coordinates"]
    else:
        return []
    return [polygon[0] for polygon in polygons]  # exterior ring only


def flatten(ring):
    flat, last = [], None
    for lon, lat in ring:
        point = (round(lon, 1), round(lat, 1))
        if point != last:  # drop points that collapse after rounding
            flat.extend(point)
            last = point
    return flat


def rings_for(features):
    return [flatten(r) for feature in features for r in rings_of(feature["geometry"])]


def in_europe(ring):
    """Keeps the mainland and nearby islands: drops overseas territories (French Guiana) and Svalbard."""
    lons, lats = ring[0::2], ring[1::2]
    return -25 <= sum(lons) / len(lons) <= 45 and 34 <= sum(lats) / len(lats) <= 72


def main(land_path, countries_path, out_path):
    with open(land_path, encoding="utf-8") as f:
        land = json.load(f)
    with open(countries_path, encoding="utf-8") as f:
        countries = json.load(f)["features"]

    def admin(name):
        found = [c for c in countries if c["properties"].get("ADMIN") == name]
        if len(found) != 1:
            sys.exit("expected exactly one %s feature, found %d" % (name, len(found)))
        return found

    regions = {
        "ru": rings_for(admin("Russia")),
        "us": rings_for(admin("United States of America")),
        "eu": [r for r in rings_for(c for c in countries
                                    if c["properties"].get("CONTINENT") == "Europe" and c["properties"].get("ADMIN") != "Russia")
               if in_europe(r)],
    }

    with open(out_path, "w", encoding="utf-8") as f:
        json.dump({"land": rings_for(land["features"]), "regions": regions}, f, separators=(",", ":"))

    points = lambda rings: sum(len(r) // 2 for r in rings)
    print("land: %d points" % points(rings_for(land["features"])))
    for key, rings in regions.items():
        print("%s: %d rings, %d points" % (key, len(rings), points(rings)))


if __name__ == "__main__":
    main(*sys.argv[1:4])
