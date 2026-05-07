# 项目设计基线（架构师 agent 产出，2026-05-06）

> 单人 90 天 MVP / 12 月 10K star 的设计基线。原则：能 bundle 的不自写，能 FFI 的不重写，能砍的先砍。
> 状态：项目最终名待 name1 agent 锁定后全部 "flint" 替换为最终名。
> scope 已按 planner 修订：v1.0 砍 rollback netcode（推到 v1.5）。

---

## 0. 一句话定位

「Pico-8 + GPT + GGPO 装进一个 6MB 二进制：写一个 cart，世界上每个 NPC 都能跟你嘴炮，朋友点链接就能在浏览器里跟你对打。」
5 秒理解版："像素游戏机 + AI 角色 + 联机回滚，单文件分享。"

---

## 1. 选型最终落定（含 scout 仲裁后修正）

### 1.1 窗口/GPU/音频
**sokol-zig**（floooh，~7k stars，10+ 年维护）。C 单头库，跨 GL/D3D11/Metal/WebGPU/WebAudio。静态链接 < 200KB。仅作 GFX/APP/AUDIO 三层 wrapper。
**砍**：mach（v0.4 后无新 tag，0.x 不稳）/ raylib-zig（哲学冲突）/ mach-glfw（仅窗口，徒增维护）。

### 1.2 脚本层（scout 推翻原方案）
**ziglua → Luau**（Roblox-validated 沙箱，自带 luaL_sandbox，已落 Alan Wake 2 / Farming Simulator 2025 / Second Life / Warframe）。
~~Lua 5.4~~ 替换为 Luau，原因：(1) 沙箱工业级 (2) safeenv 性能优化 (3) 梯度类型对 mod 作者友好 (4) ziglua 已支持 Luau。
**砍**：纯 Zig hot-reload（玩家要装 Zig 工具链）/ wasmtime-zig（启动 30ms+ 不可接受）/ MicroPython / QuickJS。
沙箱预算：每帧每 cart 默认 200K Luau 指令 + 16MB 内存上限。

### 1.3 ECS（scout 新增）
**zflecs**（zig-gamedev，flecs C v4.1.5 binding）。flecs 在 C++ 圈是事实标准，性能最好文档最全。
**砍**：zig-ecs（EnTT port）/ mach-ecs（与 mach 强耦合）/ port Bevy ECS（ROI 极低）。

### 1.4 生命周期 + 安全（scout 新增 Factorio + WASM Component Model 思想）
**load 阶段** = 注册 ECS components / 声明 NPC schemas / 声明 capability ("net"/"ai"/"save")
**runtime 阶段** = update systems（rollback-aware）/ draw systems / `_ai()` 回调（异步进入，**不参与确定性 state**）
Capability 显式声明：cart 元数据中列举所需权限，引擎按权限决定授予/拒绝/玩家弹窗确认。

### 1.5 LLM
**llama.cpp via dlopen**（不静态链接，避 6MB → 30MB 膨胀）。用户 `<bin> config llm.local <path-to.gguf>` 指自己下的模型。
默认体验：Qwen2.5-0.5B-Q4 GGUF（~280MB，sha256-verified 自动下载到 `~/.<bin>/models/`）。
云端备选：OpenAI / Anthropic / Groq / 自托管 OpenAI 兼容端点（自写 < 300 LOC HTTP client）。
**砍**：candle / mistral.rs（Rust 体系 FFI 边界复杂）。

### 1.6 网络（v1.5 才做）
**cImport GekkoNet**（C++ rollback netcode 现代 GGPO 替代）。
**砍**：自写 UDP reliable layer（单人 90 天不现实，scout 警告）。

### 1.7 cart 格式（scout 推荐 PICO-8 风路径）
**PNG 隐写**：160×205 PNG，每 RGBA 末 2 bit 存 1 byte，总 32800 字节。
病毒钩子：cart 是 PNG，发到 Twitter 直接是封面图，下载即玩。
内容分段（TLV）：CODE / SPRITE / MAP / MUSIC / SFX / AI / META / ICON。
**自实现**（不依赖外部库的语义）：编码 + 解码各 ~40 行 Zig，PNG IO 用 cImport lodepng。

### 1.8 一图汇总外部依赖

```
<bin>（静态二进制）
├── sokol (C, static)            -- 窗口/GPU/音频/输入
├── Luau (vendored via ziglua)   -- 脚本运行时（沙箱工业级）
├── flecs (C via zflecs)         -- ECS
├── lodepng (C, single header)   -- PNG IO
├── libxmp (C, optional)         -- .it tracker 播放（音乐编辑器内置后可砍）
├── zigimg (Zig, dev-only)       -- aseprite/PNG 导入
└── 运行时 dlopen:
    ├── llama.so/dll (可选)       -- 本地 LLM
    └── GekkoNet.so/dll (v1.5)    -- rollback netcode
```

**总外部代码** ≈ sokol 25K + Luau 60K + flecs 30K + lodepng 4K ≈ 120K LOC C/C++，可控。

---

## 2. 三个 Lighthouse cart（替换原 5 cart）

### Demo 1（旗舰）: `gym_beef.<ext>` —— AI 道馆主嘴炮
Pokemon 风像素道馆。4 个道馆主，性格 + system prompt（电系暴躁/水系阴阳怪气/草系装哲学/火系 cocky）。
玩家文字嘲讽 → AI 回喷。每次 cart 内 deterministic 战斗结果不变（保 rollback-ready），但对话每次新鲜。
30s TikTok hook："I trash-talked an AI gym leader and it BODIED me 💀"
工时：12 天。

### Demo 2: `tavern.<ext>` —— 酒馆秘密
黑暗酒馆 5 NPC，每人 3 秘密被 AI prompt 锁住，玩家用对话技巧解锁。CRT shader 全开 + 4-bit 钢琴 BGM。
情感钩：Reddit 长玩家叙事。"5 分钟像素游戏让我哭了" 类标题。
工时：8 天。

### Demo 3: `dungeon_ai.<ext>` —— 地牢 AI Boss 嘲讽
俯视像素地牢，每层 boss 战前 30s 对话。Boss 知道玩家近期失败次数（"听说你刚才在第 3 层死了 5 次？"）。
病毒钩子：技术 + 戏剧 双中。"AI 知道我刚才死了几次还嘲讽我"。
工时：14 天。

**工时合计**：34 天 / 90 天预算（剩 56 天给 runtime + buffer）。
**已砍**：smash.<ext>（rollback netcode 推 v1.5）/ dating_sim.<ext>（v1.1 候选）。

---

## 3. cart 文件格式 v1.0

```
+---------+-------------+----------+----------+
| Magic 8B| Header 56B  | Sections | Footer   |
+---------+-------------+----------+----------+

Magic:    "<NAME>\x00\x01\x00"  (版本 1.0)，<NAME> 是项目名 5 字节大写
Header:   {
            cart_id: u128 (uuid v4),
            author: [16]u8,
            title:  [32]u8,
            flags:  u32,    // bit0=needs_net, bit1=needs_llm, bit2=multiplayer
            n_sections: u8,
          }

Section (TLV):
  type: u8     0=CODE 1=SPRITE 2=MAP 3=MUSIC 4=SFX 5=AI 6=META 7=ICON
  len:  u32 LE
  data: [len]u8

Footer:   crc32 of everything before footer (4B) + magic_end "END<NAME>"
```

外层：把上述字节流通过 PICO-8 PNG 隐写嵌入 160×205 PNG。
典型大小：sprite 16KB + map 8KB + Luau 16KB + AI prompt 4KB + music 4KB ≈ **48KB cart**。
硬上限：单 cart 1MB。

AI section 内容（TOML 嵌入）：
```toml
[[npc]]
id = "gym_leader_beef"
system = "You are Beef, a cocky electric-type gym leader..."
model_pref = ["groq:llama-3.1-70b", "local:qwen-2.5-0.5b", "fallback"]
max_tokens_per_turn = 80
memory = "summary"   # summary | full | none
fallback_lines = ["...", "...", "..."]   # 离线兜底
```

---

## 4. CLI Surface

```
<bin> run <cart>                 # 运行 cart（默认）
<bin> dev [dir/]                 # 开发模式：watch 文件，热重载 Lua/sprite
<bin> new <name>                 # 脚手架新 cart 工程
<bin> pack <dir/> -o cart.<ext>  # 打包目录为 cart
<bin> export --target wasm <c>   # 导出为 wasm + index.html
<bin> export --target native <c> # 嵌 cart 到 runtime → 单二进制可执行
<bin> share <cart>               # 上传到 <bin>.gg（官方 CDN）
<bin> config llm.local <path>    # 配置本地 LLM 模型路径
<bin> config llm.cloud groq      # 选择云 provider
<bin> replay <inputs.bin> <cart> # 1000× 头无运行 + state hash 不变断言
<bin> replay-crash <file.crash>  # 重放崩溃报告
<bin> version
```

---

## 5. 模块布局（src/）

```
src/
├── main.zig                 -- CLI 入口、subcommand 路由
├── runtime/
│   ├── core.zig             -- 主循环、帧调度、事件
│   ├── pixel.zig            -- 128×128 framebuffer + palette
│   ├── sprite.zig           -- atlas + draw API
│   ├── tilemap.zig          -- map 数据 + 渲染
│   ├── audio.zig            -- 4 通道混音器
│   ├── tracker.zig          -- pattern player（.it 解析）
│   ├── input.zig            -- gamepad/键盘/触屏抽象
│   └── post.zig             -- CRT shader uniform 管理
├── lua/
│   ├── vm.zig               -- ziglua + Luau 实例 + 沙箱
│   ├── api.zig              -- 全部 cart 可调函数（≤80）
│   └── hot_reload.zig       -- dev 模式 chunk 替换
├── cart/
│   ├── format.zig           -- .cart 序列化/解析
│   ├── png_steg.zig         -- PNG 隐写 encode/decode
│   ├── pack.zig             -- pack 命令
│   └── validate.zig         -- 结构校验、CRC、capability 矩阵
├── ai/
│   ├── router.zig           -- model 路由 + 降级
│   ├── llama_local.zig      -- llama.cpp dlopen FFI
│   ├── openai_compat.zig    -- HTTP client，云 provider
│   ├── memory.zig           -- 三档上下文策略（none/summary/full）
│   ├── ratelimit.zig        -- 令牌桶
│   └── safety.zig           -- 输入注入过滤
├── net/                     -- v1.5
│   ├── socket.zig
│   ├── reliable.zig
│   ├── rollback.zig         -- cImport GekkoNet
│   ├── snapshot.zig
│   ├── matchmake.zig
│   └── stun.zig
├── render/
│   ├── sokol_gfx_init.zig   -- 后端选择 + pipeline
│   ├── shaders/             -- glsl 源 + sokol-shdc 编译输出
│   └── upscale.zig          -- 整数倍 + CRT
├── ecs/
│   └── world.zig            -- zflecs wrapper + 注册 helpers
├── tools/
│   ├── dev_watch.zig        -- 文件 watch
│   ├── ase_import.zig       -- aseprite 解析
│   ├── tmx_import.zig       -- tiled 解析
│   └── editor/              -- 内置 sprite/tracker 编辑器（cart 形态）
├── share/
│   └── cdn_upload.zig       -- share 实现
└── wasm/
    ├── glue.js              -- 浏览器侧 50 行胶水
    └── entry.zig            -- wasm 入口
```

每个 .zig 文件目标 <600 LOC（强制；超了拆分）。
预估 v1.0 总量 18-22K LOC Zig + 50 行 JS。

---

## 6. build.zig 交叉编译矩阵

```
zig build              -> debug native
zig build -Doptimize=ReleaseSmall -Dtarget=x86_64-linux-musl
zig build -Doptimize=ReleaseSmall -Dtarget=aarch64-linux-musl
zig build -Doptimize=ReleaseSmall -Dtarget=aarch64-macos
zig build -Doptimize=ReleaseSmall -Dtarget=x86_64-windows-gnu
zig build -Doptimize=ReleaseSmall -Dtarget=wasm32-freestanding
zig build release-all  -> 一键打包 5 平台 + 校验和
```

**最终二进制目标**：
| Target | Size |
|---|---|
| linux-x86_64 | 4-5 MB |
| linux-aarch64 | 4-5 MB |
| macos-aarch64 | 5 MB |
| windows-x86_64 | 5-6 MB |
| wasm32 | 1.2 MB（gzipped 450KB） |

---

## 7. 三大风险 + 缓解（已纳入 dx1 spec）

### 风险 1: LLM 启动延迟 / 体验断裂
（多层防御）：默认走云（Groq llama-3.1-8b 实测 <200ms 首 token）→ 后台预热 dummy prompt → 流式响应 + 打字动画 30ms/字符下限 → 800ms 超时回 fallback → 首启动 5s 引导让用户选 free Groq / OpenAI / 本地。

### 风险 2: Rollback + Lua + AI 三者确定性冲突（v1.5 时再处理）
- AI 回调路径与 deterministic state 物理隔离（metatable 拦截写入）
- AI 触发的游戏事件走 deterministic 翻译路径（reply hash 作 seed）
- Luau 沙箱限制 GC 行为（禁用 weak table、finalizer，强制 incremental GC + 每帧固定步数）
- State diff 校验：每秒同步一次 state hash，对端不一致则强制 desync 中断

### 风险 3: 工时不可能性（已砍 netcode + 5 cart → 3 cart）
- runtime 估算 90-120 天 vs 单人 90 天总预算 90 天
- 已砍 rollback netcode 到 v1.5
- 已砍 demo 到 3 个
- 已砍 v1.0 内置 sprite/tracker 编辑器（用 aseprite + 命令行 tracker），v1.1 补
- Day 60 必须有 1 个 demo + landing page，开始 build in public

---

## 相关文件路径

- 设计文档（本文件）：`D:\bak\doc\design-blueprint.md`
- planner 路线图：`D:\bak\doc\roadmap.md`
- scout 主报告：`D:\bak\doc\flint-market-recon-2026-05.md`
- scout 补章：`D:\bak\doc\ADDENDUM-RECON.md`
- session 进度：`D:\bak\doc\session-progress-2026-05-06.md`
