# glint

> a 4MB fantasy console where every NPC runs its own local LLM.
> zig. mit licensed. one binary. windows, linux, macos, web.

glint is a tiny game-making computer. you write a few hundred lines of luau,
press save, and a 128×128 pixel world boots in your terminal — or in any
browser, from a single tweet-sized URL.

what makes glint different from pico-8, tic-80, and the dozen other fantasy
consoles already out there is one thing: every character in your game can
think. glint embeds llama.cpp and a 0.5B-parameter open-weights model, runs
entirely offline, costs zero API dollars, and exposes one function to your
luau code: `ai.ask(npc_id, "what just happened?")`.

the binary is 4 megabytes. the model auto-downloads on first run, ~280 MB,
sha256-verified. the cart format is a PNG, lives in a single file, and
fits in a tweet. multiplayer rollback netcode is on the roadmap for v1.5.
there is no editor — your editor is the editor. there is no asset store —
github is the asset store. glint does five things and refuses the rest,
on purpose.

## status

⚠️ **pre-alpha** — engine boots, CLI stubs in place. cart format, Luau bindings,
LLM integration are tracked in [`doc/roadmap.md`](doc/roadmap.md) on a 12-week MVP plan.

## quick try

```sh
zig build
zig build run -- version
zig build test
```

Requires Zig 0.16.0 or newer.

## docs

- [architecture & decisions](doc/design.md)
- [12-week MVP plan + 12-month star path](doc/roadmap.md)
- [cart-author API surface](doc/dx-reliability-spec.md) — 80-function ceiling, error-message style guide, capability declaration grammar
- [lighthouse cart spec](doc/lighthouse-cart-gym-beef.md) — `gym_beef`, the cart that sells the engine
- [market reconnaissance](doc/market-recon.md) — honest competitive scoring; 8–15% to 10K stars in 36 months
- [mature-tech leverage list](doc/recon-addendum.md) — Luau / GekkoNet / libxmp / lodepng / xxh3 / Q16.16

## license

MIT. see [LICENSE](LICENSE).
