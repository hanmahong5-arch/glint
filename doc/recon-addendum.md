# ADDENDUM — flint 调研补章（2026-05）

> 主报告：[`flint-market-recon-2026-05.md`](flint-market-recon-2026-05.md)
> 本补章追加两章：
> - **A**：成熟旧技术清单 + Zig 生态可用度
> - **B**：游戏 plugin/extension 架构哪种设计被反复证明

---

## 章节 A — 成熟旧技术清单 + 在 Zig 生态的复活/移植情况

### 总览表

| # | 技术 | 龄期 | Zig 生态状态 | 推荐策略 |
|---|---|---|---|---|
| 1 | GGPO rollback netcode | 17 年（2008） | **无原生 Zig port**；需 `@cImport` GekkoNet（C++）或 GGPO（C） | **直接 leverage**（cImport GekkoNet） |
| 2 | Lua / LuaJIT | 32 年（1993） | ziglua 478 stars，6 release，主线追 Zig master | **直接 leverage** |
| 3 | Mod tracker (mod/xm/it) | 30+ 年 | 无 Zig 库；libxmp 是 C，可 cImport；微缩 .it 解析器可两天写完 | **leverage libxmp** + 可选自实现 |
| 4 | PICO-8 cart PNG steg | 11 年 | 无现成 Zig 实现；算法极简（每色道末 2 bit）40 行 Zig 可写 | **自实现**（学习 picotool/shrinko8） |
| 5 | Aseprite ASE 格式 | 24 年 | 无成熟 Zig parser；libaseprite-c 不存在；格式公开 | **自实现** parser（一周以内） |
| 6 | Bevy ECS | 5 年 | 无 Zig port；Zig 侧用 zflecs (63★) / zig-ecs (412★) / mach-ecs | **不要 port Bevy**，用 zflecs |
| 7 | Tiled TMX | 16 年 | 无 Zig 库；XML/JSON 都有 Zig parser；tilengine 是 C | **自实现** JSON 路径 |
| 8 | Spine 2D / DragonBones | 13 年（Spine 2013） | spine-c 官方 runtime 可 cImport；无 Zig wrapper | **flint 不需要**（fantasy console 体量过头） |
| 9 | OpenSimplex / Perlin | 30+ 年 | std 没有；社区有 zig-noise 等小库；50 行 Zig 可写 | **自实现** |
| 10 | CRC32 / zstd / lz4 | 25+ 年 | std.compress 已含 deflate/lzma/xz；CRC32 在 std.hash；zstd 走 cImport facebook/zstd | **std 自带 + cImport zstd** |

### 1. GGPO rollback netcode（17 年验证）

**Zig 现状**：
- 没有原生 Zig 实现。
- 替代品 1：**GGPO**（pond3r/ggpo, MIT，~1.7k stars） — C API，2019 评估 SDK 后基本停摆，但**API 已稳定**。
- 替代品 2：**GekkoNet**（HeatXD, BSD-2，39 stars，2026-04-15 仍 commit） — C++ API 现代化的 GGPO。已被 3sx / Klawiatura / bsnes netplay 采用。

**leverage vs 重写判断**：
- **直接 cImport GekkoNet** — 成本一周以内，成熟度比重写高一个量级。
- 风险：GekkoNet 仅 39 stars 单作者，bus factor = 1。flint 应有"如果 GekkoNet 死了我们 fork 它"的预备方案。
- "Rollback as a Zig library" 是潜在 OSS 副产品 — 把 GekkoNet 抽象成 idiomatic Zig API，可能本身就是个有故事的开源副作物。

### 2. Lua / LuaJIT（32 年验证，最古老脚本宿主）

**Zig 现状**：
- **ziglua**（natecraddock）478 stars，v0.6.0 / 2025-11-25，支持 Lua 5.1-5.5 + LuaJIT + Luau。**主线跟随 Zig master**，有 zig-0.15.2 分支。
- **zig-luajit**（sackosoft）针对 0.15.1 stable，强调安全检查和测试覆盖。
- **zluajit**（negrel）专攻 LuaJIT 5.1/5.2。

**性能**：LuaJIT 在动态语言里仍是 top-tier，比 V8 慢一截但比 CPython 快数十倍。对 fantasy console cart 脚本完全够用。

**沙箱能力**：
- 标准 Lua 没有强沙箱，但 `setfenv`（5.1）/ `_ENV`（5.2+）可以做基本环境隔离。
- **生产级沙箱方案是 Luau**（见 §A 备注）—— Luau 5.5k stars，自带 `luaL_sandbox` / `luaL_sandboxthread`，被 Roblox / Alan Wake 2 / Farming Simulator 2025 / Second Life / Warframe 验证。
- ziglua 已支持 Luau，**这就是 flint 应该走的路**：用 ziglua 接 Luau，免费拿到工业级沙箱。

**leverage 判断**：**直接 leverage ziglua + Luau**。这是整个 §A 里最高 ROI 的现成技术。

### 3. Mod tracker 格式（mod/xm/it/s3m，30+ 年）

**Zig 现状**：
- 没有 Zig 原生 .mod/.xm/.it 解析器或播放器。
- **libxmp** （C，BSD-3，~600 stars）是行业标准库，cImport 即用。
- **OpenMPT** 库可作 Pro 选项。
- 自己写 .it 播放器：业界已知套路，1-2 周可达"够用"水平（参考 muki.io 的 Rust 版 OpenMPT 移植笔记）。

**leverage 判断**：
- 短期：**cImport libxmp**（一天集成）
- 长期：如果想做 chiptune 创作 IDE 内置编辑器，自实现一个简易 .it 写入器（一周）

为什么这个选项重要：fantasy console 必须有"内置音乐编辑器"，PICO-8 / TIC-80 都有。flint 抄它们的 tracker UX，但底层数据格式建议直接选 .it（容量小，工具链成熟）。

### 4. PICO-8 cart PNG 隐写术（11 年验证）

**算法核心**（公开规范，详见主报告 §11 链接的 Wiki）：
- 160×205 PNG，每像素 RGBA 4 字节
- 每色道**末 2 bit** 存 1 PICO-8 byte（A=高 2 bit, R, G, B=低 2 bit），ARGB 拼成 1 byte
- 总容量 32800 bytes（0x8020）
- bytes 0x4300-0x7fff 是源码区，自带压缩（move-to-front + offset/length 编码）

**参考实现**：
- 官方 C：[dansanderson/lexaloffle](https://github.com/dansanderson/lexaloffle)
- Python：picotool, shrinko8
- Roberto Vaccari 博客有完整 Python 解码示例

**flint 自实现路径**（Zig 角度）：
- 编码 + 解码各 ~40 行 Zig
- PNG 读写：std.compress.zlib + std.io 自己写 IDAT，**或** cImport libpng/lodepng
- 推荐 **lodepng**（zlib 自包含 + 单文件 C）

**leverage 判断**：**自实现**。这是 flint 的核心差异化能力之一（"cart 是 PNG，发到 Twitter 直接玩"），不能依赖任何外部库的语义。

### 5. Aseprite ASE 格式（24 年，从 90 年代 Allegro 时代）

**Zig 现状**：
- 没有成熟 Zig parser。
- aseprite 官方文件格式公开（ase-file-specs.md in aseprite repo）。
- Rust 有 `asefile` crate（4k+ downloads/month）可作设计参考。

**flint 自实现路径**：
- ASE 是 chunk-based 二进制格式，Zig 写 reader/writer ~500 行
- 关键 chunk：layer (0x2004), cel (0x2005), palette (0x2019)
- LZ77 解压（cel chunk 内）—— std.compress.flate 直接用

**leverage 判断**：**自实现 reader 即可**。flint 不需要 writer（创作者用 Aseprite 编辑，导出 ASE，flint 读入）。500 行 Zig，一周搞定。

### 6. Bevy ECS（5 年，Rust 现代答案）

**Zig 现状**：
- **完全没有人 port Bevy ECS 到 Zig**。Bevy 的 ECS 与 Rust 的 trait/lifetime 高度耦合，port 成本远超 reimplement。
- Zig 侧 ECS 已有三个选项：

| 库 | Stars | 类型 | 备注 |
|---|---|---|---|
| **prime31/zig-ecs** | **412** | 纯 Zig（EnTT port） | 274 commits，活跃 |
| **zig-gamedev/zflecs** | 63 | Flecs C 库 binding | 跟 flecs v4.1.5，2026-03 commit |
| **hexops/mach-ecs** | 在 mach 主仓 | 纯 Zig，第一性原理设计 | 与 mach 强耦合 |

**leverage 判断**：
- **不要 port Bevy**（ROI 极低）
- **首选 zflecs**（flecs 在 C++ 圈已是事实标准，性能最好，文档最全）
- 备选 zig-ecs（如果"全 Zig 无 C 依赖"是硬约束）
- mach-ecs 只在你已绑 mach 时考虑

### 7. Tiled TMX 地图格式（16 年）

**Zig 现状**：
- 无 Zig 库。
- TMX 有 XML 和 JSON 两种存储；JSON 路径用 std.json 30 分钟搞定。
- C 库 tilengine（~1.5k stars）能 cImport，但带太多渲染相关代码。

**leverage 判断**：**自实现 JSON 解析**（~200 行 Zig）。fantasy console 不需要 Tiled 完整功能（多层、对象、tile property 复杂规则），只需要 width/height/tile array。**不要引入 tilengine**。

### 8. Spine 2D / DragonBones（13 年，Spine 2013）

**Zig 现状**：
- spine-c（官方 C runtime）可 cImport。
- DragonBones 已基本停止开发（最后大版本 2019）。
- **flint 不需要这个层级**：fantasy console 是 8/16-bit 像素美学，骨骼动画过头了。

**leverage 判断**：**不抄**。flint 的动画应该是 sprite frame-based（PICO-8/TIC-80 风格），而非骨骼。引入 Spine 是产品定位错误。

### 9. OpenSimplex / Perlin noise

**Zig 现状**：
- std 没有。
- 社区有 [Srekel/zig-noise](https://github.com/Srekel/zig-noise)、[ziglibs/zigly](https://github.com/ziglibs)（含 noise）
- 经典 OpenSimplex 算法在 50-150 行 Zig 内可写完。

**leverage 判断**：**自实现**。fantasy console cart 经常需要 noise 函数生成地形/纹理，作为 cart 标准库一部分，自己写并冻结 API（确定性！rollback 必需）。

### 10. CRC32 / zstd / lz4

**Zig 现状**：
- **CRC32**：`std.hash.crc.Crc32` 已自带（CRC32-IEEE）
- **deflate / gzip / xz / lzma**：`std.compress.flate` / `xz` / `lzma` 全部自带
- **zstd**：std 没有，需 cImport facebook/zstd（C99，零依赖）
- **lz4**：std 没有，cImport lz4/lz4 或者 70 行 Zig 自实现 LZ4 解压器

**leverage 判断**：
- 包内压缩：**std.compress.flate** 即可，与 PNG 一体
- 网络压缩：**自写 LZ4 解压**（决定性 + 二进制小 + 70 行）
- 备份归档：cImport zstd（如果将来引入）

---

### §A 总结表 — 直接 leverage / 自实现 / 不抄

| 类别 | 项目 |
|---|---|
| **直接 leverage**（已有成熟 Zig binding 或 C 库可 cImport） | GekkoNet, Luau via ziglua, libxmp, lodepng, zflecs, zstd（如需） |
| **自实现**（核心差异化或简单到不值得依赖） | PICO-8 PNG steg, ASE reader, TMX JSON, OpenSimplex, LZ4 解压 |
| **不抄**（产品定位错误） | Spine 骨骼, Bevy ECS port, DragonBones |

---

## 章节 B — 游戏 plugin/extension 架构反复验证的设计模式

### 9 大架构设计抽象 + flint 取舍判断

#### 1. Source Engine mod（17 年，CS / TF2 / DOTA2 / Garry's Mod）

**核心设计抽象**：
- **C++ DLL 注入** + **Hammer level editor** + **GCF/VPK 资产打包**
- 服务器/客户端共享一份代码，通过 `entity` system 抽象 game logic
- Garry's Mod 在 Source 上加了 **Lua 层**，让 mod 能用脚本而非 C++

**关键启示**：
- **二层架构**：底层引擎（重，专家做） + 上层脚本（轻，玩家做）。Garry's Mod 的成功就是因为这一层。
- **资产打包格式必须可读可改**：VPK 是 valve 自创但**完全文档化**，社区工具链丰富。

**flint 应不应该抄**：**抄分层思想，不抄 C++ DLL**。flint 的"上层脚本"应该是 Luau；"DLL 注入"在 fantasy console 里不需要。

#### 2. id Tech mod（30 年，Quake / Doom）

**核心设计抽象**：
- **QuakeC**（Quake 1）：自创 VM 字节码，沙箱完美，**这是最早的"游戏专用 VM"**
- **Doom WAD**：纯数据驱动 mod（关卡、贴图），**无脚本也能 mod**
- **id Tech 4** 起改用 C++ DLL，社区 mod 反而下降

**关键启示**：
- **数据驱动 > 代码驱动**。Doom WAD 在 1993 年就证明：让玩家改"数据"（关卡、贴图、敌人参数），比让玩家"编程"门槛低 100 倍，传播广 1000 倍。
- **专用 VM** 比"嵌入通用语言"更适合游戏（QuakeC 早 Lua 4 年）

**flint 应不应该抄**：
- **抄"数据驱动"哲学**：cart 应该让"非程序员"也能 fork（改 sprite/map/palette 不需要写代码）
- **不抄"自创 VM"**：今天有 Luau / WASM，重新发明轮子无收益

#### 3. Bevy ECS plugin（Rust 现代答案）

**核心设计抽象**：
- **Plugin trait**：每个 plugin 实现 `fn build(&self, app: &mut App)`，注册自己的 system / component / resource
- **Schedule** 驱动：plugin 不是"挂钩入口"，是"参与 ECS 调度"
- **Type-driven**：plugin 之间通过类型签名匹配，无字符串约定

**关键启示**：
- Plugin 不是"别在主进程外跑"，而是"无差别参与主循环"
- Type system 做 contract 比文档约定可靠 100 倍

**flint 应不应该抄**：
- **抄"plugin 是一等公民"**：cart 里的"系统"应该和引擎自带"系统"无差别（同样的 ECS 接口）
- **不抄 Rust trait**：Zig 没有 trait，用 vtable + comptime interface 等价物

#### 4. Godot GDExtension（动态库 plugin）

**核心设计抽象**：
- **C ABI 边界**（`godot_cpp` 是上层包装）
- 通过 `.gdextension` 文件描述动态库 + 入口
- 调用通过 GDExtensionInterface（一组 C 函数指针）

**关键启示**：
- 动态库 plugin 必须有**稳定的 C ABI**，否则每次引擎升级都要重编 plugin
- C 函数指针表（vtable as table of fns）比 dlsym 单函数稳定得多

**flint 应不应该抄**：**抄 C ABI 边界思想**，但 fantasy console 体量不需要"动态库 plugin"。这条对 flint 更多是**警告**：如果将来要做"原生扩展"（例如 Steam SDK 集成），必须从 day 1 设计稳定 C ABI。

#### 5. Roblox Luau + 沙箱（最大 UGC 平台之一）

**核心设计抽象**：
- **Luau 5.5k stars**，从 Lua 5.1 fork 出来加梯度类型 + 沙箱
- `luaL_sandbox` 隔离 global table；`luaL_sandboxthread` 隔离每个执行线程
- **safeenv** 性能优化（沙箱开启反而更快，因为禁止 monkey-patch 后 JIT 假设更强）
- 已被 Alan Wake 2 / Farming Simulator 2025 / Second Life / Warframe 采用 — **不再是"Roblox 私货"**

**关键启示**：
- **沙箱不是性能税，是性能助力**（如果 VM 设计得好）
- **梯度类型**对 mod 作者友好（写裸 Lua 可，加类型注解可，自然进化）
- 一个 sandbox 模型反复验证 = **直接抄**

**flint 应不应该抄**：**核心抄**。Luau 是 flint 脚本层的事实最优解。

#### 6. Minecraft mod（Forge / Fabric，最大成功 mod 生态）

**核心设计抽象**：
- **Forge**：API 层 + ASM 字节码注入，重，但能改一切
- **Fabric**：mixin（同样 ASM 但更轻量）+ event API，**模块化哲学**
- **CurseForge / Modrinth**：分发平台是事实标准，**这个比技术更重要**

**关键启示**：
- **生态价值 > 技术优雅**。Forge ASM 注入是技术烂活，但 18 年来支撑了几十万 mod。
- **分发平台必须从 day 1 规划**。flint 必须有"flint.fun cart 分享站"或寄生在 itch.io。

**flint 应不应该抄**：
- **抄"分发即产品"思想**
- **不抄 ASM 注入**：fantasy console 没必要那么 hack；脚本层 + 数据层已足够

#### 7. Factorio mod + Lua 绑定（指数级 mod 数量）

**核心设计抽象**：
- **三阶段生命周期**：settings → prototype → runtime（清晰、不可逾越）
- **Modified Lua 5.2 沙箱**：去除 io/os 等危险模块
- **事件驱动**：runtime 阶段 mod 通过 `script.on_event` 注册回调，引擎统一派发
- **Mod portal**：单一权威分发渠道（每类别 280-1400 个 mod，仓储类 1414 个）

**关键启示**：
- **生命周期切割**是天才设计：prototype 阶段定义"什么存在"（确定性、可缓存），runtime 阶段处理"发生什么"（动态、状态化）。两个阶段不可混淆 = 性能 + 可维护性双赢。
- **去除危险模块的 Lua 比 Luau 简单**，但牺牲了"反 monkey-patch"

**flint 应不应该抄**：**强烈抄"生命周期切割"**。flint cart 应该有：
- **load 阶段**：定义 sprites / palettes / map / NPC schemas（确定性，可序列化）
- **runtime 阶段**：每帧 update / draw（动态，参与 rollback）

这与 ECS 的 component 注册 vs system tick 自然契合。

#### 8. WebAssembly Component Model（2026 新答案）

**核心设计抽象**：
- **WIT**（WebAssembly Interface Types）IDL 描述 plugin 接口
- **Component** 是 `Module + 类型元数据 + adapter`，跨语言无 glue
- **Capability-based 安全**：plugin 默认零权限，host 显式授予 fs/net/clock
- **Wasmtime** 作为 reference runtime（也最常用），可限制 CPU/内存/执行时间
- 已落地：Envoy / Zed / Shopify Functions / Figma 都用 WASM 做 plugin

**关键启示**：
- **多语言 plugin** 是 2026 共识：rust / go / python / zig / c 都能产出同一个 .wasm，host 不关心
- **Capability 模型** 是工业级安全（比 Lua 沙箱更严格、更可审计）
- **Component Model 仍在快速演进**（async stream/future、GC、threads 都是 2026-2027 路线）

**flint 应不应该抄**：
- **不抄完整 Component Model 作为 day 1 plugin 模型** — 太重，编译期复杂度 + 工具链门槛对 fantasy console 用户致命
- **抄 capability-based 思想**：cart 声明它要什么权限（"我要联网"、"我要存档"、"我要打开摄像头喂 AI vision"），引擎按权限决定要不要给
- **保留 future-fit**：cart 内核脚本是 Luau，但 cart 元数据格式预留 "wasm-component" 类型，留给未来想做"我用 Rust 写 cart"的硬核作者

#### 9. PICO-8 / TIC-80 cart（fantasy console 原生答案）

**核心设计抽象**：
- **单文件 = 一切**：脚本 + sprite + palette + sfx + music + 元数据全在一个文件
- **PICO-8 用 PNG 隐写**（cart 看起来就是个 cart 图）
- **TIC-80 用纯文本 .tic + 二进制 .tic**（双格式）
- **极小容量** = 强制创意

**关键启示**：
- **"一文件即一切"** 是 fantasy console 的灵魂，不能丢
- **限制即特性**（32KB cart 是文化标识，不是缺陷）

**flint 应不应该抄**：
- **核心抄**：cart 必须是单文件
- **改进点**：让 cart 元数据声明 AI prompt + rollback 配置（PICO-8/TIC-80 没有这两层）

---

### §B 总结 — flint plugin 架构 day-1 设计建议

基于 9 个被反复验证的设计，flint 应该这样设计：

```
flint cart (.flint.png)
├── 数据层 (Doom WAD / fantasy console 哲学)
│   ├── sprite atlas
│   ├── palette
│   ├── tilemap
│   └── sfx/music (.it format)
├── 脚本层 (Luau via ziglua, Roblox 路径)
│   ├── load 阶段 (Factorio prototype 哲学)
│   │   ├── 注册 ECS components (zflecs)
│   │   ├── 声明 AI NPC schemas
│   │   └── 声明 capability ("net", "ai", "save")
│   └── runtime 阶段 (Bevy plugin 哲学)
│       ├── update systems (rollback-aware)
│       └── draw systems (rollback-aware)
└── 元数据层
    ├── AI prompt blocks (flint 独家)
    ├── rollback config (flint 独家, GekkoNet bound)
    └── future: wasm-component plugin (留接口)
```

**最关键的两个设计选择**：

1. **Luau + ziglua 是脚本层基石**（不是 plain Lua，不是 JavaScript，不是 Wren，不是 自创 DSL）
2. **load/runtime 二段式生命周期**（抄 Factorio）+ **capability 声明**（抄 WASM Component Model）

---

## Sources（章节 A + B 新增）

- [GitHub - natecraddock/ziglua](https://github.com/natecraddock/ziglua) — 478 stars, Lua 5.1-5.5 + LuaJIT + Luau
- [GitHub - sackosoft/zig-luajit](https://github.com/sackosoft/zig-luajit)
- [GitHub - luau-lang/luau](https://github.com/luau-lang/luau) — 5.5k stars, v0.719 / 2026-05-01
- [Luau goes open-source (2021)](https://mobidev.github.io/luau/2021/11/03/luau-goes-open-source.html)
- [GitHub - prime31/zig-ecs](https://github.com/prime31/zig-ecs) — 412 stars
- [GitHub - zig-gamedev/zflecs](https://github.com/zig-gamedev/zflecs) — 63 stars, flecs v4.1.5
- [GitHub - hexops/mach-ecs (in mach)](https://github.com/hexops/mach)
- [Flecs - flecs.dev](https://www.flecs.dev/)
- [P8PNGFileFormat - PICO-8 Wiki](https://pico-8.fandom.com/wiki/P8PNGFileFormat)
- [Steganography: decoding Pico-8 cartridges (Roberto Vaccari)](https://robertovaccari.com/blog/2021_01_03_stegano_pico8/)
- [Cartridge storage and code compression scheme (Lexaloffle BBS)](https://www.lexaloffle.com/bbs/?tid=2400)
- [Building Native Plugin Systems with WebAssembly Components (Sy Brand)](https://tartanllama.xyz/posts/wasm-plugins/)
- [WebAssembly Component Model docs](https://component-model.bytecodealliance.org/)
- [GitHub - WebAssembly/component-model](https://github.com/WebAssembly/component-model)
- [Factorio API Docs](https://lua-api.factorio.com/latest/)
- [Factorio Modding Wiki](https://wiki.factorio.com/Modding)
- [Sandboxed LuaCombinator (Factorio mod)](https://mods.factorio.com/mod/SandboxedLuaCombinator)
- [GekkoNet repo](https://github.com/HeatXD/GekkoNet) — 39 stars, 2026-04-15
- [GGPO repo](https://github.com/pond3r/ggpo) — ~1.7k stars
- [4x8Matrix/sandbox-luau](https://github.com/4x8Matrix/sandbox-luau)

---

**ADDENDUM 结束**。
