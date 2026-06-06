# Wobbleweed

Wobbleweed is a retro **PS1/N64-era** software 3D engine in pure Hemlock, rendering to a real
**SDL2 window** — no OpenGL, no game framework. The CPU rasterizes textured, lit
triangles into a memory framebuffer; SDL just blits that framebuffer to the
screen each frame and feeds back input.

> Status: **early.** The SDL output path + real-time loop are in. The 3D
> pipeline (rasterizer, meshes, camera) is being built on top.

## How it works

```
game loop ─▶ render into framebuffer (w·h·3 RGB bytes)
                 │
                 ├─▶ SDL streaming texture ─▶ window   (real-time)
                 └─▶ PNG                              (headless / screenshots)
```

SDL is reached through Hemlock's **FFI** (`extern fn` against
`libSDL2-2.0.so.0`) — see `src/sdl.hml`. The framebuffer is 24-bit RGB,
row-major, which maps straight to SDL's `RGB24` texture (no conversion).

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
| `src/sdl.hml`        | SDL2 FFI binding: `window_open` / `present` / `poll` / `ticks` |
| `examples/plasma.hml`| animated framebuffer → window (no 3D yet) |

## Roadmap

- [x] SDL window + framebuffer present + event polling (real-time loop)
- [x] vec3 / 4×4 matrix math, perspective + look-at camera
- [x] triangle rasterizer — affine UV + z-buffer (flat + textured fills)
- [x] PNG sink for screenshots
- [x] procedural textures + affine-warp ground plane (the retro core)
- [x] input-driven free camera (WASD + arrows), real-time SDL loop
- [ ] near-plane clipping (fixes the edge artifacts when close to the ground)
- [ ] skybox with pixelated clouds
- [ ] retro post-fx (5-bit color + ordered dither, vertex jitter)
- [ ] OBJ mesh loader + per-vertex Gouraud lighting

Reached through `@stdlib/math` + FFI only, so it should run under `hemlockc`
(compiled) as well as the interpreter.
