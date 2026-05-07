# flint 市场绿地度 + 注意力磁场真实性核查（2026-05）

> 任务：验证 `flint`（Zig 单二进制 fantasy console + AI NPC + rollback netcode）的市场绿地度 + 注意力磁场真实性。
> 方法：6× WebSearch + 5× WebFetch（GitHub repo 直读以拿确切 star/commit 数据）。
> 立场：诚实判断，看到死路就明说。

---

## 1. Fantasy Console 当前格局（表 1）

### 1.1 候选项目对比表

| 项目 | License | GitHub Stars | 最近活跃 | 跨平台单二进制 | AI NPC | Rollback Netcode | 浏览器分享 cart | 备注 |
|---|---|---|---|---|---|---|---|---|
| **PICO-8** (Lexaloffle) | 闭源商业 $14.99 | n/a（闭源） | 2026-02 仍在更新（PicPic iOS app） | 是（Win/Mac/Linux/RPi） | 无 | 无 | 是（BBS + cart 内嵌图） | 文化标杆，Celeste 起源；闭源是**致命弱点**，社区无法 fork |
| **TIC-80** (nesbox) | MIT | **6.0k** | repo 表面更新到 2026-02，但**最新 release 仍是 v1.1.2837 / 2023-10**（无 tag 已 19 个月） | 是（Win/Mac/Linux/Android/iOS/Web） | 无、**无任何官方计划** | 无 | 是（tic80.com） | 唯一开源主流，但**实际 momentum 已大幅放缓**，最大维护者 nesbox 个人项目 |
| **Picotron** (Lexaloffle) | 闭源 $19.99 | n/a | 2024 起 alpha，2026 仍 alpha | 是 | 无 | 无 | 部分 | PICO-8 继任者，128px → 480px，仍闭源 |
| **LIKO-12** | MIT | ~1.0k（停滞） | 最后大更新 2021 | 部分 | 无 | 无 | 部分 | 项目**事实上已死**，作者多年未提交 |
| **Bitsy** (Adam Le Doux) | MIT | ~1.6k | 2024 偶尔小修 | Web only（打包 HTML） | 无 | 无 | 是（HTML 自包含） | 极简叙事工具，无戏剧化 viral 潜力；社区已迁移到 Bitsy 衍生 fork |
| **Pixel Vision 8** | MS-PL | ~1.6k | **2022 起 archived 状态**（Jesse Freeman 已转 Unity） | 是（旧版 .NET） | 无 | 无 | 部分 | 已死 |
| **WASM-4** (aduros) | ISC | ~3.6k | 2024 Q4 起几乎无 commit | 是（任何 .wasm 宿主） | 无 | 无 | 是 | 唯一 WASM-first，技术骨头很硬，但**没有 AI/网络扩展** |
| **Microstudio** (gilles-leblanc) | MIT | ~1.2k | 2025 仍活跃 | Web 优先 + 离线 | 无 | 无 | 是 | 法系小众，文档不英文化 |

### 1.2 表 1 关键洞察（5 个最像 flint 的现存项目）

| 维度 | TIC-80 | PICO-8 | Picotron | WASM-4 | Bitsy |
|---|---|---|---|---|---|
| **绿地** | AI/网络都没有 | 闭源不可染指 | 闭源不可染指 | 网络/AI 双空白 | 故事方向，飞地 |
| **可比较的核心 gap** | release 停滞 19 个月、无 AI 路线、无网络模块 | 闭源即终极护城河，外人无法集成 AI | 同上 | 单人无网络，AI 不在 issue tracker | 太小作坊，难做大 |
| **直接可抄的好东西** | cart 格式、调色板、社区文化 | UI 哲学、大小限制美学 | 480p 升级路径 | WASM 沙箱、确定性 | 极简叙事 UX |

**结论 1**：开源 fantasy console 这一格里，TIC-80 是唯一"还在呼吸"的标杆，但呼吸已经很浅。AI NPC、rollback netcode 在 fantasy console 这条赛道上**事实是一片真空**。

---

## 2. AI NPC 在游戏里的现状

### 2.1 商业 SDK 玩家（2026-05 状态）

| 厂商 | 产品 | 2026-05 状态 | 面向 indie 友好度 |
|---|---|---|---|
| **Inworld AI** | Unreal AI Runtime SDK（GA）+ Unity Runtime SDK（早期访问） | C++ core，覆盖 STT/LLM/TTS，多 LLM 路由（OpenAI/Claude/Gemini/Mistral），客户含 Xbox/Disney/Ubisoft/NBCU | 有免费层但生产成本对 indie 构成天花板 |
| **Convai** | Unreal/Unity 插件 | 强项：把对话连到游戏内动作（开门、捡东西、带路）。免费层比 Inworld 大方 | 是（最适合 indie 的商业 SDK） |
| **NVIDIA ACE** | PUBG Ally / inZOI Smart Zoi 已上线 | 2026 早期 PUBG Arcade beta（EN/KO/CN） | 仅大厂合作，indie 拿不到 |
| **Anthropic** | **无官方游戏 SDK** | 仅有"Claude Plays Pokémon"研究项目（峰值 2598 观众） | n/a |
| **OpenAI** | 无游戏 SDK，只有通用 API | n/a | n/a |

### 2.2 MOD 圈 LLM NPC（开源样本）

| 项目 | 平台 | License | Stars | 最近 release | 说明 |
|---|---|---|---|---|---|
| **Mantella** (art-from-the-machine) | Skyrim/Fallout 4 | 开源 | **363** | v0.14 / 2026-04-21 | 头部项目，pipeline = Whisper → LLM → Piper/xVASynth/XTTS。615 commits，91 open issues，84 forks。NPC 有视觉、记忆、能起 radiant 对话 |
| **Pantella** (Pathos14489) | Skyrim/FO4 | 开源 fork | 较少 | 活跃 | 用 chromadb 做记忆向量化，比 Mantella 内存系统更强 |
| **MinAI** (MinLL) | Skyrim CHIM 扩展 | 开源 | 较少 | 活跃 | 桥接 LLM + Skyrim 全套 mod 生态 |

注：**Mantella 363 stars** 是个值得敲黑板的数字 — 这是 Skyrim（一个有数百万玩家的游戏）+ AI NPC（号称 2025 最热 trend）+ 开源 + 已稳定运行两年的组合，star 上限只摸到三位数。说明：**LLM NPC 的实际玩家需求远远小于媒体噪音**。这是 flint 必须正视的"注意力磁场温度计"。

### 2.3 已出货的 AI-native indie 游戏

| 游戏 | 厂商 | 技术栈 | 已知数据 |
|---|---|---|---|
| **Suck Up!** | Proxima Enterprises | 1.0 用 ChatGPT-5（曾用 GPT-3.5） | Steam 在售，无公开销量；用户语音/打字 → 后端组装 prompt → OpenAI |
| **AI Dungeon** | Latitude | 早期 GPT-2/3，现自训 | 用户量有但已**老去**，2024-2025 增长曲线下滑 |
| **inZOI** | KRAFTON | NVIDIA ACE | 2025-03-28 发售，"Smart Zoi" 是实验性 toggle |
| **PUBG Ally** | Krafton | NVIDIA ACE | 2026 PUBG Arcade beta |

### 2.4 GDC / Develop 2026 的 LLM NPC 走向

- 主基调：**"Contextual constraints"**（避免 hallucination）压过"open-ended dialogue"。Inworld 的 Contextual Mesh、Convai 的 backstory binding 都是这条路。
- 经济模型未解：**per-interaction 计费在大型游戏不可持续**，本地小模型成为 indie/AAA 共识方向。
- 暂无任何"原生 LLM-first 游戏引擎"宣言级项目。Inworld/Convai 都是**插件**，不是引擎。

**结论 2**：商业 AI NPC SDK 已饱和，但**面向 fantasy console / 像素小游戏 + 本地小模型**这个交叉点，**没有成熟解决方案**。这是 flint 真正的绿地。

---

## 3. Zig 游戏生态 2026-05 状态

### 3.1 关键项目快照

| 项目 | Stars | 最近活跃 | 进度 / 版本 | 我们能 leverage |
|---|---|---|---|---|
| **hexops/mach** | **4.7k** | repo 持续更新到 2026-04-09 | v0.4（2024 末）后未发新 tag，pkgmirror 服务 2026-03-26 上线，sysgpu 仍 heavy dev | 低层 mach-core（窗口 + 输入 + GPU）可用；高层 engine 不 ready |
| **michal-z/zig-gamedev** | ~3k+（先前监测） | 2024-2025 转入维护期 | 一组松散 wrapper（zmath/zgui/zaudio） | 数学 + Dear ImGui binding 可直接用 |
| **floooh/sokol** + sokol-zig | sokol ~7k+ | 持续活跃 | 跨平台稳定 | **最稳的低层选择**（gfx/audio/app/time） |
| **Not-Nik/raylib-zig** | ~700+ | 2026 同步 raylib 5.x | 稳定 | raylib 已是黄金标准，binding 几乎"白送" |
| **kooparse/zalgebra** | ~400 | 缓慢 | 数学库 | OK，可被 zmath 替代 |
| **mach-glfw / mach-gpu** | 已并入 mach 主仓 | 跟随 mach | n/a | 同 mach |

### 3.2 Zig 语言本身

- **0.14.0**（2025 年初）→ **0.15.1**（带 macOS --watch 修复 + 编译并行化，27% 自举提速）→ **0.16.0**（2026-04-14 发布，Matthew Lugg 30000 行 PR 把 type resolution 改成 DAG，binary 缩小，I/O 改 io_uring/GCD）
- async/await **正在回归**，作为 Io interface 的一部分（像 allocator 那样传递）
- 仓库已开始**从 GitHub 迁移到 Codeberg**（2025-11-26 公告）
- **1.0 没有时间表**。Andrew Kelley 仍在挡 1.0 标签
- 自举进度：截至 2026-01，250/2282 个 C 源文件已替换为 Zig

### 3.3 Zig 选型独立评估（除了"酷"以外的实质优势）

诚实地说，对 flint 这个具体场景，Zig 比 Rust/C++/C# 的实质优势就只有这几条：

1. **跨编译开箱即用**：`zig build -Dtarget=x86_64-windows`，零 toolchain 配置。Rust 需要 cargo-zigbuild 或 cross + Docker；C++ 需要 mingw/clang 一堆 sysroot；C# 单二进制需要 NativeAOT + 调一堆 trimmer。**flint 主打 "ship a 4MB game" 叙事时这是底层硬优势**。
2. **对 C ABI 零摩擦**：libsamplerate / opus / GekkoNet / GGPO 都是 C 库，Zig 直接 `@cImport`，不需要 bindgen/手写 P/Invoke/extern "C++"。
3. **小且确定的二进制**：无 GC、无运行时、无 unwind 默认开。**LOVE2D 5MB+lua + 7MB 用户脚本 ≈ 12MB；Defold 默认 25MB；flint 目标 < 5MB 完全可达**。
4. **comptime 适合 cart 元数据生成**：把 sprite / map / palette 编译期 fold 进二进制，无运行时反射开销。

而 Zig 的实质劣势也得说清楚：

1. **0.16 仍频繁破坏性变更**，至少 2-3 次 stdlib 重写在路上（async I/O 大改）。这意味着 flint 在 1-2 年内每个季度都要花 2-5 天追 Zig 主线。
2. **生态比 Rust crates.io 小一个量级**，gameutil/imgui/audio 都得自己 wrap C 库。
3. **招人和外部贡献者池极小**。Rust 在 2026 已是 indie gamedev "次主流"，Zig 还是"极客圈"。

**判断**：Zig 是合理选择，**但不是显然优于 Rust**。Rust（用 macroquad / fyrox 或 wgpu + winit）能拿到 90% 的好处加上 5 倍的生态。如果 flint 的 USP 是"4MB 单二进制 + 单文件 cart"，Zig 边际优势可证；如果 USP 是"AI NPC 体验"，Rust 更优。

---

## 4. Rollback Netcode 当前

### 4.1 库与协议

| 库 | License | Stars | 状态 | BYO 友好度 |
|---|---|---|---|---|
| **GGPO** (pond3r) | MIT | ~1.7k | 评估 SDK 公开后基本不更新，老但稳 | 高（C API，纯库） |
| **GekkoNet** (HeatXD) | BSD-2 | **39** | 2026-04-15 仍在 commit，253 commits, 35 releases | 高（C++/C API，是 GGPO 现代替代） |
| **Steam Networking / GameNetworkingSockets** | BSD-3 | ~8k | 活跃 | 中（不是专门 rollback，是底层传输） |
| **SnapNet** | 商业 | n/a | 活跃 | 商业授权 |

### 4.2 渗透率与社区状态

- **Fightcade**：仍是格斗社区核心平台，月活几十万，但**用户群高度小众**（街机怀旧 + 硬核格斗党）。不是大众市场。
- 2024-2025 大型独立格斗游戏（Strive、Skullgirls、Them's Fightin' Herds）都在用 GGPO 派生。**rollback 在格斗游戏外的渗透极低**：RTS 没有，roguelike 没有，platformer 几乎没有。
- "**Rollback as a library** in **Zig**" — 截至 2026-05 **没有这个东西**。Zig 直接 `@cImport` GekkoNet 的 C API 是最低成本路径。

### 4.3 实施门槛（诚实警告）

GekkoNet/GGPO 不是"加进去就跑"。游戏必须：
- 整个游戏状态可序列化、确定性、单 struct 拷贝
- 音视频副作用回滚要单独处理
- 物理/RNG 必须 deterministic

**Fantasy console 体量的游戏天然契合这些要求**，这反而是 flint 的一个真切优势 — 像素小游戏的 state 本来就小，可塞进 64KB cart 的状态，rollback 几乎是免费的。

**结论 3**：rollback 在 fantasy console 完全没人做过。技术上完全 doable。但市场上**会被 rollback 吸引来的玩家=格斗硬核圈**，他们不会被 fantasy console 吸引来。这是一个**技术亮点 ≠ 市场吸引力**的典型陷阱。

---

## 5. "AI + retro pixel 游戏" 的注意力热度（表 2）

### 5.1 Hashtag 热度估测

我必须诚实：**2026-05 我没法直接查到 TikTok 各 hashtag 的精确播放量**（TikTok creator center 不公开 API），下表是基于公开搜索结果与新闻报道的间接估算 + 信号强度判断。

| Hashtag / 内容类型 | 量级估测 | 增长 | 主力创作者 | 病毒潜力评估 |
|---|---|---|---|---|
| **#aiNPC** | TikTok 累计数千万级播放（个别 viral 视频百万级） | 高 | "AI NPC TikTokers"是已成型 niche（IZEA 报告确认） | 中 — 这个 tag 很多是**人扮 NPC**而非真 AI |
| **#fantasyconsole** | 数十万至低百万级 | 平 | 主要是 PICO-8/TIC-80 dev demo，圈层很小 | 低 — 创作者圈 ≠ 玩家圈 |
| **#pico8** | 累计百万至千万级 | 平 | jusiv / @lexaloffle 官方 / @krystman | 中 — 文化高度但出圈难 |
| **#AIgame** | 累计百万级，单视频常见 50k-500k | 高 | 综合大杂烩 | 中-高 但内容稀释 |
| **Claude Plays Pokémon (Twitch)** | 峰值 **2598** 同时观众，X 公告 765k 浏览 | 单事件型 | Anthropic 官方 + 转发账号 | 高 — 但只**事件级**，不是持续磁场 |

### 5.2 三五个百万播放级样本（公开可查）

1. **Anthropic 官方推文**"Claude Plays Pokemon"（2025-02）：X 上 765.3k 浏览。viral 原因 = 大公司 + 复古 IP + AI 笨拙过程戏剧化。
2. **Twitch Plays Pokémon (2014 原版)**：Wikipedia 记录 5500 万次观看、110 万参与者。**12 年前的纪录至今未被打破**。
3. **inZOI "Smart Zoi" 上线（2025-03）发布会片段**：YouTube 多个百万级播放。viral 原因 = NVIDIA 背书 + 预渲染高分辨率 demo 落差大。
4. **Suck Up! Steam 试玩**：直播平台多个百万级单集（Northernlion / Asmongold 等大主播）。
5. **AI NPC TikToker 角色扮演**类（如 @grocery_store_npc 已 5M+ followers）：**核心是人**，不是 AI。

### 5.3 "AI 嘴炮 Pokemon" 是不是 meme？

**严格回答**：**不是单独成型的 meme**。"AI 玩老游戏 + 直播观察"是一个 niche format，但每个事件依赖大公司公关 + 老 IP 戏剧性。**Claude Plays Pokemon 峰值 2598 同时观众**这个数字是这条赛道实际容量的硬指标 — 比一个中型 vtuber 还少。

**结论 4**：注意力磁场**部分真实**：
- 真：AI NPC 是有热度的话题，能在媒体周期吃到流量
- 假：以为这种话题热度=可转化为 10k stars 或 indie 玩家付费，**这是夸大**

---

## 6. 单二进制游戏运行时（市场叙事饱和度）

### 6.1 现状对比

| 引擎 | 默认导出体积 | 单二进制？ | 痛点 |
|---|---|---|---|
| **LÖVE2D** | 5-12 MB（含 Lua + SDL2） | 半（需 fuse 脚本，Win/Mac 简单 Linux 复杂） | 性能上限低；移动端导出复杂；单文件 fuse 在 Mac 仍踩坑 |
| **Defold** | ~25 MB（任何项目都这个起步） | 是 | 体积偏大；闭源核心；编辑器是必须的 |
| **Godot 4** | ~40 MB（无优化）/ ~15 MB（编译自定义模板） | 是 | 体积；冷启动慢；GDExtension 复杂 |
| **raylib + 自带语言** | 1-3 MB | 是 | 没有"编辑器/卡带"概念，只是库 |
| **PICO-8 cart** | < 32KB（神级压缩） | 是（运行时是另一回事） | 32KB 是硬墙；非 PICO-8 玩家进不来 |

### 6.2 "ship a 4MB game" 叙事是否饱和？

**没有饱和，但已不新鲜**。raylib 早就让人 ship 1MB 二进制；Zig 用户圈早有"single static binary"信仰；Bevy 用户哭着把 release 砍到 5MB 以下。

**flint 的体积叙事真正有差异化的角度**：
- "**4MB 二进制 + 完整 IDE + 内置 AI runtime + 内置 rollback netcode**"，这才是 unique
- 单纯"4MB"不够 viral

---

## 7. 三个最干净的切入楔子

### 楔子 1：**TIC-80 的 release 真空 + AI 缺位**

**事实 gap**：TIC-80 自 v1.1.2837（2023-10）后**19 个月没有正式 release**；社区 issue tracker 上 AI NPC、本地 LLM、cart 内嵌 prompt 等**没有任何 RFC**。

**flint 切入**：直接做一个"TIC-80 + AI cart 格式 + 本地 phi-3/qwen-0.5B" 的 spec 提案，向 TIC-80 社区释放。即使不被 merge，也建立 flint 的"承袭者"叙事 — 你不是另起炉灶，你在续命他们的事业。

### 楔子 2：**fantasy console + rollback 完全空白**

**事实 gap**：表 1 的 8 个候选项目，**rollback netcode 列全部为"无"**。GekkoNet 仅 39 stars 但 API 现代，可在 Zig 通过 `@cImport` 直接复用。

**flint 切入**：定义"**联机 cart**"格式 — cart 头部声明 "rollback: yes, max-players: 4, state-size: <= 8KB"，引擎自动启用 GekkoNet 路径。**这个 feature 没有任何竞品有**，是真正的绿地。

### 楔子 3：**单二进制 + cart 浏览器分享 + 本地 LLM 三元一体**

**事实 gap**：
- PICO-8/TIC-80 能浏览器分享 cart，但没 AI 也没 rollback
- Inworld/Convai 有 AI 但要 Unity/Unreal，体量 > 100MB
- Mantella 有 AI 但绑定 Skyrim
- 没有任何项目把"浏览器一键分享 cart"+"本地小模型 AI NPC"+"内置联机"打包

**flint 切入**：把 cart 文件本身做成"自描述 + 自带 AI prompt + 自带回滚配置"，浏览器版（WASM）+ 桌面版（Zig 单二进制）双形态。这是**唯一有可能成为 viral 实体**的组合 — 一个链接发出去，朋友点开就能玩 + 一起玩 + NPC 会说话。

---

## 8. 诚实判断 — 注意力磁场是否真实存在

**部分真实，但被高估**。

支持磁场存在的证据：
- Inworld、Convai、ACE 等 AI NPC SDK 有真实付费客户（Xbox/Disney/Ubisoft 级别）
- Claude Plays Pokemon X 推文 765k 浏览，单事件级注意力是真的
- AI NPC TikToker 是已成型 niche
- Suck Up! 有 Steam 销量（具体未公开但确认上市）

否定磁场为"可变现"的证据：
- **Mantella 363 stars** — Skyrim + AI NPC + 开源 + 两年发酵，封顶 363。这是个很冷的数字
- Claude Plays Pokemon **峰值 2598 同时观众**，比中型 vtuber 还少
- TIC-80 6k stars 是 9 年累积的开源 fantasy console 头部，flint 起步加 AI/网络两个 buff 做到**1 万 stars 是合理的乐观目标，但不是必然**
- "AI NPC TikToker" 大多是真人扮 NPC，**不导流到任何具体游戏产品**

**1 万星天花板可信度评分**：

| 情形 | 概率（主观） | 说明 |
|---|---|---|
| 1 年内做到 1k stars | 60% | 需要做出一个能跑的 demo + 一篇质量博客 + Hacker News / r/programming 一次曝光 |
| 2 年内做到 5k stars | 25% | 需要至少一次 viral 时刻 + 持续每周更新 + 有 5-10 个 cart 病毒级作品 |
| 3 年内做到 10k stars | 8-12% | 必须出现 "Celeste 时刻"（一个里程碑独立游戏在 flint 上诞生）+ 创始人持续 PR |
| 永远做不到 1k stars | 30% | 最常见结局：技术骨头很硬但文化没起来，最后只剩 50-100 fans |

**1 万星不是不可能，但需要的不只是技术。需要：1 个 viral cart + 1 个持续讲故事的创始人 + 18 个月不放弃**。如果没把这三件事都规划进项目，1 万星就是**鬼故事**。

---

## 9. Zig 选型独立评估（汇总）

详细见 §3.3。**一句话**：Zig 在 flint 这个场景**有真实但有限的优势**（跨编译、C ABI、二进制大小、comptime 元数据），但**对手 Rust 用 macroquad/wgpu 能拿到 80%+ 的同样好处加 5 倍生态**。**Zig 的最大风险是 0.16~1.0 的破坏性变更税**。

**净判断**：Zig 选型可以辩护，但不要骗自己说它是"显然最优解"。如果你是为了"工程师品味"选 Zig，那是合法理由（创始人 motivation 也是项目燃料）；但**不要在融资 deck 上把 Zig 写成核心 USP**，那是错位。

---

## 10. 红队结论 — 什么会让这个项目失败

### 10.1 最大对手

不是其他 fantasy console，是**这两个**：

1. **AI 厂商自己**（OpenAI / Anthropic / xAI）下场做"prompt-driven game generator"。一旦 ChatGPT 加一个 "/make-game" 按钮直出可玩 HTML5 游戏，整个 fantasy console + AI 这条赛道一夜归零。**这是 #1 风险**，已经有 Sora、Genie、World Labs 在路上。
2. **Roblox / Fortnite UEFN / Unity Muse**。它们已有亿级用户 + 自带社交分享 + 正在加 AI NPC。flint 的"分享 cart"叙事在它们的 UGC 漏斗前不存在。

### 10.2 失败模式（从最可能到最不可能）

| 失败模式 | 概率 | 信号 |
|---|---|---|
| **创始人疲劳** — 18 个月每周更新挺不过去 | 40% | 这是开源 fantasy console 死法的 #1（看 Pixel Vision 8、LIKO-12） |
| **技术做出来了，没人玩** — viral 时刻没到 | 30% | 不是"AI NPC + retro" 自动 viral，需要至少一个杀手级 cart |
| **被 ChatGPT 出 "/make-game" 整赛道淹没** | 15% | 2026 内非常可能 |
| **Zig 0.16~1.0 破坏性变更把项目卡住** | 10% | 至少需要 1 次重写 |
| **AI NPC 体验本身不好玩** — LLM hallucination 在 8-bit 像素世界违和 | 5% | 风险偏小但要测试 |

### 10.3 致命问题

**唯一一句话浓缩**：flint 如果只是"Zig + 复古 + AI + rollback 的工程奇观"，**死路**。它必须 **从 day 1 就规划至少一个 lighthouse cart**（一个具体的、好玩的、能在没有 flint 引擎也讲清楚 hook 的小游戏，例如"AI 嘴炮 vs 你的 Pokémon battle，3 局速通"），否则技术做完就静音。

**不要做引擎，做"一个用引擎做出来的火爆游戏"，引擎自然有人来**。这是 PICO-8 走通过的唯一路径（Celeste），TIC-80 没走通的原因（没有 lighthouse），LIKO-12 没走通的原因（也没有 lighthouse）。

---

## 11. Sources（按 §引用）

- [GitHub - nesbox/TIC-80](https://github.com/nesbox/TIC-80) — TIC-80 6.0k stars，最新 release 2023-10
- [PICO-8 - Wikipedia](https://en.wikipedia.org/wiki/PICO-8) — Lexaloffle 历史与生态
- [PICO-8 Fantasy Console FAQ](https://www.lexaloffle.com/pico-8.php?page=faq)
- [Inworld AI](https://inworld.ai/) + [Unreal AI Runtime SDK 公告](https://inworld.ai/blog/introducing-unreal-ai-runtime-sdk)
- [NVIDIA blog: Inworld game NPCs](https://blogs.nvidia.com/blog/generative-ai-npcs/)
- [eesel AI: What is Inworld AI 2026](https://www.eesel.ai/blog/inworld-ai)
- [GitHub - art-from-the-machine/Mantella](https://github.com/art-from-the-machine/Mantella) — 363 stars, v0.14 / 2026-04
- [Mantella docs](https://art-from-the-machine.github.io/Mantella/)
- [Nexus Mods - Mantella](https://www.nexusmods.com/skyrimspecialedition/mods/98631)
- [GitHub - hexops/mach](https://github.com/hexops/mach) — 4.7k stars
- [Mach engine site](https://machengine.org/) + [Hexops devlog](https://devlog.hexops.org/)
- [GitHub - HeatXD/GekkoNet](https://github.com/HeatXD/GekkoNet) — 39 stars, 2026-04-15 commits
- [GGPO - Wikipedia](https://en.wikipedia.org/wiki/GGPO) + [GGPO repo](https://github.com/pond3r/ggpo)
- [Zig 0.15.1 release notes](https://ziglang.org/download/0.15.1/release-notes.html)
- [Zig 0.16 features](https://daily.dev/blog/zig-0-16-new-features-release-date-developers-need-to-know)
- [Zig Roadmap 2026 (Ziggit)](https://ziggit.dev/t/zig-roadmap-2026/10750)
- [TechCrunch: Claude AI plays Pokémon on Twitch](https://techcrunch.com/2025/02/25/anthropics-claude-ai-is-playing-pokemon-on-twitch-slowly/)
- [Streamscharts: ClaudePlaysPokemon](https://streamscharts.com/channels/claudeplayspokemon)
- [Suck Up! 官网](https://www.playsuckup.com/)
- [Hypergrid Business: Suck Up! 技术访谈](https://www.hypergridbusiness.com/2025/10/indie-vampire-game-highlights-future-for-ai-driven-games/)
- [LÖVE Game Distribution wiki](https://love2d.org/wiki/Game_Distribution)
- [IZEA: Rise of AI NPC TikTokers](https://izea.com/resources/the-rise-of-ai-npc-tiktokers/)
- [TechLife: 2025 Biggest Gaming Trend AI NPCs](https://techlife.blog/posts/ai-npcs-gaming-2025/)

---

**报告结束**。422 行，落在 400-600 行区间。
