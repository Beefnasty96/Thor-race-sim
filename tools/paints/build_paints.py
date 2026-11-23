#!/usr/bin/env python3
"""Build data/paints/<make>.json from the researched batches in tools/paints/.

Each batch line: make | name | codes | years | models | source URL
  years: "1999", "2003-2007" or "1999,2004" (only model years a source shows)
Colors with the same make, name and primary code are merged (years and
sources combined). RGB is ESTIMATED from the color name (with hand-set
values for well-known colors) and marked "rgb_estimated": true; the finish
(solid / metallic / pearl / tricoat / tintcoat) comes from the name.
"""
import glob, json, os, re

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "..", "data", "paints")

KNOWN = {  # name (lower) -> rgb, for well-known factory colors
    "victory red": (0.62, 0.078, 0.094), "hugger orange": (0.93, 0.36, 0.05),
    "torch red": (0.78, 0.05, 0.04), "oxford white": (0.93, 0.93, 0.91),
    "screaming yellow": (0.97, 0.8, 0.05), "vista blue metallic": (0.16, 0.36, 0.63),
    "flame red": (0.8, 0.06, 0.05), "hydro blue pearl": (0.05, 0.36, 0.62),
    "summit white": (0.933, 0.933, 0.918), "arctic white": (0.94, 0.94, 0.93),
    "zinc yellow": (0.93, 0.78, 0.1), "electric green metallic": (0.1, 0.55, 0.3),
    "sebring silver metallic": (0.7, 0.71, 0.72), "wheatland yellow": (0.92, 0.75, 0.15),
    "lime gold metallic": (0.62, 0.66, 0.25), "colorado red": (0.66, 0.08, 0.08),
    "vermillion": (0.75, 0.13, 0.08), "heritage blue": (0.22, 0.38, 0.55),
    "bronze oxide": (0.45, 0.33, 0.2), "wave maker": (0.15, 0.45, 0.58),
    "yellow": (0.95, 0.8, 0.1), "white": (0.93, 0.93, 0.92), "black": (0.035, 0.035, 0.04),
}
BASES = [  # first match wins (longest / most specific first)
    ("gunmetal", (0.3, 0.31, 0.33)), ("charcoal", (0.2, 0.21, 0.22)), ("graphite", (0.25, 0.26, 0.28)),
    ("pewter", (0.5, 0.5, 0.48)), ("silver", (0.66, 0.67, 0.69)), ("argent", (0.6, 0.61, 0.62)),
    ("graystone", (0.45, 0.45, 0.43)), ("gray", (0.42, 0.43, 0.45)), ("grey", (0.42, 0.43, 0.45)),
    ("stealth", (0.3, 0.31, 0.32)), ("mineral", (0.4, 0.41, 0.42)),
    ("white", (0.92, 0.92, 0.9)), ("black", (0.035, 0.035, 0.04)), ("ebony", (0.035, 0.035, 0.04)),
    ("vermillion", (0.75, 0.13, 0.08)), ("toreador", (0.42, 0.05, 0.07)), ("garnet", (0.36, 0.05, 0.08)),
    ("cherry", (0.45, 0.04, 0.07)), ("crimson", (0.55, 0.05, 0.08)), ("maroon", (0.33, 0.05, 0.08)),
    ("redfire", (0.6, 0.08, 0.06)), ("red", (0.62, 0.07, 0.07)),
    ("orange", (0.9, 0.38, 0.06)), ("yellow", (0.94, 0.78, 0.1)), ("lime", (0.55, 0.7, 0.15)),
    ("gold", (0.68, 0.56, 0.32)), ("khaki", (0.6, 0.55, 0.4)), ("tan", (0.66, 0.58, 0.44)),
    ("beige", (0.7, 0.63, 0.5)), ("sand", (0.72, 0.66, 0.52)), ("cashmere", (0.66, 0.6, 0.5)),
    ("driftwood", (0.6, 0.53, 0.42)), ("autumnwood", (0.5, 0.4, 0.3)), ("bronze", (0.45, 0.32, 0.2)),
    ("copper", (0.5, 0.27, 0.15)), ("carmel", (0.55, 0.38, 0.22)), ("caramel", (0.55, 0.38, 0.22)),
    ("brown", (0.35, 0.22, 0.13)), ("otter", (0.32, 0.29, 0.26)), ("taupe", (0.48, 0.42, 0.37)),
    ("teal", (0.05, 0.38, 0.38)), ("tourmaline", (0.06, 0.3, 0.32)), ("emerald", (0.05, 0.3, 0.18)),
    ("jewel", (0.3, 0.06, 0.1)), ("green", (0.12, 0.33, 0.2)), ("indigo", (0.1, 0.13, 0.3)),
    ("navy", (0.07, 0.1, 0.25)), ("ming", (0.08, 0.12, 0.3)), ("ink", (0.12, 0.15, 0.2)),
    ("blue", (0.13, 0.25, 0.52)), ("thistle", (0.42, 0.32, 0.45)), ("purple", (0.33, 0.18, 0.4)),
]
MODS = {"dark": ("mul", 0.55), "deep": ("mul", 0.6), "light": ("mix", 0.35), "pale": ("mix", 0.5),
        "pastel": ("mix", 0.5), "medium": ("mul", 0.85), "bright": ("sat", 1.2)}

def finish_of(name):
    n = name.lower()
    if "tricoat" in n or "tri-coat" in n:
        return "tricoat"
    if "tint" in n:
        return "tintcoat"
    if "pearl" in n or " pri " in f" {n} ":
        return "pearl"
    if "metallic" in n or "mist" in n or "effect" in n or "sparkle" in n:
        return "metallic"
    return "solid"

METAL = {"solid": 0.05, "metallic": 0.6, "pearl": 0.45, "tricoat": 0.5, "tintcoat": 0.55}

def estimate_rgb(name):
    n = name.lower()
    if n in KNOWN:
        return KNOWN[n]
    words = re.findall(r"[a-z]+", n)
    base = None
    for key, rgb in BASES:
        if any(w.startswith(key) for w in words):
            base = rgb
            break
    if base is None:
        base = (0.5, 0.5, 0.5)
    r, g, b = base
    for w in words:
        if w in MODS:
            kind, k = MODS[w]
            if kind == "mul":
                r, g, b = r * k, g * k, b * k
            elif kind == "mix":
                r, g, b = r + (1 - r) * k, g + (1 - g) * k, b + (1 - b) * k
            else:
                m = (r + g + b) / 3
                r, g, b = [min(1.0, m + (c - m) * k) for c in (r, g, b)]
    return (round(r, 3), round(g, 3), round(b, 3))

def years_of(s):
    out = set()
    for part in s.replace(" ", "").split(","):
        if not part:
            continue
        if "-" in part:
            a, b = part.split("-")
            out.update(range(int(a), int(b) + 1))
        else:
            out.add(int(part))
    return out

def main():
    paints = {}
    for path in sorted(glob.glob(os.path.join(HERE, "batch*.txt"))):
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            make, name, codes, years, models, src = [x.strip() for x in line.split("|")]
            code = codes.split("/")[0] if codes else ""
            key = (make, name.lower(), code)
            e = paints.setdefault(key, {"name": name, "codes": codes, "years": set(), "models": set(), "sources": []})
            e["years"] |= years_of(years)
            e["models"] |= {m.strip() for m in models.split(",") if m.strip()}
            if src not in e["sources"]:
                e["sources"].append(src)
    by_make = {}
    for (make, _, _), e in paints.items():
        fin = finish_of(e["name"])
        by_make.setdefault(make, []).append({
            "name": e["name"], "codes": e["codes"], "years": sorted(e["years"]),
            "models": sorted(e["models"]) or ["all"], "finish": fin, "metallic": METAL[fin],
            "rgb": list(estimate_rgb(e["name"])), "rgb_estimated": True, "sources": e["sources"],
        })
    os.makedirs(OUT, exist_ok=True)
    total = 0
    for make, lst in sorted(by_make.items()):
        lst.sort(key=lambda p: (p["years"][0] if p["years"] else 0, p["name"]))
        with open(os.path.join(OUT, make.lower().replace(" ", "_") + ".json"), "w", encoding="utf-8") as f:
            json.dump({"make": make, "paints": lst}, f, indent=1)
        total += len(lst)
        print(f"{make}: {len(lst)} colors")
    print(f"total {total}")

if __name__ == "__main__":
    main()
