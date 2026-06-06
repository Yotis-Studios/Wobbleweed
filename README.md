# Wobbleweed

Wobbleweed is a retro **PS1/N64-era** 3D engine in pure Hemlock, rendering to a
real **SDL2 window** — no OpenGL, no game framework. It ships **two rendering
paths** that share the same vec math, camera, textures and scene:

- **CPU framebuffer** — a hand-written rasterizer fills textured, lit triangles
  (affine UV + z-buffer) into a memory framebuffer that SDL blits to the screen.
  Owns every pixel, so retro post-fx (dither, 5-bit) are trivial.
- **GPU geometry** — projects on the CPU, then hands screen-space triangles to
  **`SDL_RenderGeometry`** so the GPU does the expensive rasterization. Because
  `SDL_Vertex` is 2D, UVs interpolate **affinely** — the PS1 *wobble* survives,
  GPU-accelerated. Occlusion is painter's-sort (no z-buffer — exactly how PS1
  hardware ordered primitives), and vertex colors give Gouraud shading for free.

> Status: **early but real.** Both paths render the same walkable scene
> (textured ground + crate + sky) in an SDL window, in the interpreter and
> compiled (`hemlockc`), with byte-identical output.

## How it works

```
                          ┌─▶ CPU rasterizer ─▶ framebuffer ─▶ SDL texture ─┐
project + light (CPU) ────┤                                                 ├─▶ window
                          └─▶ SDL_RenderGeometry (GPU, affine UVs) ─────────┘
                                                                   │
                                                                   └─▶ PNG (headless)
```

SDL is reached through Hemlock's **FFI** (`extern fn` against
`libSDL2-2.0.so.0`) — see `src/sdl.hml`. The CPU framebuffer is 24-bit RGB,
row-major, which maps straight to SDL's `RGB24` texture (no conversion); the GPU
path packs `SDL_Vertex` arrays (`src/geom.hml`).

## Run

```bash
# needs a display (DISPLAY set). Interpreter is fine for a demo; compile for speed.
hemlock examples/plasma.hml      # animated plasma — first window smoke test
```

For a headless box, force SDL's dummy driver to exercise the loop without a
window: `SDL_VIDEODRIVER=dummy hemlock examples/plasma.hml`.

## Layout

| Path | What |
|------|------|
| `src/sdl.hml`        | SDL2 FFI: window, framebuffer `present`, input, plus the GPU path (`upload_texture` / `draw_tris` / `RenderGeometry`) |
| `src/geom.hml`       | GPU triangle backend — painter's sort + per-texture batching → `SDL_RenderGeometry` |
| `src/raster.hml`     | CPU rasterizer — affine UV + z-buffer triangle fills |
| `src/scene.hml` / `src/scene_gpu.hml` | the demo world, CPU and GPU renderers |
| `examples/walk.hml` / `examples/walk_gpu.hml` | real-time walkable scene (CPU / GPU) |
| `examples/geom_scene.hml` | GPU render → PNG (headless verification) |

## Roadmap

- [x] SDL window + framebuffer present + event polling (real-time loop)
- [x] vec3 / 4×4 matrix math, perspective + look-at camera
- [x] triangle rasterizer — affine UV + z-buffer (flat + textured fills)
- [x] PNG sink for screenshots
- [x] procedural textures + affine-warp ground plane (the retro core)
- [x] input-driven free camera (WASD + arrows), real-time SDL loop
- [x] sky: gradient + chunky pixelated cloud streaks that pan with the camera (CPU path)
- [x] GPU backend via `SDL_RenderGeometry` — affine UVs, painter's sort, Gouraud (offloads rasterization, keeps the wobble)
- [ ] near-plane clipping (fixes the edge artifacts when close to the ground)
- [ ] clouds on the GPU sky (bake the cloud layer into a panned sky texture)
- [ ] retro post-fx (5-bit color + ordered dither, vertex jitter)
- [ ] OBJ mesh loader + per-vertex Gouraud lighting

Reached through `@stdlib/math` + FFI only, so it should run under `hemlockc`
(compiled) as well as the interpreter.
