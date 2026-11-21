"""GT3-style low-poly car: bake the detailed body onto a simple shell.

Gran Turismo 3 cars are a low-poly hull whose lamps, grille, chrome, handles,
moldings and panel shading live in a texture. This script takes the detailed
model made by convert_tahoe_glb.py ("high") and produces:

  tahoe_body.glb   low-poly body shell (one UV-mapped material "BakedBody"),
                   separate transparent glass, the interior and steering wheel
  body_detail.png  baked albedo of everything that isn't paint (paint = white)
  body_mask.png    R = paint, G = chrome/bright metal, B = tail lamp,
                   A = baked ambient occlusion

Run (Blender as a Python module):
  bvenv/bin/python tools/blender/bake_lowpoly.py -- <high_dir> <out_dir> [body_tris] [tex_size]
"""
import bpy
import bmesh
import json
import math
import os
import shutil
import sys

argv = sys.argv[sys.argv.index("--") + 1:]
SRC, OUT = argv[0], argv[1]
BODY_TRIS = int(argv[2]) if len(argv) > 2 else 3500
TEX = int(argv[3]) if len(argv) > 3 else 1024


def log(*a):
    print("[bake]", *a, flush=True)


def tris(o):
    return sum(len(p.vertices) - 2 for p in o.data.polygons)


def only_select(objs, active):
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = active


bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=os.path.join(SRC, "tahoe_body.glb"))
for o in bpy.context.scene.objects:            # bake glTF node transforms into the meshes
    if o.type == "MESH":
        only_select([o], o)
        bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
high = bpy.data.objects["Body"]
interior = bpy.data.objects.get("Interior")
steering = bpy.data.objects.get("SteeringWheel")
moldings = bpy.data.objects.get("ArchMoldings")
names = [m.name for m in high.data.materials]
log("high body tris", tris(high))

# ---------------------------------------------------------------- low shell
low = high.copy()
low.data = high.data.copy()
low.name = "BodyLow"
bpy.context.collection.objects.link(low)
# glass stays real geometry (transparent, and the cockpit needs to see out)
glass = high.copy()
glass.data = high.data.copy()
glass.name = "Glass"
bpy.context.collection.objects.link(glass)
gi = names.index("Glass")
for ob, keep_glass in ((low, False), (glass, True)):
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    kill = [f for f in bm.faces if (f.material_index == gi) != keep_glass]
    bmesh.ops.delete(bm, geom=kill, context="FACES")
    bm.to_mesh(ob.data)
    bm.free()

only_select([low], low)
m = low.modifiers.new("planar", "DECIMATE")
m.decimate_type = "DISSOLVE"
m.angle_limit = math.radians(2.0)
bpy.ops.object.modifier_apply(modifier=m.name)
bpy.ops.object.mode_set(mode="EDIT")
bpy.ops.mesh.select_all(action="SELECT")
bpy.ops.mesh.quads_convert_to_tris()
bpy.ops.object.mode_set(mode="OBJECT")
t0 = tris(low)
if t0 > BODY_TRIS:
    m = low.modifiers.new("collapse", "DECIMATE")
    m.ratio = BODY_TRIS / t0
    m.use_symmetry = True
    m.symmetry_axis = "X"
    bpy.ops.object.modifier_apply(modifier=m.name)
log("low body tris", tris(low), "(from", t0, "after planar dissolve)")

# mirrored halves come in with inverted winding: point every face outward
# (on the shell, and on the detailed body the AO is computed from)
def face_outward(ob, recalc=True):
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    if recalc:
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    flipped = 0
    for f in bm.faces:
        c = f.calc_center_median()
        axis = c.copy()
        axis.x = 0.0
        axis.y = max(-1.9, min(1.9, c.y))
        axis.z = 0.95
        if f.normal.dot(c - axis) < 0:
            f.normal_flip()
            flipped += 1
    bm.to_mesh(ob.data)
    bm.free()
    return flipped


log("faces turned outward: shell", face_outward(low), "detailed", face_outward(high, recalc=False))

# one material + UVs
for p in low.data.polygons:
    p.material_index = 0
low.data.materials.clear()
bm_mat = bpy.data.materials.new("BakedBody")
bm_mat.use_nodes = True
low.data.materials.append(bm_mat)
while low.data.uv_layers:
    low.data.uv_layers.remove(low.data.uv_layers[0])
low.data.uv_layers.new(name="UVMap")
only_select([low], low)
bpy.ops.object.mode_set(mode="EDIT")
bpy.ops.mesh.select_all(action="SELECT")
bpy.ops.uv.smart_project(angle_limit=math.radians(55), island_margin=0.004, area_weight=0.0,
                         correct_aspect=True, scale_to_bounds=False)
bpy.ops.uv.pack_islands(margin=0.004)
bpy.ops.object.mode_set(mode="OBJECT")
for p in low.data.polygons:
    p.use_smooth = True
low.data.set_sharp_from_angle(angle=math.radians(40))

# ---------------------------------------------------------------- bake setup
scn = bpy.context.scene
scn.render.engine = "CYCLES"
scn.cycles.device = "CPU"
scn.cycles.samples = 8
bk = scn.render.bake
bk.use_selected_to_active = True
bk.cage_extrusion = 0.035
bk.max_ray_distance = 0.12
bk.margin = 6

nt = bm_mat.node_tree
tex_node = nt.nodes.new("ShaderNodeTexImage")
nt.nodes.active = tex_node


def target(name, alpha=False, color=True):
    img = bpy.data.images.new(name, TEX, TEX, alpha=alpha, float_buffer=False)
    if not color:
        img.colorspace_settings.name = "Non-Color"
    tex_node.image = img
    return img


def bake(kind, **kw):
    only_select([high, low], low)
    bpy.ops.object.bake(type=kind, **kw)


originals = list(high.data.materials)


def swap(per_name):
    for i, mat in enumerate(originals):
        high.data.materials[i] = per_name(mat.name, mat)


def restore():
    for i, mat in enumerate(originals):
        high.data.materials[i] = mat


# 1) detail albedo: paint white, everything non-metal so the diffuse pass keeps its colour
def albedo_mat(name, src):
    mm = src.copy()
    b = mm.node_tree.nodes.get("Principled BSDF")
    if b:
        if name in ("Paint", "Lower"):
            b.inputs["Base Color"].default_value = (1, 1, 1, 1)
        b.inputs["Metallic"].default_value = 0.0
    return mm


swap(albedo_mat)
detail = target("body_detail")
bake("DIFFUSE", pass_filter={"COLOR"})
restore()
log("baked detail")


# 2) material mask as emission
def emit_mat(rgb):
    mm = bpy.data.materials.new("mask")
    mm.use_nodes = True
    n = mm.node_tree.nodes
    for x in list(n):
        n.remove(x)
    e = n.new("ShaderNodeEmission")
    e.inputs["Color"].default_value = (*rgb, 1)
    o = n.new("ShaderNodeOutputMaterial")
    mm.node_tree.links.new(e.outputs[0], o.inputs[0])
    return mm


MASKS = {"Paint": (1, 0, 0), "Lower": (1, 0, 0), "Stripe": (0, 0, 0), "Chrome": (0, 1, 0),
         "Rim": (0, 1, 0), "Taillight": (0, 0, 1)}
swap(lambda name, src: emit_mat(MASKS.get(name, (0, 0, 0))))
mask = target("body_mask", alpha=True, color=False)
bake("EMIT")
restore()
log("baked mask")

# 3) ambient occlusion (from the detailed body)
scn.cycles.samples = 64
scn.world = scn.world or bpy.data.worlds.new("W")
scn.world.light_settings.distance = 0.6
ao = target("body_ao", color=False)
bake("AO")
log("baked AO")

# pack AO into the mask alpha, save PNGs
os.makedirs(OUT, exist_ok=True)
mp = list(mask.pixels)
ap = list(ao.pixels)
for i in range(0, len(mp), 4):
    mp[i + 3] = ap[i]
mask.pixels = mp
for img, fn in ((detail, "body_detail.png"), (mask, "body_mask.png")):
    img.filepath_raw = os.path.join(OUT, fn)
    img.file_format = "PNG"
    img.save()
log("saved textures", TEX, "x", TEX)

# ---------------------------------------------------------------- export
tex_node.image = None
high.name = "BodyHigh"
low.name = "Body"
exp = [low, glass] + [o for o in (interior, steering, moldings) if o]
only_select(exp, low)
bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, "tahoe_body.glb"), export_format="GLB",
                          use_selection=True, export_apply=True, export_yup=True)
shutil.copy(os.path.join(SRC, "tahoe_wheel.glb"), os.path.join(OUT, "tahoe_wheel.glb"))
info = json.load(open(os.path.join(SRC, "model_info.json")))
wheel_tris = info["triangles"] - 0   # recomputed below
body_total = tris(low) + tris(glass) + sum(tris(o) for o in (interior, steering, moldings) if o)
info["baked"] = {"detail": "body_detail.png", "mask": "body_mask.png", "size": TEX}
info["triangles_body_shell"] = tris(low)
info["triangles"] = body_total + 4 * 682
json.dump(info, open(os.path.join(OUT, "model_info.json"), "w"), indent=2)
log("TRIANGLES shell %d glass %d interior %d steering %d => body total %d" %
    (tris(low), tris(glass), tris(interior) if interior else 0, tris(steering) if steering else 0, body_total))
