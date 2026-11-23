# Factory paint database

One JSON file per make, built by `tools/paints/build_paints.py` from the
researched batches in `tools/paints/batch*.txt` (one line per color:
make | name | codes | years | models | source URL).

- **Names and codes** are as printed in period sources: sales brochures and
  ads, manufacturer press releases (modern colors) and paint-code references
  for the codes (GM two-digit RPO / WA number, Ford two-letter / M number,
  Chrysler two- and three-letter codes). Every color lists its sources.
- **Years** are only the model years a source shows. `PaintDB.paints_for()`
  uses the exact year first and falls back to the nearest years within 3,
  marking those `near_year`.
- **Models**: a model name, `all`, or a family (`trucks`, `SUVs`, `cars`)
  that `PaintDB.fits_model()` maps to model names.
- **Colors are estimated** from the names (`rgb_estimated: true`), with
  hand-set values for well-known colors. They are close, not exact: Car
  Porter's "Add a paint from your photo" records the exact color of a real
  car. Finish (solid / metallic / pearl / tricoat / tintcoat) comes from the
  name and sets the game's metallic level.

Coverage grows in batches: GM, Ford / Chrysler / Jeep and the Japanese makes
for the 1990s–2000s, then 2015+ for all major makes.

- Batch 1: GM / Ford / Dodge 1990s–2000s (111 colors).
- Batch 2: Toyota, Honda, Nissan, Mazda, Subaru, Mitsubishi 1990s–2000s;
  more Ford, Dodge and Jeep; first 2019–2020 colors (Supra, Camaro, Mustang,
  Civic, WRX, 370Z, Challenger, Wrangler). Database total after batch 2: 386 colors.
- Batch 3: more model years (2005 Tahoe, 2010 Camaro, 2015 Mustang, 1994 and
  2006 Civic, 2008 Lancer) and 2015+ trucks and SUVs (F-Series, Ram, Tacoma,
  4Runner, Frontier, CR-V, Outback, Camry, WRX). Database total: 460 colors.
- 2019+ GM model pages on the source site list GM's internal paint names and
  colors pooled from other models, so they're left out until a GM source
  (order guide or press release) can be checked.
