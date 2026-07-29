#!/usr/bin/env bash
# probes.sh — build and run every Wobbleweed acceptance probe.
#
# One entry point for CI and for humans, so "it passes on my machine" and
# "it passes in CI" mean the same thing.
#
#   ci/probes.sh            # headless (SDL dummy driver)
#   ci/probes.sh display    # against whatever DISPLAY points at (Xvfb or a real one)
#
# Exit status is the number of failing probes, so CI fails on any red.
#
# WHY BOTH MODES EXIST. The engine once shipped a crash that fired on EVERY run
# against a real display -- upload_texture() called SDL_SetTextureScaleMode on an
# RGB24 texture, which is not an OpenGL-native format, so SDL allocated a
# conversion texture and the scale-mode path faulted on it. The software and
# dummy renderers never take that path. It survived because every test was
# headless. A headless-only CI would not have caught it, and would not catch the
# next one either.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="${1:-headless}"
HC="${HEMLOCKC:-hemlockc}"
OUT="${TMPDIR:-/tmp}/ww-probes"
mkdir -p "$OUT"

if [ "$MODE" = "headless" ]; then
    export SDL_VIDEODRIVER=dummy
    export SDL_AUDIODRIVER=dummy
    unset DISPLAY 2>/dev/null || true
    LABEL="headless (dummy driver)"
else
    unset SDL_VIDEODRIVER SDL_AUDIODRIVER 2>/dev/null || true
    LABEL="display ${DISPLAY:-<unset>}"
fi

echo "=============================================================="
echo " Wobbleweed probes — $LABEL"
echo " compiler: $($HC --version 2>/dev/null | head -1 || echo "$HC")"
echo "=============================================================="

# --- the toolchain sanity check -------------------------------------------
# A stale compiler once produced WRONG ANSWERS rather than errors, and a whole
# wave of measurements had to be thrown away. Fail loudly and early instead.
cat > "$OUT/toolchain.hml" <<'EOF'
fn mix(s: i32): i32 { return s + 7; }
fn main() { let s: i32 = 100; let b: u64 = 10241477005482035122; print(mix(s)); print(b >> 1); }
main();
EOF
if ! $HC "$OUT/toolchain.hml" -o "$OUT/toolchain" >"$OUT/toolchain.log" 2>&1; then
    echo "TOOLCHAIN CHECK FAILED TO BUILD — compiler predates the inliner fix (H-1)?"
    cat "$OUT/toolchain.log"; exit 99
fi
TC="$("$OUT/toolchain")"
if [ "$TC" != "$(printf '107\n5120738502741017561')" ]; then
    echo "TOOLCHAIN CHECK PRODUCED WRONG OUTPUT:"; echo "$TC"
    echo "expected 107 then 5120738502741017561 — the compiler is stale or broken."
    exit 99
fi
echo "toolchain check ok (inliner + u64 shift correct)"
echo

# --- display preflight -----------------------------------------------------
# In display mode, confirm SDL can actually open a window and make a renderer
# BEFORE running 16 probes that will each die the same way.
#
# Xvfb frequently ships without a working GLX (this project's own dev box fails
# X_GLXCreateContext with BadValue, and even `glxinfo` dies with GLXBadContext),
# so SDL cannot create an accelerated renderer and every windowed probe aborts.
# That is an environment limitation, NOT an engine defect.
#
# Exit 77 -- the long-standing "skipped" convention -- so the caller can report
# the display path as UNTESTED. It must never be reported as passing: the whole
# reason this mode exists is that a real-display-only crash once survived
# indefinitely behind headless-only testing. A false green here would recreate
# exactly that blind spot. Equally it must not be a hard red, because a CI that
# is red for reasons nobody can fix is a CI everybody learns to ignore.
if [ "$MODE" != "headless" ]; then
    cat > "$OUT/preflight.hml" <<'EOF'
import "libSDL2-2.0.so.0";
extern fn SDL_Init(f: u32): i32;
extern fn SDL_CreateWindow(t: string, x: i32, y: i32, w: i32, h: i32, f: u32): ptr;
extern fn SDL_CreateRenderer(w: ptr, i: i32, f: u32): ptr;
extern fn SDL_GetError(): string;
fn main() {
    if (SDL_Init(32) != 0) { print(`INIT_FAIL ${SDL_GetError()}`); return; }
    let w = SDL_CreateWindow("preflight", 805240832, 805240832, 64, 64, 4);
    if (w == ptr_null()) { print(`WINDOW_FAIL ${SDL_GetError()}`); return; }
    let r = SDL_CreateRenderer(w, -1, 0);
    if (r == ptr_null()) { print(`RENDERER_FAIL ${SDL_GetError()}`); return; }
    print("PREFLIGHT_OK");
}
main();
EOF
    if $HC "$OUT/preflight.hml" -o "$OUT/preflight" >"$OUT/preflight.build.log" 2>&1; then
        PF="$(timeout 120 "$OUT/preflight" 2>&1 || true)"
        if ! printf '%s' "$PF" | grep -q PREFLIGHT_OK; then
            echo "=============================================================="
            echo " DISPLAY PATH UNTESTED — SDL cannot open a window/renderer here"
            echo "--------------------------------------------------------------"
            printf '%s
' "$PF" | sed 's/^/   /'
            echo
            echo " This is an environment limitation (usually Xvfb without a"
            echo " working GLX), not an engine failure. The display path is"
            echo " reported as SKIPPED rather than passing, because a real-"
            echo " display-only crash has slipped through headless testing"
            echo " before and a false green would hide the next one."
            echo "=============================================================="
            exit 77
        fi
        echo "display preflight ok (window + renderer created)"
        echo
    fi
fi

FAIL=0
RAN=0

for src in examples/probe_*.hml; do
    [ -e "$src" ] || continue
    name="$(basename "$src" .hml)"
    RAN=$((RAN + 1))
    printf '  %-22s ' "$name"

    if ! $HC -O1 "$src" -o "$OUT/$name" >"$OUT/$name.build.log" 2>&1; then
        echo "BUILD FAIL"
        sed -n '1,15p' "$OUT/$name.build.log" | sed 's/^/      /'
        FAIL=$((FAIL + 1))
        continue
    fi

    if timeout 600 "$OUT/$name" >"$OUT/$name.log" 2>&1; then
        # Exit 0 is necessary but not sufficient: report the score line too, so a
        # probe that silently stops asserting is visible in the log.
        echo "PASS   $(grep -oE '(PASS|FAIL) [0-9]+/[0-9]+|[0-9]+/[0-9]+ passed|assertions run [0-9]+ \(expected [0-9]+\), failed [0-9]+' "$OUT/$name.log" | tail -1)"
    else
        rc=$?
        echo "FAIL (exit $rc)"
        grep -E 'FAIL' "$OUT/$name.log" | head -8 | sed 's/^/      /'
        tail -3 "$OUT/$name.log" | sed 's/^/      /'
        FAIL=$((FAIL + 1))
    fi
done

# --- the legacy path must keep building ------------------------------------
# Seven modules are marked LEGACY and are not on the shipping path, but the
# examples that use them are the engine's public demos. Breaking them silently
# is how an engine loses its users.
printf '  %-22s ' "legacy examples"
LEGACY_FAIL=0
for ex in examples/walk_gpu.hml examples/walk.hml examples/plasma.hml; do
    [ -e "$ex" ] || continue
    if ! $HC -O1 "$ex" -o "$OUT/$(basename "$ex" .hml)" >>"$OUT/legacy.log" 2>&1; then
        LEGACY_FAIL=$((LEGACY_FAIL + 1))
    fi
done
if [ "$LEGACY_FAIL" -eq 0 ]; then echo "BUILD OK"; else echo "BUILD FAIL ($LEGACY_FAIL)"; FAIL=$((FAIL + 1)); fi

echo
echo "--------------------------------------------------------------"
echo " probes run: $RAN   failing: $FAIL   ($LABEL)"
echo "--------------------------------------------------------------"
exit "$FAIL"
