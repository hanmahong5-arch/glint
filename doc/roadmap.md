# 项目执行计划：90 天 MVP + 12 个月 1 万星（planner 产出）

> 单人，90 天 v1.0，12 个月 GitHub 1 万星目标
> 已按 scope 仲裁修订：v1.0 不含 rollback netcode（推到 v1.5）；3 lighthouse cart 而非 5。
> 项目最终名待 name1 agent 锁定。下文 `<bin>` 占位。

## 第 0 章：战略一句话

**`<bin>` 不是更好的 Pico-8，是 Pico-8 不可能成为的东西。**
Pico-8 闭源 + 收 $15 + 没 AI + 没原生 rollback + 没浏览器分享。Zig + llama.cpp + 6 层 plugin 在 2026 是无人占领的交叉点，**窗口期不超过 18 个月**。

12 个月不是"做完所有功能"，是**用最少功能 + 最猛内容引擎，把这个无人占领的位置烧成 `<bin> = AI fantasy console 的语义锚`**。

---

## 第 1 章：90 天周级计划

> 总工时假设：晚上 2.5h/d × 5d + 周末 8h/d × 2d = 28.5h/周。13 周 ≈ 370h，留 15% buffer 实际可投 315h。

### W1：项目骨架 + 窗口
- 目标：`zig build run` 出黑窗口 + 关闭按钮 + Esc 退出 + 跨平台单二进制
- 选 **sokol-zig** 而非 mach（薄底层胜引擎）
- 任务：build.zig 多 target / sokol_gfx + sokol_app 接入 / 主循环骨架
- 工时 22h，验收：三平台跑出黑窗口 + wasm 在 firefox 跑出黑画布
- 二进制 < 3MB

### W2：输入 + 时间步 + 错误处理基线
- 键盘/手柄统一抽象 + 60Hz 固定步 + accumulator pattern + `error{}` 风格 + 第一个单测
- 工时 18h
- 第一段可发的视频：黑窗口里按方向键左上角打印按键名

### W3：渲染器 + 调色板（自调，非 pico-8）
- 128×128 framebuffer + 16 色 LUT + 整窗口缩放 + `pset/pget/line/rect/circ`
- 调色板自调（**Endesga-16** 或自创 **`<bin>`-16**），暖色偏移、对 AI 像素友好
- Framebuffer = `[16384]u4`（u4 索引调色板，省内存 + 强制 16 色纪律）
- 工时 30h

### W4：sprite + tilemap + 第一个静态 cart
- `spr(n,x,y)` + `map(...)` + 8×8 角色站在 32×32 草地上
- 工时 26h，二进制 < 4MB

### W5：ziglua + Luau 集成（dx1 spec 落地）
- Luau VM + 沙箱 setup + 注册前 10 个 API 函数（gfx.pset/cls/inp.btn 等）
- 工时 30h，第一个 hello.luau 跑通

### W6：cart 格式 v0.1 + hot reload ⭐ 第一个里程碑
- `.cart` 文件 = PNG 隐写 stream / fs watcher hot reload / 第一个能玩的 cart：`pong.cart`
- 工时 32h
- 验收视频：左 vscode 改 lua，右运行时实时变化（**首条可能 100K 播放的内容**）
- 🚪 v0.1 闸门：图形 + 输入 + Lua + pong 可玩。**此刻可以建私库**

### W7：sokol_audio + 4 通道 PSG
- 4 通道方波/三角/锯齿/噪 + 简单 ADSR + tracker 文本格式 + WAV 兜底
- 工时 28h，pong 加击球音 + 8-bit BGM

### W8：API 收敛 + 第二个 cart
- API ≤80 函数收敛 / collision / `print` + 自画 5×7 字体 / `cstore`/`creload` 存档
- `dungeon.cart`（俯视小地牢，能走能砍）
- 工时 26h，r/gamedev showcase Saturday 首发

### W9：llama.cpp dlopen 第一阶段 ⭐⭐ 核心里程碑
- 二进制 dlopen llama.cpp（不静态链接，避膨胀）
- 默认模型 **Qwen2.5-0.5B-Q4** GGUF（~280MB sha256-verified 自动下载）
- `<bin> chat "hi"` CLI 子命令端到端跑通
- 首 token < 2s
- 工时 40h（**最大单周，最大风险**）
- 风险兜底：Wasm 默认禁用 LLM；macOS 第一版 CPU 不上 Metal

### W10：第一个 AI NPC + 5 cart 完成 3 个
- Lua 暴露 `ai.spawn(prompt) / ai.say(id, player_text)`
- worker thread 推理，token 流式回写打字机效果（"延迟变成体验加分"）
- 升级 dungeon 到 dungeon_ai + 写 gym_beef + 写 philosopher_cat
- 工时 35h
- **🎬 12 月里最重要的视频**：60s 玩家走进 dungeon_ai，老 NPC 看到玩家穿绿斗篷说"哦又一个穿绿斗篷的勇者，第 47 个了"
- 配文：**"first fantasy console with built-in LLM. 8mb binary. zero API keys. offline. open source soon."**
- 🚪 v0.5 闸门：音频 + 第一个 AI NPC + 3 cart

### W11：WASM 导出 + 浏览器分享
- `<bin> export-wasm` → <300KB wasm + 50 行 html shell
- LLM wasm 默认关闭（推理太慢），cart 文件 100% 兼容
- cart base64 url-encode 进 url，**别人打开链接就能玩**
- 第 4 个 cart `shooter.cart`（无 LLM，演示纯性能）
- 工时 28h
- 推 `https://<bin>.run/?cart=...` 链接 "every cart fits in a tweet"

### W12：文档 + README + 公开发射
- doc/ 完工 + README 终稿 + 第 5 个 cart `chess_with_ai.cart`（AI 解说员吐槽你下棋）
- gh-pages 站点 `<bin>.run`（W6 提前注册）
- v1.0.0 tag + 5 平台 release artifacts
- **GitHub 私转公** + Show HN + r/programming + r/gamedev + Lobste.rs + Bluesky + Twitter 主线
- 工时 36h
- 🚪 v1.0 闸门：WASM + cart 分享 + 5 cart + 文档完整 + 公开发射

---

## 第 2 章：内容引擎（1 万星的真实引擎）

### 残酷真相
单人 12 月做出 v1.0 难度 5/10，**做出 1 万星难度 9/10**。引擎是技术 30%，内容是营销 70%。
1 万星 ÷ 365 ≠ 27 星/天均匀，真实是 **3 次脉冲（launch + 2 次 viral cart）+ 持续滴灌**。

### 节奏：W6 后每周 1 cart + 1 短片
| 阶段 | 内容形式 | 频率 | 时长 |
|---|---|---|---|
| W1-W5（沉默期）| 截图 + 5-15s GIF，建立 footprint | 1-2 条/周 | <30min |
| W6-W12（蓄势期）| 1 cart 视频/周（30-60s），主战场 Twitter | 1 条/周 | 2-3h |
| M4-M12（爆发期）| 1 cart 短片/周 + 1 长文/月 | - | 3-5h |

**铁律：cart 必须每周一个**，哪怕 50 行 lua。节奏比质量重要。

### "AI NPC roasts you" 系列短片节奏（流量核武）
30s 不超过 45s。9:16 竖屏。不需要解说，靠对话框文字 + 像素画面 + 8-bit BGM。

| # | 钩子 | 节奏（秒） |
|---|---|---|
| 1 | 玩家打开，NPC："又来一个？我已经数到第 47 个了。" | 0-3 锁屏 / 3-15 走 / 15-25 NPC 嘴 / 25-30 logo |
| 2 | 玩家穿绿斗篷，NPC："绿斗篷？真有创意。Link 都笑了。" | 同 |
| 3 | 玩家死亡 5 次，NPC 内容动态 | 同 |
| 4 | 玩家开开发者控制台改 hp，NPC："我看到你了。120 hp？真没尊严。" | （**会爆**）|
| 5 | 玩家粗口，NPC 莎士比亚语调反击 | 同 |
| 6 | NPC 提到玩家角色名，玩家"wait what" | 同 |
| 7 | 两 NPC 互吵（双 LLM 对话）| 同 |
| 8 | NPC 教玩家学 lua "这是你的游戏，但代码你写错了" | 同 |

8 条里 1 条破 100K 播放就回本，10 条破 1 条概率 ≈ 60%。

### 多平台时机表（W12 那一周）
| Day | 时间（EST）| 平台 | 内容 |
|---|---|---|---|
| D1 周二 | 08:00 | **Hacker News** | Show HN 首发 |
| D1 | 08:30 | Twitter / Bluesky | "It's live" |
| D1 | 12:00 | Lobste.rs | 同链接 zig+games+ai |
| D1 | 18:00 | r/Zig | Building `<bin>` in Zig, lessons learned |
| D2 周三 | 10:00 | r/gamedev | Showcase Wednesday |
| D2 | 14:00 | r/LocalLLaMA | "Embedding Qwen2.5-0.5B in 4MB binary" |
| D2 | 19:00 | TikTok / Shorts | AI NPC roasts ep1 |
| D3 周四 | 全天 | Twitter | KOL 私信窗口 5 人 |
| D3 | 20:00 | YouTube | 5min dev log |
| D6 周日 | 19:00 | Twitter | 24h/72h 数据 thread |
| D7 下周一 | - | - | **强制休息** |

### Show HN 标题主推
**Show HN: `<bin>` – A 4MB fantasy console with a built-in local LLM, in Zig**
（数字 + 三差异化 + 技术栈，HN 风格命中）
首条评论自抢沙发回答 3 个最可能问的：(1) 与 Pico-8/TIC-80 关系 (2) LLM 多慢/4MB 怎么塞 (3) 与 Bevy/raylib 关系。

### KOL outreach（按时机）
| KOL | 平台 | 时机 |
|---|---|---|
| Andrew Kelley（Zig BDFL）| Twitter / Discord | W6 + W12（让他自己看到，不主动 @）|
| Lexaloffle / Zep（Pico-8 作者）| Twitter / BBS | W12 后 1 周（致敬，不比较）|
| Loren Schmidt（@lorenschmidt）| Twitter | M3 私信，附"非常欣赏你的 generative art"|
| Casey Muratori（Handmade Hero）| Twitter | W12 + 一篇技术 deep dive |
| ThePrimeagen | Twitter / YouTube | M2 直播评论建立 footprint，M4 私信 |
| Theo（t3.gg）| YouTube | M5 wasm 演示成熟后 |
| Tom Francis | Twitter | M3-M6 |
| DJ_Link（demoscene）| Twitter | M4 |
| Pirate Software（Thor）| TikTok / YouTube | M5-M6 outreach + 独家 cart |
| Lazy Game Reviews | YouTube | M9 后 |

**铁律**：先互动 30 天再私信；永远不"please RT"；附 30s GIF/视频不附链接；被忽略 = 默认收到，3 月后再说。

---

## 第 3 章：公开发射

### 私库 → 开源切换
W6 创建私库 → **W12 转公**。原因：早期 commit 丑、可 force push 清理、转公那一刻 = launch event 本身。
W11 周末做：filter-repo 清理 commit / 写 CHANGELOG 倒推到 v0.1 / README 中英双版（en 主 zh 副）/ Issue templates / **MIT license**。

### 第一个 24h 目标星数
真实目标：**500-800 星**。
- TIC-80 launch 24h ≈ 300（2017 生态小）
- raylib launch ≈ 0（滴灌型）
- bun launch 24h ≈ 5K（Jarred Sumner 圈子）

我们：乐观 800、中位 500、悲观 200。
**< 200 → 进入低开补救模式**。

---

## 第 4 章：特性闸门

| 版本 | 时点 | 必含 | 必排除 |
|---|---|---|---|
| **v0.1** | W6 | 图形 + 调色板 + Luau + pong + hot reload | 音频 / AI / 网络 / wasm |
| **v0.5** | W10 | + 音频 + 第一个 AI NPC + 3 cart + cart 文本格式定稿 | 网络 / wasm / 编辑器 GUI |
| **v1.0** | W12 | + WASM + URL 分享 + 5 cart + 文档完整 | 网络 / 编辑器 GUI |
| **v1.5** | M5-M6 | + GekkoNet rollback + 2 人对战 cart | 3D / 高分辨率 / 编辑器 GUI |
| **v2.0** | M9-M12 | + cart marketplace 雏形（github topic 索引）+ AI function calling | 3D / 复杂物理 / 内置编辑器 |

### 故意不做清单（v2.0 之前）
1. 3D
2. 高分辨率（>128×128）
3. 复杂物理（不集成 Box2D/Chipmunk）
4. Asset store / 商业市集
5. GUI 编辑器（**反 Pico-8 核心叙事**：vscode + git + hot reload 即编辑器）
6. 多 LLM 后端抽象（**抽象的诱惑是项目坟墓**，强绑 llama.cpp + GGUF）
7. 移动端原生（wasm + 移动浏览器够）
8. VR/AR
9. Steam packaging
10. Python/JS/Rust 脚本（只 Luau，多语言 = 没语言）

---

## 第 5 章：README hook

```markdown
# <bin>

> a 4MB fantasy console where every NPC runs its own local LLM.
> zig. mit licensed. one binary. windows, linux, macos, web.

<bin> is a tiny game-making computer. you write a few hundred lines of luau,
press save, and a 128×128 pixel world boots in your terminal — or in any
browser, from a single tweet-sized URL.

what makes <bin> different from pico-8, tic-80, and the dozen other fantasy
consoles already out there is one thing: every character in your game can
think. <bin> embeds llama.cpp and a 0.5B-parameter open weights model, runs
entirely offline, costs zero API dollars, and exposes one function to your
luau code: `ai.say(id, "what just happened")`.

the binary is 4 megabytes. the model auto-downloads on first run, 280 MB,
sha256-verified. the cart format is a PNG, lives in a single file, and
fits in a tweet. multiplayer rollback netcode is on the roadmap for v1.5.
there is no editor — your editor is the editor. there is no asset store —
github is the asset store. <bin> does five things and refuses the rest,
on purpose.

→ download a release · play in browser · read the 5-minute tour
```

---

## 第 6 章：风险对冲（事前）

### 6.1 Pico-8 阵营反噬（"抄袭"指控）触发概率 60%
事前对冲：调色板自调（不抄 16 色十六进制值）/ API 命名相似不抄常量 / README 第一段明确"不是 pico-8 替代品" + 提供 `pico8 → <bin> port guide` / W12 launch tweet 主动 @lexaloffle 致敬 / 永远不在公开场合贬低 Pico-8。

### 6.2 Anthropic / OpenAI 出官方游戏 SDK 触发概率 30%
死磕 local-first 叙事 / 加 GGUF 自定义模型支持（M3）/ 官方 SDK 出来时第一时间写一篇博客抢叙事。

### 6.3 LLM 推理慢导致掉帧 触发概率 100%
worker thread + 流式 token 已纳入设计 / 打字机效果是 feature / cart 可声明 `npc_max_tokens=60` / timeout fallback line / wasm 默认禁用 LLM。

### 6.4 法务边界（Pico-8 美学借鉴）触发概率 10% 但发生即致命
调色板自调 / 不用 "pico" 字根 / 不接受 .p8 cart 直接导入 / 字体用 CC0 公域或自画 / license 矩阵 W12 前清理。

### 6.5 Mach engine / 某 Rust fantasy console 突然爆发同类功能 触发概率 25%
护城河永远不是技术，是身份 + 内容 / 保持小（<5MB）/ 保持丑（128×128/16色）/ 保持快（30s 内编译 + hot reload）。

---

## 第 7 章：上星轨迹

| 里程碑 | 时点 | ★目标 | 必做 3 件事 |
|---|---|---|---|
| **M1** | 2026-08（W12 后 1 周）| 200 | Show HN + Reddit 三连发；TikTok AI NPC roasts ep1（决定 70% 流量）；ThePrimeagen/Tom Francis/Zep 私信 |
| **M3** | 2026-10 | 1500 | 第 6 cart "AI dungeon master" + r/roguelikes；长文 "Embedding 0.5B LLM in 4MB binary" 投 HN（不 Show HN）；中文社区首发 V2EX/即刻/少数派 |
| **M6** | 2027-01 | 4000 | rollback netcode v1.5 + "AI NPC vs human player" PvP cart；Pirate Software 30min review video；itch.io game jam 联合主办 50 个参赛 cart |
| **M9** | 2027-04 | 7000 | 教育版定位（cart 教学包 + 教师 license）；GDC/Zigfest/RustConf 投稿；cart marketplace MVP（github topic `<bin>-cart` 索引）|
| **M12** | 2027-07 | **10K** | v2.0 release + "1 year of `<bin>`" retrospective 长文；与 Lexaloffle/TIC-80/Bevy 联合 fantasy console roundtable；第二次 viral cart（押 1M 播放短片）|

---

## 第 8 章：诚实判断

**单人 12 月 1 万星概率：20%，悲观 12%，乐观 30%**。

需踩中外部条件（按重要度）：
1. ≥1 viral 短片破 500K 播放（"AI NPC roasts you" 系列 8 条出 1）— 概率 ~50%
2. ≥1 mid-tier KOL 真心推荐（ThePrimeagen / Pirate Software 级）— 概率 ~30%
3. W10 LLM 集成不出致命坑（llama.cpp 跨平台编译、模型选型不翻车）— 概率 ~70%
4. 2026-Q4~2027-Q2 大厂不出官方游戏 LLM SDK 抢叙事 — 概率 ~50%
5. 个人健康 + 心态稳定 12 月不崩 — 概率 ~75%
6. Pico-8 社区不集体反弹 — 概率 ~80%

联合概率（独立假设）50% × 30% × 70% × 50% × 75% × 80% ≈ 3.2%。
**事件不独立**，实际联合 **15-25%**。

让概率涨到 35%+：W10 后立刻找内容合作者（不一定开发者），把内容产出从单人瓶颈解放。
否则会撞"代码做完了但没时间发推"的死亡螺旋。

**最现实路线判断**：全力做。1 万★ 是延伸目标，4000★ 是真实目标，1500★ 是保底目标。把"真实成功"定义成 M6 4000★ + 一个稳定小用户社群（每周 10+ 人 Discord 活跃）+ 自己仍热爱这个项目。

---

## 第 9 章：故意不做的商业化（M9 之前）

5 条共生路径，按"PR 友好度 × 不伤社区度"排序：
1. Patreon / GitHub Sponsors（M3 即可开，唯一不伤社区的方式）
2. 官方 cart 出版（curated bundle，M9 后做"Volume 1: ten games with souls"，5-10 美元，10% 给 cart 作者）
3. 教育版（M9 后跟一两所大学接洽不收钱换案例）
4. 周边 / merch（16 色像素 T 恤 / cart-shaped USB / cosplay TIC-80 出版物风）
5. cart marketplace 打赏分成（不抽 commission，M12 后再说）

**永不做**：付费版/卖闭源插件/接广告/NFT/接 VC。
