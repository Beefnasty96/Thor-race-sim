"""Blender model of the 1996 Chevrolet Tahoe 4-door (GMT400).

Run headless:
    python tools/blender/tahoe_1996.py --out assets/cars/tahoe_1996 [--render preview.png]

Built from real dimensions (wheelbase 117.5 in, length 199.1 in, width 77.1 in)
and matched to reference photos. Target detail: PS2 "Gran Turismo 4" era,
~10k triangles for the body. No manufacturer logos or badges.

Axes: Blender X = right, Y = forward, Z = up; origin on the ground midway
between the axles (the glTF exporter converts to Godot's -Z forward / Y up).
"""
import argparse
import math
import os
import sys

import bpy  # must come before bmesh
import bmesh
from mathutils import Matrix, Vector

# ---------------------------------------------------------------- dimensions
WB = 2.985                  # wheelbase
FRONT = WB / 2 + 0.93       # front face Y
REAR = -(WB / 2 + 1.142)    # rear face Y  (length 5.057 m)
YF = WB / 2                 # front axle Y
YR = -WB / 2
TRACK_F = 1.628
TRACK_R = 1.613
TIRE_R = 0.387              # 245/75R16 (1996 4WD factory size)
ARCH_R = 0.47               # arch top ~0.93 m, measured from reference photos
ARCH_Z = 0.46
COWL = 1.10                 # windshield base Y (above the front tire's rear edge)
ROOF_FRONT = 0.50           # windshield top Y (upright, like the GMT400)
BELT = 1.21


# ---------------------------------------------------------------- materials
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


def build_materials():
    srgb = lambda r, g, b: tuple(pow(c, 2.2) for c in (r, g, b))
    return {
        "Paint": mat("Paint", srgb(0.17, 0.22, 0.42), 0.55, 0.28),          # indigo blue metallic
        "Lower": mat("Lower", srgb(0.62, 0.52, 0.40), 0.5, 0.32),           # light autumnwood
        "Stripe": mat("Stripe", srgb(0.12, 0.12, 0.13), 0.2, 0.45),
        "Chrome": mat("Chrome", (0.9, 0.9, 0.92), 1.0, 0.08),
        "Glass": mat("Glass", srgb(0.03, 0.035, 0.04), 0.0, 0.05, alpha=0.62),
        "Black": mat("Black", srgb(0.06, 0.06, 0.065), 0.0, 0.62),
        "Rubber": mat("Rubber", srgb(0.03, 0.03, 0.03), 0.0, 0.85),
        "Headlamp": mat("Headlamp", (0.32, 0.33, 0.35), 1.0, 0.05, (1.0, 0.98, 0.9), 0.05),
        "Amber": mat("Amber", srgb(0.95, 0.55, 0.12), 0.2, 0.15, (1.0, 0.5, 0.05), 0.2),
        "Taillight": mat("Taillight", srgb(0.7, 0.05, 0.04), 0.2, 0.12, (0.9, 0.02, 0.0), 0.3),
        "Reverse": mat("Reverse", (0.9, 0.9, 0.9), 0.3, 0.1),
        "Grille": mat("Grille", srgb(0.05, 0.05, 0.055), 0.4, 0.4),
        "Interior": mat("Interior", srgb(0.45, 0.43, 0.40), 0.0, 0.9),
        "Tire": mat("Tire", srgb(0.07, 0.07, 0.07), 0.0, 0.9),
        "Rim": mat("Rim", srgb(0.78, 0.78, 0.8), 0.85, 0.22),
        "Hub": mat("Hub", srgb(0.15, 0.15, 0.16), 0.6, 0.5),
    }


# ---------------------------------------------------------------- helpers
def new_obj(name, bm, mats, smooth_angle=35.0):
    me = bpy.data.meshes.new(name)
    bm.normal_update()
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(ob)
    for m in mats:
        me.materials.append(m)
    for p in me.polygons:
        p.use_smooth = True
    me.set_sharp_from_angle(angle=math.radians(smooth_angle))
    return ob


def add_box(bm, size, loc, mi, bevel=0.0, rot=None):
    """Axis-aligned (optionally rotated) box, optional chamfer, material index mi."""
    tmp = bmesh.new()
    bmesh.ops.create_cube(tmp, size=1.0)
    bmesh.ops.scale(tmp, vec=Vector(size), verts=tmp.verts)
    if bevel > 0:
        bmesh.ops.bevel(tmp, geom=tmp.edges[:], offset=bevel, segments=1, affect="EDGES", profile=0.5)
    if rot:
        bmesh.ops.rotate(tmp, verts=tmp.verts, cent=(0, 0, 0), matrix=rot)
    bmesh.ops.translate(tmp, vec=Vector(loc), verts=tmp.verts)
    for f in tmp.faces:
        f.material_index = mi
    _merge(bm, tmp)


def _merge(bm, other):
    me = bpy.data.meshes.new("_tmp")
    other.to_mesh(me)
    other.free()
    bm.from_mesh(me)
    bpy.data.meshes.remove(me)


def add_cyl(bm, r, depth, loc, axis, mi, segs=16, r2=None):
    tmp = bmesh.new()
    bmesh.ops.create_cone(tmp, cap_ends=True, segments=segs, radius1=r, radius2=r2 if r2 is not None else r, depth=depth)
    if axis == "X":
        bmesh.ops.rotate(tmp, verts=tmp.verts, cent=(0, 0, 0), matrix=Matrix.Rotation(math.pi / 2, 3, "Y"))
    elif axis == "Y":
        bmesh.ops.rotate(tmp, verts=tmp.verts, cent=(0, 0, 0), matrix=Matrix.Rotation(math.pi / 2, 3, "X"))
    bmesh.ops.translate(tmp, vec=Vector(loc), verts=tmp.verts)
    for f in tmp.faces:
        f.material_index = mi
    _merge(bm, tmp)


def sweep(bm, path, section, mi, cap=True):
    """Sweep a cross-section (u = outward horizontal offset, v = height) along
    a plan-view path of (x, y) points. Outward = Z x tangent."""
    rings = []
    n = len(path)
    for i, (x, y) in enumerate(path):
        a = Vector(path[max(i - 1, 0)] + (0,))
        c = Vector(path[min(i + 1, n - 1)] + (0,))
        t = (c - a).normalized()
        out = Vector((0, 0, 1)).cross(t).normalized()
        rings.append([bm.verts.new((x + out.x * u, y + out.y * u, v)) for u, v in section])
    m = len(section)
    for r0, r1 in zip(rings[:-1], rings[1:]):
        for j in range(m):
            f = bm.faces.new((r0[j], r0[(j + 1) % m], r1[(j + 1) % m], r1[j]))
            f.material_index = mi
    if cap:
        for ring in (rings[0], list(reversed(rings[-1]))):
            f = bm.faces.new(ring)
            f.material_index = mi


def bumper_path(y_face, half_w, corner_r, wrap_back, front=True, segs=6):
    """Plan path across the vehicle face, curving back around both corners."""
    sgn = 1 if front else -1
    cx = half_w - corner_r
    cy = y_face - sgn * corner_r
    pts = [(-half_w, cy - sgn * wrap_back)]
    for i in range(segs + 1):
        th = math.pi - (math.pi / 2) * i / segs     # 180 -> 90 deg
        pts.append((-cx + corner_r * math.cos(th), cy + sgn * corner_r * math.sin(th)))
    for i in range(segs + 1):
        th = math.pi / 2 - (math.pi / 2) * i / segs # 90 -> 0 deg
        pts.append((cx + corner_r * math.cos(th), cy + sgn * corner_r * math.sin(th)))
    pts.append((half_w, cy - sgn * wrap_back))
    if not front:
        pts.reverse()
    return pts


def lerp(a, b, t):
    return a + (b - a) * t


# ---------------------------------------------------------------- body shell
MAT_ORDER = ["Paint", "Lower", "Stripe", "Chrome", "Glass", "Black", "Rubber", "Headlamp",
             "Amber", "Taillight", "Reverse", "Grille", "Interior"]
MI = {n: i for i, n in enumerate(MAT_ORDER)}

# greenhouse: near-vertical side glass, crisp drip-rail edge, wide flat roof
GH_FULL = [(0.928, 1.22), (0.922, 1.40), (0.912, 1.58), (0.898, 1.755),
           (0.872, 1.792), (0.55, 1.803), (0.0, 1.807)]
GH_COWL_X = [0.928, 0.92, 0.91, 0.875, 0.62, 0.50, 0.0]


def hood_z(y):
    t = max(0.0, min(1.0, (FRONT - y) / (FRONT - COWL)))
    return lerp(1.12, 1.20, math.sin(t * math.pi / 2))


def profile(y):
    """Half cross-section at station y: list of (x, z), bottom centre → roof centre."""
    ztop = hood_z(y) if y > COWL else BELT
    # corner rounding at the very front and back
    s = 1.0
    if y > FRONT - 0.06:
        s = 0.985
    if y < REAR + 0.05:
        s = 0.99
    # rocker 0.43 | tan 0.43-0.58 | dark stripe band 0.58-0.69 | tan 0.69-0.75 | body colour
    lower = [(0.0, 0.43), (0.90, 0.43), (0.965, 0.48), (0.973, 0.58), (0.975, 0.69),
             (0.976, 0.75), (0.978, ztop - 0.045), (0.975, ztop - 0.012), (0.958, ztop)]
    lower = [(x * s, z) for x, z in lower]
    if y >= COWL:
        gh = [(x * s, ztop + (0.022 if x < 0.55 else 0.004)) for x in GH_COWL_X]
    elif y > ROOF_FRONT:
        t = (COWL - y) / (COWL - ROOF_FRONT)
        cowl = [(x, BELT + 0.012 * (1 - (x / 0.95) ** 2) + 0.004) for x in GH_COWL_X]
        gh = [(lerp(c[0], f[0], t), lerp(c[1], f[1], t)) for c, f in zip(cowl, GH_FULL)]
    else:
        gh = list(GH_FULL)
        if y < REAR + 0.09:
            gh = [(x * 0.985, z - 0.012) for x, z in gh]
    return lower + gh


STATIONS = [FRONT, FRONT - 0.035, FRONT - 0.12, 1.95, YF + 0.30, YF,
            COWL + 0.012, COWL, 0.90, 0.70, ROOF_FRONT, 0.25, 0.0, -0.45, -0.85, -0.95, -1.03,
            YR, -1.80, -1.92, -2.2, REAR + 0.09, REAR + 0.035, REAR]

# window layout along Y (glass / pillar), strips 10..12 are the window band
def strip_material(k, y):
    """Profile strips: 0 underside, 1-2 and 4 lower two-tone, 3 dark stripe band,
    4-7 body side and shoulder, 8 window ledge, 9-11 side glass band,
    12 drip rail (A-pillar in the windshield zone), 13-14 roof or windshield."""
    if k == 0:
        return MI["Black"]
    if k in (1, 2, 4):
        return MI["Lower"]
    if k == 3:
        return MI["Stripe"]
    if k <= 7:
        return MI["Paint"]
    if y >= COWL:                       # hood
        return MI["Paint"]
    if k == 8:
        return MI["Black"]              # window seal along the belt
    if k in (9, 10, 11):                # side glass band
        if y < REAR + 0.09:
            return MI["Paint"]          # D-pillar
        if -0.95 < y <= -0.85 or -1.92 < y <= -1.80:
            return MI["Black"]          # blacked-out B and C pillars
        return MI["Glass"]
    if k == 12:
        return MI["Paint"]              # drip rail / A-pillar
    if ROOF_FRONT < y < COWL:
        return MI["Glass"]              # windshield
    return MI["Paint"]                  # roof


def build_shell(bm):
    rings = []
    for y in STATIONS:
        half = profile(y)
        n = len(half)                    # 16
        ring = []
        for x, z in half:
            ring.append(bm.verts.new((x, y, z)))
        for i in range(n - 2, 0, -1):    # mirrored left side, skip centre points
            x, z = half[i]
            ring.append(bm.verts.new((-x, y, z)))
        rings.append(ring)
    n = len(rings[0])
    half_n = len(profile(0.0))
    for a, b in zip(rings[:-1], rings[1:]):
        ya = a[0].co.y
        yb = b[0].co.y
        ymid = (ya + yb) / 2
        for r in range(n):
            r2 = (r + 1) % n
            f = bm.faces.new((a[r], a[r2], b[r2], b[r]))
            k = r if r < half_n - 1 else (n - 1 - r)
            f.material_index = strip_material(k, ymid)
    # end caps
    fc = bm.faces.new(rings[0])
    fc.material_index = MI["Paint"]
    rc = bm.faces.new(list(reversed(rings[-1])))
    rc.material_index = MI["Paint"]
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    return rings


def arch_outline(yc):
    """GMT400 wheel opening: flat top (~0.93 m), angled sides, rounded corners.
    Returns (y, z) points from rear-bottom over the top to front-bottom."""
    raw = [(-0.56, 0.38), (-0.47, 0.74), (-0.33, 0.925), (0.33, 0.925), (0.47, 0.74), (0.56, 0.38)]
    pts = raw
    for _ in range(2):                                  # Chaikin corner rounding
        new = [pts[0]]
        for a, b in zip(pts[:-1], pts[1:]):
            new.append((0.75 * a[0] + 0.25 * b[0], 0.75 * a[1] + 0.25 * b[1]))
            new.append((0.25 * a[0] + 0.75 * b[0], 0.25 * a[1] + 0.75 * b[1]))
        new.append(pts[-1])
        pts = new
    return [(yc + y, z) for y, z in pts]


def outline_strip(bm, side, pts, centre, off_in, off_out, x_in, x_out, mi):
    """Sweep a small rectangle along a side-view outline (fender lip / trim)."""
    prev = None
    n = len(pts)
    for i, (y, z) in enumerate(pts):
        a = pts[max(i - 1, 0)]
        c = pts[min(i + 1, n - 1)]
        ty, tz = c[0] - a[0], c[1] - a[1]
        ln = math.hypot(ty, tz) or 1.0
        ny, nz = -tz / ln, ty / ln
        if ny * (y - centre[0]) + nz * (z - centre[1]) < 0:
            ny, nz = -ny, -nz
        quad = [bm.verts.new((side * x_in, y + ny * off_in, z + nz * off_in)),
                bm.verts.new((side * x_out, y + ny * off_in, z + nz * off_in)),
                bm.verts.new((side * x_out, y + ny * off_out, z + nz * off_out)),
                bm.verts.new((side * x_in, y + ny * off_out, z + nz * off_out))]
        if prev:
            for j in range(4):
                f = bm.faces.new((prev[j], prev[(j + 1) % 4], quad[(j + 1) % 4], quad[j]))
                f.material_index = mi
        prev = quad


def round_edges(ob):
    """Bevel every crease sharper than ~25 degrees: the GMT400 is boxy but all
    its panel edges are softly radiused."""
    mod = ob.modifiers.new("round", "BEVEL")
    mod.width = 0.045
    mod.segments = 2
    mod.limit_method = "ANGLE"
    mod.angle_limit = math.radians(25)
    mod.profile = 0.6
    mod.harden_normals = False
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.modifier_apply(modifier=mod.name)


def cut_arches(ob):
    """Boolean the four wheel openings out of the shell."""
    cutters = []
    for y in (YF, YR):
        bm = bmesh.new()
        prof = arch_outline(y) + [(y + 0.56, 0.0), (y - 0.56, 0.0)]
        left = [bm.verts.new((-1.3, py, pz)) for py, pz in prof]
        right = [bm.verts.new((1.3, py, pz)) for py, pz in prof]
        bm.faces.new(left)
        bm.faces.new(list(reversed(right)))
        m = len(prof)
        for i in range(m):
            bm.faces.new((left[i], left[(i + 1) % m], right[(i + 1) % m], right[i]))
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
        me = bpy.data.meshes.new("cut")
        bm.to_mesh(me)
        bm.free()
        c = bpy.data.objects.new("cut", me)
        bpy.context.collection.objects.link(c)
        cutters.append(c)
    for c in cutters:
        mod = ob.modifiers.new("arch", "BOOLEAN")
        mod.operation = "DIFFERENCE"
        mod.object = c
        mod.solver = "FAST"
        bpy.context.view_layer.objects.active = ob
        bpy.ops.object.modifier_apply(modifier=mod.name)
        bpy.data.objects.remove(c, do_unlink=True)


# ---------------------------------------------------------------- details
def arc_strip(bm, side, yc, zc, r_in, r_out, x_in, x_out, a0, a1, mi, segs=18):
    """Swept rectangle along an arc (fender flare lip / inner wheel well)."""
    prev = None
    for i in range(segs + 1):
        a = lerp(a0, a1, i / segs)
        cy, cz = math.cos(a), math.sin(a)
        quad = [
            bm.verts.new((side * x_in, yc + r_in * cy, zc + r_in * cz)),
            bm.verts.new((side * x_out, yc + r_in * cy, zc + r_in * cz)),
            bm.verts.new((side * x_out, yc + r_out * cy, zc + r_out * cz)),
            bm.verts.new((side * x_in, yc + r_out * cy, zc + r_out * cz)),
        ]
        if prev:
            for j in range(4):
                f = bm.faces.new((prev[j], prev[(j + 1) % 4], quad[(j + 1) % 4], quad[j]))
                f.material_index = mi
        prev = quad


def build_details(bm):
    # --- fender flares (black, like the photo) and inner wheel wells
    for y in (YF, YR):
        for s in (-1, 1):
            ol = arch_outline(y)
            outline_strip(bm, s, ol, (y, 0.4), -0.004, 0.03, 0.966, 0.99, MI["Paint"])     # lip
            outline_strip(bm, s, ol, (y, 0.4), -0.006, 0.008, 0.968, 0.996, MI["Chrome"])  # bright trim
            outline_strip(bm, s, ol, (y, 0.4), -0.012, 0.0, 0.62, 0.97, MI["Black"])       # well
            # well roof (inner side wall)
            add_box(bm, (0.02, ARCH_R * 2, 0.5), (s * 0.63, y, ARCH_Z + 0.2), MI["Black"])

    # --- front end (heights measured from reference photos): lamp/grille block
    # 0.70-1.09 m, chrome bumper 0.50-0.64 m over a black lower 0.38-0.50 m
    fy = FRONT + 0.004
    add_box(bm, (1.90, 0.03, 0.39), (0, fy - 0.012, 0.895), MI["Grille"])            # face backing
    add_box(bm, (0.96, 0.03, 0.35), (0, fy - 0.004, 0.895), MI["Grille"])            # grille insert
    for z in (0.80, 0.99):
        add_box(bm, (0.94, 0.03, 0.014), (0, fy + 0.004, z), MI["Black"])             # eggcrate
    for x in (-0.24, 0.0, 0.24):
        add_box(bm, (0.014, 0.03, 0.33), (x, fy + 0.004, 0.895), MI["Black"])
    add_box(bm, (1.94, 0.05, 0.06), (0, fy + 0.018, 0.885), MI["Chrome"])             # full-width bar
    add_box(bm, (1.94, 0.035, 0.022), (0, fy + 0.008, 1.088), MI["Chrome"])           # top trim
    add_box(bm, (1.94, 0.035, 0.022), (0, fy + 0.008, 0.702), MI["Chrome"])           # bottom trim
    for s in (-1, 1):
        add_box(bm, (0.03, 0.04, 0.39), (s * 0.495, fy + 0.008, 0.895), MI["Chrome"])
        add_box(bm, (0.33, 0.03, 0.13), (s * 0.68, fy + 0.002, 0.98), MI["Headlamp"])     # upper lamp
        add_box(bm, (0.33, 0.03, 0.13), (s * 0.68, fy + 0.002, 0.79), MI["Headlamp"])     # lower lamp
        add_box(bm, (0.10, 0.03, 0.13), (s * 0.905, fy + 0.002, 0.98), MI["Headlamp"])
        add_box(bm, (0.10, 0.03, 0.13), (s * 0.905, fy + 0.003, 0.79), MI["Amber"])
        add_box(bm, (0.03, 0.12, 0.13), (s * 0.975, fy - 0.065, 0.79), MI["Amber"])       # side wraps
        add_box(bm, (0.03, 0.12, 0.13), (s * 0.975, fy - 0.065, 0.98), MI["Amber"])
    # tall chrome bumper over a black lower section, swept around the corners
    chrome_sec = [(-0.14, 0.50), (-0.012, 0.50), (0.0, 0.515), (0.006, 0.57), (0.0, 0.625),
                  (-0.012, 0.64), (-0.14, 0.64)]
    lower_sec = [(-0.13, 0.38), (-0.025, 0.38), (-0.015, 0.395), (-0.012, 0.50), (-0.13, 0.50)]
    sweep(bm, bumper_path(fy + 0.15, 0.985, 0.22, 0.12, True), chrome_sec, MI["Chrome"])
    sweep(bm, bumper_path(fy + 0.15, 0.975, 0.22, 0.10, True), lower_sec, MI["Black"])
    add_box(bm, (0.32, 0.02, 0.15), (0, fy + 0.15, 0.50), MI["Black"])                 # plate holder
    add_box(bm, (1.50, 0.12, 0.05), (0, fy + 0.0, 0.355), MI["Black"])                 # air dam

    # --- rear end
    ry = REAR
    for s in (-1, 1):
        add_box(bm, (0.17, 0.04, 0.46), (s * 0.87, ry - 0.008, 0.99), MI["Taillight"])
        add_box(bm, (0.15, 0.045, 0.09), (s * 0.87, ry - 0.008, 0.93), MI["Reverse"])
        add_box(bm, (0.03, 0.08, 0.46), (s * 0.965, ry + 0.04, 0.99), MI["Taillight"])
    add_box(bm, (1.66, 0.012, 0.44), (0, ry - 0.004, 1.47), MI["Glass"], bevel=0.02)  # rear glass
    add_box(bm, (0.01, 0.014, 0.72), (0, ry - 0.008, 0.95), MI["Black"])                # barn-door split
    add_box(bm, (0.32, 0.01, 0.16), (0, ry - 0.006, 0.86), MI["Black"])                 # plate recess
    rear_sec = [(-0.16, 0.48), (-0.012, 0.48), (0.0, 0.495), (0.0, 0.645), (-0.012, 0.66), (-0.16, 0.66)]
    sweep(bm, bumper_path(ry - 0.17, 0.985, 0.16, 0.10, False), rear_sec, MI["Chrome"])
    add_box(bm, (1.60, 0.10, 0.008), (0, ry - 0.11, 0.664), MI["Rubber"])                # step pad
    add_box(bm, (0.18, 0.07, 0.035), (-0.42, ry - 0.02, 1.13), MI["Chrome"])  # handle

    # --- sides
    for s in (-1, 1):
        x = s * 0.982
        # door shut lines
        for y, z0, z1 in ((0.915, 0.94, 1.20), (-0.90, 0.45, 1.20), (-1.86, 0.94, 1.20)):
            add_box(bm, (0.006, 0.008, z1 - z0), (x, y, (z0 + z1) / 2), MI["Black"])
        add_box(bm, (0.006, 1.86, 0.008), (x, -0.40, 0.448), MI["Black"])
        # door handles
        for y in (-0.70, -1.68):
            add_box(bm, (0.02, 0.17, 0.045), (s * 0.985, y, 1.085), MI["Black"])
        # mirror on a door-mounted arm
        add_box(bm, (0.035, 0.06, 0.06), (s * 0.99, COWL - 0.18, 1.30), MI["Black"])
        add_box(bm, (0.11, 0.09, 0.20), (s * 1.08, COWL - 0.20, 1.33), MI["Black"], bevel=0.02)
        add_box(bm, (0.005, 0.07, 0.17), (s * 1.08, COWL - 0.248, 1.33), MI["Glass"])
        # running board between the arches
        add_box(bm, (0.20, 2.0, 0.045), (s * 0.93, 0.0, 0.36), MI["Black"])
        add_box(bm, (0.17, 1.95, 0.008), (s * 0.935, 0.0, 0.384), MI["Rubber"])
        # roof rack rails
        add_box(bm, (0.045, 2.35, 0.04), (s * 0.62, -0.95, 1.845), MI["Black"], bevel=0.01)
        for y in (0.15, -2.05):
            add_box(bm, (0.06, 0.14, 0.05), (s * 0.62, y, 1.825), MI["Black"])
    for y in (-0.35, -1.75):
        add_box(bm, (1.24, 0.04, 0.025), (0, y, 1.873), MI["Black"])                    # crossbars
    # antenna on the left front fender
    add_cyl(bm, 0.003, 0.75, (-0.88, COWL + 0.05, 1.20 + 0.37), "Z", MI["Chrome"], segs=6)
    # interior silhouettes seen through the tint: dash, two buckets, rear bench
    add_box(bm, (1.80, 0.40, 0.14), (0, 0.82, 1.20), MI["Black"])                      # dash top
    for x in (-0.42, 0.42):
        add_box(bm, (0.50, 0.50, 0.12), (x, -0.20, 0.92), MI["Interior"])               # cushion
        add_box(bm, (0.48, 0.12, 0.58), (x, -0.45, 1.22), MI["Interior"])               # back
        add_box(bm, (0.24, 0.08, 0.16), (x, -0.47, 1.58), MI["Interior"])               # headrest
    add_box(bm, (1.55, 0.55, 0.12), (0, -1.30, 0.92), MI["Interior"])                   # rear bench
    add_box(bm, (1.55, 0.12, 0.55), (0, -1.58, 1.20), MI["Interior"])
    for s in (-1, 1):
        add_box(bm, (0.12, 0.02, 0.1), (s * 0.4, COWL - 0.07, 1.235), MI["Black"])                # wipers rest


# ---------------------------------------------------------------- wheel
def lathe(bm, prof, segs, mi):
    """Revolve (radius, x) profile around the X axis."""
    rings = []
    for i in range(segs):
        a = 2 * math.pi * i / segs
        ring = [bm.verts.new((x, r * math.cos(a), r * math.sin(a))) for r, x in prof]
        rings.append(ring)
    for i in range(segs):
        a, b = rings[i], rings[(i + 1) % segs]
        for j in range(len(prof) - 1):
            f = bm.faces.new((a[j], b[j], b[j + 1], a[j + 1]))
            f.material_index = mi


def build_wheel(mats):
    """~420 triangles: 16-sided tire with shaped sidewall, dished 5-spoke rim."""
    bm = bmesh.new()
    tire = [(0.205, -0.11), (0.31, -0.127), (0.373, -0.112), (0.387, -0.09),
            (0.387, 0.09), (0.373, 0.112), (0.31, 0.127), (0.205, 0.11)]
    lathe(bm, tire, 16, 0)
    rim = [(0.203, -0.06), (0.203, 0.078), (0.209, 0.098), (0.185, 0.091)]
    lathe(bm, rim, 16, 1)
    lathe(bm, [(0.175, 0.05), (0.06, 0.05)], 10, 2)          # dark hub face behind spokes
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
        _merge(bm, tmp)
    lathe(bm, [(0.075, 0.07), (0.055, 0.098), (0.0, 0.102)], 10, 1)   # centre cap
    ob = new_obj("Wheel", bm, [mats["Tire"], mats["Rim"], mats["Hub"]], smooth_angle=50)
    return ob


# ---------------------------------------------------------------- scene / export
def clear():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def build():
    clear()
    mats = build_materials()
    bm = bmesh.new()
    build_shell(bm)
    body = new_obj("Body", bm, [mats[n] for n in MAT_ORDER])
    cut_arches(body)
    round_edges(body)
    bm = bmesh.new()
    build_details(bm)
    det = new_obj("Details", bm, [mats[n] for n in MAT_ORDER], smooth_angle=40)
    # join details into the body (one draw-call group per material)
    bpy.ops.object.select_all(action="DESELECT")
    det.select_set(True)
    body.select_set(True)
    bpy.context.view_layer.objects.active = body
    bpy.ops.object.join()
    body.data.set_sharp_from_angle(angle=math.radians(28))
    wheel = build_wheel(mats)
    return body, wheel


def tri_count(ob):
    return sum(len(p.vertices) - 2 for p in ob.data.polygons)


def export(ob, path):
    bpy.ops.object.select_all(action="DESELECT")
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=True,
                              export_apply=True, export_yup=True)


def render_preview(body, wheel, path, angle="front34"):
    # place four wheel instances for the preview
    for (x, y) in ((TRACK_F / 2, YF), (-TRACK_F / 2, YF), (TRACK_R / 2, YR), (-TRACK_R / 2, YR)):
        inst = bpy.data.objects.new("W", wheel.data)
        bpy.context.collection.objects.link(inst)
        inst.location = (x, y, TIRE_R)
        if x < 0:
            inst.scale = (-1, 1, 1)
    wheel.hide_render = True
    scn = bpy.context.scene
    scn.render.engine = "CYCLES"
    scn.cycles.samples = 48
    scn.cycles.use_denoising = True
    scn.render.resolution_x = 1280
    scn.render.resolution_y = 720
    world = bpy.data.worlds.new("W")
    scn.world = world
    world.use_nodes = True
    nt = world.node_tree
    sky = nt.nodes.new("ShaderNodeTexSky")
    sky.sky_type = "NISHITA"
    sky.sun_elevation = math.radians(35)
    sky.sun_rotation = math.radians(200)
    nt.links.new(sky.outputs["Color"], nt.nodes["Background"].inputs["Color"])
    nt.nodes["Background"].inputs["Strength"].default_value = 0.35
    sun = bpy.data.lights.new("Sun", "SUN")
    sun.energy = 3.0
    sun.angle = math.radians(8)
    sun_ob = bpy.data.objects.new("Sun", sun)
    sun_ob.rotation_euler = (math.radians(50), 0, math.radians(-35))
    bpy.context.collection.objects.link(sun_ob)
    # studio floor like the reference photo
    bpy.ops.mesh.primitive_plane_add(size=40, location=(0, 0, 0))
    floor = bpy.context.active_object
    fm = mat("Floor", (0.35, 0.35, 0.36), 0.0, 0.35)
    floor.data.materials.append(fm)
    cams = {
        "front34": ((-6.2, 7.0, 1.6), (0, 0.2, 0.85)),
        "photo": ((-3.0, 4.7, 1.15), (0.3, -0.8, 0.95)),
        "right34": ((3.4, 4.7, 1.7), (-0.45, -0.8, 0.85)),
        "side": ((-9.5, 0.0, 1.1), (0, 0.0, 0.9)),
        "rear34": ((5.5, -7.2, 1.8), (0, -0.4, 0.9)),
        "front": ((0, 9.0, 1.2), (0, 0, 0.9)),
    }
    loc, tgt = cams[angle]
    bpy.ops.object.camera_add(location=loc)
    cam = bpy.context.active_object
    d = Vector(tgt) - Vector(loc)
    cam.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
    cam.data.lens = 26 if angle in ("photo", "right34") else 50
    scn.camera = cam
    scn.render.filepath = path
    bpy.ops.render.render(write_still=True)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="assets/cars/tahoe_1996")
    ap.add_argument("--render", default="")
    ap.add_argument("--angles", default="front34")
    a = ap.parse_args(argv)
    body, wheel = build()
    print("body tris:", tri_count(body), " wheel tris:", tri_count(wheel), " TOTAL (4 wheels):", tri_count(body) + 4 * tri_count(wheel))
    os.makedirs(a.out, exist_ok=True)
    export(body, os.path.join(a.out, "tahoe_body.glb"))
    export(wheel, os.path.join(a.out, "tahoe_wheel.glb"))
    if a.render:
        for ang in a.angles.split(","):
            base, ext = os.path.splitext(a.render)
            render_preview(body, wheel, f"{base}_{ang}{ext}", ang)
            # remove preview helpers before next angle
            for o in list(bpy.data.objects):
                if o.name not in ("Body", "Wheel"):
                    bpy.data.objects.remove(o, do_unlink=True)


if __name__ == "__main__":
    main()
