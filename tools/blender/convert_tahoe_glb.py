"""Convert the Sketchfab "West Virginia State Police Chevy Tahoe 1996" model
(by David_Holiday, CC-BY-4.0) into the game's factory 1996 Tahoe.

Steps
  1. Import, scale inches -> metres and to the real 199.1 in length, rotate so
     the front faces +Y, origin on the ground midway between the axles.
  2. Delete SketchUp back-face duplicates ("Material3*" objects), the police
     equipment (light bar, sirens, antennas, roof radio gear, partition), the
     livery overlays, the badges, the original interior and wheels.
  3. Weld, dissolve coplanar faces and decimate to the polygon budget.
  4. Re-material: factory paint with the two-tone lower body and dark stripe
     band (cut at measured heights), chrome, glass, lamps, trim.
  5. Add a semi-accurate 1995-99 GMT400 interior (dash, cluster, centre stack,
     column, steering wheel as its own node, seats) and 16 in aluminium wheels.
  6. Export assets/cars/tahoe_1999/tahoe_body.glb (+ steering wheel node) and
     tahoe_wheel.glb.

Run:  python tools/blender/convert_tahoe_glb.py -- SRC.glb OUT_DIR [--render PREFIX]
"""
import math
import os
import sys

import bpy  # noqa: E402  (bpy before bmesh)
import bmesh
from mathutils import Matrix, Vector

REAL_LENGTH = 5.057
WB = 2.985
TARGET_BODY_TRIS = 5000
ARCH_XS = []       # total vehicle budget ~10,000 triangles

# police / non-factory materials in the source model
LIGHTBAR = {"material_27", "material_28", "material_29", "material_30", "material_31", "material_32",
            "material_33", "material_34", "material_35", "material_36", "material_37", "material_38",
            "material_39", "material_40", "material_41", "material_42"}
LIVERY = {"material_11", "material_10", "material_43", "material_7"}
ROOF_GRAPHIC = {"material_16"}                    # roof skin carries the white roof graphic
ANTENNA_GEAR = {"material_14", "material_15"}
PARTITION = {"material_26"}
WHEEL_MATS = {"material_19", "material_0", "material_20", "material_21", "material_22"}  # only within wheel zones
PAINT = {"material_8", "material", "material_16", "material_11", "material_12"}
GLASS = {"material_9", "material_3"}
CHROME = {"material_0", "material_17", "material_18", "material_13", "material_4"}
DARK_TRIM = {"material_1", "material_2", "material_5", "material_19", "material_25"}
RED_LAMP = {"material_23", "material_24"}
AMBER = {"material_6"}


def log(*a):
    print("[convert]", *a, flush=True)


# ----------------------------------------------------------------- materials
def mat(name, color, metallic=0.0, rough=0.5, emit=None, emit_strength=0.0, alpha=1.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    m.use_backface_culling = False
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*color, 1.0)
    b.inputs["Metallic"].default_value = metallic
    b.inputs["Roughness"].default_value = rough
    if emit:
        b.inputs["Emission Color"].default_value = (*emit, 1.0)
        b.inputs["Emission Strength"].default_value = emit_strength
    if alpha < 1.0:
        b.inputs["Alpha"].default_value = alpha
        m.blend_method = "BLEND"
    return m


def srgb(r, g, b):
    return tuple(pow(c, 2.2) for c in (r, g, b))


def make_image(name, w, h, fn):
    """Procedural texture -> packed Blender image (exported inside the GLB)."""
    import numpy as np
    ys, xs = np.mgrid[0:h, 0:w]
    u = (xs + 0.5) / w
    v = (ys + 0.5) / h            # v = 0 bottom
    rgb = fn(u, v, np)
    px = np.ones((h, w, 4), dtype=np.float32)
    px[..., :3] = np.clip(rgb, 0, 1)
    img = bpy.data.images.new(name, w, h)
    img.pixels.foreach_set(px.ravel())
    img.pack()
    return img


def tex_grille(u, v, np):
    """'94-'98 grille: black with horizontal bars and a few vertical ribs."""
    c = np.full(u.shape + (3,), 0.025)
    bars = (np.abs(((v * 4.0) % 1.0) - 0.5) > 0.36)
    ribs = (np.abs(((u * 9.0) % 1.0) - 0.5) > 0.46)
    c[bars | ribs] = 0.11
    return c


def tex_headlamp(u, v, np):
    """Composite headlamp lens: fine vertical flutes over a bright reflector."""
    flutes = 0.80 + 0.10 * np.cos(u * 2 * np.pi * 26)
    refl = np.exp(-(((u - 0.5) / 0.30) ** 2 + ((v - 0.5) / 0.45) ** 2))
    lum = flutes * (0.80 + 0.22 * refl)
    return np.stack([lum, lum * 1.0, lum * 1.03], -1)


def tex_park(u, v, np):
    """Clear park/turn lens: vertical ribs, amber bulb glowing behind."""
    ribs = 0.78 + 0.14 * np.cos(u * 2 * np.pi * 34)
    bulb = np.exp(-(((u - 0.62) / 0.12) ** 2 + ((v - 0.5) / 0.35) ** 2))
    return np.stack([ribs + 0.15 * bulb, ribs + 0.02 * bulb, ribs - 0.25 * bulb], -1)


def tex_amber(u, v, np):
    ribs = 0.85 + 0.15 * np.cos(v * 2 * np.pi * 10)
    return np.stack([1.0 * ribs, 0.50 * ribs, 0.08 * ribs], -1)


def textured(m, img):
    nt = m.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    t = nt.nodes.new("ShaderNodeTexImage")
    t.image = img
    nt.links.new(t.outputs["Color"], bsdf.inputs["Base Color"])
    return m


def _texture_lamps(m):
    textured(m["Headlamp"], make_image("headlamp_lens", 128, 64, tex_headlamp))
    textured(m["Amber"], make_image("amber_lens", 16, 64, tex_amber))
    textured(m["Grille"], make_image("grille", 256, 64, tex_grille))
    return m


def make_materials():
    return {
        "Paint": mat("Paint", srgb(0.17, 0.22, 0.42), 0.55, 0.28),       # Indigo Blue Metallic
        "Lower": mat("Lower", srgb(0.62, 0.52, 0.40), 0.5, 0.32),        # Light Autumnwood
        "Stripe": mat("Stripe", srgb(0.13, 0.13, 0.14), 0.25, 0.45),
        "Chrome": mat("Chrome", (0.9, 0.9, 0.92), 1.0, 0.08),
        "Glass": mat("Glass", srgb(0.05, 0.06, 0.07), 0.0, 0.05, alpha=0.55),
        "Black": mat("Black", srgb(0.07, 0.07, 0.075), 0.0, 0.6),
        "Grille": mat("Grille", srgb(0.025, 0.025, 0.028), 0.3, 0.45),
        "Headlamp": mat("Headlamp", srgb(0.86, 0.88, 0.90), 0.15, 0.06, (1.0, 0.98, 0.92), 0.10),
        "Amber": mat("Amber", srgb(0.92, 0.50, 0.10), 0.3, 0.12, (1.0, 0.45, 0.05), 0.08),
        "Taillight": mat("Taillight", srgb(0.7, 0.05, 0.04), 0.2, 0.12, (0.9, 0.02, 0.0), 0.3),
        "Interior": mat("Interior", srgb(0.20, 0.22, 0.27), 0.0, 0.55),   # blue-grey leather
        "Headliner": mat("Headliner", srgb(0.30, 0.32, 0.38), 0.0, 0.95),
        "ParkLamp": textured(mat("ParkLamp", srgb(0.88, 0.88, 0.86), 0.1, 0.12),
                             make_image("park_lens", 128, 32, tex_park)),
        "Dash": mat("Dash", srgb(0.13, 0.145, 0.19), 0.0, 0.6),
        "Gauge": mat("Gauge", srgb(0.025, 0.025, 0.03), 0.0, 0.3),
        "Tire": mat("Tire", srgb(0.07, 0.07, 0.07), 0.0, 0.9),
        "Rim": mat("Rim", srgb(0.78, 0.78, 0.8), 0.85, 0.22),
        "Hub": mat("Hub", srgb(0.15, 0.15, 0.16), 0.6, 0.5),
    }


# ----------------------------------------------------------------- helpers
def world_bbox(o):
    pts = [o.matrix_world @ v.co for v in o.data.vertices]
    if not pts:
        return Vector(), Vector()
    mn = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    mx = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    return mn, mx


def tri_count(o):
    return sum(len(p.vertices) - 2 for p in o.data.polygons)


def import_and_normalise(src):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=src)
    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    # drop edge-only meshes and SketchUp back-face duplicates
    for o in list(meshes):
        if len(o.data.polygons) == 0 or o.name.startswith("Material3") or o.name.startswith("Material4") and False:
            bpy.data.objects.remove(o, do_unlink=True)
    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    # bake transforms: inches -> metres, front to +Y
    S = 0.0254
    rot = Matrix.Rotation(math.pi, 4, "Z")
    flipped = 0
    for o in meshes:
        o.data = o.data.copy()          # instances share meshes: make unique before baking
        T = rot @ Matrix.Scale(S, 4) @ o.matrix_world
        o.data.transform(T)
        if T.determinant() < 0:         # SketchUp mirrored the left side: restore face winding
            o.data.flip_normals()
            flipped += 1
        o.parent = None
        o.matrix_world = Matrix.Identity(4)
    log("mirrored parts re-oriented:", flipped)
    # remove empties
    for o in list(bpy.data.objects):
        if o.type != "MESH":
            bpy.data.objects.remove(o, do_unlink=True)
    return [o for o in bpy.data.objects if o.type == "MESH"]


def find_wheels(meshes):
    """Wheel centres from the tyre meshes (material_19 tori near the ground)."""
    cents = []
    for o in meshes:
        names = {s.material.name for s in o.material_slots if s.material}
        mn, mx = world_bbox(o)
        if "material_19" in names and mn.z < 0.02 and 0.6 < (mx.z - mn.z) < 1.0:
            cents.append(((mn + mx) / 2, mx.z - mn.z))
    return cents


def strip(meshes, wheel_zones, cabin):
    """Delete police gear, livery, badges, original wheels and interior."""
    killed = 0
    for o in list(meshes):
        mn, mx = world_bbox(o)
        size = mx - mn
        names = [s.material.name if s.material else "" for s in o.material_slots]
        centre = (mn + mx) / 2
        drop = False
        # antennas / radio gear / sirens / light-bar base above the roof skin
        if mn.z > 1.835 * SCALE_Z and size.y < 1.2:
            drop = True
        if size.z > 0.25 and size.x < 0.05 and size.y < 0.05:
            drop = True                                   # whip antennas
        if mx.z > 1.86 * SCALE_Z and size.y < 0.35 and size.x < 0.35:
            drop = True                                   # spotlight post / uprights poking through the roof
        # original wheels (tyres, covers, hubs)
        for wc, d in wheel_zones:
            if (centre - wc).length < d * 0.55 and abs(centre.x) > 0.55:
                drop = True
        # interior: anything wholly inside the cabin volume -- except roof skin
        # pieces (mostly upward-facing surface at roof height)
        if (cabin[0].x < mn.x and mx.x < cabin[1].x and cabin[0].y < mn.y and mx.y < cabin[1].y
                and cabin[0].z < mn.z and mx.z < cabin[1].z):
            up = sum(p.area for p in o.data.polygons
                     if abs(p.normal.z) > 0.8 and p.center.z > 1.74 * SCALE_Z)
            total = sum(p.area for p in o.data.polygons) or 1.0
            if not (up / total > 0.5 and up > 0.02):
                drop = True
        if drop:
            bpy.data.objects.remove(o, do_unlink=True)
            killed += 1
            continue
        bm = bmesh.new()
        bm.from_mesh(o.data)
        kill = []
        for f in bm.faces:
            n = names[f.material_index] if f.material_index < len(names) else ""
            c = f.calc_center_median()
            if n == "material_11" and c.z > 1.70 * SCALE_Z:
                continue                         # blue roof band is the roof skin itself: keep, repaint
            if n in LIGHTBAR or n in LIVERY or n in ANTENNA_GEAR or n in PARTITION:
                kill.append(f)
            elif n in ROOF_GRAPHIC and c.z > 1.88 * SCALE_Z:
                kill.append(f)
        if kill:
            bmesh.ops.delete(bm, geom=kill, context="FACES")
        bm.to_mesh(o.data)
        bm.free()
        if len(o.data.polygons) == 0:
            bpy.data.objects.remove(o, do_unlink=True)
    log("removed objects:", killed)
    return [o for o in bpy.data.objects if o.type == "MESH"]


def remove_badges(meshes, length):
    """Small many-faced text objects on the body (bow-tie, CHEVROLET, 1500)."""
    n = 0
    for o in list(meshes):
        mn, mx = world_bbox(o)
        size = mx - mn
        thin = min(size.x, size.y, size.z) < 0.012
        small = max(size.x, size.y, size.z) < 0.38
        faces = len(o.data.polygons)
        if thin and small and faces >= 24:
            c = (mn + mx) / 2
            on_side = abs(abs(c.x) - 0.98 * SCALE_Z) < 0.06
            on_rear = c.y < -length * 0.5 + 0.08
            on_front = c.y > length * 0.5 - 0.15 and abs(c.x) < 0.15
            if on_side or on_rear or on_front:
                bpy.data.objects.remove(o, do_unlink=True)
                n += 1
    # individual letters/digits: tiny pieces stuck on the side skin or tailgate
    for o in [o for o in bpy.data.objects if o.type == "MESH"]:
        mn, mx = world_bbox(o)
        size = mx - mn
        c = (mn + mx) / 2
        if max(size.x, size.y, size.z) < 0.13:
            on_side = abs(abs(c.x) - 0.97 * SCALE_Z) < 0.05 and 0.55 < c.z < 1.1
            on_rear = c.y < -length * 0.5 + 0.08 and 0.8 < c.z < 1.35 and abs(c.x) < 0.7
            if on_side or on_rear:
                bpy.data.objects.remove(o, do_unlink=True)
                n += 1
    # whole words (e.g. the tailgate script): thin decal-like plates on the rear face
    for o in [o for o in bpy.data.objects if o.type == "MESH"]:
        mn, mx = world_bbox(o)
        size = mx - mn
        c = (mn + mx) / 2
        if size.y < 0.008 and max(size.x, size.z) < 0.35 and c.y < -length * 0.5 + 0.12 and 0.8 < c.z < 1.35:
            bpy.data.objects.remove(o, do_unlink=True)
            n += 1
    log("removed badges/text:", n)
    return [o for o in bpy.data.objects if o.type == "MESH"]


SCALE_Z = 1.0


def classify(name, centre, normal, front_y):
    nose = centre.y > front_y - 0.22 and 0.68 < centre.z < 1.13 and normal.y > 0.6
    if nose and abs(centre.x) < 0.97 and name not in GLASS:
        return "Black"                           # backing behind the rebuilt lamps + grille
    if name in GLASS:
        if centre.z > 1.70 and abs(normal.z) > 0.7:
            return "Paint"                       # police roof hatch glass -> solid roof (no factory sunroof)
        return "Glass"
    if name in RED_LAMP:
        return "Taillight"
    if name in AMBER:
        return "Amber"
    if name in PAINT:
        if nose:
            return "Black"                       # grille insert between the lamps
        return "Paint"                           # B/C pillars and door frames are body colour
    if name in CHROME and centre.z > 1.77:
        return "Black"                           # roof-rack feet / rails
    if name in CHROME:
        # headlamp lenses: front face, outboard of the grille
        if centre.y > front_y - 0.18 and abs(centre.x) > 0.5 and 0.72 < centre.z < 1.12:
            return "Headlamp"
        return "Chrome"
    return "Black"


def remap_materials(meshes, mats, front_y):
    order = list(mats.keys())
    for o in meshes:
        names = [s.material.name if s.material else "" for s in o.material_slots]
        me = o.data
        me.materials.clear()
        for k in order:
            me.materials.append(mats[k])
        idx = {k: i for i, k in enumerate(order)}
        for p in me.polygons:
            src = names[p.material_index] if p.material_index < len(names) else ""
            p.material_index = idx[classify(src, p.center, p.normal, front_y)]


def two_tone(body, mats):
    """Cut the body at the measured two-tone heights and assign paint zones on
    the sides: tan 0.43-0.58 | dark stripe 0.58-0.69 | tan 0.69-0.75 m."""
    order = list(mats.keys())
    pi = order.index("Paint")
    bm = bmesh.new()
    bm.from_mesh(body.data)
    for z in (0.58, 0.588, 0.682, 0.69, 0.75):
        geom = [f for f in bm.faces if f.material_index == pi]
        edges = list({e for f in geom for e in f.edges})
        verts = list({v for f in geom for v in f.verts})
        bmesh.ops.bisect_plane(bm, geom=geom + edges + verts, plane_co=(0, 0, z), plane_no=(0, 0, 1))
    li, si = order.index("Lower"), order.index("Stripe")
    for f in bm.faces:
        if f.material_index != pi:
            continue
        c = f.calc_center_median()
        if abs(f.normal.z) > 0.6:
            continue                     # leave horizontal surfaces (hood/roof) in body colour
        ci = order.index("Chrome")
        if c.z < 0.58:
            f.material_index = li
        elif c.z < 0.588 or 0.682 <= c.z < 0.69:
            f.material_index = ci                # bright pinstripe edges of the molding band
        elif c.z < 0.69:
            f.material_index = si
        elif c.z < 0.75:
            f.material_index = li
    bm.to_mesh(body.data)
    bm.free()


def join(objs, name):
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.join()
    o = bpy.context.view_layer.objects.active
    o.name = name
    o.data.name = name
    return o


def symmetrise(body):
    """The source's mirrored left side carries back-face colours, so rebuild the
    left half by mirroring the (correct) right half across x = 0."""
    bm = bmesh.new()
    bm.from_mesh(body.data)
    geom = bm.verts[:] + bm.edges[:] + bm.faces[:]
    bmesh.ops.bisect_plane(bm, geom=geom, plane_co=(0, 0, 0), plane_no=(1, 0, 0), clear_inner=True)
    bmesh.ops.mirror(bm, geom=bm.verts[:] + bm.edges[:] + bm.faces[:], axis="X", merge_dist=0.002)
    bm.to_mesh(body.data)
    bm.free()


def reduce(body, target):
    bm = bmesh.new()
    bm.from_mesh(body.data)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=0.0015)
    # dissolve coplanar triangles SketchUp produced (keeps material borders)
    bmesh.ops.dissolve_limit(bm, angle_limit=math.radians(1.5), use_dissolve_boundaries=False,
                             verts=bm.verts, edges=bm.edges, delimit={"MATERIAL"})
    # tiny faces (rivets, edge slivers) go first
    bmesh.ops.triangulate(bm, faces=bm.faces)
    bm.to_mesh(body.data)
    bm.free()
    log("after weld/dissolve:", tri_count(body))
    if tri_count(body) > target:
        mod = body.modifiers.new("dec", "DECIMATE")
        mod.decimate_type = "COLLAPSE"
        mod.ratio = target / tri_count(body)
        mod.use_collapse_triangulate = True
        mod.use_symmetry = True
        mod.symmetry_axis = "X"
        bpy.context.view_layer.objects.active = body
        bpy.ops.object.modifier_apply(modifier=mod.name)
    log("after decimate:", tri_count(body))


# ----------------------------------------------------------------- interior
def add_box(bm, size, loc, mi, rot=None):
    tmp = bmesh.new()
    bmesh.ops.create_cube(tmp, size=1.0)
    bmesh.ops.scale(tmp, vec=Vector(size), verts=tmp.verts)
    if rot is not None:
        bmesh.ops.rotate(tmp, verts=tmp.verts, cent=(0, 0, 0), matrix=rot)
    bmesh.ops.translate(tmp, vec=Vector(loc), verts=tmp.verts)
    for f in tmp.faces:
        f.material_index = mi
    me = bpy.data.meshes.new("_t")
    tmp.to_mesh(me)
    tmp.free()
    bm.from_mesh(me)
    bpy.data.meshes.remove(me)


def build_interior(mats, cowl_y, belt_z, front_y):
    """'95-'99 GMT400 interior from reference photos. Driver sits on the LEFT (-X).
    - one-piece dark dash pad swept across the cab (profile extrusion), with the
      defroster slots along the windshield and two cupholders in the passenger top
    - lower dash and knee bolster in the lighter interior colour
    - hooded cluster ahead of the driver (tach | big speedo | 4 small gauges)
    - square louvred vents: outer left, either side of the radio, two passenger
    - centre stack: radio over HVAC over ashtray; headlamp switch under left vent
    - glovebox, column shroud, big centre console with armrest, buckets, bench."""
    order = list(mats.keys())
    D, I, B, G, C = (order.index(k) for k in ("Dash", "Interior", "Black", "Gauge", "Chrome"))
    bm = bmesh.new()
    dash_y = cowl_y - 0.42
    ws_y = cowl_y + 0.06             # windshield base (inside)
    tilt = Matrix.Rotation(math.radians(-12), 3, "X")
    bz = belt_z
    # --- dash body: side profile (y, z, material of the segment that follows)
    prof = [(ws_y, bz + 0.062, D), (dash_y + 0.21, bz + 0.062, D), (dash_y - 0.02, bz + 0.048, D),
            (dash_y - 0.09, bz + 0.015, D), (dash_y - 0.105, bz - 0.03, I),
            (dash_y - 0.08, bz - 0.05, I), (dash_y - 0.09, bz - 0.27, I),
            (dash_y - 0.16, bz - 0.37, I), (dash_y - 0.13, bz - 0.50, I), (dash_y + 0.01, bz - 0.56, I)]
    xs = [-0.84, -0.70, -0.40, -0.06, 0.25, 0.55, 0.84]
    grid = [[bm.verts.new((x, y, z)) for (y, z, _) in prof] for x in xs]
    for a in range(len(xs) - 1):
        for k in range(len(prof) - 1):
            f = bm.faces.new((grid[a][k], grid[a][k + 1], grid[a + 1][k + 1], grid[a + 1][k]))
            f.material_index = prof[k][2]
    for col in (grid[0], grid[-1]):                      # end caps against the doors
        f = bm.faces.new(col)
        f.material_index = I
    face_y = dash_y - 0.085                              # vertical face of the lower dash
    # defroster slots along the glass + side demisters; passenger cupholders
    add_box(bm, (0.95, 0.05, 0.006), (0.0, ws_y - 0.07, bz + 0.064), B)
    for x in (-0.74, 0.74):
        add_box(bm, (0.10, 0.04, 0.006), (x, ws_y - 0.09, bz + 0.064), B)
    for x in (0.40, 0.55):
        add_box(bm, (0.085, 0.085, 0.012), (x, dash_y + 0.03, bz + 0.052), B)
    # --- hooded instrument cluster (gauge face position is used by the game)
    add_box(bm, (0.66, 0.22, 0.045), (-0.37, dash_y - 0.06, bz + 0.085), D,
            Matrix.Rotation(math.radians(4), 3, "X"))                               # brow
    for sx in (-0.69, -0.05):
        add_box(bm, (0.035, 0.20, 0.17), (sx, dash_y - 0.07, bz + 0.0), D)          # hood cheeks
    add_box(bm, (0.66, 0.15, 0.035), (-0.37, dash_y - 0.085, bz - 0.11), D)         # lower lip
    add_box(bm, (0.60, 0.02, 0.16), (-0.37, dash_y - 0.135, bz - 0.035), G, tilt)   # black face
    global CLUSTER
    face = Vector((-0.37, dash_y - 0.147, bz - 0.035))
    CLUSTER = {"tilt_deg": -12,
               "tach": face + Vector((-0.175, 0, 0.005)),
               "speedo": face + Vector((0.0, 0, 0.008)),
               "fuel": face + Vector((0.155, 0, 0.032)), "volts": face + Vector((0.215, 0, 0.032)),
               "oil": face + Vector((0.155, 0, -0.025)), "temp": face + Vector((0.215, 0, -0.025))}
    # --- square louvred vents
    def vent(x, z, w=0.11, h=0.095):
        add_box(bm, (w, 0.03, h), (x, face_y - 0.005, z), B)
        for k in (-1, 1):
            add_box(bm, (w - 0.014, 0.012, 0.010), (x, face_y - 0.024, z + k * h * 0.22), D)
    vent(-0.775, bz - 0.09)
    vent(-0.005, bz - 0.10, 0.08)
    vent(0.275, bz - 0.10, 0.08)
    vent(0.42, bz - 0.20)
    vent(0.775, bz - 0.20)
    add_box(bm, (0.07, 0.02, 0.04), (-0.775, face_y - 0.012, bz - 0.20), B)        # headlamp switch
    # --- centre stack: radio, HVAC panel, ashtray
    add_box(bm, (0.24, 0.025, 0.24), (0.135, face_y - 0.010, bz - 0.17), B)
    add_box(bm, (0.17, 0.012, 0.045), (0.135, face_y - 0.026, bz - 0.09), G)        # radio display
    add_box(bm, (0.18, 0.012, 0.012), (0.135, face_y - 0.026, bz - 0.19), C)        # HVAC slider strip
    add_box(bm, (0.17, 0.012, 0.04), (0.135, face_y - 0.026, bz - 0.25), D)         # ashtray door
    # --- glovebox door and handle
    add_box(bm, (0.36, 0.022, 0.15), (0.60, face_y - 0.022, bz - 0.33), I)
    add_box(bm, (0.08, 0.02, 0.02), (0.60, face_y - 0.036, bz - 0.27), B)
    # --- steering column + shroud
    col_top = Vector((-0.38, dash_y - 0.28, bz - 0.06))
    add_box(bm, (0.07, 0.36, 0.07), (-0.38, dash_y - 0.15, bz - 0.12),
            B, Matrix.Rotation(math.radians(24), 3, "X"))
    add_box(bm, (0.12, 0.16, 0.12), (-0.38, dash_y - 0.14, bz - 0.14),
            D, Matrix.Rotation(math.radians(24), 3, "X"))
    # --- floor, centre console, seats
    eye_y = col_top.y - 0.55
    back_y = eye_y - 0.16
    add_box(bm, (1.70, 2.9, 0.04), (0, cowl_y - 1.75, 0.62), B)
    add_box(bm, (0.30, 0.70, 0.26), (0.0, back_y + 0.30, 0.77), I)                 # console body
    add_box(bm, (0.30, 0.42, 0.045), (0.0, back_y + 0.17, 0.92), D)                # armrest lid
    add_box(bm, (0.20, 0.13, 0.02), (0.0, back_y + 0.55, 0.905), B)                # cupholders
    for x in (-0.42, 0.42):
        add_box(bm, (0.50, 0.50, 0.13), (x, back_y + 0.28, 0.86), I)
        add_box(bm, (0.48, 0.12, 0.62), (x, back_y - 0.02, 1.20), I,
                Matrix.Rotation(math.radians(-10), 3, "X"))
        for bx in (-0.22, 0.22):
            add_box(bm, (0.07, 0.15, 0.55), (x + bx, back_y + 0.0, 1.18), I,
                    Matrix.Rotation(math.radians(-10), 3, "X"))
            add_box(bm, (0.07, 0.48, 0.07), (x + bx, back_y + 0.28, 0.94), I)
        add_box(bm, (0.26, 0.10, 0.18), (x, back_y - 0.08, 1.58), I)
    add_box(bm, (1.55, 0.55, 0.14), (0, back_y - 0.62, 0.86), I)
    add_box(bm, (1.55, 0.14, 0.58), (0, back_y - 0.94, 1.18), I)
    # --- headliner, visors
    H = order.index("Headliner")
    add_box(bm, (1.40, cowl_y - 0.95 - (-2.20), 0.02), (0, (cowl_y - 0.95 + -2.20) / 2, 1.715), H)
    for x in (-0.40, 0.40):
        add_box(bm, (0.40, 0.17, 0.02), (x, cowl_y - 1.02, 1.715), H, Matrix.Rotation(math.radians(10), 3, "X"))
    # --- door panels: dark upper, interior-colour lower with armrest
    for sx in (-1, 1):
        add_box(bm, (0.04, 2.1, 0.30), (sx * 0.86, cowl_y - 1.3, 0.85), I)
        add_box(bm, (0.045, 2.1, 0.14), (sx * 0.86, cowl_y - 1.3, 1.07), D)
        add_box(bm, (0.07, 0.42, 0.06), (sx * 0.82, eye_y + 0.12, 0.98), I)
    me = bpy.data.meshes.new("Interior")
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new("Interior", me)
    bpy.context.collection.objects.link(ob)
    for k in order:
        me.materials.append(mats[k])
    return ob, col_top


CLUSTER = {}


def front_face_y(body):
    """Typical y of the front-facing nose surface and its half-width."""
    ys, xs = [], []
    M = body.matrix_world
    for p in body.data.polygons:
        c = M @ p.center
        if 0.72 < c.z < 1.1 and p.normal.y > 0.6:
            if abs(c.x) < 0.9:
                ys.append(c.y)
            xs.append(abs(c.x))
    ys.sort()
    xs.sort()
    fy = ys[int(len(ys) * 0.85)] if ys else 2.3
    hw = xs[int(len(xs) * 0.97)] if xs else 0.9
    return fy, hw


def nose_y(fy, x):
    """Plan-view curve of the GMT400 nose at lamp height, measured from the
    model: flat across the grille, falling back ~12 cm to the fender corners."""
    return fy + 0.006 - 0.171 * abs(x) ** 2.35


def cpanel(bm, fy, x0, x1, z0, z1, off, depth, mi, n=None):
    """A box whose front face follows the nose curve (so lamps sit flush)."""
    if n is None:
        n = max(1, int(math.ceil(abs(x1 - x0) / 0.12)))
    xs = [x0 + (x1 - x0) * i / n for i in range(n + 1)]
    F = [(bm.verts.new((x, nose_y(fy, x) + off, z0)), bm.verts.new((x, nose_y(fy, x) + off, z1))) for x in xs]
    B = [(bm.verts.new((x, nose_y(fy, x) + off - depth, z0)), bm.verts.new((x, nose_y(fy, x) + off - depth, z1))) for x in xs]
    uvl = bm.loops.layers.uv.verify()
    def q(a, b, c, d, uvs=None):
        f = bm.faces.new((a, b, c, d))
        f.material_index = mi
        for lp, uv in zip(f.loops, uvs or ((0.02, 0.02),) * 4):
            lp[uvl].uv = uv
    for i in range(n):
        u0, u1 = i / n, (i + 1) / n
        if x1 < x0:
            u0, u1 = 1 - u0, 1 - u1
        q(F[i][0], F[i + 1][0], F[i + 1][1], F[i][1], ((u0, 0), (u1, 0), (u1, 1), (u0, 1)))
        q(F[i][1], F[i + 1][1], B[i + 1][1], B[i][1])
        q(F[i][0], B[i][0], B[i + 1][0], F[i + 1][0])
    q(F[0][0], F[0][1], B[0][1], B[0][0])
    q(F[-1][0], B[-1][0], B[-1][1], F[-1][1])


def build_fascia(mats, fy, hw):
    """'94-'98 GMT400 nose from reference photos, built flush on the nose curve:
    - grille: two black openings with horizontal bars, chrome surround
    - full-width chrome bar between the upper and lower rows
    - composite headlamp: chrome bezel, clear lens split into two reflector cells
    - clear ribbed park/turn lamp below it, chrome bezel
    - stacked amber corner lamps that wrap around onto the fender side."""
    order = list(mats.keys())
    C, K, H, A, G, P = (order.index(k) for k in ("Chrome", "Black", "Headlamp", "Amber", "Grille", "ParkLamp"))
    bm = bmesh.new()
    up = (0.935, 1.075)
    lo = (0.748, 0.872)
    gx = 0.47
    xo = 0.905                 # outer edge of the front lamps (nose corner)
    xa = 0.845                 # amber corner lamp starts here
    dep = 0.12                 # pieces run back into the body so no gaps show
    # grille openings + bars
    for (z0, z1) in (up, lo):
        cpanel(bm, fy, -gx, gx, z0, z1, -0.008, dep, G, 4)      # bars come from the grille texture
    # chrome: grille top bar, uprights, full-width centre bar with plain centre boss
    cpanel(bm, fy, -xo - 0.005, xo + 0.005, up[1], 1.108, 0.010, dep, C, 8)       # top frame under the hood
    cpanel(bm, fy, -xo - 0.005, xo + 0.005, 0.728, lo[0], 0.008, dep, C, 8)       # bottom frame over the bumper
    for sx in (-1, 1):
        cpanel(bm, fy, sx * gx - 0.012, sx * gx + 0.012, lo[0], up[1], 0.010, dep, C, 1)
    cpanel(bm, fy, -xo - 0.005, xo + 0.005, lo[1], up[0], 0.012, dep, C, 8)
    cpanel(bm, fy, -0.09, 0.09, lo[1] - 0.008, up[0] + 0.008, 0.016, 0.03, C, 1)
    for sx in (-1, 1):
        def X(a, b):
            return (min(sx * a, sx * b), max(sx * a, sx * b))
        xi = gx + 0.012
        # headlamp: bezel, two lens cells, divider
        x0, x1 = X(xi, xa)
        cpanel(bm, fy, x0, x1, up[0], up[1], 0.004, dep, C, 3)
        xm = (xi + xa) / 2
        for (a, b) in ((xi + 0.012, xm - 0.006), (xm + 0.006, xa - 0.010)):
            x0, x1 = X(a, b)
            cpanel(bm, fy, x0, x1, up[0] + 0.012, up[1] - 0.012, 0.008, 0.03, H, 2)
        # park lamp: bezel + clear lens
        x0, x1 = X(xi, xa)
        cpanel(bm, fy, x0, x1, lo[0], lo[1], 0.004, dep, C, 3)
        x0, x1 = X(xi + 0.012, xa - 0.010)
        cpanel(bm, fy, x0, x1, lo[0] + 0.012, lo[1] - 0.012, 0.008, 0.03, P, 3)
        # amber corner lamps (upper + lower) and their wrap onto the fender side
        for (z0, z1) in (up, lo):
            x0, x1 = X(xa, xo)
            cpanel(bm, fy, x0, x1, z0 + 0.004, z1 - 0.004, 0.006, dep, A, 1)
            yc = nose_y(fy, xo) + 0.006
            add_box(bm, (0.012, 0.11, (z1 - z0) - 0.008), (sx * (xo + 0.004), yc - 0.055, (z0 + z1) / 2), A)
    me = bpy.data.meshes.new("Fascia")
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new("Fascia", me)
    bpy.context.collection.objects.link(ob)
    for k in order:
        me.materials.append(mats[k])
    return ob


def sweep(bm, path, profile, seg_mats):
    """Sweep a (d, z) profile along a plan-view path; d is measured outward
    (away from the middle of the truck)."""
    rows = []
    for i, (x, y) in enumerate(path):
        a = Vector(path[max(0, i - 1)])
        b = Vector(path[min(len(path) - 1, i + 1)])
        t = (b - a).normalized()
        n = Vector((t.y, -t.x))
        if n.dot(Vector((x, y))) < 0:
            n = -n
        rows.append([bm.verts.new((x + n.x * d, y + n.y * d, z)) for (d, z) in profile])
    for r in (rows[0], rows[-1]):                 # end caps
        try:
            f = bm.faces.new(r)
            f.material_index = seg_mats[len(seg_mats) // 2]
        except ValueError:
            pass
    for i in range(len(rows) - 1):
        for j in range(len(profile) - 1):
            f = bm.faces.new((rows[i][j], rows[i + 1][j], rows[i + 1][j + 1], rows[i][j + 1]))
            f.material_index = seg_mats[j]


def mirror_path(right):
    """right: points from the outer end to the centre (x >= 0)."""
    return [(-x, y) for (x, y) in right] + [(x, y) for (x, y) in reversed(right[:-1])]


def build_bumpers(mats):
    """Front: chrome face wrapping the corners, black rubber impact strip,
    black lower valance, plate bracket. Rear: chrome step bumper with a black
    rubber step pad on top, plate recess and hitch receiver."""
    order = list(mats.keys())
    C, K = order.index("Chrome"), order.index("Black")
    bm = bmesh.new()
    front = [(0.975, 2.05), (0.955, 2.165), (0.90, 2.228), (0.72, 2.278), (0.40, 2.323), (0.0, 2.337)]
    sweep(bm, mirror_path(front),
          [(-0.08, 0.748), (0.0, 0.748), (0.004, 0.735), (0.016, 0.731), (0.016, 0.690),
           (0.007, 0.686), (0.006, 0.62), (0.003, 0.545), (-0.05, 0.535)],
          [C, C, K, K, K, C, C, C])
    sweep(bm, mirror_path(front[1:]),
          [(-0.05, 0.535), (-0.035, 0.47), (-0.06, 0.41), (-0.22, 0.40)], [K, K, K])
    add_box(bm, (0.32, 0.012, 0.16), (0.0, 2.337 + 0.026, 0.645), K)          # plate bracket
    rear = [(0.975, -2.555), (0.965, -2.665), (0.92, -2.722), (0.78, -2.742), (0.40, -2.748), (0.0, -2.748)]
    sweep(bm, mirror_path(rear),
          [(-0.17, 0.705), (-0.012, 0.705), (0.0, 0.695), (0.006, 0.64), (0.004, 0.52),
           (-0.02, 0.475), (-0.12, 0.465)],
          [K, K, C, C, C, C])
    add_box(bm, (0.34, 0.012, 0.15), (0.0, -2.748 - 0.002, 0.585), K)         # plate recess
    add_box(bm, (0.07, 0.24, 0.07), (0.0, -2.70, 0.42), K)                    # hitch receiver
    me = bpy.data.meshes.new("Bumpers")
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new("Bumpers", me)
    bpy.context.collection.objects.link(ob)
    for k in order:
        me.materials.append(mats[k])
    return ob


def delete_faces(body, test):
    bm = bmesh.new()
    bm.from_mesh(body.data)
    names = [m.name for m in body.data.materials]
    mw = body.matrix_world
    kill = [f for f in bm.faces if test(names[f.material_index], mw @ f.calc_center_median())]
    bmesh.ops.delete(bm, geom=kill, context="FACES")
    bm.to_mesh(body.data)
    bm.free()
    return len(kill)


def build_windshield(mats):
    """The source windshield was inside the police-cabin cut; rebuild it in the
    opening (cowl ~1.29 m to header ~1.745 m), set 12 mm inside the frame."""
    order = list(mats.keys())
    Gl = order.index("Glass")
    base = Vector((0, 0.97, 1.268))
    top = Vector((0, 0.40, 1.775))
    along = (top - base)
    L = along.length
    along.normalize()
    n = Vector((0, -along.z, along.y)).normalized()
    if n.y < 0:
        n = -n
    bm = bmesh.new()
    rows = []
    for t, hw in ((0.02, 0.835), (0.38, 0.795), (0.745, 0.70)):
        p = base + along * t - n * 0.012          # t in metres up the glass
        rows.append([bm.verts.new(p + Vector((x, 0, 0))) for x in (-hw, -hw / 3, hw / 3, hw)])
    for i in range(2):
        for j in range(3):
            f = bm.faces.new((rows[i][j], rows[i][j + 1], rows[i + 1][j + 1], rows[i + 1][j]))
            f.material_index = Gl
    me = bpy.data.meshes.new("Windshield")
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new("Windshield", me)
    bpy.context.collection.objects.link(ob)
    for k in order:
        me.materials.append(mats[k])
    return ob


def build_fuel_door(mats):
    """Round fuel door on the left rear quarter (behind/above the rear arch)."""
    order = list(mats.keys())
    bm = bmesh.new()
    for r, depth, mi, off in ((0.092, 0.004, order.index("Black"), 0.002), (0.085, 0.007, order.index("Paint"), 0.004)):
        tmp = bmesh.new()
        bmesh.ops.create_cone(tmp, cap_ends=True, segments=16, radius1=r, radius2=r, depth=depth)
        bmesh.ops.rotate(tmp, verts=tmp.verts, cent=(0, 0, 0), matrix=Matrix.Rotation(math.pi / 2, 3, "Y"))
        bmesh.ops.translate(tmp, vec=Vector((-0.975 - off, -2.16, 0.98)), verts=tmp.verts)
        for f in tmp.faces:
            f.material_index = mi
        me = bpy.data.meshes.new("_f")
        tmp.to_mesh(me)
        tmp.free()
        bm.from_mesh(me)
        bpy.data.meshes.remove(me)
    me = bpy.data.meshes.new("FuelDoor")
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new("FuelDoor", me)
    bpy.context.collection.objects.link(ob)
    for k in order:
        me.materials.append(mats[k])
    return ob


def build_wheel_wells(mats, wheels):
    """Black inner-fender wells that close the wheel openings completely:
    arched roof over the tyre, inner wall down to the bottom of the body,
    front and rear walls, plus a flat black underbody between the wells so
    you can't see through the truck from any low angle."""
    order = list(mats.keys())
    K = order.index("Black")
    bm = bmesh.new()
    segs = 14
    z_bot = 0.40                          # bottom edge of the body / rockers
    def quad(a, b, c, d):
        f = bm.faces.new([bm.verts.new(v) for v in (a, b, c, d)])
        f.material_index = K
    ys = []
    for (c, dia) in wheels:
        side = 1.0 if c.x > 0 else -1.0
        front = c.y > 0
        r = ARCH_R + 0.012                # just outside the new arch opening
        zc = c.z
        # outer edge just inside the fender skin (front ~0.92, rear ~0.966)
        x_in, x_out = side * (0.50 if front else 0.56), side * (0.905 if front else 0.95)
        a0 = math.asin(max(-1.0, min(1.0, (z_bot - zc) / r)))
        a1 = math.pi - a0
        arc_in, arc_out = [], []
        for i in range(segs + 1):
            a = a0 + (a1 - a0) * i / segs
            y = c.y + r * math.cos(a)
            z = zc + r * math.sin(a)
            arc_in.append(bm.verts.new((x_in, y, z)))
            arc_out.append(bm.verts.new((x_out, y, z)))
        for i in range(segs):
            f = bm.faces.new((arc_in[i], arc_out[i], arc_out[i + 1], arc_in[i + 1]))
            f.material_index = K
        f = bm.faces.new(arc_in)          # inner wall closed along the bottom
        f.material_index = K
        ys.append((c.y, r))
    # underbody: centre strip full length plus between-axle sides
    yf = max(y for y, _ in ys) + 0.55
    yr = min(y for y, _ in ys) - 0.55
    quad((-0.56, yr, 0.66), (-0.56, yf, 0.66), (0.56, yf, 0.66), (0.56, yr, 0.66))       # floor pan
    fy = max(y for y, _ in ys) - 0.58
    ry = min(y for y, _ in ys) + 0.58
    for sx in (-1, 1):
        quad((sx * 0.56, ry, 0.62), (sx * 0.56, fy, 0.62), (sx * 0.96, fy, 0.62), (sx * 0.96, ry, 0.62))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bmesh.ops.triangulate(bm, faces=bm.faces)
    me = bpy.data.meshes.new("Wells")
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new("Wells", me)
    bpy.context.collection.objects.link(ob)
    for k in order:
        me.materials.append(mats[k])
    return ob


ARCH_R = 0.475          # wheel opening radius (tyre r 0.387): ~9 cm above the tyre like the real truck


def fill_small_holes(body, mats):
    """Badge removal left a few small holes (they showed as black slots)."""
    order = list(mats.keys())
    bm = bmesh.new()
    bm.from_mesh(body.data)
    before = len(bm.faces)
    edges = [e for e in bm.edges if e.is_boundary]
    res = bmesh.ops.holes_fill(bm, edges=edges, sides=10)
    big = [f for f in res["faces"] if f.calc_area() > 0.015]
    for f in res["faces"]:
        f.material_index = order.index("Paint")
    bmesh.ops.delete(bm, geom=big, context="FACES_ONLY")
    bm.to_mesh(body.data)
    bm.free()
    return len(body.data.polygons) - before


def deform_arches(body, wheels):
    """Pull the source model's loose wheel openings in to ARCH_R by moving the
    fender's own vertices (blending out to R_OUT). Runs on the dense source
    mesh before decimation so the arch edge is finely sampled. The original
    opening edge is measured by ray-casting the painted fender."""
    me = body.data
    names = [m.name for m in me.materials]
    paint_v = set()
    for p in me.polygons:
        if names[p.material_index] == "Paint":
            paint_v.update(p.vertices)
    R_OUT = 0.78
    NA = 49
    moved = 0
    for (c, dia) in wheels:
        side = 1.0 if c.x > 0 else -1.0
        zc = c.z
        angs = [-0.25 + (math.pi + 0.5) * k / (NA - 1) for k in range(NA)]
        edge = []
        for a in angs:
            re = 0.575
            r = 0.40
            while r < 0.74:
                y, z = c.y + r * math.cos(a), zc + r * math.sin(a)
                if z < 0.36:
                    break
                hit, loc, n, idx = body.ray_cast(Vector((side * 3.0, y, z)), Vector((-side, 0, 0)))
                if hit and abs(loc.x) > 0.84 and names[me.polygons[idx].material_index] == "Paint":
                    re = r
                    break
                r += 0.004
            edge.append(min(0.70, max(0.47, re)))
        edge = [sorted(edge[max(0, k - 2):k + 3])[len(edge[max(0, k - 2):k + 3]) // 2] for k in range(NA)]
        log("arch edge", "F" if c.y > 0 else "R", "L" if side < 0 else "R", " ".join("%.2f" % e for e in edge[::4]))
        def edge_at(a):
            t = (a - angs[0]) / (angs[-1] - angs[0]) * (NA - 1)
            t = min(NA - 1.001, max(0.0, t))
            k = int(t)
            return edge[k] + (edge[k + 1] - edge[k]) * (t - k)
        for v in me.vertices:
            if v.index not in paint_v or v.co.x * side < 0.70 or v.co.z < 0.36:
                continue
            dy, dz = v.co.y - c.y, v.co.z - zc
            r, a = math.hypot(dy, dz), math.atan2(dz, dy)
            if r >= R_OUT or r < 0.30 or a < angs[0] or a > angs[-1]:
                continue
            ro = edge_at(a)
            e2 = ARCH_R + 0.01
            if r <= ro + 0.01:
                r2 = r - (ro - ARCH_R)
            else:
                t = (r - ro - 0.01) / (R_OUT - ro - 0.01)
                r2 = e2 + t * (R_OUT - e2)
            v.co.y = c.y + r2 * math.cos(a)
            v.co.z = zc + r2 * math.sin(a)
            moved += 1
    me.update()
    return moved


def recolour(body, mats, test, new):
    order = list(mats.keys())
    names = [m.name for m in body.data.materials]
    n = 0
    for p in body.data.polygons:
        if test(names[p.material_index], p.center):
            p.material_index = order.index(new)
            n += 1
    return n


def build_arch_panels(mats, wheels, body):
    """The source model's wheel openings are ~0.57 m radius, far looser than
    the real GMT400 (about 9 cm above the tyre). Body-colour panels follow the
    fender surface (ray-cast) and close the opening down to ARCH_R. They are
    Paint so the two-tone pass cuts the tan / black band / pinstripes on them."""
    order = list(mats.keys())
    P = order.index("Paint")
    bm = bmesh.new()
    segs = 16
    r_out = 0.64
    z_bot = 0.40
    for (c, dia) in wheels:
        side = 1.0 if c.x > 0 else -1.0
        zc = c.z
        default_x = 0.915 if c.y > 0 else 0.962
        a0 = math.asin(max(-1.0, min(1.0, (z_bot - zc) / ARCH_R)))
        inner, outer = [], []
        for i in range(segs + 1):
            a = a0 + (math.pi - 2 * a0) * i / segs
            yo, zo = c.y + r_out * math.cos(a), max(z_bot - 0.01, zc + r_out * math.sin(a))
            hit, loc, n, idx = body.ray_cast(Vector((side * 3.0, yo, zo)), Vector((-side, 0, 0)))
            x = abs(loc.x) if hit and 0.85 < abs(loc.x) < 1.02 else default_x
            x = side * (x + 0.003)
            outer.append(bm.verts.new((x, yo, zo)))
            inner.append(bm.verts.new((x, c.y + ARCH_R * math.cos(a), zc + ARCH_R * math.sin(a))))
        for i in range(segs):
            f = bm.faces.new((inner[i], inner[i + 1], outer[i + 1], outer[i]))
            f.material_index = P
            if f.normal.x * side < 0:
                f.normal_flip()
    me = bpy.data.meshes.new("ArchPanels")
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new("ArchPanels", me)
    bpy.context.collection.objects.link(ob)
    for k in order:
        me.materials.append(mats[k])
    return ob


def build_arch_moldings(mats, wheels, arch):
    """Bright wheel-opening molding around each arch (LS/LT trim) with a black
    inward lip that meets the liner."""
    order = list(mats.keys())
    C, K = order.index("Chrome"), order.index("Black")
    bm = bmesh.new()
    segs = 32
    z_bot = 0.40
    # profile across the molding: (radial offset from the opening, x offset from the fender skin)
    prof = [(0.024, 0.002), (0.016, 0.007), (0.007, 0.009), (0.001, 0.006), (-0.002, -0.002),
            (0.0, -0.022), (0.0, -0.045)]
    pm = [C, C, C, C, C, K]
    for wi, (c, dia) in enumerate(wheels):
        side = 1.0 if c.x > 0 else -1.0
        zc = c.z
        a0 = math.asin(max(-1.0, min(1.0, (z_bot - zc) / ARCH_R)))
        rows = []
        for i in range(segs + 1):
            a = a0 + (math.pi - 2 * a0) * i / segs
            ca, sa = math.cos(a), math.sin(a)
            best = None
            for dr in (0.006, 0.02, 0.04):         # outermost point of the lip near the edge
                hit, loc, n, idx = arch.ray_cast(Vector((side * 3.0, c.y + (ARCH_R + dr) * ca, zc + (ARCH_R + dr) * sa)),
                                                 Vector((-side, 0, 0)))
                if hit and 0.84 < abs(loc.x) < 1.02 and \
                        arch.data.materials[arch.data.polygons[idx].material_index].name == "Paint":
                    best = abs(loc.x) if best is None else max(best, abs(loc.x))
            x = side * (best if best is not None else (0.915 if c.y > 0 else 0.962))
            rows.append([bm.verts.new((x + side * dx, c.y + (ARCH_R + dr) * ca, zc + (ARCH_R + dr) * sa))
                         for (dr, dx) in prof])
        for i in range(segs):
            for j, mi in enumerate(pm):
                f = bm.faces.new((rows[i][j], rows[i + 1][j], rows[i + 1][j + 1], rows[i][j + 1]))
                f.material_index = mi
    me = bpy.data.meshes.new("ArchMoldings")
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new("ArchMoldings", me)
    bpy.context.collection.objects.link(ob)
    for k in order:
        me.materials.append(mats[k])
    for p in me.polygons:
        p.use_smooth = True
    me.set_sharp_from_angle(angle=math.radians(60))
    return ob


def build_roof_patch(mats):
    """Fill the hole left where the police overhead console/light-bar mount was
    cut out (over the front seats), following the roof crown."""
    order = list(mats.keys())
    P, H = order.index("Paint"), order.index("Headliner")
    bm = bmesh.new()
    xs = [-0.66 + 1.32 * i / 6 for i in range(7)]
    y0, y1 = -0.46, 0.34
    crown = lambda x: 1.812 - 0.083 * x * x
    top = [(bm.verts.new((x, y0, crown(x) + 0.004)), bm.verts.new((x, y1, crown(x) + 0.004))) for x in xs]
    bot = [(bm.verts.new((x, y0, crown(x) - 0.03)), bm.verts.new((x, y1, crown(x) - 0.03))) for x in xs]
    for i in range(6):
        f = bm.faces.new((top[i][0], top[i + 1][0], top[i + 1][1], top[i][1]))   # faces up
        f.material_index = P
        f = bm.faces.new((bot[i][0], bot[i][1], bot[i + 1][1], bot[i + 1][0]))   # faces down (headliner)
        f.material_index = H
    # roof side edges: the source roof skin stops ~0.66 m out but the side glass
    # tops sit at ~0.80 m, leaving a strip where the headliner showed through
    for sx in (-1, 1):
        ys_ = [-2.22 + 1.80 * i / 6 for i in range(7)]          # y -2.22 .. -0.42
        inner = [bm.verts.new((sx * 0.58, y, crown(0.58) + 0.004)) for y in ys_]
        outer = [bm.verts.new((sx * 0.81, y, 1.705)) for y in ys_]
        inner_b = [bm.verts.new((sx * 0.58, y, crown(0.58) - 0.03)) for y in ys_]
        outer_b = [bm.verts.new((sx * 0.80, y, 1.69)) for y in ys_]
        for i in range(6):
            f = bm.faces.new((inner[i], outer[i], outer[i + 1], inner[i + 1]))
            f.material_index = P
            f = bm.faces.new((inner_b[i], inner_b[i + 1], outer_b[i + 1], outer_b[i]))
            f.material_index = H
    bm.normal_update()
    for f in bm.faces:
        want = 1 if f.material_index == P else -1
        if f.normal.z * want < 0:
            f.normal_flip()
    me = bpy.data.meshes.new("RoofPatch")
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new("RoofPatch", me)
    bpy.context.collection.objects.link(ob)
    for k in order:
        me.materials.append(mats[k])
    return ob


def build_steering_wheel(mats, centre):
    """Steering wheel as its own object, origin at the hub, rim in the local
    XZ plane facing -Y (towards the driver) after the column tilt."""
    order = list(mats.keys())
    B, D = order.index("Black"), order.index("Dash")
    bm = bmesh.new()
    r, tube, segs = 0.19, 0.016, 20
    ring = bmesh.ops.create_circle(bm, cap_ends=False, radius=r, segments=segs)
    # sweep a small square section around the rim
    bm.free()
    bm = bmesh.new()
    prev = None
    first = None
    for i in range(segs + 1):
        a = 2 * math.pi * i / segs
        c = Vector((math.cos(a) * r, 0, math.sin(a) * r))
        out = Vector((math.cos(a), 0, math.sin(a)))
        quad = [bm.verts.new(c + out * tube), bm.verts.new(c + Vector((0, tube, 0))),
                bm.verts.new(c - out * tube), bm.verts.new(c - Vector((0, tube, 0)))]
        if prev:
            for j in range(4):
                f = bm.faces.new((prev[j], prev[(j + 1) % 4], quad[(j + 1) % 4], quad[j]))
                f.material_index = B
        prev = quad
    # airbag hub (the '95-'99 rounded-rectangle pad) and four spokes
    add_box(bm, (0.17, 0.065, 0.13), (0, -0.022, 0.005), D)
    for ang in (0, 180, 235, 305):
        a = math.radians(ang)
        mid = Vector((math.cos(a), 0, math.sin(a))) * (r * 0.55)
        add_box(bm, (r * 0.85, 0.02, 0.035), (mid.x, 0, mid.z), D, Matrix.Rotation(-a, 3, "Y"))
    me = bpy.data.meshes.new("SteeringWheel")
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new("SteeringWheel", me)
    bpy.context.collection.objects.link(ob)
    for k in order:
        me.materials.append(mats[k])
    ob.location = centre
    ob.rotation_euler = (math.radians(-24), 0, 0)      # column rake
    for p in me.polygons:
        p.use_smooth = True
    return ob


# ----------------------------------------------------------------- wheel
def lathe(bm, prof, segs, mi):
    rings = []
    for i in range(segs):
        a = 2 * math.pi * i / segs
        rings.append([bm.verts.new((x, r * math.cos(a), r * math.sin(a))) for r, x in prof])
    for i in range(segs):
        a, b = rings[i], rings[(i + 1) % segs]
        for j in range(len(prof) - 1):
            f = bm.faces.new((a[j], b[j], b[j + 1], a[j + 1]))
            f.material_index = mi


def build_wheel(mats):
    """1995-99 GM 16x7 aluminium wheel on LT245/75R16 (r = 0.387 m), ~520 tris:
    flat machined face with five dark pockets near the rim, raised centre cap,
    six lug nuts."""
    bm = bmesh.new()
    segs = 18
    lathe(bm, [(0.205, -0.11), (0.33, -0.126), (0.378, -0.106), (0.387, -0.07),
               (0.387, 0.07), (0.378, 0.106), (0.33, 0.126), (0.205, 0.11)], 24, 0)
    lathe(bm, [(0.203, -0.05), (0.203, 0.082), (0.210, 0.099), (0.192, 0.096)], segs, 1)   # rim lip
    lathe(bm, [(0.192, 0.088), (0.150, 0.094), (0.085, 0.097), (0.072, 0.104)], segs, 1)   # flat face
    lathe(bm, [(0.072, 0.104), (0.055, 0.112), (0.0, 0.114)], 12, 1)                      # centre cap
    # five dark pockets around the outer face
    for k in range(5):
        a0 = 2 * math.pi * k / 5 + 0.18
        a1 = a0 + 0.62
        r0, r1 = 0.118, 0.178
        x = 0.0975
        q = [Vector((x, r0 * math.cos(a0), r0 * math.sin(a0))), Vector((x, r1 * math.cos(a0 - 0.05), r1 * math.sin(a0 - 0.05))),
             Vector((x, r1 * math.cos(a1 + 0.05), r1 * math.sin(a1 + 0.05))), Vector((x, r0 * math.cos(a1), r0 * math.sin(a1)))]
        vs = [bm.verts.new(v) for v in q]
        f = bm.faces.new(vs)
        f.material_index = 2
    # six lug nuts
    for k in range(6):
        a = 2 * math.pi * k / 6
        tmp = bmesh.new()
        bmesh.ops.create_cone(tmp, cap_ends=False, segments=6, radius1=0.011, radius2=0.011, depth=0.016)
        bmesh.ops.rotate(tmp, verts=tmp.verts, cent=(0, 0, 0), matrix=Matrix.Rotation(math.pi / 2, 3, "Y"))
        bmesh.ops.translate(tmp, vec=Vector((0.104, 0.062 * math.cos(a), 0.062 * math.sin(a))), verts=tmp.verts)
        for f in tmp.faces:
            f.material_index = 1
        me = bpy.data.meshes.new("_l")
        tmp.to_mesh(me)
        tmp.free()
        bm.from_mesh(me)
        bpy.data.meshes.remove(me)
    me = bpy.data.meshes.new("Wheel")
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new("Wheel", me)
    bpy.context.collection.objects.link(ob)
    for k in ("Tire", "Rim", "Hub"):
        me.materials.append(mats[k])
    for p in me.polygons:
        p.use_smooth = True
    me.set_sharp_from_angle(angle=math.radians(40))
    return ob


# ----------------------------------------------------------------- main
def main():
    argv = sys.argv[sys.argv.index("--") + 1:]
    src, out = argv[0], argv[1]
    render = argv[argv.index("--render") + 1] if "--render" in argv else ""
    meshes = import_and_normalise(src)
    # overall bounds -> recentre and scale to the real length
    mn = Vector((1e9,) * 3)
    mx = Vector((-1e9,) * 3)
    for o in meshes:
        a, b = world_bbox(o)
        mn = Vector(map(min, mn, a))
        mx = Vector(map(max, mx, b))
    wheels = find_wheels(meshes)
    wys = sorted({round(w[0].y, 2) for w in wheels})
    log("source bounds", tuple(round(v, 3) for v in mn), tuple(round(v, 3) for v in mx), "wheel y", wys)
    length = mx.y - mn.y
    s = REAL_LENGTH / length
    front_wheel_y = max(w[0].y for w in wheels)
    rear_wheel_y = min(w[0].y for w in wheels)
    mid_y = (front_wheel_y + rear_wheel_y) / 2
    cx = (mn.x + mx.x) / 2
    M = Matrix.Scale(s, 4) @ Matrix.Translation((-cx, -mid_y, -mn.z))
    for o in meshes:
        o.data.transform(M)
    wheels = [((M @ c), d * s) for c, d in wheels]
    log("scale", round(s, 4), "wheelbase now", round((front_wheel_y - rear_wheel_y) * s, 3))
    length *= s
    front_y = length / 2 + 0.0      # approx front face
    a, b = Vector((1e9,) * 3), Vector((-1e9,) * 3)
    for o in meshes:
        p, q = world_bbox(o)
        a = Vector(map(min, a, p))
        b = Vector(map(max, b, q))
    front_y = b.y
    log("normalised bounds", tuple(round(v, 3) for v in a), tuple(round(v, 3) for v in b))
    global SCALE_Z
    SCALE_Z = s
    cabin = (Vector((-0.80, -2.0, 0.55)), Vector((0.80, front_y - 1.15, 1.785)))   # up to the roof skin
    meshes = strip(meshes, wheels, cabin)
    meshes = remove_badges(meshes, length)
    mats = _texture_lamps(make_materials())
    remap_materials(meshes, mats, front_y)
    body = join(meshes, "Body")
    symmetrise(body)
    log("filled small holes: %d faces" % fill_small_holes(body, mats))
    log("arch vertices moved: %d" % deform_arches(body, [w for w in wheels if w[0].x > 0]))
    symmetrise(body)                  # left arches = mirror of the reshaped right ones
    log("body tris before reduce:", tri_count(body))
    reduce(body, TARGET_BODY_TRIS)
    log("filled small holes after reduce: %d faces" % fill_small_holes(body, mats))
    # two-tone bands, black molding band and pinstripes are now drawn by the
    # game's body-paint shader (crisper, no extra geometry) — no mesh cuts
    log("door handles -> black: %d" % recolour(body, mats, lambda m, c: m == "Chrome" and abs(c.x) > 0.85
                                                and 0.92 < c.z < 1.18 and -1.6 < c.y < 0.7, "Black"))
    nf = delete_faces(body, lambda m, c: m in ("Black", "Chrome") and c.y > 1.95 and c.z < 0.76)
    nr = delete_faces(body, lambda m, c: m in ("Black", "Chrome") and c.y < -2.42 and c.z < 0.73)
    log("removed source bumpers: front %d rear %d faces" % (nf, nr))
    fy, hw = front_face_y(body)
    log("nose face y %.3f half-width %.3f" % (fy, hw))
    nn = delete_faces(body, lambda m, c: m not in ("Paint", "Lower", "Stripe") and c.y > 1.95
                      and 0.70 < c.z < 1.12 and abs(c.x) < 0.95)
    log("removed source lamp/grille housings: %d faces" % nn)
    fascia = build_fascia(mats, fy + 0.004, hw)
    wells = build_wheel_wells(mats, wheels)
    fuel = build_fuel_door(mats)
    roof = build_roof_patch(mats)
    bumpers = build_bumpers(mats)
    moldings = build_arch_moldings(mats, wheels, body)
    glass = build_windshield(mats)
    body = join([body, fascia, wells, fuel, roof, bumpers, glass], "Body")
    for p in body.data.polygons:
        p.use_smooth = True
    body.data.set_sharp_from_angle(angle=math.radians(35))
    log("body tris final:", tri_count(body))
    cowl_y = front_y - 1.48
    interior, col_top = build_interior(mats, cowl_y, 1.20, front_y)
    sw = build_steering_wheel(mats, col_top)
    wheel = build_wheel(mats)
    total = tri_count(body) + tri_count(interior) + tri_count(sw) + tri_count(moldings) + 4 * tri_count(wheel)
    log(f"TRIANGLES body {tri_count(body)} interior {tri_count(interior)} steering {tri_count(sw)} "
        f"wheel {tri_count(wheel)} x4 => TOTAL {total}")
    log("wheel centres:", [tuple(round(v, 3) for v in w[0]) for w in wheels])
    os.makedirs(out, exist_ok=True)
    # body glb: Body + Interior + SteeringWheel (separate node so it can turn)
    bpy.ops.object.select_all(action="DESELECT")
    for o in (body, interior, sw, moldings):
        o.select_set(True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(out, "tahoe_body.glb"), export_format="GLB",
                              use_selection=True, export_apply=True, export_yup=True)
    bpy.ops.object.select_all(action="DESELECT")
    wheel.select_set(True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(out, "tahoe_wheel.glb"), export_format="GLB",
                              use_selection=True, export_apply=True, export_yup=True)
    # metadata for the game: steering wheel pivot + credits
    with open(os.path.join(out, "model_info.json"), "w") as f:
        import json
        json.dump({
            "source": "West Virginia State Police Chevy Tahoe 1996 by David_Holiday",
            "source_url": "https://sketchfab.com/3d-models/west-virginia-state-police-chevy-tahoe-1996-cd2b81eed57942c6b1c22049c4b036f2",
            "license": "CC-BY-4.0",
            "modifications": "Converted to factory paint, police equipment/livery/badges removed, decimated, new interior and wheels",
            "steering_wheel_pivot": [round(col_top.x, 4), round(col_top.z, 4), round(-col_top.y, 4)],
            "steering_rake_deg": 24,
            "driver_eye": [-0.38, 1.46, round(-(col_top.y - 0.55), 4)],
            "cluster": {k: ([round(v.x, 4), round(v.z, 4), round(-v.y, 4)] if hasattr(v, "x") else v)
                        for k, v in CLUSTER.items()},
            "triangles": total,
            # source model rode on bigger tyres (hub 0.415 m); on the factory
            # P245/75R16 (r 0.387) the body sits this much lower over the hubs
            "body_drop": round(-(sum(w[0].z for w in wheels) / len(wheels) - 0.387), 4),
        }, f, indent=2)
    global EYE_Y
    EYE_Y = col_top.y - 0.55
    if render:
        render_previews(body, interior, sw, wheel, wheels, render)


EYE_Y = 0.0


def render_previews(body, interior, sw, wheel, wheels, prefix):
    for (c, d) in wheels:
        inst = bpy.data.objects.new("W", wheel.data)
        bpy.context.collection.objects.link(inst)
        x = 0.814 if c.x > 0 else -0.814
        inst.location = (x, c.y, 0.387)
        if x < 0:
            inst.scale = (-1, 1, 1)
    wheel.hide_render = True
    scn = bpy.context.scene
    scn.render.engine = "CYCLES"
    scn.cycles.samples = 40
    scn.cycles.use_denoising = True
    scn.render.resolution_x = 1280
    scn.render.resolution_y = 720
    w = bpy.data.worlds.new("W")
    scn.world = w
    w.use_nodes = True
    sky = w.node_tree.nodes.new("ShaderNodeTexSky")
    sky.sky_type = "NISHITA"
    sky.sun_elevation = math.radians(35)
    sky.sun_rotation = math.radians(200)
    w.node_tree.links.new(sky.outputs["Color"], w.node_tree.nodes["Background"].inputs["Color"])
    w.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.35
    sun = bpy.data.lights.new("Sun", "SUN")
    sun.energy = 3.0
    so = bpy.data.objects.new("Sun", sun)
    so.rotation_euler = (math.radians(50), 0, math.radians(-35))
    scn.collection.objects.link(so)
    bpy.ops.mesh.primitive_plane_add(size=40)
    fl = bpy.context.active_object
    fl.data.materials.append(mat("Floor", (0.35, 0.35, 0.36), 0.0, 0.35))
    cam_d = bpy.data.cameras.new("C")
    cam = bpy.data.objects.new("C", cam_d)
    scn.collection.objects.link(cam)
    scn.camera = cam
    views = {
        "photo": ((-3.0, 4.7, 1.15), (0.3, -0.8, 0.95), 26),
        "right34": ((3.4, 4.7, 1.7), (-0.45, -0.8, 0.85), 26),
        "side": ((-9.5, 0.0, 1.1), (0, 0.0, 0.9), 50),
        "rear34": ((4.5, -6.5, 1.8), (0, -0.4, 0.9), 35),
        "cockpit": ((-0.38, EYE_Y, 1.46), (-0.3, 3.5, 1.15), 18),
    }
    for k, (loc, tgt, lens) in views.items():
        cam.location = loc
        cam.rotation_euler = (Vector(tgt) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()
        cam_d.lens = lens
        scn.render.filepath = f"{prefix}_{k}.png"
        bpy.ops.render.render(write_still=True)


if __name__ == "__main__":
    main()
