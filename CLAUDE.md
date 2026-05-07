# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working in this repository.

## What is glint

glint is a single-binary fantasy console (16-color, 128×128 pixels) with a built-in local LLM for AI NPC dialogue. Like Pico-8/TIC-80 but reborn for the AI era. Stack: Zig 0.16 + sokol-zig + ziglua → Luau + zflecs + dlopen llama.cpp. Cart format = PNG steganography (PICO-8 lineage). Targets Win/Mac/Linux/WASM as a single ~5MB binary.

Current status: pre-alpha, CLI stubs in place. The build system + project skeleton are set up; engine modules are TODO per `doc/roadmap.md`.

Reference docs (always read these before designing or implementing major features):

- `doc/design.md` — architecture decision baseline (the "why")
- `doc/roadmap.md` — 12-week MVP plan + 12-month star path
- `doc/dx-reliability-spec.md` — cart-author API surface (≤80 functions) + reliability/determinism contracts
- `doc/lighthouse-cart-gym-beef.md` — first lighthouse cart spec (drives engine abstractions)
- `doc/market-recon.md` — competitive landscape + honest probability scoring
- `doc/recon-addendum.md` — mature-tech leverage list + plugin architecture patterns

## Commands

```sh
zig build                              # debug native build (default)
zig build -Doptimize=ReleaseSmall      # size-optimized release
zig build run -- version               # run CLI with arg "version"
zig build run -- run path/to/cart      # run a cart (stub until W6)
zig build test                         # run all tests (root.zig + main.zig modules)
zig build -Dtarget=x86_64-linux-musl   # cross-compile linux x86_64
zig build -Dtarget=aarch64-linux-musl  # cross-compile linux aarch64 (信创)
zig build -Dtarget=aarch64-macos       # cross-compile mac aarch64
zig build -Dtarget=x86_64-windows-gnu  # cross-compile windows
zig build -Dtarget=wasm32-freestanding # wasm browser build
```

Default optimize mode is debug. **Only build release when explicitly required** (per project rule).

## Architecture (60-second tour)

- `src/main.zig` — CLI dispatcher (subcommands: `run` / `new` / `pack` / `replay` / `version`)
- `src/root.zig` — public engine library API (the `glint` module imported by main.zig and downstream embedders)
- `src/engine/` — frame loop, dev panel, log, capability resolver
- `src/runtime/` — framebuffer (128×128 u4), sprite atlas, input, time
- `src/lua/` — ziglua + Luau, sandbox, 80-function cart API binding
- `src/cart/` — PNG steganography, manifest TOML, validation
- `src/ai/` — dlopen llama.cpp, worker thread, streaming inbox, rate limit, safety filter
- `src/ecs/` — zflecs wrapper
- `src/gfx/` — sokol_gfx init, palette LUT shader, integer-scale upscale
- `src/snd/` — sokol_audio + 4-channel PSG mixer + .it tracker via libxmp
- `src/replay/` — `glint replay` headless determinism harness, `.crash` artifact

Two-phase cart lifecycle (Factorio pattern): **load** (declare schemas, capabilities) → **runtime** (60Hz update/draw, rollback-aware). AI lives outside deterministic state; `_ai` callback fires between frames into a single-frame mailbox drained at next `_update` start.

## AI integrity rules (project policy — HARD)

These come from past project incidents and the user's global memory. Violating them is a serious bug, not a stylistic choice.

1. **Never hide compile/test errors.** Report them verbatim — every line.
2. **Never modify a test assertion to make it pass.** Only modify if the test itself has a real bug; write the reasoning when you do.
3. **Never create mock/stub integration tests** for unavailable dependencies. Skip the test with a clear annotation + comment instead.
4. **Never claim tests pass without actually running them.**
5. **Don't fabricate explanations.** If you don't know, say so.
6. **Never claim a file edit succeeded when it failed.** Verify after each Write/Edit.
7. **Never blame tools/environment for your own errors.**

## Zig code conventions

- Every FFI call, raw pointer dereference, or pointer cast that could be unsound needs a `// SAFETY:` comment explaining why it is sound at this call site.
- Library code (anything reachable from `src/root.zig`) MUST NOT call `@panic`, `unreachable`, or `std.process.exit`. Return an `EngineError`.
- Public items get `///` doc comments. Private items get `//` line comments only when the *why* is non-obvious.
- Prefer `error{}` returns over flag-out-parameters.
- Default to no comments. Only add a comment when removing it would confuse a future reader.
- Naming: namespaces are nouns (`gfx`, `cart`), functions are verbs (`gfx.draw_sprite`, not `gfx.sprite`).
- Argument order: `(x, y, anything_else...)` — width/height after position; color last.

## State separation contract (the most important invariant)

Carts have three buckets:
- `state` — DETERMINISTIC, ROLLBACK-RESTORED. Plain data only. No closures, no userdata, no engine handles. Hashed (xxh3-64) on every write via metatable.
- `transient` — PURE FX, REGENERABLE. May read state, may NOT write.
- `ai_buf` — APPEND-ONLY. LLM tokens land here; gameplay state cannot be mutated by AI.

Data flow: `state → ai_buf` and `state → transient`; **never** the reverse. Engine has no `ai.mutate_state` API. Never will. The `_ai` callback writes to a single-frame mailbox drained at the start of the next `_update`.

## What NOT to do (project-specific guardrails)

- ❌ No 3D rendering. 128×128 software framebuffer is the identity.
- ❌ No GUI editor. Editor = your editor + git + hot reload.
- ❌ No second scripting language. Luau only. "Multi-language = no language."
- ❌ No abstract LLM-backend interface. Strong-bind llama.cpp + GGUF.
- ❌ No copying PICO-8 palette RGB values, font bitmaps, or cart format magic. Differentiation is legal + brand insurance.
- ❌ No `math.*` from libm in deterministic paths. Use Q16.16 LUT-backed `sin`/`cos`/`atan2`/`sqrt`. Cross-platform float drift is a determinism bug.
- ❌ No writing to `state` from the `_ai` callback. AI cannot reach deterministic state.
- ❌ No mocked integration tests. If a dep is missing, skip the test and explain in the comment.

## Performance budget (16.67ms/frame HARD)

| Phase | Budget |
|---|---:|
| Input poll + dispatch | 0.1 ms |
| Net rollback resimulate (v1.5) | 2.0 ms |
| `_update` (cart Lua) | 6.0 ms |
| AI worker sync | 0.3 ms |
| `_draw` (cart Lua) | 2.0 ms |
| Audio mix | 0.8 ms |
| sokol present | 2.0 ms |
| Dev panel + log flush | 0.3 ms |
| Slack | 3.17 ms |

**Logic frames are sacred.** Engine drops pixels (graphics-shed mode) before dropping logic. Determinism is a load-bearing wall.

## Cross-platform constraint

Native targets: Linux x86_64/aarch64 (incl. Kylin V10 / UOS for 信创), macOS aarch64, Windows x86_64, WASM32. Windows host development cross-compiles for all via Zig's built-in toolchain — no MSVC, no extra setup. llama.cpp is dlopened at runtime — never statically linked — so the base binary stays under 5MB.

## Lighthouse cart strategy

`gym_beef` (the first cart, spec at `doc/lighthouse-cart-gym-beef.md`) drives engine abstractions; we ship cart and engine together. PICO-8 → Celeste was the proven path. TIC-80, LIKO-12, and Pixel Vision 8 all stalled because they shipped engine-without-lighthouse. 12-day cart implementation begins after engine readiness (W10 milestone in the roadmap).

## Document discipline

Per user global rule: README.md and CLAUDE.md live at the repo root. Every other document goes into `doc/`. UTF-8 encoding everywhere. LF line endings (no CRLF) where Git config permits.
