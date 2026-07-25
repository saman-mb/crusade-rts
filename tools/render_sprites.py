#!/usr/bin/env python3
"""Headless Blender iso sprite-sheet renderer for Crusade (#245).

The SC1/AoE pipeline: a 3D model is rotated about world Z in 45 deg steps under a
WORLD-FIXED orthographic iso camera + baked NW sun, rendered onto a transparent
film, and packed into a 2D 8-direction sprite sheet + JSON manifest. The camera,
both suns and the shadow catcher NEVER move -- only the model spins -- so every
facing is lit identically and the SE cast shadow never swings.

All layout/geometry/facing numbers come from the pure `sprite_manifest` module
(the single source of truth). This driver only owns the Blender rig. It renders
each frame at 2x (512) and area-downsamples to the 256 cell for clean alpha edges,
blits into a numpy RGBA sheet, and saves via a bpy Image (no Pillow).

This file imports bpy/numpy and therefore does NOT run in CI -- only
sprite_manifest (pure stdlib) is tested there. Run it by hand:

    blender --background --python tools/render_sprites.py -- --model suzanne --out assets/sprites/_test

Calibration self-check (verifies ortho_scale / shift / anchor):

    blender --background --python tools/render_sprites.py -- --calibrate --out /tmp/cal
    blender --background --python tools/render_sprites.py -- --calibrate --markers --out /tmp/cal

Deterministic: fixed Cycles seed, no adaptive sampling. See docs/ART_PIPELINE.md.
"""

import argparse
import math
import os
import sys

import bpy       # noqa: E402  (Blender-only; never imported by CI)
import numpy as np

# tools/ is not on sys.path when Blender runs an absolute script path.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sprite_manifest as sm  # noqa: E402

# --- Render resolution ---
CELL = sm.CELL_W                      # 256 final cell (square: CELL_W == CELL_H)
SS = 2                                # supersample factor
RENDER_PX = CELL * SS                 # 512 per-frame render
N_ANIM = 1                            # this story: one static pose per direction
N_FRAMES = sm.DIRECTIONS * N_ANIM     # 8

# --- Model-rotation mapping (see module docstring for the derivation) ---
# frame i depicts sm.direction_facing(i); the model's front must point at world
# angle phi_i = 45 - 45*i deg. Suzanne faces world -Y (phi0 = 270 deg), so
# model.rotation_euler.z = radians(BASE_DEG + STEP_DEG*i) with BASE = 45 - phi0.
# STEP is NEGATIVE: with screen +Y DOWN and the manifest's clockwise order, a
# clockwise-on-screen advance is a *negative* world-Z rotation. Verified by render.
BASE_DEG = 135.0
STEP_DEG = -45.0

# --- Anchor placement: world origin (0,0,0) must land on cell pixel ANCHOR. ---
# Horizontally centred (ANCHOR.x == CELL/2 -> shift_x 0); pushed DOWN in the cell.
# Blender's shift_y is a fraction of the sensor's fit dimension; empirically
# (--calibrate) a POSITIVE shift_y moves the projected origin DOWN toward larger
# pixel-y, which is what we want (ANCHOR.y 176 > cell centre 128).
_SHIFT_FRAC = (sm.ANCHOR[1] - CELL / 2.0) / CELL     # 0.1875 downward
SHIFT_X = 0.0
SHIFT_Y = _SHIFT_FRAC

# --- Rig angles (art-director's numbers) ---
CAM_EULER = (math.radians(60.0), 0.0, math.radians(45.0))
CAM_DIST = 12.0                       # ortho: position only affects clipping
MODEL_SCALE = 0.7                     # Suzanne ~2.7 wide -> ~1.9 (footprint ~1 tile)


def reset_scene():
    """Strip the startup scene down to an empty world (no default cube/cam/light)."""
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj, do_unlink=True)
    for block in (bpy.data.meshes, bpy.data.materials, bpy.data.lights, bpy.data.cameras):
        for db in list(block):
            if db.users == 0:
                block.remove(db)


def setup_render():
    """Cycles CPU, fixed seed, Standard view transform, transparent film.

    Returns (samples, denoise) actually used -- falls back to more samples with no
    denoiser if OpenImageDenoise cannot be engaged headless.
    """
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    cy = scene.cycles
    cy.device = "CPU"
    cy.use_adaptive_sampling = False
    cy.seed = 0

    samples, denoise = sm.SAMPLES, True
    try:
        cy.use_denoising = True
        cy.denoiser = "OPENIMAGEDENOISE"
        cy.samples = sm.SAMPLES
    except Exception as exc:                       # pragma: no cover - env dependent
        print("OIDN unavailable (%s); falling back to samples=256, no denoise" % exc)
        cy.use_denoising = False
        samples, denoise = 256, False
        cy.samples = samples

    scene.render.resolution_x = RENDER_PX
    scene.render.resolution_y = RENDER_PX
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = True
    scene.render.use_file_extension = True
    img = scene.render.image_settings
    img.file_format = "PNG"
    img.color_mode = "RGBA"
    img.color_depth = "8"

    vs = scene.view_settings
    vs.view_transform = "Standard"
    vs.look = "None"
    vs.exposure = 0.0
    vs.gamma = 1.0
    scene.display_settings.display_device = "sRGB"

    return samples, denoise


def setup_world():
    """Cool ambient fill (background colour + low strength)."""
    world = bpy.data.worlds.get("World") or bpy.data.worlds.new("World")
    bpy.context.scene.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes.get("Background")
    bg.inputs[0].default_value = (0.45, 0.55, 0.70, 1.0)
    bg.inputs[1].default_value = 0.20


def setup_camera():
    """World-fixed orthographic iso camera; origin projects to ANCHOR via shift."""
    cam_data = bpy.data.cameras.new("IsoCam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = sm.ORTHO_SCALE
    cam_data.sensor_fit = "HORIZONTAL"
    cam_data.shift_x = SHIFT_X
    cam_data.shift_y = SHIFT_Y
    cam_data.clip_start = 0.1
    cam_data.clip_end = 100.0

    cam = bpy.data.objects.new("IsoCam", cam_data)
    bpy.context.collection.objects.link(cam)
    cam.rotation_euler = CAM_EULER

    # View axis = camera local -Z in world; step back along it (ortho -> clip only).
    rot = cam.rotation_euler.to_matrix()
    view_dir = rot @ __import__("mathutils").Vector((0.0, 0.0, -1.0))
    cam.location = -view_dir * CAM_DIST
    bpy.context.scene.camera = cam
    return cam


def setup_lights():
    """NW key sun (only shadow-caster) + cool fill sun (no shadow). World-fixed."""
    key_d = bpy.data.lights.new("KeySun", type="SUN")
    key_d.color = (1.0, 0.86, 0.66)
    key_d.energy = 3.5
    key_d.angle = math.radians(2.5)
    key_d.use_shadow = True
    key = bpy.data.objects.new("KeySun", key_d)
    # DEVIATION from the brief's (radians(58),0,0): the marker calibration proved
    # that pitch aims the sun toward world +Y == screen NE, which would throw the
    # shadow to the screen UPPER-right. The manifest pins SUN_COMPASS="NW" and the
    # terrain/tree art (tools/gen_trees.py) bakes a NW-sun -> SE (screen lower-
    # right) shadow. Pitching about Y instead (58 deg from vertical -> 32 deg sun
    # elevation) aims the light toward world +X == screen SE, matching that
    # convention so unit shadows agree with the doodad shadows.
    key.rotation_euler = (0.0, math.radians(-58.0), 0.0)
    bpy.context.collection.objects.link(key)

    fill_d = bpy.data.lights.new("FillSun", type="SUN")
    fill_d.color = (0.70, 0.80, 1.0)
    fill_d.energy = 1.0
    fill_d.angle = math.radians(10.0)
    fill_d.use_shadow = False
    fill = bpy.data.objects.new("FillSun", fill_d)
    fill.rotation_euler = (math.radians(-45.0), 0.0, 0.0)
    bpy.context.collection.objects.link(fill)


def add_ground():
    """Shadow-catcher plane at Z=0. Only the key sun's shadow shows (transparent film)."""
    bpy.ops.mesh.primitive_plane_add(size=12.0, location=(0.0, 0.0, 0.0))
    plane = bpy.context.active_object
    plane.name = "ShadowCatcher"
    plane.is_shadow_catcher = True
    return plane


def _principled(name, base_color):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (*base_color, 1.0)
    if "Roughness" in bsdf.inputs:
        bsdf.inputs["Roughness"].default_value = 0.6
    return mat


def add_suzanne():
    """Suzanne, base on Z=0, scaled to ~1-tile footprint, warm-neutral, smooth."""
    bpy.ops.mesh.primitive_monkey_add(location=(0.0, 0.0, 0.0))
    obj = bpy.context.active_object
    obj.name = "Model"
    obj.scale = (MODEL_SCALE, MODEL_SCALE, MODEL_SCALE)
    bpy.ops.object.shade_smooth()
    bpy.context.view_layer.update()

    # Sit the base on Z=0 using the scaled world-space bounding box.
    min_z = min((obj.matrix_world @ v.co).z for v in obj.data.vertices)
    obj.location.z -= min_z

    obj.data.materials.append(_principled("SuzanneMat", (0.80, 0.62, 0.45)))
    obj.rotation_mode = "XYZ"
    return obj


def add_calibration_plane():
    """1x1 world plane centred on origin, bright unshaded -- for the diamond check."""
    bpy.ops.mesh.primitive_plane_add(size=1.0, location=(0.0, 0.0, 0.0))
    plane = bpy.context.active_object
    plane.name = "CalPlane"
    mat = bpy.data.materials.new("CalMat")
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    emit = nt.nodes.new("ShaderNodeEmission")
    emit.inputs[0].default_value = (0.9, 0.9, 0.9, 1.0)
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    nt.links.new(emit.outputs[0], out.inputs[0])
    plane.data.materials.append(mat)
    return plane


def _emitter(name, color, location):
    bpy.ops.mesh.primitive_ico_sphere_add(radius=0.06, subdivisions=2, location=location)
    obj = bpy.context.active_object
    obj.name = name
    mat = bpy.data.materials.new(name + "Mat")
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    emit = nt.nodes.new("ShaderNodeEmission")
    emit.inputs[0].default_value = (*color, 1.0)
    emit.inputs[1].default_value = 2.0
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    nt.links.new(emit.outputs[0], out.inputs[0])
    obj.data.materials.append(mat)
    return obj


def add_markers():
    """RED at world +X, GREEN at world +Y, BLUE at origin -- world->screen check."""
    _emitter("MarkerX", (1.0, 0.0, 0.0), (0.5, 0.0, 0.02))
    _emitter("MarkerY", (0.0, 1.0, 0.0), (0.0, 0.5, 0.02))
    _emitter("MarkerO", (0.0, 0.0, 1.0), (0.0, 0.0, 0.02))


def render_array(tmp_png):
    """Render the current scene to `tmp_png`, return a top-down (H,W,4) float array.

    Loaded as Non-Color so pixels are the raw display values (no re-linearise),
    then vertically flipped from Blender's bottom-up buffer to top-down image order.
    """
    scene = bpy.context.scene
    base = tmp_png[:-4] if tmp_png.lower().endswith(".png") else tmp_png
    scene.render.filepath = base
    bpy.ops.render.render(write_still=True)

    img = bpy.data.images.load(base + ".png", check_existing=False)
    img.colorspace_settings.name = "Non-Color"
    w, h = img.size
    buf = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(buf)
    bpy.data.images.remove(img)
    arr = buf.reshape(h, w, 4)[::-1]          # bottom-up -> top-down
    return np.ascontiguousarray(arr)


def downsample2(rgba):
    """Premultiplied 2x2 area downsample (H,W,4 -> H/2,W/2,4) for clean alpha edges."""
    h, w = rgba.shape[:2]
    a = rgba[..., 3:4]
    prem = np.concatenate([rgba[..., :3] * a, a], axis=-1)
    prem = prem.reshape(h // 2, 2, w // 2, 2, 4).mean(axis=(1, 3))
    out_a = prem[..., 3:4]
    rgb = np.divide(prem[..., :3], out_a, out=np.zeros_like(prem[..., :3]),
                    where=out_a > 1e-6)
    return np.concatenate([rgb, out_a], axis=-1)


def save_sheet(sheet, out_png):
    """Write a top-down (H,W,4) float sheet to PNG via a Non-Color bpy Image."""
    h, w = sheet.shape[:2]
    img = bpy.data.images.new("SpriteSheet", width=w, height=h, alpha=True)
    img.colorspace_settings.name = "Non-Color"
    flat = np.ascontiguousarray(sheet[::-1].reshape(-1), dtype=np.float32)  # top-down -> bottom-up
    img.pixels.foreach_set(flat)
    img.file_format = "PNG"
    img.filepath_raw = out_png
    img.save()
    bpy.data.images.remove(img)


def _measure_bbox(alpha, thr=0.5):
    ys, xs = np.where(alpha > thr)
    if len(xs) == 0:
        return None
    return int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())


def run_calibrate(out_dir, markers):
    setup_render()
    setup_world()
    setup_camera()
    setup_lights()
    add_calibration_plane()
    if markers:
        add_markers()
    os.makedirs(out_dir, exist_ok=True)
    hi = render_array(os.path.join(out_dir, "_calib_render"))
    cell = downsample2(hi)
    save_sheet(cell, os.path.join(out_dir, "calibration.png"))

    alpha = cell[..., 3]
    box = _measure_bbox(alpha)
    if box is None:
        print("CALIBRATION FAIL: no coverage rendered")
        return
    x0, y0, x1, y1 = box
    cx, cy = (x0 + x1 + 1) / 2.0, (y0 + y1 + 1) / 2.0
    print("CALIBRATION diamond bbox px: x[%d..%d] y[%d..%d]  w=%d h=%d  center=(%.1f,%.1f)"
          % (x0, x1, y0, y1, x1 - x0 + 1, y1 - y0 + 1, cx, cy))
    print("CALIBRATION expected: w~%d h~%d center~(%d,%d)"
          % (sm.TILE_W, sm.TILE_H, sm.ANCHOR[0], sm.ANCHOR[1]))
    if markers:
        r, g, b = cell[..., 0], cell[..., 1], cell[..., 2]
        masks = (("+X(red)", (r > 0.5) & (g < 0.3) & (b < 0.3)),
                 ("+Y(green)", (g > 0.5) & (r < 0.3) & (b < 0.3)),
                 ("origin(blue)", (b > 0.5) & (r < 0.3) & (g < 0.3)))
        for name, m in masks:
            ys, xs = np.where(m & (cell[..., 3] > 0.5))
            if len(xs):
                print("MARKER %s centroid ~ (%.0f, %.0f)" % (name, xs.mean(), ys.mean()))


def run_render(model, out_dir):
    if model != "suzanne":
        raise SystemExit("this story only ships the built-in 'suzanne' model")
    samples, denoise = setup_render()
    setup_world()
    setup_camera()
    setup_lights()
    add_ground()
    obj = add_suzanne()

    os.makedirs(out_dir, exist_ok=True)
    sheet_w, sheet_h = sm.sheet_dimensions(N_FRAMES, sm.DIRECTIONS)
    rects = sm.pack_grid(N_FRAMES, sm.DIRECTIONS)
    sheet = np.zeros((sheet_h, sheet_w, 4), dtype=np.float32)

    tmp = os.path.join(out_dir, "_frame_tmp")
    for i in range(N_FRAMES):
        obj.rotation_euler = (0.0, 0.0, math.radians(BASE_DEG + STEP_DEG * i))
        hi = render_array(tmp)
        cell = downsample2(hi)
        x, y, w, h = rects[i]
        sheet[y:y + h, x:x + w] = cell
        print("rendered frame %d dir=%s facing=%s"
              % (i, sm.DIRECTION_NAMES[i % sm.DIRECTIONS], sm.direction_facing(i % sm.DIRECTIONS)))

    if os.path.exists(tmp + ".png"):
        os.remove(tmp + ".png")

    out_png = os.path.join(out_dir, model + ".png")
    save_sheet(sheet, out_png)

    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    res_rel = os.path.relpath(os.path.abspath(out_png), repo_root).replace(os.sep, "/")
    res_path = "res://" + res_rel

    manifest = sm.build_manifest(res_path, model, N_FRAMES, sm.DIRECTIONS)
    manifest["rig"]["samples"] = samples
    manifest["rig"]["denoise"] = denoise
    sm.validate(manifest)
    out_json = os.path.join(out_dir, model + ".json")
    with open(out_json, "w") as fh:
        fh.write(sm.dumps(manifest))

    print("wrote %s (%dx%d) and %s  samples=%d denoise=%s"
          % (out_png, sheet_w, sheet_h, out_json, samples, denoise))


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", default="suzanne")
    ap.add_argument("--out", default="assets/sprites/_test")
    ap.add_argument("--calibrate", action="store_true",
                    help="render the 1x1 diamond self-check instead of the model")
    ap.add_argument("--markers", action="store_true",
                    help="with --calibrate, add world +X/+Y/origin markers")
    return ap.parse_args(argv)


def main():
    args = parse_args()
    reset_scene()
    if args.calibrate:
        run_calibrate(args.out, args.markers)
    else:
        run_render(args.model, args.out)


if __name__ == "__main__":
    main()
