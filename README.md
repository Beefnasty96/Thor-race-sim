# Racing Sim (working title)

A realistic racing simulator for the **AYN Thor**, built in **Godot 4.5**.
Real cars modelled from real specifications, with a physics model covering tire
grip, heat and wear, engine heat and wear, suspension, and a real driveline.
The visual target is the *Gran Turismo 4* era: clean shapes, glossy paint, soft
bloom and haze, running at a steady frame rate on a handheld.

**Current car:** 1996 Chevrolet Tahoe (GMT400). 4-door or 2-door, 2WD or 4WD,
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
| Y | Change camera (chase, near chase, hood, bumper) |
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

## Getting the APK onto the Thor

**From GitHub (every push):** open the repo's **Actions** tab, then the latest
*Build Android APK* run, and download the `racing-sim-apk` artifact (a zip
containing the APK).

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
- Torque curve matched to the L31 Vortec 5700 (250 hp @ 4600, 335 lb-ft @ 2800).
- Friction and pumping losses (engine braking). Cold oil adds drag. Idle air control.
- Cooling system: thermostat (opens 90.5 °C), radiator scaled by airflow,
  clutch fan, oil cooler exchange. Overheating pulls power.
- Wear from over-revving, overheating, hot oil and revving it cold. Wear costs
  power and adds friction, and it carries over between sessions (rebuild it in
  the editor).

**Driveline** (`scripts/vehicle/transmission.gd`, `vehicle.gd`)
- 4L60-E: 3.06 / 1.63 / 1.00 / 0.70, torque converter with 2.0:1 stall
  multiplication, lock-up clutch, timed shifts, throttle-based shift schedule,
  and kickdown that won't over-rev.
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

| Test | Sim 4WD / 2WD | Real 1996 Tahoe |
|---|---|---|
| 0–60 mph | 10.5 / 9.9 s | ~9–10 s |
| ¼ mile | 18.0 / 17.6 s | ~16.5–17.5 s |
| 60–0 mph | 152 / 151 ft | ~140–150 ft |
| Skidpad | 0.69 / 0.70 g | ~0.70 g |
| Top speed | 98 mph (governed) | 98 mph |

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
tools/sign_apk.py           Local APK v2 signer (when apksigner isn't available)
.github/workflows/          Cloud APK build
```

Adding a car is mostly a JSON file in `data/cars/` plus a body model.

## Roadmap

1. ~~Milestone 1: one car, one track, full physics, Thor controls, vehicle editor~~
2. Proper hand-modelled Tahoe mesh (glTF), interior and cockpit camera, better
   wheels and tires, decals
3. Sound: engine (rpm/load), tire scrub, transmission whine, wind
4. Thor second screen as a live telemetry/map display (needs an Android plugin)
5. More real cars (each from real specs) and a car-select garage
6. More tracks, time of day, weather (wet grip)
7. AI opponents and races, with the lap-test autopilot as a starting point
8. Force-feedback rumble from tire slip on the Thor's motors
