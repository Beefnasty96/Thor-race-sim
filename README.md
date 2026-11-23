# Racing Sim (working title)

A realistic racing simulator for the **AYN Thor** (top screen only), built in **Godot 4.5**.
Real cars modelled from real specifications, with a physics model covering tire
grip, heat and wear, engine heat and wear, suspension, and a real driveline.
The visual target is the *Gran Turismo 4* era: clean shapes, glossy paint, soft
bloom and haze, running at a steady frame rate on a handheld.

**Current car:** 1999 Chevrolet Tahoe (GMT400, the last year of that body). 4-door or 2-door, 2WD or 4WD,
switchable in the Vehicle Editor.

**Locations** (Free Practice → Choose Location):
- **Proving Ground** (default): drag strip with ¼-mile markings and braking
  zone, 200 ft skidpad, slalom, handling course with elevation, 10/20/30%
  grade hill (try 2H vs 4L), off-road loop with whoops and washboard.
  Automatic test timing: 0–60, ¼ mile + trap speed, 60–0, skidpad g, top speed.
- **Ridgeview Circuit**: a fictional 2.15 km circuit with elevation, curbs,
  gravel traps, barriers and lap timing.

### Maps
Maps are data files in `data/maps/*.json`: roads (polylines with elevation,
width, surface, bumps, markings), paved areas, buildings, props and signs. The
format is designed so real towns can be generated from OpenStreetMap data plus
elevation. That's the plan for town maps.

---

## Controls (XInput / Xbox layout)

The game uses the XInput controller standard, so the AYN Thor's built-in
controls (set to Xbox layout in the Thor's controller settings), an Xbox
controller, or any XInput-compatible pad all map the same way.

| XInput | Action |
|---|---|
| RT (analog) | Throttle |
| LT (analog) | Brake. Hold at a standstill to select Reverse, hold again for Drive |
| Left stick | Steer |
| Right stick | Look around |
| RB / LB | Shift up / down (manual mode) |
| A | Handbrake · menu select |
| B | Menu back |
| X | Look back |
| Y | Change camera: chase, near chase, **driver (first person)**, hood, bumper |
| D-pad ↑ | Transfer case 2H → 4H → 4L (4L needs the truck stopped) |
| D-pad ↓ | Toggle automatic / manual |
| Back (View) | Telemetry panel on/off |
| Start (Menu) | Pause |
| RS click | Reset onto the road |

**Rumble** uses XInput's two motors: the low-frequency motor for impacts
(curbs, whoops, bottoming out, collisions, rev limiter) and the high-frequency
motor for tire scrub past the grip limit, wheelspin, ABS pulsing and rough
surfaces. **Settings** has stick and trigger deadzones (XInput defaults are
24% / 12%; the Thor's hall-effect sticks work well around 10% / 6%), rumble
strength, and a live readout of the connected controller.

Keyboard (desktop testing): W/S throttle/brake, A/D steer, E/Q shift, Space
handbrake, C camera, T telemetry, 4 transfer case, M trans mode, R reset, Esc pause.

---

## The Tahoe model

The Tahoe body (GMT400, shared by 1995-99 trucks) is converted from a CC-BY-4.0 model (see Credits) by
`tools/blender/convert_tahoe_glb.py`. The script strips the police equipment,
livery and badges, applies the factory two-tone paint layout (body colour over a
lower colour with a dark stripe band), reduces it to about 6,800 triangles, and
adds a semi-accurate 1995-99 GMT400 interior: dash with a hooded, green-lit
cluster (working speedometer and tach), centre stack, steering column, airbag
steering wheel that turns with the front wheels, seats and headliner. Paint
combinations are chosen in the Vehicle Editor.

## Car Porter (companion app)

**Car Porter** is a second app built from the same Godot project, for building
new cars on a phone (target: Samsung Galaxy S24 FE). It shares the game's car
files and physics, so a car built in Car Porter drives the same in the game.
The export preset *Car Porter* sets the `porter` feature tag, which switches
the start scene to `scenes/porter.tscn` and the package to
`com.racingsim.carporter`, so both apps install side by side.

**Production car database**: *Find a production car* on the projects screen:
pick year → make → model (with search) and the project starts with that
car's real length, width, height, wheelbase, front/rear track and overhangs.
Data: Transport Canada's Canadian Vehicle Specifications (model years 1971 on),
fetched from NHTSA's vPIC API by `tools/vehicle_db/fetch_cvs.py` (GitHub
workflow *Build vehicle dimension database*) into
`data/vehicle_db/vehicle_dimensions.json`. Contains information licensed under
the Open Government Licence – Canada.

**Tires**: every new car asks for front and rear tire size (as on the door
sticker or sidewall: P245/75R16, LT265/75R16, 245/40ZR18 97W, 31x10.50R15,
7.75-15) and cold PSI. The size sets the wheel radius per axle (staggered
setups supported) in the photo outline, the 3D check and the modeler; edit
later under the dimensions panel (*Apply tires*).

**v0.1: reference photos**
- Start a project blank or with real dimensions copied from a car in the game.
- Load side, front, rear and top photos (Android's photo picker).
- Line each photo up with a true-scale outline: **Align: tap 2 points** (front
  and rear wheel centers on the side view, tire contact points on front/rear,
  bumper ends on top), or drag/pinch/twist, with fine-adjust buttons.
- Edit dimensions in inches or millimeters; the outline updates live.
- **3D check** shows every photo on its own side of a true-size box.

**v0.2: body modeling** (*Next: Model ▶* in the photo editor)
- Start from a template (SUV, pickup, sedan, coupe, hatchback, plain box)
  scaled to the car's real length, width, height, wheelbase and overhang.
- Model over the aligned photos in Side / Front / Top (orthographic, body
  see-through) or orbit in 3D. You edit the left half; the right half mirrors
  it. Centerline points (green) stay on the centerline.
- Tap points or faces to select (tap again to reach a hidden one), drag to
  move, with ↔ / ↕ locks and 1 cm / 1 mm nudge buttons. Extrude, loop cut,
  delete, undo/redo.
- **Wheel arches**: *Draw an arch* — in the side view, tap along the wheel
  well on the photo from one end to the other (live outline; Finish / Undo
  point / Cancel); the ends drop onto the body's bottom edge and the points
  between become the arch, any shape (round, squared, flared), one arch at a
  time. *Auto arches (both wheels)* cuts round arches sized from the tires
  (radius × 1.12 + 2 cm). Concave panels are ear-clipped so they render
  cleanly.
- **Wheel wells** are built automatically behind every arch you cut: a liner
  following your arch line inward, and an inner wall just inboard of the
  tire (track ÷ 2 − tire width ÷ 2, plus 3 cm, plus 5 cm more at the front
  for steering). The underbody goes back flat with the wheel opening left
  open below; every edge is shared, so no cracks. Black trim by default.
  *Build wheel wells* adds them behind arches cut before this existed.
- **Add point**: tap an edge to add a connected point on it, or empty space
  for a free point (placed at the depth of the nearest geometry; tap an
  existing point to include it). **Connect**: 2 points on one face split it
  with a new edge; 3+ points make a new face turned toward you. **Merge**
  welds the selected points into one. Flat-shaded like GT1, with a live triangle count against
  a 1,500-triangle budget. Saved as `body.json` in the project.

**v0.3: paint** (*Paint* switch in the modeler)
- Tap faces to mark them as body paint, second color, glass, headlight,
  taillight, chrome, black trim or grille; *Fill* paints a connected area.
- New templates start pre-painted (windows glass, grille, black underbody).
- Parts use the material names the game already understands (Paint, Lower,
  Glass, Taillight, plus Headlight / Chrome / Trim / Grille), so export maps
  straight onto CarModel. Preview in the source car's factory colors.

**Wheels** (*Wheels* switch in the modeler)
- The wheel is the rim only: the picture on a 16-sided disc at the tire's
  bead, kept apart from the body so the game can spin and steer it.
- The **game builds the tire** from the size (TireMesh, 224 triangles: bead,
  bulging sidewall, shoulder, tread) and deforms it every frame from the
  simulation: the patch flattens with load and pressure, sidewalls bulge,
  a flat tire sits down on the rim (bottom-out scales with sidewall height,
  so low profiles bottom out sooner), and cornering force drags the tread
  sideways. Cars whose wheel model already has a tire (the Tahoe) keep it,
  with the same squash shader.
- The rim picture is cut from the aligned side photo around each wheel
  automatically: line the orange circle up with the tire edge; only the rim
  inside the blue circle (from the tire size) is kept. Drag/pinch or nudge. The rear can reuse the front picture or get
  its own. Saved as `wheel_front.png` / `wheel_rear.png` in the project.

**Photo textures** (part *Photo texture* in Paint)
- Faces take their texture from the aligned reference photos: each face
  uses the photo that looks most squarely at it (*Auto*), or a forced one
  (Side / Front / Rear / Top). One-tap *Photos on all body paint* or
  *Photos on everything (then cut windows)*.
- The mirrored half samples its own side of the front, rear and top photos
  and a mirror of the side photo. Roof and hood look best with a top photo.
- Export will bake the used photo areas into one game-sized texture.
- **Recolor photo paint**: *Pick the paint color* (tap the paint on a Side /
  Front / Rear / Top photo) and every photo pixel close to it, by hue angle
  plus a softer saturation term so shaded and sunlit paint match, becomes
  paint the paint shop can recolor, keeping the photo's light and shade;
  badges, chrome, rubber, lights and glass keep their real color. White /
  black / silver paint (no hue) matches on brightness instead (expect more
  touch-ups). *How close counts as paint* sets the tolerance; *Show what's
  paint* tints the match; *Preview in the color above* uses Preview color.
  *Touch up* per photo: brush Not paint / Paint / Auto (erase), pinch to
  zoom. Stored as `paint_key` in project.json and `<view>_paintmask.png`;
  the maths is in `PaintKey` and `photo_recolor.gdshader` (export will turn
  it into the game's paint mask).

**Windows + hollow interior** (Paint panel)
- *Cut a window*: in Side, Front, Rear or Top, tap around a window on the
  photo (Finish / Undo point / Cancel). The panels under the outline are
  really cut along it (new points shared with neighbours, so no cracks) and
  the piece inside becomes a see-through Glass face. A windshield can cross
  the centerline. Delete a glass face in Shape for an open window.
- The body is a hollow shell: an inner surface 2 cm inside the outer one,
  with rims around every window and opening, dark interior colour. *Show
  interior* toggles it; *Driver's seat view* puts the camera at the driver's
  head (drag to look around) as a preview of the first-person mode.

**Interior** (*Interior* switch in the modeler)
- *Driver's seat*: the first-person camera; nudge eye height, fore/aft and
  side-to-side.
- *Dashboard*: start from a template (90s truck, curved, sports cockpit),
  sized to the cab in front of the seat, then *Edit the dash shape*: every
  Shape tool works on it (it mirrors like the body). Editing opens in the
  driver's seat: tap points or faces, drag to move them, drag empty space to
  look around, pinch to zoom, *Closer to me / Farther away* for depth. Side /
  Front / Top still work, with the body as a ghost. Load a dash photo taken from the driver's seat, drag / pinch it
  until the blue outline sits on the dash; faces looking at the driver take
  the photo, the rest are black trim. Each half samples its own side of the
  photo, so the gauge cluster stays on the driver's side.
- The dash can't stick out of the body: every dash point stays 3 cm inside
  the nearest wall at its height and depth (wheel-well walls count) and,
  seen from the seat, behind the windshield, roof and floor. Applied to the
  templates, live while dragging / nudging, after Extrude / Add point / …,
  and when Interior opens (in case the body was reshaped). The seat and dash
  start from the body's windshield (its bottom edge, or the sloped panel
  reaching the roof if the windshield is photo-textured): dash face 50 cm
  behind it, eye ~1.1 m back; a seat position you set yourself is kept.
- *Gauges*: pick Speedo / Tach / Fuel / Temp / Oil / Volts and tap on the dash
  photo; size them and set full scale (mph, rpm). *Hide steering wheel*
  clears the view of the whole dash (also in the dash-editing banner). They land on the dash face
  and get live needles in the game.
- *Steering wheel*: a round template with the steering-wheel photo on it.
  Fit the orange circle to the rim, then *Draw a hole* around each gap
  between the spokes; the holes are cut right through (walls on every cut
  edge). Diameter, rim thickness, tilt and position are adjustable.
- *Stretch*: every photo (the four reference photos and the dash / door /
  pillar / ceiling photos) can be stretched wider / narrower / taller /
  shorter on its own axes, 0.5x–2x, to make up for a shot taken a little off
  square (*Pinch stretches* in the interior fit views; *Reset stretch*).
  Stored as `sx` / `sy` per view; two-point align keeps it.
- *Inside panels*: the inside of the hollow shell can be painted per panel
  (grey cloth, dark plastic, tan, carpet) or take the door / A-pillar /
  ceiling photos. Pick a choice and tap panels from the driver's seat (Fill
  connected for areas), or *Auto*: ceiling, doors, the panels beside the
  windshield and a carpet floor in one tap. Each photo has a fit view (drag /
  pinch onto the blue outline, Flip, Rotate 90°). Both doors and both pillars
  share their photo. The inside paint rides along in each face's region as
  `outer|inner` (e.g. `paint|photo:door`), so cuts and extrudes keep it.
- Saved as `dash.json`, `steering_wheel.png` and `interior` in project.json;
  `PorterProject.interior_model_info()` is what export writes into the
  game's `model_info.json` (driver_eye, steering_wheel_pivot,
  steering_rake_deg, cluster). The game's cluster entries accept
  `{"pos", "r", "max"}` so each car's gauge size and full scale carry over.

Next: specs and test targets, export to
`data/cars/` + `assets/cars/`.

Desktop: `godot res://scenes/porter.tscn` (mouse acts as a finger, wheel
zooms, Q/E rotate). Tests: `godot --headless -s res://scripts/tests/porter_test.gd`, `interior_test.gd`, `paint_test.gd` and
`res://scripts/tests/modeler_test.gd`.
Screenshots: `godot res://scenes/porter.tscn -- --shots`.

## Getting the APK onto the Thor

**From GitHub (every push):** open the repo's **Actions** tab, then the latest
*Build Android APK* run, and download the `racing-sim-apk` artifact (a zip
containing the APK). Car Porter for the phone is the `car-porter-apk` artifact.

**Install:** copy the APK to the Thor (USB, cloud drive, or download it on the
device), open it with a file manager, and allow *Install unknown apps* for that
app when prompted.

### Signing (important for updates)
Android only installs a new version over an old one if both are signed with the
**same key**. Keep the file `racing-sim-signing.p12` safe (do not commit it) and add
two repository secrets under *Settings → Secrets and variables → Actions*:

- `ANDROID_KEYSTORE_B64`: output of `base64 -w0 racing-sim-signing.p12`
- `ANDROID_KEYSTORE_PASSWORD`: the keystore password

Without these secrets the workflow signs with a throwaway key, and you'll have
to uninstall (losing saves) before installing that build.

---

## How the simulation works

All physics runs at 120 Hz. Wheels, driveline and engine are sub-stepped 6× per
tick (720 Hz), because wheel spin and tire deflection are far stiffer than the
body's motion.

**Tires** (`scripts/vehicle/tire.gd`)
- Combined-slip Magic Formula (Pacejka-style) with load sensitivity: a heavily
  loaded tire grips less per newton, which is why weight transfer matters.
- Brush-style relaxation (contact-patch deflection) gives correct behaviour at
  walking pace and when parked, and the delayed build-up of cornering force.
- Three tread zones (inner/middle/outer) plus carcass and inflation gas.
  Heat comes from sliding energy and rolling hysteresis. Cooling comes from
  airflow and the road. Camber, cornering load and pressure decide which zone
  heats.
- Hot pressure follows the ideal gas law. Pressure changes grip, cornering
  stiffness and rolling resistance.
- Wear is tread depth lost from sliding energy, accelerated when overheated.
  Overheating the surface past 125 °C causes permanent blistering damage.
  Worn-out tires lose grip sharply and can go flat.

**Engine** (`scripts/vehicle/engine.gd`)
- Torque curve matched to the 1999 L31 Vortec 5700 rating (255 hp @ 4600, 330 lb-ft @ 2800).
  The curve is SAE net (flywheel) torque, so a warm engine at full throttle
  delivers exactly the rated figures; friction is added back internally.
- Friction and pumping losses (engine braking). Cold oil adds drag. Idle air control.
- Cooling system: thermostat (opens 90.5 °C), radiator scaled by airflow,
  clutch fan, oil cooler exchange. Overheating pulls power.
- Wear from over-revving, overheating, hot oil and revving it cold. Wear costs
  power and adds friction, and it carries over between sessions (rebuild it in
  the editor).

**Driveline** (`scripts/vehicle/transmission.gd`, `vehicle.gd`)
- 4L60-E: 3.06 / 1.63 / 1.00 / 0.70, torque converter with 2.0:1 stall
  multiplication, lock-up clutch, timed shifts, throttle-based shift schedule
  (full-throttle upshifts at 42 / 78 mph on the 3.42 axle), and kickdown that
  won't over-rev.
- Driveline mechanical efficiency from the car file: 91% (2WD) / 89% (4WD,
  adds the transfer case). Converter slip is simulated separately.
- NP241 part-time transfer case: 2H / 4H / 4L (2.72:1). In 4H the front and
  rear shafts are locked together, so it binds in tight corners on pavement,
  just like the real truck.
- Open differentials, with an optional G80 automatic locker.

**Chassis and suspension**
- Ray-cast suspension per corner: spring rates derived from real ride
  frequencies, separate bump and rebound damping, progressive bump stops, and
  a front anti-roll bar.
- Front IFS with camber gain. The rear solid axle stays flat to the road.
  Roll-centre heights per axle.
- Front disc / rear drum brakes with temperature and fade, slip-targeting
  4-wheel ABS, and brake bias.
- Aero drag (Cd × A), speed governor (98 mph, removable).

### Validation against the real truck
Run `godot --headless --fixed-fps 120 -s res://scripts/tests/physics_test.gd`

Acceleration is checked automatically against the instrumented-test targets
in the car file (`targets`), timed like the magazines (clock starts after 1 ft
of rollout). The test prints PASS/FAIL for each figure.

| Test | Sim 4WD | Real 4WD (avg of 3 Motor Trend tests) | Sim 2WD | Real 2WD (Motor Trend) |
|---|---|---|---|---|
| 0–60 mph | 9.06 s | 8.93 s ✅ | 8.28 s | 8.0 s ✅ |
| ¼ mile | 16.84 s | 16.77 s ✅ | 16.35 s | 15.7 s ❌ |
| Trap speed | 81.5 mph | 81.2 mph ✅ | 83.5 mph | 84.0 mph ✅ |
| 60–0 mph | 154 ft | ~140–150 ft | 152 ft | ~140–150 ft |
| Skidpad | 0.69 g | ~0.70 g | 0.70 g | ~0.70 g |
| Top speed | 98 mph (governed) | 98 mph | | |

The single 2WD test's 15.7 s ET is quick for its 84 mph trap, so that miss
may be the test rather than the sim. No 1999 was instrumented-tested; the
1996-99 trucks share the same engine and transmission.

`scripts/tests/lap_test.gd` drives an autopilot around the circuit and reports
lap times, tire and brake temperatures, tread, and fluid temperatures per lap.
`scripts/tests/proving_test.gd` drives every proving-ground area (drag, braking,
skidpad, 30% hill in 2H/4L, whoops).

---

## Project layout

```
data/cars/*.json            Car definitions (real specs, variants, paints)
scripts/core/               Game state & save, main flow/menus, input, cameras
scripts/vehicle/            Tire, engine, transmission, vehicle, Tahoe body model
scripts/track/track.gd      Procedural race circuit + surfaces + scenery
scripts/world/map_builder.gd  Builds any map from data/maps/*.json
data/maps/*.json            Map definitions (proving ground, future towns)
tools/blender/              Scripted Blender car models (exported to assets/)
scripts/ui/                 HUD, theme, option rows
scripts/tests/              Headless physics + lap tests, screenshot tool
scripts/porter/             Car Porter app (projects, reference photos, body modeler)
tools/sign_apk.py           Local APK v2 signer (when apksigner isn't available)
.github/workflows/          Cloud APK build
```

Adding a car is mostly a JSON file in `data/cars/` plus a body model.

## Roadmap

1. ~~Milestone 1: one car, one track, full physics, Thor controls, vehicle editor~~
2. Proper hand-modelled Tahoe mesh (glTF), interior and cockpit camera, better
   wheels and tires, decals
3. Sound: engine (rpm/load), tire scrub, transmission whine, wind
4. More real cars (each from real specs) and a car-select garage
5. More tracks, time of day, weather (wet grip)
6. AI opponents and races, with the lap-test autopilot as a starting point
7. Force-feedback rumble from tire slip on the Thor's motors

## Credits

- 1996 Chevrolet Tahoe 3D model based on "West Virginia State Police Chevy Tahoe 1996"
  by David_Holiday (https://sketchfab.com/David_Holiday), licensed CC-BY-4.0
  (http://creativecommons.org/licenses/by/4.0/). Modified: converted to factory
  paint, police equipment, livery and badges removed, decimated, new interior
  and wheels.
- Built with Godot Engine (MIT License).
- Vehicle names are used for identification only.
