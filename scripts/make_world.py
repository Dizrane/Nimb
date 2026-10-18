"""Builds a compact world.json (land rings + Russia rings) from Natural Earth GeoJSON.

usage: python3 -I convert.py <land.geojson> <countries.geojson> <out.json>
Every ring is a flat list [lon0, lat0, lon1, lat1, ...] rounded to 0.1 degree; holes are dropped.
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


def main(land_path, countries_path, out_path):
    with open(land_path, encoding="utf-8") as f:
        land = json.load(f)
    with open(countries_path, encoding="utf-8") as f:
        countries = json.load(f)

    land_rings = [flatten(r) for feature in land["features"] for r in rings_of(feature["geometry"])]
    russia = [feature for feature in countries["features"] if feature["properties"].get("ADMIN") == "Russia"]
    if len(russia) != 1:
        sys.exit("expected exactly one Russia feature, found %d" % len(russia))
    russia_rings = [flatten(r) for r in rings_of(russia[0]["geometry"])]

    with open(out_path, "w", encoding="utf-8") as f:
        json.dump({"land": land_rings, "russia": russia_rings}, f, separators=(",", ":"))

    points = lambda rings: sum(len(r) // 2 for r in rings)
    print("land: %d rings, %d points" % (len(land_rings), points(land_rings)))
    print("russia: %d rings, %d points" % (len(russia_rings), points(russia_rings)))


if __name__ == "__main__":
    main(*sys.argv[1:4])
