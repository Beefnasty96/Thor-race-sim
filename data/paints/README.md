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
