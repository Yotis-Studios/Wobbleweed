# Wobbleweed

Wobbleweed is a retro **PS1/N64-era** 3D engine in pure Hemlock, rendering to a
real **SDL2 window** — no OpenGL, no game framework, no shaders. `SDL_Vertex` is
2D, so UVs interpolate **affinely** and the PS1 *wobble* is the honest output of
the pipeline rather than an effect bolted on top. Occlusion is a painter's sort
(no z-buffer — exactly how PS1 hardware ordered primitives) and vertex colours
give Gouraud shading for free.

The engine is **generic**. It knows about triangles, textures, sound, input and
time. It knows nothing about any particular game: every colour, every constant
and every asset is supplied by the caller.

## Status

The repository currently holds **two engines**, and the difference matters.

**The shipping core** — `sdl.hml`, `vec.hml`, `time.hml`, `stats.hml`,
`engine.hml`, and the render modules being built alongside them (batch, emit,
shade, frustum, target, atlas, font, mesh, input, audio). It renders into an
offscreen 320×240 target and upscales it with `SDL_RenderCopyEx`, which is what
makes the pixels chunky. It is built compiled, measured per frame, and has a
lifecycle: `engine_init` → `engine_shutdown`, with a texture registry and a
documented teardown order.

**The legacy demo engine** — `geom.hml`, `framebuffer.hml`, `raster.hml`,
`sky.hml`, `postfx.hml`, `scene.hml`, `scene_gpu.hml`. These are the original v1
modules that render the walkable demo scene (textured ground + crate +
Gouraud-lit OBJ tree + sky) through either a hand-written CPU rasterizer or
`SDL_RenderGeometry`. They are **frozen**: still present, still buildable, still
running the examples and the benchmark regressions, and each carries a
`// LEGACY` header. They are not on the shipping path and should not be imported
by new code.

### Two claims this README used to make, corrected

> ~~"feature-complete for v1 … in the interpreter and compiled, with
> byte-identical output."~~

**Both halves were overstated. Neither should be relied on.**

**1. "Byte-identical between the interpreter and compiled" is not a guarantee
this engine makes.** It was measured false when it was written: the engine recon
found the interpreter emitting 404 triangles where the compiler emitted 425, with
different pixels. The underlying compiler defects have since been fixed upstream
(hemlock `ed12be28`), and on a current toolchain `examples/geom_scene.hml` does
now produce a byte-identical PNG on both backends (md5
`f5d6e05b20a9aad08c31f7b30788da3f`, `SDL_VIDEODRIVER=dummy`). That is a
measurement of one scene, not a property of the engine, and there are two live
reasons not to promote it to a promise:

- **`array.sort` is a different algorithm per backend, and is not stable when
  compiled** (Lomuto quicksort) while it *is* stable interpreted (insertion
  sort). Sorting 24 records whose keys tie in threes returns
  `0 3 6 9 12 15 18 21 1 13 7 16 …` compiled and
  `0 3 6 9 12 15 18 21 1 4 7 10 …` interpreted. The legacy painter's sort in
  `geom.hml` is exactly that call on triangle depths, so **coplanar triangles can
  be drawn in a different order on the two backends.** The demo scene happens to
  contain no tie that changes a pixel. Another scene will.
- **A stale toolchain still diverges.** The `hemlockc` in `/usr/local/bin` was
  two weeks behind at one point and silently produced wrong arithmetic, not
  errors. Build with a `hemlockc` from current `main` or the comparison means
  nothing.

**`hemlockc` is the ground truth.** The engine is developed and shipped compiled;
the interpreter is a convenience for quick demos. Do not do visual or performance
work in the interpreter.

**2. "Feature-complete for v1" described the demo, not an engine.** What that
status referred to is now the frozen legacy set above. The shipping core is under
active construction — see the roadmap below.

## How it works

```
                          ┌─▶ CPU rasterizer ─▶ framebuffer ─▶ SDL texture ─┐   LEGACY
project + light (CPU) ────┤                                                 ├─▶ window
                          └─▶ SDL_RenderGeometry (GPU, affine UVs) ─────────┘
                                                                   │
                                                                   └─▶ PNG (headless)

shipping core:
  emit (native f64 locals, no objects) ─▶ 4-layer triangle pool ─▶ bucket sort on
  view-space depth ─▶ one SDL_RenderGeometry per texture run ─▶ 320×240 offscreen
  target ─▶ integer upscale via SDL_RenderCopyEx ─▶ window
```

SDL is reached through Hemlock's **FFI** (`extern fn` against
`libSDL2-2.0.so.0`, and `libSDL2_mixer-2.0.so.0` for audio) — see `src/sdl.hml`.
Each library's externs are grouped under its own `import`, because `extern fn`
binds to the most recently declared one.

## Build and run

```bash
# Use a hemlockc built from current main. The one on PATH may be stale.
hemlockc --check src/engine.hml                       # instant type/arity check
hemlockc -O1 examples/walk_gpu.hml -o /tmp/walk_gpu && /tmp/walk_gpu
SDL_VIDEODRIVER=dummy /tmp/walk_gpu                   # headless
```

The verification programs live in `examples/probe_*.hml`. Each prints
`PASS n/n`, asserts its own assertion count, and exits non-zero on any failure,
so a CI gate can key on the exit code:

```bash
hemlockc -O1 examples/probe_lifecycle.hml -o /tmp/probe_lifecycle
SDL_VIDEODRIVER=dummy /tmp/probe_lifecycle
```

The legacy demos need a display (`DISPLAY` set) and must be run from the repo
root, because they load `assets/tree.obj` by relative path.

## Layout

### Shipping core

| Path | What |
|------|------|
| `src/sdl.hml`     | The whole OS surface: SDL2 + SDL2_mixer FFI, window/renderer/target lifecycle, textures, blending, events, input, timing, audio |
| `src/vec.hml`     | vec3 + row-major 4×4 for setup-time use, plus the FPS primitives (`mat_look_dir`, `mat_invert_rigid`, `ray_aabb`, …) |
| `src/time.hml`    | Monotonic clock on `SDL_GetPerformanceCounter` + a clamped fixed-step accumulator |
| `src/stats.hml`   | Fixed-index per-frame counters and stage timers, compiled into shipping builds |
| `src/engine.hml`  | Lifecycle: `engine_init` → `engine_shutdown`, the texture registry, and the teardown order (audio → target → textures → renderer → window → `SDL_Quit`) |
| `src/clip.hml`    | Near-plane and screen-space guard-band clipping |
| `src/png.hml`     | PNG **writer** — screenshots and headless verification. There is no reader |
| `src/obj.hml`     | Wavefront OBJ loader: all face index forms, `usemtl` palette, computed smooth normals |
| `src/texture.hml` | Procedural texture container |

Further shipping modules (triangle batch, emit kernel, shade/fog parameter block,
frustum, render target, atlas, font, mesh, billboard, quad, input, audio) are in
progress. Ownership, status and acceptance criteria are in
`nightshade/docs/BUILD_PLAN.md`; the signatures are in
`nightshade/docs/ARCHITECTURE.md` §5.1.

### Frozen legacy — buildable, not shipping

| Path | What |
|------|------|
| `src/geom.hml`        | GPU triangle backend — `array.sort` painter's sort + per-texture batching → `SDL_RenderGeometry` |
| `src/framebuffer.hml` | Colour + depth buffers for the software rasterizer |
| `src/raster.hml`      | CPU rasterizer — affine UV + z-buffer triangle fills (textured + Gouraud) |
| `src/sky.hml`         | Gradient + chunky pixelated cloud streaks that pan with the camera |
| `src/postfx.hml`      | The PS1 finishing pass: 4×4 ordered dither to 5-bit colour |
| `src/scene.hml`, `src/scene_gpu.hml` | The demo world, CPU and GPU |

### Examples and assets

| Path | What |
|------|------|
| `examples/walk.hml`, `examples/walk_gpu.hml` | Real-time walkable demo scene (CPU / GPU; Space toggles dither on the CPU one) |
| `examples/geom_scene.hml`, `examples/tree_png.hml`, `examples/scene_png.hml` | Headless renders to PNG |
| `examples/probe_*.hml` | Verification programs — assertions, timings, `PASS n/n`, non-zero exit on failure |
| `examples/bench_*.hml` | Benchmark corpus for the budget regressions |
| `examples/repro_*.hml` | Minimal repros kept as regression guards |
| `assets/tree.obj` | Hand-built low-poly tree (the Gouraud demo mesh) |

## Roadmap

**Done — the legacy demo engine (v1):**

- [x] SDL window + framebuffer present + event polling (real-time loop)
- [x] vec3 / 4×4 matrix math, perspective + look-at camera
- [x] Triangle rasterizer — affine UV + z-buffer (flat + textured fills)
- [x] PNG sink for screenshots
- [x] Procedural textures + affine-warp ground plane
- [x] Input-driven free camera, real-time SDL loop
- [x] Sky: gradient + chunky pixelated cloud streaks that pan with the camera
- [x] GPU backend via `SDL_RenderGeometry` — affine UVs, painter's sort, Gouraud
- [x] Near-plane clipping — clip-space Sutherland–Hodgman on both paths
- [x] Retro post-fx — 4×4 ordered dither to 5-bit colour, whole-pixel vertex snap
- [x] OBJ mesh loader + per-vertex Gouraud lighting

**Done — shipping core foundation:**

- [x] Full SDL2 + SDL2_mixer FFI surface, grouped per library, capped at SDL 2.0.18
- [x] FPS vector/matrix primitives (`mat_look_dir`, stable at pitch ±89.9°; `ray_aabb`; `mat_invert_rigid`)
- [x] Monotonic clock + clamped fixed-step accumulator
- [x] Per-frame instrumentation — fixed-index counters and stage timers
- [x] Engine lifecycle, texture registry, documented teardown order
- [x] Legacy quarantine — the seven demo modules marked and kept building

**In progress — shipping render core.** Triangle pool with an O(n) bucket sort on
view-space depth, the allocation-free emit kernel, the lighting/fog parameter
block, frustum culling, the 320×240 offscreen target and integer upscale, RGBA8
atlases with half-texel insets, a generic bitmap-font layer, meshes and
billboards, an input layer with graceful headless failure, and SDL2_mixer audio.

**Not planned:** a PNG reader (art is procedural), a z-buffer on the GPU path,
skeletal skinning, shadow maps, bloom / DOF / motion blur.

## Constraints worth knowing before you edit anything

- **Test an FFI pointer with `p == ptr_null()`, never `p == null`.** A NULL `ptr`
  returned from FFI compares **false** against `null` in compiled code. Every
  `if (handle == null)` guard on an SDL handle is silently dead in the shipping
  build.
- **The SDL runtime here is 2.0.18** — the headers and `pkg-config` say 2.0.20
  and are lying. Do not bind a symbol newer than 2.0.18.
- **Never call `SDL_SetTextureScaleMode`.** It segfaults on SDL's internal
  format-conversion textures. `SDL_SetHint("SDL_RENDER_SCALE_QUALITY", "0")` at
  startup covers every texture on every renderer, and `window_open` already does
  it. The extern is deliberately absent so the mistake is a compile error.
- **`SDL_RenderCopyEx`'s `angle` is a C `double`.** Pass `0.0`, never `0`.
- **`Mix_PlayChannel` and `Mix_LoadWAV` are C macros, not exported symbols.**
  Bind `Mix_PlayChannelTimed` and `Mix_LoadWAV_RW`. `Mix_QuickLoad_RAW` does
  **not** copy, so every PCM buffer must outlive every possible playback.
- **`alloc()` is never reclaimed for you**, and `buffer` / `array` / `object` /
  `string` are refcounted — do not `free()` one that is still reachable from a
  top-level `let`. `engine_shutdown` is where the engine's own reclamation lives.
