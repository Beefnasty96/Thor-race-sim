#!/usr/bin/env python3
"""
Build Car Porter's vehicle dimension database from Transport Canada's
Canadian Vehicle Specifications (CVS), served by NHTSA's vPIC API.
Licence: Open Government Licence - Canada (attribution required).

  python3 fetch_cvs.py probe            # dump raw responses for a sample
  python3 fetch_cvs.py full OUT.json    # every make, 1971..current year

Output rows (metres / kg): year, make, model, length, width, height,
wheelbase, track front, track rear, front overhang, rear overhang,
curb weight, front weight %.
"""
import json, sys, time, urllib.parse, urllib.request, datetime

API = "https://vpic.nhtsa.dot.gov/api/vehicles/GetCanadianVehicleSpecifications/"
MAKES = """Acura, Alfa Romeo, AMC, Aston Martin, Audi, Bentley, BMW, Buick, Cadillac, Chevrolet,
Chrysler, Daewoo, Datsun, Dodge, Eagle, Ferrari, Fiat, Fisker, Ford, Genesis, Geo, GMC, Honda, Hummer,
Hyundai, Infiniti, Isuzu, Jaguar, Jeep, Kia, Lada, Lamborghini, Land Rover, Lexus, Lincoln, Lotus,
Lucid, Maserati, Maybach, Mazda, McLaren, Mercedes-Benz, Mercury, Merkur, MG, Mini, Mitsubishi, Nissan,
Oldsmobile, Peugeot, Plymouth, Polestar, Pontiac, Porsche, Ram, Renault, Rivian, Rolls-Royce, Saab,
Saturn, Scion, Smart, Sterling, Subaru, Suzuki, Tesla, Toyota, Triumph, VinFast, Volkswagen, Volvo,
Yugo, Asuna, Passport, Pontiac""".replace("\n", " ")
MAKES = sorted({m.strip() for m in MAKES.split(",") if m.strip()})


def get(params):
    url = API + "?" + urllib.parse.urlencode({**params, "format": "json"})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(url, timeout=60) as r:
                return json.load(r)
        except Exception as e:  # rate control / transient errors
            time.sleep(2 + attempt * 3)
            last = e
    raise last


def specs_of(result):
    """Result -> {NAME: value}; handles a Specs list or flat keys."""
    if isinstance(result, dict) and "Specs" in result:
        return {str(s.get("Name", "")).upper(): s.get("Value") for s in result["Specs"]}
    return {str(k).upper(): v for k, v in result.items()}


def num(v):
    try:
        return float(str(v).replace(",", "").strip())
    except Exception:
        return None


def row(year, s):
    cm = lambda k: (num(s.get(k)) or 0) / 100.0
    L, W, H, WB = cm("OL"), cm("OW"), cm("OH"), cm("WB")
    if min(L, W, H, WB) <= 0.3 or L > 25 or WB >= L:
        return None
    wd = str(s.get("WD") or "")
    front_pct = num(wd.split("/")[0]) if "/" in wd else num(wd)
    return [year, str(s.get("MAKE", "")).strip().title(), str(s.get("MODEL", "")).strip(),
            round(L, 3), round(W, 3), round(H, 3), round(WB, 3),
            round(cm("TWF"), 3), round(cm("TWR"), 3), round(cm("F"), 3), round(cm("G"), 3),
            num(s.get("CW")), front_pct]


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "probe"
    if mode == "probe":
        out = {}
        for p in [{"year": 1999, "make": "Chevrolet"}, {"year": 1999}, {"year": 2015, "make": "Mazda"}]:
            try:
                out[json.dumps(p)] = get(p)
            except Exception as e:
                out[json.dumps(p)] = {"error": str(e)}
        json.dump(out, open("probe.json", "w"), indent=1)
        for k, v in out.items():
            res = v.get("Results", []) if isinstance(v, dict) else []
            print(k, "count", v.get("Count") if isinstance(v, dict) else "?", "results", len(res))
            if res:
                print(json.dumps(res[0])[:1500])
        return
    out_path = sys.argv[2]
    last_year = datetime.date.today().year + 1
    rows, seen = [], set()
    for year in range(1971, last_year + 1):
        n0 = len(rows)
        for make in MAKES:
            try:
                data = get({"year": year, "make": make, "units": "Metric"})
            except Exception as e:
                print(f"{year} {make}: failed {e}", flush=True)
                continue
            for r in data.get("Results", []) or []:
                rr = row(year, specs_of(r))
                if rr:
                    key = tuple(rr[:3])
                    if key not in seen:
                        seen.add(key)
                        rows.append(rr)
            time.sleep(0.25)
        print(f"{year}: {len(rows) - n0} models", flush=True)
    db = {
        "source": "Transport Canada, Canadian Vehicle Specifications (CVS), via NHTSA vPIC API",
        "licence": "Contains information licensed under the Open Government Licence - Canada",
        "built": datetime.date.today().isoformat(),
        "fields": ["year", "make", "model", "length_m", "width_m", "height_m", "wheelbase_m",
                   "track_front_m", "track_rear_m", "front_overhang_m", "rear_overhang_m",
                   "curb_kg", "front_weight_pct"],
        "rows": rows,
    }
    with open(out_path, "w") as f:
        json.dump(db, f, separators=(",", ":"))
    print("total", len(rows))


if __name__ == "__main__":
    main()
