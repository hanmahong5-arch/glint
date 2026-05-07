<div align="center">

# glint

**a 4 MB fantasy console where every NPC runs its own local LLM.**

`zig 0.16` · `MIT` · `one binary` · `windows · linux · macos · wasm`

[design](doc/design.md) · [roadmap](doc/roadmap.md) · [api surface](doc/dx-reliability-spec.md) · [lighthouse cart](doc/lighthouse-cart-gym-beef.md)

</div>

---

> press save. a 128×128 pixel world boots in your terminal. one of the
> characters in it is *thinking* — not from an API key, not from a cloud,
> not from your wallet. from a 280 MB model file living next to your cart,
> 4 MB of `glint` binary, and the silicon already on your desk.

glint is a tiny **game-making computer** in the lineage of [Pico-8] and
[TIC-80] — a hard-edged 128×128, 16-color sandbox where you write a few
hundred lines of [Luau], press save, and a game boots. but glint asks
one new question:

> ### what if every character in your game could think?

glint dlopens [llama.cpp] at runtime and ships a default 0.5B-parameter
open-weights model (Qwen2.5, ~280 MB, sha256-verified, auto-downloaded on
first use). your Luau code talks to it through one function:

```lua
-- coming in W10 (see doc/roadmap.md)
ai.ask("baker", "the player just stole bread")
-- → "OI! THIEF! THAT'S THE THIRD ROLL THIS WEEK"
```

the engine streams the answer in token-by-token, on a worker thread, behind
a deterministic mailbox so the AI **cannot desync your gameplay state. ever.**
no API keys. no internet. no per-call dollars. forever.

---

## the smallest game you'll ever write

```lua
-- on main today: paste, pack, play.
function _init() x = 64 end

function _update()
  if btn(0) then x = x - 1 end
  if btn(1) then x = x + 1 end
end

function _draw()
  cls(15)
  circfill(x, 64, 4, 11)
end
```

```sh
$ glint pack mygame && glint play mygame/mygame.glint
```

a window opens. a sparkbright dot moves when you press the arrow keys.
you have written a video game.

---

## why glint exists

- **pico-8** is closed source, costs $14.99, has no AI, and won't run on aarch64 linux.
- **tic-80** is open source and lovely, but it has no AI either.
- **bevy / godot / unity** are extraordinary engines. they are also small operating systems.
- **chatgpt-as-NPC** is fun — until your game needs an internet connection and a credit card to start.

glint is the smallest possible answer to *"i want a game where the world
talks back, and i don't want to ship anybody's API into my players' lives."*

it does five things and refuses the rest.

## what works today

> **status: pre-alpha.** everything below is in `main`, runnable, tested.
> nothing below is fabricated; the columns track [`doc/roadmap.md`](doc/roadmap.md).

| working in main | next milestone |
|---|---|
| ✅ `zig build` → ~4 MB single binary, win/mac/linux | ⏳ wasm export + tweet-sized cart URLs (W11) |
| ✅ sokol window + 128×128 framebuffer + 16-color palette LUT | ⏳ 4-channel PSG audio + .it tracker (W7) |
| ✅ **sandboxed Luau VM** + cart-author API surface | ⏳ `ai.ask` / `ai.spawn` Luau bindings (W10) |
| ✅ cart binary container + PNG-steganography codec | ⏳ llama.cpp dlopen + Qwen-0.5B GGUF router (W9) |
| ✅ manifest TOML + capability grammar + `glint new` / `pack` / `run` / `play` | ⏳ sprite + tilemap (W4 backfill) |
| ✅ Q16.16 deterministic math, **no libm** in hot paths | ⏳ rollback netcode (v1.5, M5–M6) |
| ✅ xxh3-64 state hashing — same cart, same hash, every machine | ⏳ cart marketplace via GitHub topics (v2.0) |
| ✅ 60 Hz fixed-step accumulator + per-phase frame budget tracker | |
| ✅ `.crash` artifact format (replay-able post-mortem) | |

cart-author surface live on `main` today (≈ 26 of 80 budgeted functions):

```
cls   pset  pget         line  rect  rectfill  circ  circfill
btn   btnp  rnd  srand
sin   cos   atan2  sqrt  abs   flr   ceil      min   max
mid   lerp  saturate     sgn   smoothstep
```

## try it

```sh
git clone https://github.com/hanmahong5-arch/glint
cd glint && zig build                          # zig 0.16.0 or newer

./zig-out/bin/glint new mygame                 # scaffold a cart
./zig-out/bin/glint pack mygame                # → mygame/mygame.glint
./zig-out/bin/glint play mygame/mygame.glint   # window opens, you play

./zig-out/bin/glint pack samples/demo          # the in-repo sample
./zig-out/bin/glint play samples/demo/demo.glint

zig build test                                 # unit tests across all modules
```

## design constraints (the things glint refuses)

| no | because |
|---|---|
| no 3D | 128×128 is the identity. constraint is creativity. |
| no GUI editor | your editor *is* the editor. git is the asset store. |
| no second scripting language | Luau only. multi-language = no language. |
| no abstract LLM-backend interface | strong-bind llama.cpp + GGUF. abstraction is the project graveyard. |
| no float-math determinism drift | Q16.16 + LUT sin/cos/atan2/sqrt. logic frames are sacred. |
| no AI writing your gameplay state | the `_ai` callback can append to a mailbox. it cannot mutate state. ever. |

## comparison

|                              | glint                 | Pico-8         | TIC-80         |
|------------------------------|-----------------------|----------------|----------------|
| price                        | free, MIT             | $14.99, closed | free, MIT      |
| binary size                  | ~4 MB                 | ~4.6 MB        | ~7 MB          |
| cart fits in a tweet         | ✅                    | ✅             | ✅             |
| browser-playable             | ⏳ W11               | ✅             | ✅             |
| **local LLM NPCs**           | ✅                    | ❌             | ❌             |
| editor                       | use yours             | bundled        | bundled        |
| determinism / rollback-ready | ✅                    | no             | no             |
| 信创 (aarch64-linux-musl)    | ✅                    | ❌             | ❌             |

we love both Pico-8 and TIC-80. glint borrows their format DNA but
isn't trying to replace them. the question we're answering is the one
neither of them can: *what does a fantasy console look like after LLMs?*

## roadmap

milestones from [`doc/roadmap.md`](doc/roadmap.md):

- **v0.1** (W6 — ✅ done) graphics + input + Luau + first playable cart
- **v0.5** (W10 — ⏳ in progress) audio + first AI NPC + 3 lighthouse carts
- **v1.0** (W12 — public launch) WASM export + cart-via-URL + 5 carts + docs
- **v1.5** (M5–M6) GekkoNet rollback + 2-player carts
- **v2.0** (M9–M12) cart marketplace + AI function calling

we publish in the open from day one. cart format, engine, model choice,
build scripts — all of it. when v1.0 ships you will have watched every
commit get there.

## docs

- [**architecture & decisions**](doc/design.md) — the *why*
- [**12-week MVP plan + 12-month star path**](doc/roadmap.md) — the *when*
- [**cart-author API surface**](doc/dx-reliability-spec.md) — 80-function ceiling, error-message style guide, capability grammar
- [**lighthouse cart spec**](doc/lighthouse-cart-gym-beef.md) — `gym_beef`, the cart that sells the engine
- [**market reconnaissance**](doc/market-recon.md) — honest competitive scoring; 8–15% to 10K stars in 36 months
- [**mature-tech leverage list**](doc/recon-addendum.md) — Luau / GekkoNet / libxmp / lodepng / xxh3 / Q16.16

## philosophy

glint does five things and refuses the rest, on purpose:

1. **boot a 128×128 16-color world from a single file** in under a second.
2. **let you write that world in Luau**, with at most 80 functions to learn.
3. **let one of the characters in that world *think*** — with a model you own.
4. **stay deterministic**, so you can replay, rollback, and trust your tests.
5. **fit in 4 MB**, so it ships everywhere, runs anywhere, depends on no one.

everything else is feature creep until it isn't.

## contributing

issues and PRs welcome — but read [`doc/dx-reliability-spec.md`](doc/dx-reliability-spec.md)
first. the cart-author surface is **capped at 80 functions**, the binary
is **capped at 5 MB**, and the engine has hard rules about what AI is
allowed to touch. constraint is the feature.

## license

MIT — see [LICENSE](LICENSE).

---

<div align="center">
<sub>built by <a href="https://github.com/hanmahong5-arch">@hanmahong5-arch</a> · <a href="doc/roadmap.md">12-week MVP</a> · <a href="https://github.com/hanmahong5-arch/glint/issues">issues</a></sub>
</div>

[Pico-8]: https://www.lexaloffle.com/pico-8.php
[TIC-80]: https://tic80.com/
[Luau]: https://luau-lang.org/
[llama.cpp]: https://github.com/ggerganov/llama.cpp
