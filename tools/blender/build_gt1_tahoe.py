"""Gran Turismo 1 style Tahoe: a ~1k-triangle shell with an orthographically
projected texture sheet, like GT1 mapped side / front / rear / top views of the
real car onto a very simple hull.

The "photos" are renders of our own detailed model (convert_tahoe_glb.py
output), so the texture matches the reference trucks without copying anyone's
images or badges.

Outputs (in <out_dir>):
  tahoe_body.glb   Body (materials BakedBody + Glass), Interior, SteeringWheel
  body_detail.png  albedo sheet (paint = white so any paint colour can be used)
  body_mask.png    R paint, G chrome, B tail lamp, A baked lighting/shade
  model_info.json  copied from the detailed model, updated

Run: bvenv/bin/python tools/blender/build_gt1_tahoe.py -- <detailed_dir> <out_dir>
"""
import bpy
import bmesh
import json
import math
import os
import shutil
import sys
from mathutils import Vector
from bpy_extras.object_utils import world_to_camera_view

argv = sys.argv[sys.argv.index("--") + 1:]
SRC, OUT = argv[0], argv[1]
ATLAS = 2048
# atlas regions (x, y from the top, w, h) and camera setups (location, euler deg, ortho extent)
VIEWS = {
    "left":  ((0, 0, 2048, 768),     (-6.0, -0.20, 0.98), (90, 0, -90), 5.2),
    "right": ((0, 768, 2048, 768),   (6.0, -0.20, 0.98),  (90, 0, 90),  5.2),
    "top":   ((0, 1536, 1024, 512),  (0.0, -0.20, 8.0),   (0, 0, 90),   5.2),
    "front": ((1024, 1536, 512, 512), (0.0, 8.0, 1.0),    (90, 0, 180), 2.2),
    "rear":  ((1536, 1536, 512, 512), (0.0, -8.0, 1.0),   (90, 0, 0),   2.2),
}
BLACK_UV = ((2040 + 4) / ATLAS, 1.0 - (2040 + 4) / ATLAS)     # a painted-black corner texel
WHEEL_Y = 1.519
ARCH_R = 0.475


def log(*a):
    print("[gt1]", *a, flush=True)


# ------------------------------------------------------------------ scene
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=os.path.join(SRC, "tahoe_body.glb"))
for o in list(bpy.context.scene.objects):
    if o.type == "MESH":
        bpy.ops.object.select_all(action="DESELECT")
        o.select_set(True)
        bpy.context.view_layer.objects.active = o
        bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
high = bpy.data.objects["Body"]
interior = bpy.data.objects.get("Interior")
steering = bpy.data.objects.get("SteeringWheel")
moldings = bpy.data.objects.get("ArchMoldings")
info = json.load(open(os.path.join(SRC, "model_info.json")))
wz = 0.415          # hub height of the detailed model


def matname(o, idx):
    return o.data.materials[o.data.polygons[idx].material_index].name


def hide_for_probe(hide):
    for o in (interior, steering):
        if o:
            o.hide_viewport = hide
            o.hide_render = hide


# ------------------------------------------------------------------ shell
def cast(origin, d):
    """First hit on the body skin, skipping the roof rack and mirrors."""
    dg = bpy.context.evaluated_depsgraph_get()
    o = origin.copy()
    for _ in range(8):
        hit, loc, n, idx, ob, _m = bpy.context.scene.ray_cast(dg, o, d)
        if not hit:
            return None
        m = matname(ob, idx)
        skip = (m == "Black" and loc.z > 1.79) or (m == "Black" and abs(loc.x) > 0.93 and loc.z > 1.05)
        if not skip:
            return loc
        o = loc + d * 0.002
    return None


SIDE_Z = [0.44, 0.62, 0.84, 1.05, 1.22, 1.42, 1.62]     # level rays from the side
TOP_X = [0.68, 0.35, 0.0]                               # straight-down rays
R = ARCH_R
_arch = [WHEEL_Y + R * k for k in (1.0, 0.7, 0.35, 0.0, -0.35, -0.7, -1.0)]
STATIONS = ([2.34, 2.27, 2.22, 2.10] + [a + 0.0 for a in _arch] +
            [0.95, 0.80, 0.62, 0.42, 0.10, -0.30, -0.70, -0.98] + [-a for a in reversed(_arch)] +
            [-2.10, -2.30, -2.45, -2.56, -2.60, -2.66, -2.74])


def section(y):
    side = []
    for z in SIDE_Z:
        p = cast(Vector((3.0, y, z)), Vector((-1, 0, 0)))
        side.append(None if p is None else Vector((p.x, y, z)))
    top = []
    for x in TOP_X:
        p = cast(Vector((x, y, 3.0)), Vector((0, 0, -1)))
        top.append(None if p is None else Vector((x, y, p.z)))
    valid = [p for p in side if p is not None]
    if not valid:
        valid = [Vector((0.9, y, 0.6))]
    # fill misses: below the body -> first valid, above -> last valid
    first = next(k for k, p in enumerate(side) if p is not None) if any(side) else 0
    for k in range(len(side)):
        if side[k] is None:
            side[k] = (side[first] if k < first else side[k - 1]).copy()
    ztop_side = max(p.z for p in side)
    xs = side[-1].x
    for k, x in enumerate(TOP_X):
        if top[k] is None:
            top[k] = Vector((min(x, xs), y, ztop_side))
        top[k].x = min(top[k].x, xs)
        top[k].z = max(top[k].z, side[-1].z if top[k].x >= xs - 1e-4 else top[k].z)
    pts = side + top
    pts[-1].x = 0.0
    # wheel arch openings: lift the lower side up to the arch line
    for wy in (WHEEL_Y, -WHEEL_Y):
        dy = y - wy
        if abs(dy) < ARCH_R - 1e-4:
            az = wz + math.sqrt(ARCH_R * ARCH_R - dy * dy)
            for p in pts:
                if p.z < az and p.x > 0.45:
                    p.z = az
    return pts


hide_for_probe(True)
secs = [section(y) for y in STATIONS]
hide_for_probe(False)

bm = bmesh.new()
rings = []
for pts in secs:
    right = [bm.verts.new(p) for p in pts]
    left = [bm.verts.new((-p.x, p.y, p.z)) for p in pts]
    # ring order: left bottom -> left top ... (mirror) ... right top -> right bottom
    ring = list(reversed(left[:-1])) + right          # left[-1] == right[-1] at x = 0 (top centre)
    rings.append(ring)
for k in range(len(rings) - 1):
    a, b = rings[k], rings[k + 1]
    n = len(a)
    for j in range(n):                                # j = n-1 closes the bottom (right bottom -> left bottom)
        j2 = (j + 1) % n
        try:
            bm.faces.new((a[j], a[j2], b[j2], b[j]))
        except ValueError:
            pass
for ring in (rings[0], rings[-1]):
    try:
        bm.faces.new(ring)
    except ValueError:
        pass
bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=0.004)
# degenerate quads (collapsed arch points) -> drop
bmesh.ops.dissolve_degenerate(bm, edges=bm.edges, dist=0.002)
# mirrors
for sx in (-1, 1):
    r = bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=(0.07, 0.22, 0.17), verts=r["verts"])
    bmesh.ops.translate(bm, vec=(sx * 1.02, 0.86, 1.31), verts=r["verts"])
bmesh.ops.triangulate(bm, faces=bm.faces)
# drop slivers left by collapsed section points
slivers = [f for f in bm.faces if f.calc_area() < 1e-5]
bmesh.ops.delete(bm, geom=slivers, context="FACES")
# point every face outward (the shell is open at the arches, so the automatic
# recalculation can't be trusted): outward = away from the truck's centre line
for f in bm.faces:
    f.normal_update()
    c = f.calc_center_median()
    ax = Vector((0.0, max(-2.0, min(1.9, c.y)), 0.95))
    out = c - ax
    if abs(c.x) < 0.5 and c.z > 1.0:          # roof / hood / windscreen: up and outward
        out = Vector((c.x, 0.0, 1.0)) if -2.4 < c.y < 2.1 else out
    if f.normal.dot(out) < 0:
        f.normal_flip()
me = bpy.data.meshes.new("Body")
bm.to_mesh(me)
bm.free()
low = bpy.data.objects.new("BodyGT1", me)
bpy.context.collection.objects.link(low)
log("shell triangles", len(me.polygons))

# ------------------------------------------------------------------ cameras
scn = bpy.context.scene
cams = {}
for name, (reg, loc, eul, ext) in VIEWS.items():
    cd = bpy.data.cameras.new(name)
    cd.type = "ORTHO"
    cd.ortho_scale = ext
    cam = bpy.data.objects.new("cam_" + name, cd)
    cam.location = loc
    cam.rotation_euler = tuple(math.radians(v) for v in eul)
    scn.collection.objects.link(cam)
    cams[name] = cam
bpy.context.view_layer.update()          # camera matrices must be current before projecting UVs


def view_for(n):
    if n.z > 0.62:
        return "top"
    if n.z < -0.55:
        return None
    if abs(n.x) >= abs(n.y) * 0.75:
        return "left" if n.x < 0 else "right"
    return "front" if n.y > 0 else "rear"


glass_faces = set()
me.materials.append(bpy.data.materials.new("BakedBody"))
uvl = me.uv_layers.new(name="UVMap")
scn.render.resolution_percentage = 100
for p in me.polygons:
    p.material_index = 0
    v = view_for(p.normal)
    c = p.center
    for wy in (WHEEL_Y, -WHEEL_Y):         # inside the wheel openings: plain black wheelhouse
        if math.hypot(c.y - wy, c.z - wz) < ARCH_R + 0.015 and abs(c.x) > 0.3:
            v = None
    for li in p.loop_indices:
        if v is None:
            uvl.data[li].uv = BLACK_UV
            continue
        (rx, ry, rw, rh), loc, eul, ext = VIEWS[v]
        scn.render.resolution_x, scn.render.resolution_y = rw, rh
        co = me.vertices[me.loops[li].vertex_index].co
        q = world_to_camera_view(scn, cams[v], co)
        uvl.data[li].uv = ((rx + q.x * rw) / ATLAS, 1.0 - (ry + (1.0 - q.y) * rh) / ATLAS)

# ------------------------------------------------------------------ renders
scn.render.engine = "CYCLES"
scn.cycles.device = "CPU"
scn.render.film_transparent = True
scn.render.image_settings.file_format = "PNG"
scn.render.image_settings.color_mode = "RGBA"
scn.view_settings.view_transform = "Standard"
low.hide_render = True
for o in (interior, steering):
    if o:
        o.hide_render = True
originals = list(high.data.materials)
mold_orig = list(moldings.data.materials) if moldings else []


def emission_of(src, rgb=None):
    mm = bpy.data.materials.new("e")
    mm.use_nodes = True
    nt = mm.node_tree
    for x in list(nt.nodes):
        nt.nodes.remove(x)
    e = nt.nodes.new("ShaderNodeEmission")
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    nt.links.new(e.outputs[0], out.inputs[0])
    if rgb is not None:
        e.inputs["Color"].default_value = (*rgb, 1)
        return mm
    b = src.node_tree.nodes.get("Principled BSDF") if src.use_nodes else None
    col = (0.5, 0.5, 0.5, 1)
    if b:
        col = tuple(b.inputs["Base Color"].default_value)
        lk = b.inputs["Base Color"].links
        if lk and lk[0].from_node.type == "TEX_IMAGE":
            t = nt.nodes.new("ShaderNodeTexImage")
            t.image = lk[0].from_node.image
            uvn = nt.nodes.new("ShaderNodeUVMap")
            nt.links.new(uvn.outputs[0], t.inputs[0])
            nt.links.new(t.outputs[0], e.inputs["Color"])
            return mm
    if src.name in ("Paint", "Lower"):
        col = (1, 1, 1, 1)
    if src.name == "Chrome":
        col = (0.80, 0.81, 0.83, 1)
    e.inputs["Color"].default_value = col
    return mm


def white_diffuse():
    mm = bpy.data.materials.new("w")
    mm.use_nodes = True
    mm.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.8, 0.8, 0.8, 1)
    mm.node_tree.nodes["Principled BSDF"].inputs["Roughness"].default_value = 0.9
    return mm


MASK = {"Paint": (1, 0, 0), "Lower": (1, 0, 0), "Chrome": (0, 1, 0), "Rim": (0, 1, 0), "Taillight": (0, 0, 1)}


def assign(fn):
    for i, m in enumerate(originals):
        high.data.materials[i] = fn(m)
    if moldings:
        for i, m in enumerate(mold_orig):
            moldings.data.materials[i] = fn(m)


def render_views(tag, samples):
    scn.cycles.samples = samples
    imgs = {}
    for name, (reg, loc, eul, ext) in VIEWS.items():
        scn.camera = cams[name]
        scn.render.resolution_x, scn.render.resolution_y = reg[2], reg[3]
        fp = "/tmp/gt1_%s_%s.png" % (tag, name)
        scn.render.filepath = fp
        bpy.ops.render.render(write_still=True)
        imgs[name] = fp
    return imgs


world = bpy.data.worlds.new("W")
scn.world = world
world.use_nodes = True
bg = world.node_tree.nodes["Background"]

# albedo (flat colours) and mask: emission only, black world
bg.inputs["Strength"].default_value = 0.0
glass_hide = {"Glass"}
assign(lambda m: emission_of(m))
alb = render_views("albedo", 1)
assign(lambda m: emission_of(m, MASK.get(m.name, (0, 0, 0))))
msk = render_views("mask", 1)
assign(lambda m: emission_of(m, (1, 1, 1) if m.name == "Glass" else (0, 0, 0)))
gls = render_views("glass", 1)
# lighting: white clay under a soft sky with a gentle key from above
assign(lambda m: white_diffuse())
sky = world.node_tree.nodes.new("ShaderNodeTexSky")
bg.inputs["Color"].default_value = (1, 1, 1, 1)
bg.inputs["Strength"].default_value = 1.0
sun = bpy.data.objects.new("key", bpy.data.lights.new("key", "SUN"))
sun.data.energy = 1.6
sun.rotation_euler = (math.radians(25), math.radians(-20), 0)
scn.collection.objects.link(sun)
shd = render_views("shade", 48)
for i, m in enumerate(originals):
    high.data.materials[i] = m

# ------------------------------------------------------------------ atlas
import numpy as np


def load_rgba(fp):
    im = bpy.data.images.load(fp)
    a = np.array(im.pixels[:], dtype=np.float32).reshape(im.size[1], im.size[0], 4)
    return a[::-1]                     # top row first


def dilate(a, it=24):
    rgb, al = a[..., :3].copy(), (a[..., 3] > 0.5).astype(np.float32)
    for _ in range(it):
        acc = np.zeros_like(rgb)
        cnt = np.zeros(al.shape, np.float32)
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            acc += np.roll(np.roll(rgb * al[..., None], dy, 0), dx, 1)
            cnt += np.roll(np.roll(al, dy, 0), dx, 1)
        grow = (al == 0) & (cnt > 0)
        rgb[grow] = acc[grow] / cnt[grow][:, None]
        al[grow] = 1.0
    return rgb


detail = np.zeros((ATLAS, ATLAS, 4), np.float32)
mask = np.zeros((ATLAS, ATLAS, 4), np.float32)
detail[..., 3] = 1.0
for name, (reg, loc, eul, ext) in VIEWS.items():
    x, y, w, h = reg
    A = dilate(load_rgba(alb[name]))
    M = dilate(load_rgba(msk[name]))
    S = dilate(load_rgba(shd[name]))
    G = dilate(load_rgba(gls[name]))[..., 0]
    lum = np.clip(S.mean(-1) / max(1e-3, np.percentile(S.mean(-1), 97)), 0.0, 1.0)
    detail[y:y + h, x:x + w, :3] = A
    detail[y:y + h, x:x + w, 3] = 1.0 - 0.72 * np.clip(G, 0, 1)      # windows: see-through tint
    mask[y:y + h, x:x + w, :3] = M
    mask[y:y + h, x:x + w, 3] = 0.35 + 0.65 * lum
detail[2036:2048, 2036:2048, :3] = 0.02          # black texel for undersides / wheelhouses
mask[2036:2048, 2036:2048] = (0, 0, 0, 0.6)
os.makedirs(OUT, exist_ok=True)
for arr, fn, cs in ((detail, "body_detail.png", "sRGB"), (mask, "body_mask.png", "Non-Color")):
    im = bpy.data.images.new(fn, ATLAS, ATLAS, alpha=True)
    im.colorspace_settings.name = cs
    im.pixels.foreach_set(arr[::-1].ravel())
    im.filepath_raw = os.path.join(OUT, fn)
    im.file_format = "PNG"
    im.save()
log("texture sheet", ATLAS, "x", ATLAS)

# ------------------------------------------------------------------ export
high.name = "BodyHigh"
low.name = "Body"
for p in me.polygons:
    p.use_smooth = False
bpy.ops.object.select_all(action="DESELECT")
exp = [low] + [o for o in (interior, steering) if o]
for o in exp:
    o.select_set(True)
bpy.context.view_layer.objects.active = low
bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, "tahoe_body.glb"), export_format="GLB",
                          use_selection=True, export_apply=True, export_yup=True)
shutil.copy(os.path.join(SRC, "tahoe_wheel.glb"), os.path.join(OUT, "tahoe_wheel.glb"))
tri = lambda o: sum(len(p.vertices) - 2 for p in o.data.polygons)
info["baked"] = {"detail": "body_detail.png", "mask": "body_mask.png", "size": ATLAS, "style": "gt1"}
info["triangles_body_shell"] = tri(low)
info["triangles"] = tri(low) + sum(tri(o) for o in (interior, steering) if o) + 4 * 682
json.dump(info, open(os.path.join(OUT, "model_info.json"), "w"), indent=2)
log("TRIANGLES shell %d (glass %d) interior %d steering %d" %
    (tri(low), len(glass_faces), tri(interior) if interior else 0, tri(steering) if steering else 0))
