# Cart-Author DX & Engine Reliability Spec

> agent: dx1（everything-claude-code:architect），2026-05-06
> 状态：Design lock candidate v0.1
> 受众：cart authors（主），engine 开发者（次）

---

## 0. North Stars（先读，迷茫时回看）

1. **One obvious way.** 两个函数语义重叠 → 一个是错的。v1 前删掉。
2. **The engine never blames the cart author.** 每个错误信息含：what was tried / why it failed / smallest next step。
3. **Reliability is invisible until missing.** 本文每个约束配 test/harness/runtime assertion。零靠希望。
4. **Determinism is a load-bearing wall.** 任何破坏确定性的（float drift / time-of-day / 未追踪 global）都破坏 rollback netcode、replay、crash artifact。当 security bug 处理。
5. **The cart is the bug report.** `.crash` 文件无损重放最后 3 秒；用户发一个文件，开发者立刻复现。

---

# PART A — CART-AUTHOR DEVELOPER EXPERIENCE

## A.1 8 命名空间

| # | 命名空间 | 心智锚 | 函数数 | PICO-8 肌肉记忆 |
|---|---|---|---|---|
| 1 | **gfx.*** | "画一个东西" | 12 | 大部分兼容（pset/spr/print/cls/circ/rect/line）|
| 2 | **inp.*** | "玩家做了什么" | 8 | btn/btnp 保留 |
| 3 | **snd.*** | "发出声音" | 7 | sfx/music 保留 |
| 4 | **map.*** | "世界 tile" | 6 | mget/mset/map 保留 |
| 5 | **state**（table，非 namespace）| "跨帧持久" | 4 methods | new — 替代 PICO-8 globals |
| 6 | **ai.*** | "让 NPC 思考" | 9 | new |
| 7 | **net.*** (v1.5) | "rollback 多人" | 6 | new |
| 8 | **cap.*** | "我能做什么" | 5 | new |
| **+ globals** | `_init`/`_update`/`_draw`/`_ai`/`_net` lifecycle | 5 | partial PICO-8 |
| **+ misc** | `time`, `frame`, `print` (legacy alias), `dbg`, etc. | 18 | mixed |
| | | **TOTAL** | **80** | |

命名规则：namespace 函数是**动词**（`gfx.draw_sprite`，不是 `gfx.sprite`）。顶级保短（`btn`/`sfx`/`pset`）保肌肉记忆。
参数顺序铁律：`(x, y, anything_else...)`。Width/height 在 position 后。Color 永远最后除非改变签名语义。

## A.2 Full API Table（80 行，错误模式简化）

> 错误模式：
> - `nil-on-fail`: 返 nil 加可选第二返错串
> - `default-on-fail`: 返 sensible default（false / 0）
> - `silent-clamp`: 越界 arg 钳制，无错
> - `scold`: engine warn，函数 no-op，cart 继续
> - `unload`: engine error，卸 cart + `.crash` artifact
> - `infallible`: 文档承诺永不 fail

### gfx.* (12)

| Signature | Error | Example |
|---|---|---|
| `cls(c?)` | infallible | `cls(0)` |
| `pset(x,y,c)` | silent-clamp | `pset(64,64,7)` |
| `pget(x,y) -> c` | default-on-fail (0) | `if pget(x,y)==7 then` |
| `gfx.draw_sprite(x,y,sid,fx?,fy?)` | scold | `gfx.draw_sprite(20,30,1)` |
| `spr(x,y,sid,fx?,fy?)` | scold | `spr(20,30,1,true)` (alias) |
| `gfx.draw_sprite_ext(x,y,sid,w,h,fx?,fy?,palette_remap?)` | scold | — |
| `circ(x,y,r,c,filled?)` | silent-clamp | `circ(64,64,8,7,true)` |
| `rect(x1,y1,x2,y2,c,filled?)` | silent-clamp | `rect(0,0,127,127,1)` |
| `line(x1,y1,x2,y2,c)` | silent-clamp | — |
| `print(s,x,y,c?)` | scold | `print("hi",10,10,7)` |
| `gfx.set_palette(slot,rgb24)` | scold | `gfx.set_palette(0,0x1a1c2c)` |
| `gfx.camera(dx,dy)` | infallible | `gfx.camera(player.x-64,player.y-64)` |

### inp.* (8)

| Signature | Error | Example |
|---|---|---|
| `btn(b,p?) -> bool` | default-on-fail | `if btn(0) then` |
| `btnp(b,p?) -> bool` | default-on-fail | first frame only |
| `inp.held_frames(b,p?) -> n` | default-on-fail (0) | charge attack |
| `inp.mouse() -> x,y,btn_mask` | nil-on-fail | `local mx,my = inp.mouse()` |
| `inp.touch(slot) -> x,y,on` | nil-on-fail | `inp.touch(0)` |
| `inp.text_buffer() -> s` | default-on-fail ("") | name entry |
| `inp.text_clear()` | infallible | — |
| `inp.controller_count() -> n` | infallible | — |

### snd.* (7)

| Signature | Error | Example |
|---|---|---|
| `sfx(id,ch?)` | scold | `sfx(3)` |
| `music(track,fade_ms?,loop?)` | scold | `music(0,200,true)` |
| `snd.stop(ch?)` | infallible | stop all if no arg |
| `snd.volume(ch,v_0_to_1)` | silent-clamp | — |
| `snd.is_playing(ch) -> bool` | default-on-fail | — |
| `snd.pitch(ch,semitones)` | silent-clamp | `snd.pitch(0,-12)` |
| `snd.peek(ch) -> sfx_id,frame_pos` | nil-on-fail | tight visual sync |

### map.* (6)

| Signature | Error | Example |
|---|---|---|
| `mget(tx,ty) -> tile_id` | default-on-fail (0) | — |
| `mset(tx,ty,tile_id)` | silent-clamp | — |
| `map(tx,ty,sx,sy,tw,th,layer?)` | scold | draws tilemap region |
| `map.flag(tile_id,flag_idx) -> bool` | default-on-fail | collision check |
| `map.set_flag(tile_id,flag_idx,v)` | infallible | — |
| `map.layer_visible(idx,v?)` | infallible | toggle/query |

### state (4 methods) — persistent + rollback-tracked

`state` 表是**唯一**写入跨帧持久的位置（rollback-safe）。在外部写的视为 scratch，每帧重置（dev mode scold；release 未定义行为，见 B.7）。

| Signature | Error | Example |
|---|---|---|
| `state.save(slot) -> bool` | nil-on-fail | `state.save(0)`（cap "save" 必需）|
| `state.load(slot) -> bool` | nil-on-fail | — |
| `state.hash() -> u64` | infallible | tests / replay assert |
| `state.reset()` | infallible | new-game button |

加上 metatable 写读：`state.player_x = 10`，`state.enemies[3].hp = 0` 等。

### ai.* (9) — local LLM NPC

cap `ai` 必需。全部**非阻塞**；推理在 worker thread。

| Signature | Error | Example |
|---|---|---|
| `ai.ask(npc_id,prompt,opts?) -> req_id` | nil-on-fail | `local r = ai.ask("guard","what's beyond the gate?")` |
| `ai.poll(req_id) -> status,partial_text` | default-on-fail | status: pending/streaming/done/error |
| `ai.cancel(req_id)` | infallible | — |
| `ai.set_persona(npc_id,persona_text)` | scold | one persona/npc |
| `ai.tokens_used() -> n` | infallible | dev panel + budget |
| `ai.tokens_budget() -> n` | infallible | per-second cap |
| `ai.model_info() -> name,n_params,ctx` | nil-on-fail | — |
| `ai.embed(text) -> vec_or_nil` | nil-on-fail | semantic match |
| `ai.cosine(v1,v2) -> n` | default-on-fail | helper |

> Lifecycle hook：`function _ai(npc_id, req_id, status, text) end` — fires on streaming/done/error。**永不在 `_update` 内 fire** 以保确定性（写入 AI inbox，下一帧 `_update` 起始时 drain）。

### net.* (6) — rollback multiplayer (v1.5)

cap `net` 必需。net 副作用 deferred 到下帧边界保确定性。

| Signature | Error | Example |
|---|---|---|
| `net.start_session(opts) -> bool` | nil-on-fail | `net.start_session{mode="p2p",port=7777}` |
| `net.join(addr) -> bool` | nil-on-fail | — |
| `net.leave()` | infallible | — |
| `net.peers() -> {pid,...}` | default-on-fail ({}) | — |
| `net.rtt(pid) -> ms` | default-on-fail (-1) | dev panel |
| `net.local_player() -> pid` | default-on-fail (0) | — |

> Hook：`function _net(event, payload) end` — event ∈ {"join","leave","desync","stall","resume"}。

### cap.* (5)

| Signature | Error | Example |
|---|---|---|
| `cap.has(name) -> bool` | infallible | `if cap.has("ai") then ai.ask(...)` |
| `cap.list() -> {name,...}` | infallible | granted set |
| `cap.requested() -> {name,...}` | infallible | from manifest |
| `cap.denied() -> {name=reason,...}` | infallible | diagnostic UI |
| `cap.request_dynamic(name,reason) -> bool` | nil-on-fail | optional v1.6 — 交互弹窗 |

### Lifecycle (5)

| Function | Error | Notes |
|---|---|---|
| `_init()` | scold | 一次，manifest 验证 + cap 解析后 |
| `_update()` | unload on 3 连续 errors | 60Hz；deterministic |
| `_draw()` | scold | 在 `_update` 后；非确定性 IO 允许（screen shake）|
| `_ai(npc_id,req_id,status,text)` | scold | optional |
| `_net(event,payload)` | scold | optional v1.5 |

### Misc (18)

| Signature | Error | Example |
|---|---|---|
| `time() -> n` | infallible | 秒数自 `_init`（确定性，1/60 tick）|
| `frame() -> n` | infallible | 整数 frame |
| `dbg(msg, ...)` | infallible | info level；release 可 strip |
| `log(level, msg, ...)` | infallible | `log("warn","hp low: %d", hp)` |
| `min(a,b)` / `max(a,b)` / `mid(a,b,c)` | infallible | numeric |
| `flr(n)` / `ceil(n)` / `abs(n)` | infallible | fixed-point safe |
| `sin(n)` / `cos(n)` / `atan2(y,x)` | infallible | **deterministic** Q16.16 LUT，**非 libm**（B.7）|
| `sqrt(n)` | infallible | deterministic Q16.16 |
| `rnd(n?) -> n` | infallible | xorshift32 from `state` |
| `srand(seed)` | infallible | reseed |
| `tostr(v)` / `tonum(s)` | nil-on-fail (tonum) | 安全转换 |
| `peek(addr)` / `poke(addr,v)` | scold | bounded VRAM/RAM；cap "raw" 必需 |

**总计**：12+8+7+6+4+9+6+5+5+18 = **80**。新增需删除一个。

## A.3 6 个 Categorical Example Carts

### A.3.1 hello.lua（lifecycle + draw）
```lua
-- hello.lua: smallest possible cart
function _init()
  state.x = 64
  state.y = 64
  state.msg = "hello, world"
end
function _update()
  if btn(0) then state.x -= 1 end
  if btn(1) then state.x += 1 end
  if btn(2) then state.y -= 1 end
  if btn(3) then state.y += 1 end
end
function _draw()
  cls(0)
  print(state.msg, 30, 60, 7)
  pset(state.x, state.y, 8)
end
```

### A.3.2 sprite.lua（sprite + animation）
```lua
function _init() state.x=32; state.facing=1 end
function _update()
  if btn(0) then state.x, state.facing = state.x-1, -1 end
  if btn(1) then state.x, state.facing = state.x+1,  1 end
  state.x = mid(0, state.x, 120)
end
function _draw()
  cls(1)
  local sid = (frame() // 8) % 4
  spr(state.x, 60, sid, state.facing == -1)
end
```

### A.3.3 map.lua（tilemap + collision）
```lua
function _init() state.px, state.py = 16, 16 end
function _solid(tx, ty) return map.flag(mget(tx, ty), 0) end
function _try_move(dx, dy)
  local nx, ny = state.px + dx, state.py + dy
  if not _solid(nx // 8, ny // 8) then state.px, state.py = nx, ny end
end
function _update()
  if btn(0) then _try_move(-1, 0) end
  if btn(1) then _try_move( 1, 0) end
  if btn(2) then _try_move( 0,-1) end
  if btn(3) then _try_move( 0, 1) end
end
function _draw()
  cls(0)
  gfx.camera(state.px - 64, state.py - 64)
  map(0, 0, 0, 0, 32, 32)
  spr(state.px, state.py, 8)
end
```

### A.3.4 sfx.lua（audio）
```lua
function _init()
  music(0, 500, true)
  state.step_cooldown = 0
end
function _update()
  state.step_cooldown = max(0, state.step_cooldown - 1)
  local moving = btn(0) or btn(1) or btn(2) or btn(3)
  if moving and state.step_cooldown == 0 then
    sfx(1)
    state.step_cooldown = 10
  end
end
function _draw()
  cls(0)
  print("move to step", 24, 60, 7)
  print("music: " .. (snd.is_playing(0) and "on" or "off"), 24, 70, 6)
end
```

### A.3.5 ai.lua（AI NPC dialogue）
```lua
function _init()
  state.reply = ""
  state.req = nil
  if not cap.has("ai") then
    state.reply = "(ai cap not granted)"
  else
    ai.set_persona("guard", "a tired night-watchman of a small keep.")
  end
end
function _update()
  if btnp(4) and cap.has("ai") and not state.req then
    state.req = ai.ask("guard", "what's beyond the gate?")
    state.reply = ""
  end
end
function _ai(npc, req, status, text)
  if req == state.req then
    state.reply = text
    if status == "done" or status == "error" then state.req = nil end
  end
end
function _draw()
  cls(0)
  print("press Z to ask", 4, 4, 6)
  print(state.reply, 4, 16, 7)
end
```

### A.3.6 save.lua（persistence）
```lua
function _init()
  state.count = 0
  if cap.has("save") then state.load(0) end
end
function _update()
  if btnp(4) then state.count = state.count + 1 end
  if btnp(5) and cap.has("save") then
    if not state.save(0) then log("warn", "save failed; disk full?") end
  end
end
function _draw()
  cls(0)
  print("count: " .. state.count, 32, 56, 7)
  print("Z=+1  X=save", 24, 70, 6)
end
```

## A.4 Capability Declaration Manifest

### A.4.1 BNF-ish 文法

```bnf
manifest        ::= "[flint]" version_line cart_meta cap_block? limits_block?

version_line    ::= "version" "=" string                      ; manifest format, "1"
cart_meta       ::= "cart_id"     "=" string                  ; reverse-DNS or uuid
                  | "cart_version" "=" string                 ; semver
                  | "title"       "=" string
                  | "author"      "=" string
                  | "min_engine"  "=" string                  ; engine semver minimum

cap_block       ::= "[caps]" cap_line+
cap_line        ::= cap_name "=" cap_value
cap_name        ::= "ai" | "save" | "net" | "raw" | "fs_read" | "fs_write" | "clipboard"
cap_value       ::= "required" | "optional" | cap_table
cap_table       ::= "{" cap_field ("," cap_field)* "}"
cap_field       ::= "mode"   "=" ("required" | "optional")
                  | "reason" "=" string
                  | "model"  "=" string
                  | "max_tokens_per_sec" "=" integer
                  | "slots"  "=" integer
                  | "max_bytes" "=" integer

limits_block    ::= "[limits]" limit_line+
limit_line      ::= "lua_instr_per_frame" "=" integer         ; default 200000
                  | "lua_heap_kb"         "=" integer         ; default 16384
                  | "rollback_frames"     "=" integer         ; default 8 (v1.5)
```

解析规则：
- `required` cap denied at load → cart fails to load with named error（不静默）
- `optional` cap denied → cart loads；`cap.has(name)` 返 `false`
- 未知 cap name → unload with `manifest: unknown capability "xxx"`
- 缺 `cart_id` 或 `version` → unload with `manifest: missing required field`
- `min_engine` 大于运行版本 → load 中断 + 版本错（不崩）

### A.4.2 三个 example manifest

**Manifest 1: 无 cap 离线 puzzle**
```toml
[flint]
version = "1"
cart_id = "com.example.tile-pusher"
cart_version = "1.0.0"
title = "Tile Pusher"
author = "ada"
min_engine = "0.4.0"
```

**Manifest 2: AI dungeon master**
```toml
[flint]
version = "1"
cart_id = "studio.example.ai-dm"
cart_version = "0.3.1-beta.2"
title = "AI Dungeon Master"
author = "example"
min_engine = "0.5.0"

[caps]
ai = { mode = "required", reason = "the dungeon master speaks", model = "qwen2.5-1.5b", max_tokens_per_sec = 96 }
save = { mode = "optional", reason = "save your campaign", slots = 8, max_bytes = 131072 }
```

**Manifest 3: rollback 格斗游戏**
```toml
[flint]
version = "1"
cart_id = "club.frame-trap.knife-fight"
cart_version = "2.0.0"
title = "Knife Fight"
author = "frame-trap-club"
min_engine = "1.5.0"

[caps]
net  = { mode = "required", reason = "online matches" }
save = { mode = "optional", reason = "training-mode notes" }

[limits]
lua_instr_per_frame = 120000
rollback_frames     = 7
```

## A.5 Error Message Style Guide

**Voice**：短、具体、blame-free。三段：**what was tried** / **why it failed** / **smallest next step**。永不止于失败，必终于行动。

反模式：`"Error: invalid argument"`（vague）、`"You did X wrong"`（blames）、`"FATAL: panic at xyz.lua:42"`（吓人无路径）。

### 10 个 example error messages

1. `gfx.draw_sprite: sprite id 999 out of range (atlas has 0..255). Did you mean to import a sprite sheet larger than 16×16 tiles?`
2. `ai.ask: capability "ai" not granted. Add to manifest: [caps]\nai = { mode = "required", reason = "..." }`
3. `state.save: slot 7 out of range (allowed 0..3). Increase slots in manifest, or use slot 0..3.`
4. `manifest: cart_version "1.0" is not semver. Try "1.0.0".`
5. `_update raised error 3 frames in a row, unloading cart. Last error: attempt to index nil (state.player). Crash artifact saved to flint-2026-05-06-1442.crash.`
6. `sfx: track 17 not present in this cart. Tracker has 0..15. (loaded from cart at 0x4F00, run 'flint inspect <cart>' to list)`
7. `inp.text_buffer: returned empty string because no IME is active. Call inp.text_buffer() only when text input is open (see inp.text_open).`
8. `lua heap: cart used 16387 KB of 16384 KB budget at frame 612. Drop some textures from state, or raise lua_heap_kb in manifest [limits].`
9. `net.join: address "192.0.2.5:7777" unreachable after 5s. Check firewall, then retry.`
10. `peek(0xC000): address out of bounds (VRAM is 0x6000..0xBFFF). Did you mean 0xA000?`

## A.6 First 10 Minutes 上手剧本

> 帧级；作者 Windows，已装 PATH，VS Code 已开。预计 **8m20s** 到能跑的 cart。

**T+0:00** 作者敲 `flint new my-game` → 创建 my-game/ 含 cart.lua / cart.toml / sprites.png / .gitignore，提示 `cd my-game && flint run`。

**T+0:30** `cd my-game && flint run` → 128×128 窗口开，magenta 点居中。按方向键，点动。微笑。

**T+1:00** Alt-Tab 回，按 F12（dev panel）→ 半透明条 `FPS 60.0  RAM 0.4/16 MB  HASH 7c3a...e1`。

**T+1:30** 改 cart.lua 的 `print(state.msg, 30, 60, 7)` → `print("hello, world!", 30, 60, 11)`。保存。引擎自重载（file watcher），cart hot-restart < 100ms。文字变光绿。**第一个学习闭环关闭**。

**T+2:30** 故意敲错 `prnt("oops", 0, 0, 7)`。引擎 scold：`[warn] cart.lua:14 attempt to call nil (did you mean 'print'?)` `[info] cart continues; expect missing draw output`。点仍动。**引擎从未崩**。

**T+3:30** 想要 sprite。开 sprites.png（任意 editor），在 tile 1 画小角色。改 cart.lua 的 `pset(state.x, state.y, 8)` → `spr(state.x, state.y, 1)`。重载。角色走起。

**T+5:00** 想要声音。`flint scaffold sfx` → `sfx.it`（impulse-tracker 文件 1 个 placeholder）。OpenMPT 开，做 beep。保存。重载。`if btnp(4) then sfx(0) end`。按 Z，beep。**有动 + 形 + 声**。

**T+7:00** 开 `flint book`（内置 browser book viewer，`localhost:7333`）。读 `cap.has("ai")`。改 cart.toml：
```toml
[caps]
ai = { mode = "optional", reason = "let the dot speak" }
```
重载。引擎控制台问 `cart "my-game" requests optional capability: ai - reason: "let the dot speak" - grant for this run? [y/n/always]:`。按 y。

**T+8:00** book viewer "copy" 按钮粘 ai.lua example。点能答问。**8 分钟内做出 working AI cart**。

**T+8:20** 再按 F12。Dev panel 多了 `AI tokens 64/64`。注意到是每秒 rate。开始 tweaking。**正在开发了**。

成功标准：scaffold 一命令 ✓ / run 一命令 ✓ / live reload ✓ / 错误宽容（scold + continue）✓ / 文档可发现 ✓ / AI 功能 < 10min ✓。

---

# PART B — RELIABILITY / STABILITY / ROBUSTNESS / PERFORMANCE

## B.1 Per-Frame Budget（16.67ms HARD）

| Phase | Budget | 理由 |
|---|---:|---|
| 1. Input poll + dispatch | **0.1 ms** | sokol app event drain + button-state diff 是微秒；偏执 headroom |
| 2. Net rollback resimulate (v1.5; 0 in v1) | **2.0 ms** | up to 7 frames × 250µs/sim under typical cart |
| 3. `_update`（cart Lua）| **6.0 ms** | 从 8ms 让出 2ms 给 rollback resim；v1（无 rollback）回 8ms |
| 4. AI worker sync（drain inbox）| **0.3 ms** | 仅 marshal worker 已产 string；ms 不是推理本身 |
| 5. `_draw`（cart Lua）| **2.0 ms** | 软件 framebuffer 绘画 + 末尾 GPU upload |
| 6. Audio mix（4 ch PSG + tracker）| **0.8 ms** | 22050Hz fixed-point，367 sample/frame |
| 7. sokol present（GPU upload + vsync wait）| **2.0 ms** | dirty-rect 128×128 上传是微秒；wait 主导 |
| 8. Dev panel + log flush + frame stats | **0.3 ms** | F12 才有；release build 是 0 |
| 9. Slack | **3.17 ms** | 吸收 hiccup；持续用满 → 调预算 |
| **Sum** | **16.67 ms** | |

**调整理由**：
- Lua _update 降 6ms（从 8）腾给 v1.5 rollback。v1 回 8（同代码路径，旋钮在 [limits]）
- AI worker sync 升 0.3ms（从 0.1）because string marshaling 跨线程
- Audio 降 0.8ms（从 1）because PSG 廉价；tracker IT mix 是主成本，~0.7ms 实测
- Slack 升 ~3.17ms 吸收 GC sweep、文件 watcher 事件、OS 调度抖动

**强制**：per-phase timer（Zig std.time.Timer）记每相。超预算 → 每秒 1 warn；连续 60 帧超 → error + 开始减 `_draw` 质量（B.7）。

## B.2 Determinism Harness（`flint replay`）

### B.2.1 Spec
```
flint replay <input-stream.bin> <cart.png> [--iterations N=1000] [--platforms linux,mac,win] [--strict]
```

读 input stream（60Hz button bitfield + system event 流），headless 跑 cart（无 sokol_gfx，无 audio，无 vsync），逐帧推进，每帧末 hash `state.*`，断言：

1. **平台内稳定**：单 binary 1000 跑出每帧相同 hash-trace
2. **跨平台稳定**：Linux x86_64 == macOS arm64 == Windows x86_64。**Wasm 单独 gate**（float 精度不同；过 Q16.16 strict validation，不要求 bitwise）
3. **跨引擎版本稳定**：hash-trace 标 `flint_version`；CI 用新引擎重跑老 trace，仅"rollback-stable"frame 要求相等

### B.2.2 Input stream 格式
```
[4 magic "FNTI"][1 version][2 button_bitmask_per_frame_count][8 cart_id_hash][4 frame_count]
[per frame: 4 button_bitfield + 1 system_events_count + N system_event TLVs]
```

System events：cap-grant outcome、文件加载时间（不可见 cart 但 log 用 diff）、AI response shape（确定性 fake — B.5）。

### B.2.3 CI 集成
GitHub Actions matrix `{linux,mac,win} × {debug,release}`：
- 拉 `tests/golden_carts/` 30 个 cart
- per cart `flint replay` 100×（CI 预算；nightly 跑全 1000×）
- diff hash-trace；任何 mismatch = red build，附首 divergent frame 的 `.crash` artifact
- Wasm 在 wasm32-wasi runner 单独跑；Q16.16 normalization 后比 hash

### B.2.4 哪些被 hash
仅 `state.*`（metatable 包装的 store）。引擎内部（sokol、GPU buffer）排除。AI 产 string 仅当 cart 写入 `state` 时 hash；AI inbox 中 streaming 文本不入 state hash。

## B.3 Crash Artifact `.crash` 格式

目标：发一个文件给开发者，跑 `flint replay <file.crash>` 完全相同分歧。必须跨版本前向兼容。

### B.3.1 TLV 布局（binary, little-endian, zlib-compressed body）
```
header (uncompressed, 32 bytes):
  +0   magic        u8[4]   = "FCRH"
  +4   format_ver   u16     = 1
  +6   reserved     u16     = 0
  +8   payload_len  u32
  +12  crc32        u32
  +16  flint_ver    u8[12]  ; ascii semver 0-padded
  +28  flags        u32     ; bit 0 = redacted; bit 1 = ai_present; bit 2 = net_present

body (zlib-compressed TLV stream):
  each record: tag u16 | len u32 | payload[len]
  tag values (forward-tolerant; unknown tags skipped):
    0x0001 cart_id            utf8 string
    0x0002 cart_version       utf8 string
    0x0003 cart_blob_sha256   32 bytes
    0x0004 manifest_toml      utf8 string
    0x0005 caps_granted       toml-ish list
    0x0010 input_stream       last 3s = 180 frames
    0x0011 state_snapshot     msgpack of state at frame F-180
    0x0012 state_hash_trace   180 × u64 hashes
    0x0020 log_tail           last 8 lines, utf8
    0x0030 ai_inbox_snapshot  pending+streaming requests at F (if ai cap)
    0x0031 ai_model_info      name/params/seed
    0x0040 net_session_id     16 bytes
    0x0041 net_input_history  per-peer last 3s of acked inputs
    0x00FF cause              utf8: "lua_error" | "instr_overrun" | "heap_overrun" | "engine_assert" | "user_quit_hotkey"
```

### B.3.2 Forward-compat
- 未知 TLV tag 必须跳，不报错（reader log info: unknown tag）
- field 从 optional 升 required 仅在 major format_ver bump
- field 改 layout 仅在 major bump；minor 仅加新 tag
- 老引擎读未来格式 .crash：尽力，log warn；不删 tag 都能成

### B.3.3 Privacy
- `--no-logs` 编译期 strip log_tail
- `flint redact <file.crash>` 清 ai_inbox_snapshot + net inputs，保 hash trace

## B.4 Dev Panel UX

### B.4.1 显示
单底条（10px 高），半透（α 0.7 over framebuffer），4 色（用 palette 13/14/15 + 固定深 0）。6 字段，定宽：
```
FPS 59.8 ↓1   RAM 1.2/16M   AI 32/64 t/s   NET 38ms ●●○   GC 0.3ms   HASH 7c3a...e1  ⚠2
```
- FPS + last-frame Δ（↑/↓）+ dropped frame
- RAM：cart Lua heap 用/预算（75% 黄，95% 红）
- AI：tokens/sec 用/预算；仅 cap "ai"
- NET：median peer RTT + 实/空圆点 peers；仅 cap "net"
- GC：last GC pause ms（Luau incremental）
- HASH：state.hash() 末 12 hex
- ⚠N：60s 内 warn 数；click（或 \`） 展开 log

### B.4.2 Toggle
- `flint --dev`：panel 默认开；hot-reload 开；`dbg(...)` 活
- `flint --release`：panel 默认关，F12 可开；hot-reload 关；`dbg(...)` no-op（编译期 strip if `--strip`）
- F12 toggle、` toggle 展开 log、F11 toggle hash-trace 录制（写 `.fnti`）
- Esc 把控制还引擎（panel 输入不达 cart）

### B.4.3 Determinism guarantee
Dev panel 在 frame phase 8 跑（B.1），**严格在 _draw 后**，**永不**在 _update 内。仅读引擎私 timer counter、`state.hash()`（idempotent）、AI worker 原子统计。**绝不调 cart-visible 函数**。**不能改 state 一个字节**。CI 测：`--dev` 与不带 1000 帧 hash 必须 bitwise 相等。

## B.5 Capability Sandbox Edge Case Matrix（15 case）

| # | 场景 | 引擎行为 |
|---|---|---|
| 1 | cart 声明 `ai = required` 但模型缺/坏 | **load 失败** with `cap "ai" required but model "qwen2.5-0.5b" not found`. 无 .crash（load-time error）。建议 `flint models pull qwen2.5-0.5b` |
| 2 | `ai = optional` 模型缺 | **load 成功**，`cap.has("ai")` = false，`cap.denied()` = `{ai="model file missing"}`。cart 当无 ai 跑 |
| 3 | `save = required` 磁盘满 | 首 `state.save()`：返 `nil, "disk full"`。cart 可应。load-time pre-check 满则同 |
| 4 | `save = required` 路径只读 | 同形：`state.save()` 返 `nil, "read-only filesystem"`；cart 继续 |
| 5 | `net = required` 离线 / DNS down | `net.start_session()` / `net.join()` 返 `nil, "network unreachable"`。cart 留单人 UI；warn |
| 6 | `ai = required` 但从不调 `ai.ask()` | 无加载 warn。runtime 30s 零 ai 调 → log info：`cart declared cap "ai" but has not used it for 30s — consider mode = "optional"`。仍授 cap |
| 7 | cart 调 `ai.ask()` 未声明 "ai" | `ai.ask` 返 `nil, "capability ai not granted"`。每分钟最多 1 warn（rate-limit）。不崩不卸 |
| 8 | 仅声明 "ai" 试 `state.save()` | 返 `nil, "capability save not granted"`。不卸 |
| 9 | manifest TOML malformed（缺 cart_id）| **load 失败** with `manifest: missing required field "cart_id"`。无 .crash（静态错）。作者见 console error + line/column |
| 10 | cart binary > 1MB | **load 失败** before Lua: `cart "xyz" is 1048577 bytes, hard limit is 1048576 (1 MB). Largest blob: sprites.png at 712 KB` |
| 11 | cart Lua 超内存预算 | Luau allocator 返 OOM，cart `_update` error `out of memory`。引擎接；log error；3 连续 → unload + .crash（cause=heap_overrun）|
| 12 | cart Lua 超 200K 指令/帧 | Luau interrupt 触发；当帧 `_update` abort；warn `cart exceeded 200000 instructions/frame at frame N`。state 回滚到帧起（无部分 update）。3 连续 → unload + .crash（cause=instr_overrun）|
| 13 | cart 从 `_ai` callback 写 `state.foo` | `_ai` 在帧间跑，state 逻辑冻结。写入入单帧 mailbox，下一帧 `_update` 起始前应用。CI 强制；hash-trace 稳定。无错给 cart；这是 intended |
| 14 | cart float ops 跨平台漂移 | **政策禁**。cart Lua 不见 libm `math.*`；见 `sin`/`cos`/`atan2`/`sqrt` 由纯 Zig Q16.16 LUT 撑（无 libm）。直 `*`/`/` doubles 允许 because IEEE 754 SSE2/NEON 一致；但 determinism harness（B.2）catch 任何 escape。Wasm gate 单独验 because 精度策略更窄 |
| 15 | cart 调 `ai.embed()` 立即用结果，worker 未完 | `ai.embed()` 返 `nil, "embedding pending"` if 未缓；cart 应下帧 retry 或 `_init` 一次缓 in `state`。热路径 async；永不阻 frame |

Bonus #16：`min_engine = "9.9.9"` → load fails at version-gate before any Lua: `cart requires flint >= 9.9.9, you have 0.5.1. Update at https://flint.dev/get`.

## B.6 Logging

### B.6.1 Levels
| Level | When | Default | Rate limit |
|---|---|---|---|
| **error** | cart unload, engine assertion, replay divergence | 总 + stderr | 无 |
| **warn** | cap denied, budget exceeded, "scolded" arg | 默认 + 合并（50× → "× 50"）| 1/同 key/sec |
| **info** | cap granted, model loaded, cart load/reload | `--log-level info` 或 `--dev` | 无 |
| **debug** | engine internals, frame timings | `--log-level debug` | 无 |

CLI: `flint run --log-level=warn|info|debug` env `FLINT_LOG=info`。

### B.6.2 per-cart 隔离
每 cart 独有 ring（last 256 lines, ~16KB）。引擎 log 分别。`.crash` log_tail 是 cart-specific 末 8 行，永非引擎 ring。

### B.6.3 Crash auto-attach
unload 时 `.crash` 写：cart log tail（8 行）→ TLV 0x0020；引擎 log tail（8 行 error+warn）→ 单独 0x0021（私；redacted by default；仅 `--include-engine-log` 含）。

### B.6.4 Log 格式
```
[<level>] <iso8601> <cart_id>:<frame> <message>
```

## B.7 Performance Reliability

### B.7.1 Anti-GC strategy
Luau incremental tri-color GC；pause bounded（典型 <1ms 默认）：
- **每帧 GC step**：`_update` 末调 `lua_gc(L, LUA_GCSTEP, K)`，K 调到边际 pause < 0.3ms。**不**做 mid-frame `LUA_GCCOLLECT`
- **`_init` 预分配**：cart 作者鼓励（`flint book` 推）`_init` 中扩表（`for i=1,1000 do state.particles[i]=nil end`）避 mid-frame rehash
- **每帧 scratch arena**：64KB Zig 端 bump arena 暴露给 `_draw` 期短生命字符串/表。`_draw` 末重置。cart 不见。逃逸（赋给 `state`）→ 写时复制 out 到 cart heap
- **string interning**：字面量内置 Luau 机制

### B.7.2 Framerate enforcement
- vsync 默认开（sokol_gfx swap interval = 1）
- 6-frame 移动平均 `_update + _draw + present` > 16.67ms → **graphics-shed mode**：
  1. **Tier 1**：跳 dev panel 渲（不跳数据采集 — 保确定性）
  2. **Tier 2**：每隔 1 帧跳 `_draw`；逻辑帧每帧仍跑（**永不跳 `_update`**）
  3. **Tier 3**：drop palette dithering effects
- **逻辑帧神圣**。引擎**永不**跳 `_update` because 那破坏确定性 + rollback + replay

### B.7.3 The contract
> **"We drop pixels before we drop logic."**

承重承诺：慢一点的机器看着卡，state.hash() 仍同。Replay portable。

## B.8 State Hash Algorithm

### B.8.1 Choice: **xxh3-64**
| 算法 | Speed (1KB) | Avalanche | Cross-platform stable | Lib size |
|---|---:|---|---|---|
| FNV-1a 64 | ~700 MB/s | weak (linear) | trivially | tiny |
| **xxh3-64** | **~30 GB/s** | strong | yes（well-spec'd）| ~2 KB |
| BLAKE3 | ~2 GB/s（single）| strong（cryptographic）| yes | ~50 KB |
| CityHash | ~10 GB/s | strong | yes-ish（versions）| ~5 KB |

选 **xxh3-64**：每写都 incremental 更新（dev panel + replay 用）；30 GB/s = 16KB state hash < 1µs。

### B.8.2 Coverage via metatable
`state` 是 userdata with `__newindex` / `__index`：
```
state.foo = 42
   → engine: hash_state(key="foo", old=existing, new=42), then write backing
```
内部 32-bit checksum/top-level key + 全局 xxh3：
```
state_hash = xxh3_64(concat(sorted(keys), sorted(per_key_checksums)))
```
每写 re-hash 廉价 because per-key incremental + 顶级减少在小固定 key 集（典型 50-500 顶级 key）。

嵌套表（`state.enemies[3].hp = 10`）应用相同 metatable 任意深。Path 捕获 `("enemies", 3, "hp")`。Per-leaf 滚总。

### B.8.3 暴露给 cart
```
state.hash() -> u64
```
用例：
- **cart 单测**：`assert state.hash() == 0x7c3a...` 已知输入序列后
- **多人 desync 检测**（v1.5）：每 N 帧 peer gossip hash；mismatch 触 `_net("desync", {...})`
- **dev panel**：显末 12 hex

返 64-bit Lua number（Luau 支）。老 Lua 用 `state.hash_hex() -> string`。

### B.8.4 Edge case
- **state 中 float**：用 sin/cos/sqrt LUT 时存 Q16.16；直 Lua double 允（不鼓励），bit 模式直 hash。Determinism harness catches 漂移
- **NaN**：Lua 一 NaN ≠ 另；hashing 时所有 NaN bit 模式归一化到 canonical 0x7ff8000000000000
- **string**：内容（非指针）；Luau intern；hash 内容流
- **circular ref**：禁；写时检测；cart `error: circular reference assigned to state.x`

## B.9 内存预算图

`--dev` 跑典型 cart：
| Region | Budget | 备注 |
|---|---:|---|
| Cart Lua heap | 16 MB（cart 可调）| manifest [limits] 声明 |
| Rollback state buffer | 64KB × 8 frames = 512 KB（v1.5）| state snapshot |
| Sprite atlas | 128 KB | 256 × 8×8 4bpp = 64KB；2× page = 128KB |
| Audio buffer | 128 KB | tracker pattern + 4 PSG voice + 2× mix @22050Hz |
| Framebuffer + dirty rect | 32 KB | 128×128×1byte ×2（front+back）|
| Engine baseline | 512 KB | sokol + Luau VM + zflecs internal + log ring |
| AI worker | external；按 ai cap 预算 cap | 模型 mmap 不计 |
| **TOTAL baseline（无 AI 无 rollback）** | **~17 MB** | cart heap 主导 |

512KB 总 runtime baseline 指引擎代码+state（不含 cart heap 不含 AI 模型）：512KB engine + ~150KB framebuffer/atlas/audio = 662KB without cart and AI。命中。Cart 作者知道 16MB 是他的。

## B.10 Cart 反模式 Watch（review 红旗）

红旗仅 info-level 提示（不是 warn）：
1. `for i=1,1000000 do end`（高指令数）→ 建议跨帧拆
2. `state.foo = nil` 然后 `= something_big` 每帧 → 建议复用
3. 热路径 `string.format` → 建议预算字符串
4. `_update` 内调 `ai.ask` → 建议 `_init` 或 input-event guard
5. 读 `inp.mouse()` 在 `_update` 用结果（非确定性）→ 引擎把 mouse 当确定性输入流，但 cart 必须每帧捕获一次

## B.11 编译/测试/CI 布局

```
flint/
├── build.zig
├── src/
│   ├── main.zig
│   ├── engine/                        # frame loop, dev panel, log, cap resolver
│   ├── lua_api/                       # 80 fn binding，每 namespace 一文件
│   ├── cart/                          # PNG steg, manifest TOML, capability resolve
│   ├── state/                         # metatable wrap, xxh3, snapshot for rollback
│   ├── ai/                            # llama.cpp dlopen, worker thread, inbox
│   ├── net/                           # GekkoNet cImport (v1.5)
│   ├── sndmix/                        # PSG + .it tracker
│   ├── gfx/                           # 软件 framebuffer + sokol_gfx upload
│   └── replay/                        # flint replay subcommand
├── tests/
│   ├── golden_carts/                  # 30 reference carts
│   ├── determinism/                   # 1000× headless replay matrix
│   ├── crash_format/                  # forward-compat .crash reader
│   └── budget/                        # per-frame budget regression
├── doc/
│   ├── dx-reliability-spec.md         # 本文
│   └── book/                          # `flint book` 内容（markdown）
└── .github/workflows/
    ├── matrix.yml
    └── nightly-replay.yml
```

CI 硬 gate（PR 不能合并 if 失）：
1. 80 API 函数全部至少 1 个单测覆盖 happy + error
2. 30 golden cart 全过 100× replay 跨 linux/mac/win
3. 无新 unsafe 不带 `// SAFETY:`（项目级镜像）
4. cart heap budget regression：基线 cart "tile-pusher" max RSS < 17.0 MB（允 0.5MB 漂）
5. .crash round-trip：写 100 个随机 .crash，读回，TLV 相等
6. Frame budget regression：CI runner 99 百分位 < 12 ms（留 16.67 头空间）

---

## C. 待 RFC 的 open questions

1. **`peek`/`poke` with cap "raw"**：v1 暴露 VRAM/sound RAM？复古 vibe 想；rollback safety 难。**默认 v1：no**。cap "raw" enable 但禁 state.hash() portability
2. **`cap.request_dynamic` mid-game**：用户要游戏在 frame 18000 弹许可？大概不要。所有 cap 在 manifest 声明。drop `cap.request_dynamic` from v1
3. **Replay 期热重载**：`flint replay` 应理文件改？**No** — replay 是冻结录制；热重载会废 trace。`flint dev` 是 live mode
4. **AI 模型换 mid-cart**：`model = "auto"` 让 host 选。host 升级模型？依 AI text 内容的 cart `state.hash()` 漂移。**政策**：AI tokens **不**入 `state.hash()` 除非 cart 显式赋（`state.last_reply = text`）
5. **Net + AI**：AI inbox 入 rollback state？**No** — AI 异步，对 net 非确定性；side-channel。v1.5 doc "lockstep AI" 模式（一玩家 AI authority + gossip）

---

## D. Glossary

- **Cart**：单 PNG，含 Lua + asset + manifest，全藏 pixel 低位
- **Manifest**：TOML 元，cart payload 顶部，声明身份/版本/cap/limit
- **Cap (capability)**：cart 声明 + host 解析的权限位（ai/save/net/raw）
- **Scold**：引擎 warn + 继续 — cart 跑下去
- **Unload**：引擎写 `.crash` + 停 cart 但**不**停自身
- **Hash trace**：每帧 `state.hash()` 的有序序列
- **Rollback-stable**：cart 标注其 hash trace 在 documented compat 范围内跨引擎版本稳定
- **Determinism harness**：`flint replay` + 跑它的 CI matrix

---

## E. 文档维护

- 本文是 cart 作者 API 表面 + 引擎可靠性属性的**单一真理源**。其他 doc（book/README/marketing）引用此，不重复
- A.2（80 函数表）改：(a) `api-change` issue (b) 更新 golden cart (c) 越 80 必删一
- B.3（.crash 格式）改：format_ver bump + forward-compat reader test
- per-frame budget（B.1）每 release 复审；数追 `tests/budget/baseline.json`，>5% regression 标
