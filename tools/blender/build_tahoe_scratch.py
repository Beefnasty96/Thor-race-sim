"""1996 Chevy Tahoe 4-door, built from scratch in the Gran Turismo 1 style.

Every vertex of the body is placed by hand from real GMT400 dimensions and the
reference photos (side, front, rear, top), and the texture sheet is painted in
code: grille, lamps, chrome, door seams, handles, glass, taillights. No logos.

The painter and the UV mapper share the same view mappings, so a detail painted
at a body coordinate (e.g. the door handle at y=-0.03, z=1.15) lands exactly on
that spot of the model.

Coordinates (Blender): +Y forward, +X = right side of the truck, +Z up.
Frame matches the earlier detailed model (hub height 0.415, body_drop -0.028),
so the interior, steering wheel, cockpit camera and gauges stay where they were.
Wheel centres at y = +-1.4925 (117.5 in wheelbase), the same as the physics.

Outputs (in <out_dir>):
  tahoe_body.glb   Body (material BakedBody), Interior, SteeringWheel
  body_detail.png  albedo (paint = white), alpha 0 = window glass
  body_mask.png    R paint, G chrome, B tail lamp, A hand-painted shade
  model_info.json  frame/cockpit data + bake info

Run: bvenv/bin/python tools/blender/build_tahoe_scratch.py -- <parts_dir> <out_dir>
     (<parts_dir> holds the interior/steering/wheel from convert_tahoe_glb.py)
"""
import bpy
import bmesh
import json
import math
import os
import shutil
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

argv = sys.argv[sys.argv.index("--") + 1:]
SRC, OUT = argv[0], argv[1]
ATLAS = 2048
SS = 2                                    # paint at 2x, then downsample (anti-aliasing)


def log(*a):
    print("[tahoe]", *a, flush=True)


# =========================================================== dimensions (m)
WZ = 0.415            # hub height in this frame
WY = 1.4925           # wheel centre, front +, rear -
ARCH_R = 0.47         # wheel opening radius at the body side
XIN = 0.56            # wheelhouse inner wall
ZF = 0.45             # rocker bottom / floor
COWL_Y, HOOD_END_Y, HEADER_Y = 0.97, 1.03, 0.42
NOSE_Y, TAIL_Y = 2.235, -2.583
BELT_Z = 1.27
CREASE_Z = 1.05


def lerp_tab(tab, y):
    """Piecewise-linear lookup in [(y, v), ...] sorted by y descending."""
    if y >= tab[0][0]:
        return tab[0][1]
    for (y0, a), (y1, b) in zip(tab, tab[1:]):
        if y1 <= y <= y0:
            return a + (b - a) * (y0 - y) / (y0 - y1)
    return tab[-1][1]


SIDE_X = [(2.235, 0.90), (2.20, 0.958), (2.12, 0.965), (-2.45, 0.965), (-2.55, 0.955), (-2.583, 0.92)]
HOOD_C = [(2.235, 1.108), (2.15, 1.150), (2.0, 1.184), (1.8, 1.218), (1.5, 1.247), (1.2, 1.266), (1.03, 1.272)]
HOOD_E = [(2.235, 1.100), (2.15, 1.135), (2.0, 1.153), (1.8, 1.192), (1.5, 1.225), (1.2, 1.246), (1.03, 1.256)]
FLOOR = [(2.235, 0.74), (2.05, 0.66), (1.9625, ZF), (-1.9625, ZF), (-2.30, 0.52), (-2.42, 0.56), (-2.583, 0.60)]
ROOF_C = [(0.42, 1.815), (-2.42, 1.815), (-2.52, 1.80), (-2.583, 1.765)]
ROOF_EX = [(0.42, 0.80), (-2.42, 0.84), (-2.52, 0.835), (-2.583, 0.82)]
ROOF_EZ = [(0.42, 1.775), (-2.42, 1.78), (-2.52, 1.765), (-2.583, 1.74)]


def arch_z(y):
    for wy in (WY, -WY):
        d = y - wy
        if abs(d) < ARCH_R - 1e-6:
            c = math.sqrt(1.0 - (d / ARCH_R) ** 2)
            return max(ZF, WZ + ARCH_R * c ** 0.85)        # slightly squared-off, like GMT400
    return None


def half(y):
    """Right half of the body section at y: 9 (x, z) points from the
    wheelhouse floor up to the roof/hood centre line."""
    xs = lerp_tab(SIDE_X, y)
    zf = lerp_tab(FLOOR, y)
    za = arch_z(y)
    zw, zin = (za, za + 0.08) if za is not None and za > zf + 1e-4 else (zf, zf)
    pts = [(XIN, zf), (XIN, zin), (xs - 0.03, zw), (xs, zw + 0.05)]
    if y >= HOOD_END_Y:                                      # hood + front fenders
        he, hc = lerp_tab(HOOD_E, y), lerp_tab(HOOD_C, y)
        pts += [(xs + 0.006, min(CREASE_Z, he - 0.06)), (xs - 0.006, he - 0.012),
                (xs - 0.05, he), (xs - 0.10, he + 0.006), (0.0, hc)]
    elif y >= COWL_Y - 1e-6:                                 # cowl / windscreen base
        pts += [(xs + 0.006, CREASE_Z), (xs - 0.006, BELT_Z), (xs - 0.045, BELT_Z + 0.012),
                (0.80, 1.285), (0.0, 1.29)]
    else:                                                    # greenhouse
        pts += [(xs + 0.006, CREASE_Z), (xs - 0.006, BELT_Z), (xs - 0.045, BELT_Z + 0.015),
                (lerp_tab(ROOF_EX, y), lerp_tab(ROOF_EZ, y)), (0.0, lerp_tab(ROOF_C, y))]
    return pts


def arch_stations(wy):
    return [wy + ARCH_R * math.sin(math.radians(t)) for t in range(90, -91, -20)]


STATIONS = sorted(set([NOSE_Y, 2.20, 2.12, 2.05] + arch_stations(WY) + [HOOD_END_Y, COWL_Y, HEADER_Y]
                      + arch_stations(-WY) + [-2.30, -2.42, -2.52, -2.55, TAIL_Y]), reverse=True)
STATIONS = [round(s, 5) for s in STATIONS]
# arch stations at +-90 deg duplicate nothing else; keep a tiny gap check
STATIONS = [s for i, s in enumerate(STATIONS) if i == 0 or abs(s - STATIONS[i - 1]) > 0.004]

# =========================================================== atlas views
# name: (rx, ry, rw, rh, a0, b0, su, sv, a_dir)  pixel = (rx + (a - a0)*su*a_dir, ry + (b0 - b)*sv)
VIEWS = {
    "left":  (0, 0, 2048, 608, 2.48, 1.90, 390, 390, -1),     # a = y, b = z
    "right": (0, 608, 2048, 608, 2.48, 1.90, 390, 390, -1),
    "top":   (0, 1216, 1024, 400, 2.48, 1.02, 195, 195, -1),  # a = y, b = x
    "front": (1024, 1216, 1024, 256, -1.066, 1.15, 480, 480, 1),   # a = x, b = z
    "wind":  (1024, 1472, 1024, 320, -1.28, 0.78, 400, 400, 1),    # a = x, b = t (along glass)
    "fbump": (1024, 1792, 1024, 128, -1.28, 0.0, 400, -240, 1),    # a = u (path), b = v (profile)
    "rbump": (1024, 1920, 1024, 128, -1.28, 0.0, 400, -240, 1),
    "rear":  (0, 1616, 1024, 432, -1.42, 1.82, 360, 360, 1),       # a = x, b = z
}
BLACK_PX = (1016, 2040)                       # painted-black texel (free corner of the rear region)
WS_B = (0.97, 1.285)                          # windscreen base (y, z) at centre
_d = (HEADER_Y - COWL_Y, 1.775 - 1.285)
_l = math.hypot(*_d)
WS_D = (_d[0] / _l, _d[1] / _l)               # unit direction up the glass in (y, z)


def to_px(view, a, b):
    rx, ry, rw, rh, a0, b0, su, sv, ad = VIEWS[view]
    return rx + (a - a0) * su * ad, ry + (b0 - b) * sv


def to_uv(view, a, b):
    px, py = to_px(view, a, b)
    return px / ATLAS, 1.0 - py / ATLAS


def view_ab(view, co):
    x, y, z = co
    if view in ("left", "right"):
        return y, z
    if view == "top":
        return y, x
    if view in ("front", "rear"):
        return x, z
    if view == "wind":
        return x, (y - WS_B[0]) * WS_D[0] + (z - WS_B[1]) * WS_D[1]
    raise ValueError(view)


# =========================================================== body shell
verts, vindex = [], {}


def V(x, y, z):
    k = (round(x, 5), round(y, 5), round(z, 5))
    if k not in vindex:
        vindex[k] = len(verts)
        verts.append(k)
    return vindex[k]


faces = []          # (vertex ids, tag)


def F(ids, tag):
    out = []
    for i in ids:
        if not out or out[-1] != i:
            out.append(i)
    if len(out) > 1 and out[0] == out[-1]:
        out.pop()
    if len(set(out)) >= 3 and len(set(out)) == len(out):
        faces.append((out, tag))


rings = []
for y in STATIONS:
    h = half(y)
    rings.append(([V(x, y, z) for x, z in h], [V(-x, y, z) for x, z in h]))

for i in range(len(STATIONS) - 1):
    (r0, l0), (r1, l1) = rings[i], rings[i + 1]
    wind_span = abs(STATIONS[i] - COWL_Y) < 1e-4 and abs(STATIONS[i + 1] - HEADER_Y) < 1e-4
    for k in range(8):
        tag = "black" if k < 2 else ("windzone" if (wind_span and k >= 6) else "auto")
        F([r0[k], r0[k + 1], r1[k + 1], r1[k]], tag)
        F([l0[k], l1[k], l1[k + 1], l0[k + 1]], tag)
    F([r0[0], r1[0], l1[0], l0[0]], "black")                 # floor
# end caps
r, l = rings[0]
F(r + l[::-1][1:], "front")
r, l = rings[-1]
F(r + l[::-1][1:], "rear")
n_shell = len(faces)


# =========================================================== bumpers, dam, mirrors
def path_normals(path, sign):
    """Outward (horizontal) normals at each path vertex; sign flips the side."""
    ns = []
    for i in range(len(path)):
        a = path[max(i - 1, 0)]
        b = path[min(i + 1, len(path) - 1)]
        dx, dy = b[0] - a[0], b[1] - a[1]
        L = math.hypot(dx, dy)
        ns.append((sign * dy / L, -sign * dx / L))
    return ns


def bumper(path, profile, sign, region):
    """Sweep a (d, z) profile along a plan path; UV by path length / profile length."""
    ns = path_normals(path, sign)
    s = [0.0]
    for a, b in zip(path, path[1:]):
        s.append(s[-1] + math.hypot(b[0] - a[0], b[1] - a[1]))
    smid = s[-1] / 2
    v = [0.0]
    for a, b in zip(profile, profile[1:]):
        v.append(v[-1] + math.hypot(b[0] - a[0], b[1] - a[1]))
    grid = [[V(p[0] + n[0] * d, p[1] + n[1] * d, z) for d, z in profile] for p, n in zip(path, ns)]
    for i in range(len(path) - 1):
        for j in range(len(profile) - 1):
            ids = [grid[i][j], grid[i + 1][j], grid[i + 1][j + 1], grid[i][j + 1]]
            uvs = [(s[i] - smid, v[j]), (s[i + 1] - smid, v[j]), (s[i + 1] - smid, v[j + 1]), (s[i] - smid, v[j + 1])]
            faces.append((ids, (region, uvs)))
    for g in (grid[0], grid[-1]):                             # end caps
        F(g, "black")
    return v[-1], smid


F_PATH = [(-0.975, 2.00), (-0.97, 2.30), (-0.90, 2.385), (-0.70, 2.40), (0.70, 2.40), (0.90, 2.385), (0.97, 2.30), (0.975, 2.00)]
F_PROF = [(-0.17, 0.805), (0.0, 0.80), (0.02, 0.69), (0.02, 0.64), (0.0, 0.535), (-0.08, 0.515)]
R_PATH = [(0.985, -2.40), (0.985, -2.60), (0.93, -2.665), (-0.93, -2.665), (-0.985, -2.60), (-0.985, -2.40)]
R_PROF = [(-0.13, 0.68), (0.0, 0.68), (0.012, 0.60), (0.0, 0.48), (-0.07, 0.46)]
FV_LEN, _ = bumper(F_PATH, F_PROF, -1, "fbump")
RV_LEN, _ = bumper(R_PATH, R_PROF, -1, "rbump")


def box(x0, x1, y0, y1, z0, z1, tag="black"):
    c = [V(x, y, z) for z in (z0, z1) for y in (y0, y1) for x in (x0, x1)]
    for q in ((0, 2, 3, 1), (4, 5, 7, 6), (0, 1, 5, 4), (2, 6, 7, 3), (0, 4, 6, 2), (1, 3, 7, 5)):
        F([c[i] for i in q], tag)


box(-0.80, 0.80, 2.22, 2.36, 0.43, 0.52)                     # air dam
box(-0.045, 0.045, -2.71, -2.56, 0.41, 0.47)                 # hitch receiver
for sx in (1, -1):                                           # door mirrors
    xa, xb = sorted((sx * 0.955, sx * 0.995))
    box(xa, xb, 0.74, 0.79, 1.33, 1.38)
    xa, xb = sorted((sx * 0.99, sx * 1.14))
    box(xa, xb, 0.71, 0.80, 1.29, 1.50)


# =========================================================== blender mesh + UVs
bpy.ops.wm.read_factory_settings(use_empty=True)
me = bpy.data.meshes.new("Body")
me.from_pydata([tuple(v) for v in verts], [], [f for f, _t in faces])
me.update()
low = bpy.data.objects.new("Body", me)
bpy.context.scene.collection.objects.link(low)

bm = bmesh.new()
bm.from_mesh(me)
bm.faces.ensure_lookup_table()
nonman = [e for e in bm.edges if not e.is_manifold]
log("verts", len(bm.verts), "faces", len(bm.faces), "non-manifold edges", len(nonman))
# shell: orient outward. Recalc on the manifold shell, then check against the
# centre (a face pointing toward the body axis is flipped).
shell = [bm.faces[i] for i in range(n_shell)]
bmesh.ops.recalc_face_normals(bm, faces=shell)
flipped = 0
for i, f in enumerate(bm.faces):
    c = f.calc_center_median()
    tag = faces[i][1]
    if i < n_shell:
        ref = (0.0, c.y, 1.05) if tag != "black" else (0.0, c.y, 0.9)
        if tag == "front":
            ref = (0.0, 0.0, 1.0)
        if tag == "rear":
            ref = (0.0, 0.0, 1.0)
    else:
        ref = None
    if ref is not None:
        out = c - type(c)(ref)
        if f.normal.dot(out) < 0 and tag not in ("black",):
            f.normal_flip()
            flipped += 1
log("flipped after recalc", flipped)
# bumpers / boxes: outward from their own centre
for i in range(n_shell, len(bm.faces)):
    f = bm.faces[i]
    tag = faces[i][1]
    c = f.calc_center_median()
    if isinstance(tag, tuple):        # bumper skin: outward = away from body centre in plan, or up
        out = type(c)((c.x * 0.3, c.y, 0.0)) if abs(c.y) > 2.0 else type(c)((c.x, 0, 0))
        if f.normal.z > 0.7 or f.normal.z < -0.7:
            continue
        if f.normal.dot(out) < 0:
            f.normal_flip()
bm.to_mesh(me)
bm.free()
# boxes: recalc per box island is simplest via a second pass (all boxes are closed)
bm = bmesh.new()
bm.from_mesh(me)
bm.faces.ensure_lookup_table()
box_faces = [f for i, f in enumerate(bm.faces) if i >= n_shell and not isinstance(faces[i][1], tuple)]
bmesh.ops.recalc_face_normals(bm, faces=box_faces)
bump_faces = [f for i, f in enumerate(bm.faces) if i >= n_shell and isinstance(faces[i][1], tuple)]
bm.to_mesh(me)
bm.free()


def pick_view(n, c):
    if n.z < -0.55:
        return None
    if n.z > 0.62:
        return "top"
    if abs(n.x) >= abs(n.y) * 0.75:
        return "left" if n.x < 0 else "right"
    return "front" if n.y > 0 else "rear"


bx, by = BLACK_PX
BLACK_UV = ((bx + 0.5) / ATLAS, 1.0 - (by + 0.5) / ATLAS)
me.materials.append(bpy.data.materials.new("BakedBody"))
uvl = me.uv_layers.new(name="UVMap")
counts = {}
for p in me.polygons:
    tag = faces[p.index][1]
    p.use_smooth = False
    if isinstance(tag, tuple):
        region, uvs = tag
        for li, (a, b) in zip(p.loop_indices, uvs):
            uvl.data[li].uv = to_uv(region, a, b)
        counts[region] = counts.get(region, 0) + 1
        continue
    if tag == "black":
        v = None
    elif tag in ("front", "rear"):
        v = tag
    elif tag == "windzone" and p.normal.y > 0.35:
        v = "wind"
    else:
        v = pick_view(p.normal, p.center)
    counts[v] = counts.get(v, 0) + 1
    for li in p.loop_indices:
        if v is None:
            uvl.data[li].uv = BLACK_UV
        else:
            co = me.vertices[me.loops[li].vertex_index].co
            uvl.data[li].uv = to_uv(v, *view_ab(v, co))
log("faces per view", counts)

# =========================================================== texture painting
W = ATLAS * SS
L = {k: Image.new("L", (W, W), v) for k, v in
     (("r", 255), ("g", 255), ("b", 255), ("a", 255), ("mr", 255), ("mg", 0), ("mb", 0), ("ma", 225))}
D = {k: ImageDraw.Draw(im) for k, im in L.items()}


def P(view, a, b):
    x, y = to_px(view, a, b)
    return x * SS, y * SS


def fill(view, pts, rgb=None, alpha=None, paint=None, chrome=None, tail=None, shade=None, line=0):
    px = [P(view, a, b) for a, b in pts]
    vals = {}
    if rgb is not None:
        vals.update(r=rgb[0], g=rgb[1], b=rgb[2])
    for k, v in (("a", alpha), ("mr", paint), ("mg", chrome), ("mb", tail), ("ma", shade)):
        if v is not None:
            vals[k] = v
    for k, v in vals.items():
        if line:
            D[k].line(px, fill=v, width=max(1, int(line * VIEWS[view][6] * SS)), joint="curve")
        else:
            D[k].polygon(px, fill=v)


def rect(view, a0, a1, b0, b1, **kw):
    fill(view, [(a0, b0), (a1, b0), (a1, b1), (a0, b1)], **kw)


def rrect(view, a0, a1, b0, b1, r, **kw):
    """Rounded rectangle (r in metres)."""
    pts = []
    for (ca, cb, t0) in ((a1 - r, b1 - r, 0), (a0 + r, b1 - r, 90), (a0 + r, b0 + r, 180), (a1 - r, b0 + r, 270)):
        for t in range(t0, t0 + 91, 15):
            pts.append((ca + r * math.cos(math.radians(t)), cb + r * math.sin(math.radians(t))))
    fill(view, pts, **kw)


def seam(view, pts, w=0.006, shade=40):
    fill(view, pts, shade=shade, line=w)


def chrome_rect(view, a0, a1, b0, b1, steps=12):
    """Chrome: sky-light top, dark horizon line, warm ground glow below."""
    lo, hi = min(b0, b1), max(b0, b1)
    for i in range(steps):
        t = (i + 0.5) / steps                                 # 0 top .. 1 bottom
        if t < 0.45:
            c = 235 - 60 * t
        elif t < 0.6:
            c = 90
        else:
            c = 150 + 70 * (t - 0.6)
        bb0 = hi - (hi - lo) * i / steps
        bb1 = hi - (hi - lo) * (i + 1) / steps
        rect(view, a0, a1, bb1, bb0, rgb=(int(c), int(c), int(c * 1.03)), paint=0, chrome=255, shade=255)


GLASS = (22, 28, 34)
TRIM = (20, 20, 22)
AMBER = (238, 136, 28)
LENS = (200, 208, 216)
RED = (175, 18, 14)


def glass(view, pts):
    fill(view, pts, rgb=GLASS, alpha=0, paint=0, chrome=0, shade=255)


def headlamp(view, a0, a1, b0, b1, amber=False):
    rect(view, a0, a1, b0, b1, rgb=(150, 155, 160), paint=0, chrome=200, shade=255)
    col = AMBER if amber else LENS
    rect(view, a0 + 0.006, a1 - 0.006, b0 + 0.006, b1 - 0.006, rgb=col, paint=0, chrome=0 if amber else 140, shade=255)
    n = 6                                                     # lens ribs
    for i in range(1, n):
        a = a0 + (a1 - a0) * i / n
        c = tuple(max(0, v - 35) for v in col)
        fill(view, [(a, b0 + 0.01), (a, b1 - 0.01)], rgb=c, line=0.002)
    if not amber:                                             # reflector bowl
        cx, cz = (a0 + a1) / 2, (b0 + b1) / 2
        rr = min(a1 - a0, b1 - b0) * 0.32
        fill(view, [(cx + rr * math.cos(t / 8 * math.pi), cz + rr * 0.8 * math.sin(t / 8 * math.pi)) for t in range(16)],
             rgb=(235, 240, 245), chrome=255)


# ---------------------------------------------------------------- sides
def paint_side(view, left):
    # greenhouse: black frame band, then the glass openings
    a_pillar = lambda t: (COWL_Y + (HEADER_Y - COWL_Y) * t, BELT_Z + 0.012 + (1.775 - BELT_Z - 0.012) * t)
    frame = [a_pillar(0.0), a_pillar(1.0), (-2.36, 1.775), (-2.36, BELT_Z + 0.012)]
    fill(view, frame, rgb=TRIM, paint=0, shade=255)
    # mirror sail at the front lower corner
    fill(view, [(0.96, BELT_Z + 0.01), (0.78, BELT_Z + 0.01), (0.78, 1.42), (0.86, 1.42)], rgb=TRIM, paint=0)
    top = 1.752
    y_ap = lambda z: COWL_Y - (z - BELT_Z - 0.012) / (1.775 - BELT_Z - 0.012) * (COWL_Y - HEADER_Y) - 0.035
    glass(view, [(0.77, BELT_Z + 0.03), (0.77, 1.43), (y_ap(top), top), (-0.075, top), (-0.075, BELT_Z + 0.03)])
    glass(view, [(-0.165, BELT_Z + 0.03), (-0.165, top), (-0.99, top), (-0.99, BELT_Z + 0.03)])
    q = [(-1.09, BELT_Z + 0.03), (-1.09, top)]
    for t in range(0, 91, 15):                                # rounded rear-top corner
        q.append((-2.25 - 0.08 * math.sin(math.radians(t)), top - 0.08 + 0.08 * math.cos(math.radians(t))))
    q += [(-2.33, BELT_Z + 0.03)]
    glass(view, q)
    seam(view, [(-2.36, 1.775), (TAIL_Y + 0.01, 1.775)], w=0.008, shade=120)     # drip rail
    seam(view, [a_pillar(1.0), (-2.36, 1.775)], w=0.006, shade=60)
    # door cut lines
    seam(view, [(0.935, BELT_Z), (0.935, 0.50), (0.90, 0.47), (-0.10, 0.47), (-0.12, 0.50), (-0.12, BELT_Z)])
    seam(view, [(-0.14, BELT_Z), (-0.14, 0.50), (-0.16, 0.47), (-0.98, 0.47)])
    za = arch_z(-1.00) or 0.6
    seam(view, [(-1.00, BELT_Z), (-1.00, za + 0.05)])
    seam(view, [(0.935, BELT_Z), (0.935, 1.30)], w=0.004)
    # fender / hood gap along the top of the fender
    seam(view, [(HOOD_END_Y, 1.262), (2.15, 1.13), (NOSE_Y, 1.096)], w=0.004, shade=90)
    # door handles (black paddles) and lock cylinders
    for a0 in (0.06, -0.84):
        rrect(view, a0 - 0.15, a0, 1.125, 1.165, 0.012, rgb=TRIM, paint=0, shade=255)
        rect(view, a0 - 0.14, a0 - 0.01, 1.13, 1.136, rgb=(5, 5, 6), paint=0)
    rrect(view, 0.07 - 0.01, 0.07 + 0.014, 1.135, 1.159, 0.01, rgb=(170, 170, 170), paint=0, chrome=255)
    # side markers
    rrect(view, -2.53, -2.44, 0.86, 0.91, 0.01, rgb=RED, paint=0, shade=255)
    # wrap of the corner lamps (nose chamfer) and taillights (tail chamfer)
    rect(view, 2.195, NOSE_Y + 0.01, 0.952, 1.062, rgb=AMBER, paint=0, shade=255)
    rect(view, 2.195, NOSE_Y + 0.01, 0.822, 0.935, rgb=LENS, paint=0, chrome=120, shade=255)
    rect(view, 2.195, NOSE_Y + 0.01, 0.78, 0.822, rgb=TRIM, paint=0)
    rect(view, TAIL_Y - 0.01, -2.548, 0.86, 1.32, rgb=RED, paint=0, tail=255, shade=255)
    if left:                                                  # fuel door (driver's side rear)
        rrect(view, -2.12, -1.95, 0.985, 1.115, 0.02, shade=70)
        rrect(view, -2.115, -1.955, 0.99, 1.11, 0.018, shade=225)
    # rocker shadow / arch lips (hand-painted AO)
    for wy in (WY, -WY):
        pts = []
        for t in range(-90, 91, 10):
            y = wy + (ARCH_R + 0.02) * math.sin(math.radians(t))
            pts.append((y, max(ZF, WZ + (ARCH_R + 0.02) * math.cos(math.radians(t)) ** 0.85)))
        fill(view, pts, shade=150, line=0.03)


paint_side("left", True)
paint_side("right", False)

# ---------------------------------------------------------------- front (grille / lamps)
rect("front", -0.92, 0.92, 0.70, 0.82, rgb=(30, 30, 32), paint=0, shade=255)           # under-lamp shadow
chrome_rect("front", -0.905, 0.905, 0.81, 1.072, steps=10)                          # surround
for s in (1, -1):
    a0, a1 = sorted((s * 0.52, s * 0.775))
    headlamp("front", a0, a1, 0.952, 1.062)
    headlamp("front", a0, a1, 0.822, 0.935)
    a0, a1 = sorted((s * 0.785, s * 0.90))
    headlamp("front", a0, a1, 0.952, 1.062, amber=True)
    headlamp("front", a0, a1, 0.822, 0.935)
# grille: black egg-crate in two rows
for b0, b1 in ((0.952, 1.062), (0.822, 0.935)):
    rect("front", -0.505, 0.505, b0, b1, rgb=(14, 14, 15), paint=0)
    x = -0.505
    while x <= 0.505:
        fill("front", [(x, b0), (x, b1)], rgb=(70, 70, 74), line=0.004)
        x += 0.034
    z = b0
    while z <= b1:
        fill("front", [(-0.505, z), (0.505, z)], rgb=(70, 70, 74), line=0.004)
        z += 0.024
chrome_rect("front", -0.905, 0.905, 0.935, 0.952, steps=4)                          # centre bar (no badge)
rect("front", -0.905, 0.905, 1.072, 1.12, rgb=(255, 255, 255), paint=255, chrome=0, shade=225)   # hood nose
seam("front", [(-0.905, 1.085), (0.905, 1.085)], w=0.004, shade=80)

# ---------------------------------------------------------------- rear (barn doors)
rect("rear", -1.0, 1.0, 0.58, 0.665, rgb=(30, 30, 32), paint=0, shade=255)
seam("rear", [(0.0, 0.665), (0.0, 1.745)], w=0.006, shade=40)
for s in (1, -1):
    seam("rear", [(s * 0.86, 0.68), (s * 0.86, 1.745)], w=0.006, shade=50)
    a0, a1 = sorted((s * 0.022, s * 0.80))
    rrect("rear", a0, a1, 1.275, 1.728, 0.02, rgb=TRIM, paint=0, shade=255)
    a0, a1 = sorted((s * 0.035, s * 0.785))
    glass("rear", [(a0, 1.29), (a1, 1.29), (a1, 1.713), (a0, 1.713)])
    a0, a1 = sorted((s * 0.80, s * 0.918))                    # taillights
    rrect("rear", a0, a1, 0.86, 1.32, 0.012, rgb=(60, 10, 8), paint=0, shade=255)
    rect("rear", a0 + 0.008, a1 - 0.008, 1.02, 1.31, rgb=RED, tail=255, shade=255)
    rect("rear", a0 + 0.008, a1 - 0.008, 0.95, 1.015, rgb=(225, 225, 230), chrome=200, tail=0)
    rect("rear", a0 + 0.008, a1 - 0.008, 0.87, 0.945, rgb=RED, tail=255)
    for z in (1.08, 1.15, 1.22):
        fill("rear", [(a0 + 0.01, z), (a1 - 0.01, z)], rgb=(120, 10, 8), line=0.003)
    for z in (0.95, 1.42):                                    # hinges
        rect("rear", s * 0.868 - 0.012, s * 0.868 + 0.012, z, z + 0.07, rgb=TRIM, paint=0)
rrect("rear", 0.05, 0.18, 1.06, 1.105, 0.012, rgb=TRIM, paint=0, shade=255)            # handle (right door)
rect("rear", 0.06, 0.17, 1.066, 1.072, rgb=(5, 5, 6), paint=0)
rect("rear", -0.10, 0.10, 1.743, 1.762, rgb=RED, paint=0, tail=255, shade=255)          # third brake light

# ---------------------------------------------------------------- top
rect("top", COWL_Y - 0.01, HOOD_END_Y + 0.004, -0.86, 0.86, rgb=(25, 25, 27), paint=0, shade=255)   # cowl vent
y = COWL_Y + 0.005
while y < HOOD_END_Y:
    fill("top", [(y, -0.80), (y, 0.80)], rgb=(60, 60, 62), line=0.004)
    y += 0.012
for s in (1, -1):
    seam("top", [(HOOD_END_Y, s * 0.905), (NOSE_Y, s * 0.85)], w=0.007, shade=70)        # hood gaps
    seam("top", [(HEADER_Y, s * 0.80), (-2.42, s * 0.84)], w=0.010, shade=120)           # drip rails
    # roof rack side rails
    rrect("top", -2.36, -0.32, s * 0.60 - 0.02, s * 0.60 + 0.02, 0.02, rgb=(35, 35, 38), paint=0, shade=255)
seam("top", [(NOSE_Y - 0.008, -0.85), (NOSE_Y - 0.008, 0.85)], w=0.005, shade=90)
seam("top", [(HOOD_END_Y + 0.003, -0.905), (HOOD_END_Y + 0.003, 0.905)], w=0.006, shade=60)
for yy in (-0.95, -1.75):                                    # rack cross bars
    rect("top", yy - 0.02, yy + 0.02, -0.60, 0.60, rgb=(45, 45, 48), paint=0, shade=255)

# ---------------------------------------------------------------- windscreen
WS_LEN = _l
rect("wind", -1.0, 1.0, -0.02, WS_LEN + 0.02, rgb=TRIM, paint=0, shade=255)
glass("wind", [(-0.755, 0.035), (0.755, 0.035), (0.705, WS_LEN - 0.035), (-0.705, WS_LEN - 0.035)])
for x0 in (-0.66, -0.02):                                    # parked wipers
    fill("wind", [(x0, 0.05), (x0 + 0.60, 0.065)], rgb=(10, 10, 10), alpha=255, line=0.012)
    fill("wind", [(x0 + 0.05, 0.045), (x0 + 0.32, 0.06)], rgb=(10, 10, 10), alpha=255, line=0.02)


# ---------------------------------------------------------------- bumpers
def prof_v(profile, z):
    """Profile length coordinate at height z on the front-facing run."""
    v = 0.0
    for (d0, z0), (d1, z1) in zip(profile, profile[1:]):
        seg = math.hypot(d1 - d0, z1 - z0)
        if min(z0, z1) <= z <= max(z0, z1) and abs(z1 - z0) > 1e-6:
            return v + seg * (z0 - z) / (z0 - z1) if z0 > z1 else v + seg * (z - z0) / (z1 - z0)
        v += seg
    return v


def bands(region, profile, spec):
    """spec: list of (v0, v1, kind) along the profile length."""
    for v0, v1, kind in spec:
        if kind == "chrome":
            chrome_rect(region, -1.28, 1.28, v0, v1, steps=6)
        elif kind == "black":
            rect(region, -1.28, 1.28, v0, v1, rgb=(24, 24, 26), paint=0, chrome=0, shade=255)
        elif kind == "pad":
            rect(region, -1.28, 1.28, v0, v1, rgb=(30, 30, 32), paint=0, chrome=0, shade=255)
            u = -1.28
            while u < 1.28:
                fill(region, [(u, v0), (u, v1)], rgb=(12, 12, 13), line=0.005)
                u += 0.02


fv = [0.0]
for a, b in zip(F_PROF, F_PROF[1:]):
    fv.append(fv[-1] + math.hypot(b[0] - a[0], b[1] - a[1]))
bands("fbump", F_PROF, [(0, fv[2], "chrome"), (fv[2], fv[3], "black"), (fv[3], fv[4], "chrome"), (fv[4], fv[5], "black")])
pv0, pv1 = prof_v(F_PROF, 0.60), prof_v(F_PROF, 0.505)
pv0 = fv[3] + 0.004
rect("fbump", -0.155, 0.155, pv0, pv0 + 0.088, rgb=(40, 40, 42), paint=0, chrome=0)           # plate bracket
rect("fbump", -0.148, 0.148, pv0 + 0.006, pv0 + 0.082, rgb=(232, 232, 224), paint=0)
rect("fbump", -0.148, 0.148, pv0 + 0.006, pv0 + 0.018, rgb=(40, 70, 150), paint=0)

rv = [0.0]
for a, b in zip(R_PROF, R_PROF[1:]):
    rv.append(rv[-1] + math.hypot(b[0] - a[0], b[1] - a[1]))
bands("rbump", R_PROF, [(0, rv[1], "pad"), (rv[1], rv[3], "chrome"), (rv[3], rv[4], "black")])
rect("rbump", -0.18, 0.18, rv[1] + 0.012, rv[1] + 0.112, rgb=(22, 22, 24), paint=0, chrome=0)   # plate recess
rect("rbump", -0.152, 0.152, rv[1] + 0.022, rv[1] + 0.102, rgb=(232, 232, 224), paint=0)
rect("rbump", -0.152, 0.152, rv[1] + 0.022, rv[1] + 0.034, rgb=(40, 70, 150), paint=0)

# black texel
x, yb = BLACK_PX
for k, v in (("r", 12), ("g", 12), ("b", 13), ("a", 255), ("mr", 0), ("mg", 0), ("mb", 0), ("ma", 150)):
    D[k].rectangle([(x - 8) * SS, (yb - 8) * SS, (x + 8) * SS, (yb + 7) * SS], fill=v)

# ---------------------------------------------------------------- downsample + hand-painted shading
arr = {k: np.asarray(im.resize((ATLAS, ATLAS), Image.LANCZOS), dtype=np.float32) / 255.0 for k, im in L.items()}
ma = arr["ma"]
yy, xx = np.mgrid[0:ATLAS, 0:ATLAS].astype(np.float32)


def region_ab(view):
    rx, ry, rw, rh, a0, b0, su, sv, ad = VIEWS[view]
    sl = (slice(ry, ry + rh), slice(rx, rx + rw))
    a = a0 + (xx[sl] - rx) / (su * ad)
    b = b0 - (yy[sl] - ry) / sv
    return sl, a, b


for view in ("left", "right"):
    sl, a, z = region_ab(view)
    g = np.ones_like(z)
    g *= np.where(z > CREASE_Z, 1.06, 0.93 + 0.05 * np.clip((z - ZF) / (CREASE_Z - ZF), 0, 1))   # light catches the shoulder
    g *= 1.0 - 0.25 * np.clip((0.62 - z) / 0.17, 0, 1)                                        # rocker in shadow
    g *= np.where(np.abs(z - CREASE_Z) < 0.006, 1.12, 1.0)                                    # crease highlight
    ma[sl] = np.clip(ma[sl] * g, 0, 1)
sl, a, x = region_ab("top")
ma[sl] = np.clip(ma[sl] * (1.0 - 0.10 * np.clip((np.abs(x) - 0.55) / 0.35, 0, 1)), 0, 1)        # crown falloff
sl, x, z = region_ab("rear")
ma[sl] = np.clip(ma[sl] * (1.0 - 0.2 * np.clip((0.80 - z) / 0.2, 0, 1)), 0, 1)

detail = np.dstack([arr["r"], arr["g"], arr["b"], arr["a"]])
mask = np.dstack([arr["mr"], arr["mg"], arr["mb"], ma])
os.makedirs(OUT, exist_ok=True)
Image.fromarray((detail * 255 + 0.5).astype(np.uint8), "RGBA").save(os.path.join(OUT, "body_detail.png"))
Image.fromarray((mask * 255 + 0.5).astype(np.uint8), "RGBA").save(os.path.join(OUT, "body_mask.png"))
log("texture sheet", ATLAS)

# =========================================================== interior / steering from the parts file
bpy.ops.import_scene.gltf(filepath=os.path.join(SRC, "tahoe_body.glb"))
keep = []
for o in list(bpy.context.scene.objects):
    if o == low:
        continue
    if o.name.startswith("Interior") or o.name.startswith("SteeringWheel"):
        keep.append(o)
for o in list(bpy.context.scene.objects):
    if o != low and o not in keep:
        bpy.data.objects.remove(o, do_unlink=True)
for o in keep:
    o.name = o.name.split(".")[0]
    bpy.context.view_layer.objects.active = o
    o.select_set(True)
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
    o.select_set(False)
low.name = "Body"
me.name = "Body"
log("kept", [o.name for o in keep])

# =========================================================== export
bpy.ops.object.select_all(action="DESELECT")
for o in [low] + keep:
    o.select_set(True)
bpy.context.view_layer.objects.active = low
bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, "tahoe_body.glb"), export_format="GLB",
                          use_selection=True, export_apply=True, export_yup=True)
shutil.copy(os.path.join(SRC, "tahoe_wheel.glb"), os.path.join(OUT, "tahoe_wheel.glb"))
tri = lambda o: sum(len(p.vertices) - 2 for p in o.data.polygons)
info = json.load(open(os.path.join(SRC, "model_info.json")))
for k in ("source", "source_url", "license", "modifications"):
    info.pop(k, None)
info["source"] = "Built from scratch: hand-placed low-poly GMT400 body and a texture painted in code (build_tahoe_scratch.py)"
info["baked"] = {"detail": "body_detail.png", "mask": "body_mask.png", "size": ATLAS, "style": "gt1_scratch"}
info["triangles_body_shell"] = tri(low)
info["triangles"] = tri(low) + sum(tri(o) for o in keep) + 4 * 682
json.dump(info, open(os.path.join(OUT, "model_info.json"), "w"), indent=2)
log("TRIANGLES body %d  interior+steering %d" % (tri(low), sum(tri(o) for o in keep)))
