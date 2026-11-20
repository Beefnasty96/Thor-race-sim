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
  6. Export assets/cars/tahoe_1996/tahoe_body.glb (+ steering wheel node) and
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
TARGET_BODY_TRIS = 4300

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


def make_materials():
    return {
        "Paint": mat("Paint", srgb(0.17, 0.22, 0.42), 0.55, 0.28),       # Indigo Blue Metallic
        "Lower": mat("Lower", srgb(0.62, 0.52, 0.40), 0.5, 0.32),        # Light Autumnwood
        "Stripe": mat("Stripe", srgb(0.13, 0.13, 0.14), 0.25, 0.45),
        "Chrome": mat("Chrome", (0.9, 0.9, 0.92), 1.0, 0.08),
        "Glass": mat("Glass", srgb(0.05, 0.06, 0.07), 0.0, 0.05, alpha=0.55),
        "Black": mat("Black", srgb(0.07, 0.07, 0.075), 0.0, 0.6),
        "Headlamp": mat("Headlamp", (0.82, 0.84, 0.86), 0.6, 0.06, (1.0, 0.98, 0.9), 0.15),
        "Amber": mat("Amber", srgb(0.95, 0.55, 0.12), 0.2, 0.15, (1.0, 0.5, 0.05), 0.2),
        "Taillight": mat("Taillight", srgb(0.7, 0.05, 0.04), 0.2, 0.12, (0.9, 0.02, 0.0), 0.3),
        "Interior": mat("Interior", srgb(0.42, 0.40, 0.37), 0.0, 0.85),   # neutral/grey cloth
        "Headliner": mat("Headliner", srgb(0.62, 0.60, 0.56), 0.0, 0.95),
        "Dash": mat("Dash", srgb(0.13, 0.13, 0.14), 0.0, 0.65),
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
        # interior: anything wholly inside the cabin volume
        if (cabin[0].x < mn.x and mx.x < cabin[1].x and cabin[0].y < mn.y and mx.y < cabin[1].y
                and cabin[0].z < mn.z and mx.z < cabin[1].z):
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
    if nose and abs(centre.x) > 0.5 and name not in GLASS:
        # stacked composite lamps; amber section at the outer end of the lower lamp
        if abs(centre.x) > 0.84 and centre.z < 0.90:
            return "Amber"
        return "Headlamp"
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
        if name == "material" and centre.z > 1.24 and abs(normal.z) < 0.6:
            return "Black"                       # window frames, blacked-out B/C pillars
        return "Paint"
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
    for z in (0.58, 0.69, 0.75):
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
        if c.z < 0.58:
            f.material_index = li
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
    """1995-99 GMT400 interior, semi-accurate: wide flat-topped dash with a
    hooded instrument cluster in front of the driver, centre stack (radio over
    HVAC), glovebox, steering column, 4-spoke airbag steering wheel, bucket
    seats and a rear bench. Driver sits on the LEFT (-X)."""
    order = list(mats.keys())
    D, I, B, G, C = (order.index(k) for k in ("Dash", "Interior", "Black", "Gauge", "Chrome"))
    bm = bmesh.new()
    dash_y = cowl_y - 0.42           # dash face (deep '95-'99 dash)
    tilt = Matrix.Rotation(math.radians(-12), 3, "X")
    # dash top pad and lower face
    add_box(bm, (1.70, 0.46, 0.10), (0, dash_y + 0.13, belt_z - 0.02), D)   # top pad ahead of the cluster
    add_box(bm, (1.66, 0.12, 0.34), (0, dash_y - 0.12, belt_z - 0.24), D, tilt)
    # instrument cluster hood + gauge face (speedo centre, tach right, small gauges left)
    add_box(bm, (0.50, 0.16, 0.06), (-0.38, dash_y - 0.06, belt_z + 0.06), D)
    add_box(bm, (0.46, 0.02, 0.15), (-0.38, dash_y - 0.135, belt_z - 0.04), G, tilt)
    global CLUSTER
    face = Vector((-0.38, dash_y - 0.147, belt_z - 0.04))
    CLUSTER = {"speedo": face + Vector((-0.02, 0, 0)), "tach": face + Vector((0.14, 0, 0)),
               "small": face + Vector((-0.17, 0, 0)), "tilt_deg": -12}
    # centre stack: radio + HVAC with chrome-ish trim, then floor console
    add_box(bm, (0.30, 0.10, 0.30), (0.02, dash_y - 0.16, belt_z - 0.25), D, tilt)
    add_box(bm, (0.20, 0.02, 0.05), (0.02, dash_y - 0.215, belt_z - 0.17), G, tilt)    # radio display
    add_box(bm, (0.22, 0.02, 0.08), (0.02, dash_y - 0.24, belt_z - 0.31), B, tilt)    # HVAC knobs
    add_box(bm, (0.30, 0.55, 0.22), (0.0, dash_y - 0.75, 0.80), D)                    # console
    # glovebox outline
    add_box(bm, (0.42, 0.02, 0.16), (0.48, dash_y - 0.175, belt_z - 0.22), B, tilt)
    # steering column
    col_top = Vector((-0.38, dash_y - 0.28, belt_z - 0.06))
    add_box(bm, (0.08, 0.36, 0.08), (-0.38, dash_y - 0.15, belt_z - 0.12),
            B, Matrix.Rotation(math.radians(24), 3, "X"))
    # floor + carpet, seats
    eye_y = col_top.y - 0.55
    back_y = eye_y - 0.16
    add_box(bm, (1.70, 2.9, 0.04), (0, cowl_y - 1.75, 0.62), B)
    for x in (-0.42, 0.42):
        add_box(bm, (0.52, 0.50, 0.14), (x, back_y + 0.28, 0.86), I)
        add_box(bm, (0.50, 0.13, 0.62), (x, back_y - 0.02, 1.20), I,
                Matrix.Rotation(math.radians(-10), 3, "X"))
        add_box(bm, (0.26, 0.10, 0.18), (x, back_y - 0.08, 1.58), I)
    add_box(bm, (1.55, 0.55, 0.14), (0, back_y - 0.62, 0.86), I)
    add_box(bm, (1.55, 0.14, 0.58), (0, back_y - 0.94, 1.18), I)
    # headliner under the roof skin (hides the inside of the roof and old police console)
    H = order.index("Headliner")
    add_box(bm, (1.66, cowl_y - 0.95 - (-2.55), 0.02), (0, (cowl_y - 0.95 + -2.55) / 2, 1.745), H)
    # sun visors
    for x in (-0.40, 0.40):
        add_box(bm, (0.40, 0.17, 0.02), (x, cowl_y - 1.02, 1.715), H, Matrix.Rotation(math.radians(10), 3, "X"))
    # door panels (inner)
    for s in (-1, 1):
        add_box(bm, (0.04, 2.1, 0.45), (s * 0.86, cowl_y - 1.3, 0.92), D)
    me = bpy.data.meshes.new("Interior")
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new("Interior", me)
    bpy.context.collection.objects.link(ob)
    for k in order:
        me.materials.append(mats[k])
    return ob, col_top


CLUSTER = {}


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
    add_box(bm, (0.15, 0.06, 0.11), (0, -0.02, 0), D)
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
    """16 in aluminium 5-spoke on LT245/75R16 (r = 0.387 m), ~300 triangles."""
    bm = bmesh.new()
    lathe(bm, [(0.205, -0.11), (0.33, -0.125), (0.381, -0.10), (0.387, -0.06), (0.387, 0.06),
               (0.381, 0.10), (0.33, 0.125), (0.205, 0.11)], 14, 0)
    lathe(bm, [(0.203, -0.05), (0.203, 0.08), (0.209, 0.098), (0.185, 0.091)], 14, 1)
    lathe(bm, [(0.185, 0.05), (0.06, 0.05)], 8, 2)
    for k in range(5):
        a = 2 * math.pi * k / 5 + math.pi / 2
        tmp = bmesh.new()
        bmesh.ops.create_cube(tmp, size=1.0)
        bmesh.ops.scale(tmp, vec=Vector((0.03, 0.13, 0.075)), verts=tmp.verts)
        for v in tmp.verts:
            v.co.z *= 1.4 if v.co.y > 0 else 0.7
        bmesh.ops.translate(tmp, vec=Vector((0.075, 0.12, 0)), verts=tmp.verts)
        bmesh.ops.rotate(tmp, verts=tmp.verts, cent=(0, 0, 0), matrix=Matrix.Rotation(a, 3, "X"))
        for f in tmp.faces:
            f.material_index = 1
        me = bpy.data.meshes.new("_s")
        tmp.to_mesh(me)
        tmp.free()
        bm.from_mesh(me)
        bpy.data.meshes.remove(me)
    lathe(bm, [(0.075, 0.07), (0.055, 0.098), (0.0, 0.102)], 8, 1)
    me = bpy.data.meshes.new("Wheel")
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new("Wheel", me)
    bpy.context.collection.objects.link(ob)
    for k in ("Tire", "Rim", "Hub"):
        me.materials.append(mats[k])
    for p in me.polygons:
        p.use_smooth = True
    me.set_sharp_from_angle(angle=math.radians(50))
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
    mats = make_materials()
    remap_materials(meshes, mats, front_y)
    body = join(meshes, "Body")
    symmetrise(body)
    log("body tris before reduce:", tri_count(body))
    reduce(body, TARGET_BODY_TRIS)
    two_tone(body, mats)
    for p in body.data.polygons:
        p.use_smooth = True
    body.data.set_sharp_from_angle(angle=math.radians(35))
    log("body tris final:", tri_count(body))
    cowl_y = front_y - 1.48
    interior, col_top = build_interior(mats, cowl_y, 1.20, front_y)
    sw = build_steering_wheel(mats, col_top)
    wheel = build_wheel(mats)
    total = tri_count(body) + tri_count(interior) + tri_count(sw) + 4 * tri_count(wheel)
    log(f"TRIANGLES body {tri_count(body)} interior {tri_count(interior)} steering {tri_count(sw)} "
        f"wheel {tri_count(wheel)} x4 => TOTAL {total}")
    log("wheel centres:", [tuple(round(v, 3) for v in w[0]) for w in wheels])
    os.makedirs(out, exist_ok=True)
    # body glb: Body + Interior + SteeringWheel (separate node so it can turn)
    bpy.ops.object.select_all(action="DESELECT")
    for o in (body, interior, sw):
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
