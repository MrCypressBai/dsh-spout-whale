<div align="center">

<img src="docs/images/hero.png" alt="SpoutWhale 浮在 macOS 桌面上，头顶弹出 DSH 运行状态气泡" width="620">

# 🐳 SpoutWhale

**一只住在 macOS 桌面上的喷水鲸鱼。**

透明 · 置顶 · 可拖动 · 88 帧动画 · 16 个注视方向 · 实时显示 DeepSeek Harness 运行状态

![platform](https://img.shields.io/badge/platform-macOS%2015%2B-1f6feb?style=flat-square)
![swift](https://img.shields.io/badge/Swift-AppKit-f05138?style=flat-square&logo=swift&logoColor=white)
![deps](https://img.shields.io/badge/dependencies-none-2ea44f?style=flat-square)
![size](https://img.shields.io/badge/App-1.5%20MB-2ea44f?style=flat-square)
![license](https://img.shields.io/badge/license-MIT-blue?style=flat-square)

</div>

---

## 这是什么

一个原生 macOS 桌宠：一只 DeepSeek 风格的蓝鲸浮在桌面上摆尾、喷水、游动，鼠标经过时会**转头看向光标**。它还会在旁边弹出一个状态气泡，**实时报告 DeepSeek Harness 正在干什么**——思考中、执行工具（带真实耗时）、等你回答、还是出错了。

没有 Electron，没有运行时依赖，App 本体 1.5 MB。

> 它最初是 DSH Web GUI 里的一个网页宠物。这个仓库是把它改造成**独立桌面程序**的结果。

---

## 演示

<img src="docs/images/actions.gif" alt="11 组动作演示" width="300">

从左到右依次是：**空闲 → 工作中（摆尾+喷水）→ 挥手 → 跳跃 → 完成待查看 → 等待用户 → 失败 → 16 个注视方向 → 回到空闲**。帧时长与 Codex 图集协议一致。

---

## 特性

| 特性 | 说明 |
| --- | --- |
| **88 帧动画** | 8 列 × 11 行图集，11 组动作，每组帧数/帧时长严格对齐 Codex 图集协议 |
| **16 方向注视** | 光标在 28pt 死区外时，鲸鱼转头看向光标，按 22.5° 分 16 档（000° 在正上方） |
| **真·透明 + 置顶** | `NSWindow` 无边框 + `isOpaque=false` + `.floating`，跨桌面（`canJoinAllSpaces`）常驻 |
| **自主行为** | 空闲时会随机游动、挥手、跳跃；自己会撞到屏幕边缘停下 |
| **状态气泡** | 零侵入读取 DSH 会话投影，把 Harness 的实时状态映射成文案 + 姿态 |
| **单实例守卫** | 怎么启动都不会开出第二只鲸鱼 |
| **不碰用户配置** | 位置/大小存 `UserDefaults`；自测模式走独立域，跑测试不会改你的设置 |
| **状态气泡不挡点击** | 气泡窗口 `ignoresMouseEvents = true`，永远不抢你的鼠标 |

---

## 快速开始

### 1. 构建

```bash
git clone https://github.com/MrCypressBai/spout-whale.git
cd spout-whale
sh desktop/build.sh ./SpoutWhale.app
```

> 需要一个可用的 Swift 工具链。`build.sh` 里写死了本机验证过的组合（Xcode 自带 `swiftc` + `MacOSX15.5.sdk`）——见 [从源码重建](#从源码重建)。

### 2. 运行

```bash
sh scripts/spoutwhale-ctl.sh start     # start | stop | restart | status
```

或者直接双击 `SpoutWhale.app`。

### 3. 装到 `~/Applications`（可选）

```bash
sh scripts/install.sh "$HOME/Applications"               # 只安装
sh scripts/install.sh "$HOME/Applications" --autostart   # 顺便开机自启（LaunchAgent）
```

**撞到过并已修掉的坑**：

- **单实例**。`open` 靠 LaunchServices 天然去重，但**直接执行二进制**（LaunchAgent 就是这条路）会开出多个实例——两只鲸鱼各记一份位置、互相覆盖气泡。现在 App 自己按 bundle id 探测并退出（`--force` 可强行再开）。
- **测完别把你的设置改了**。`--drivetest` 会真拖窗口、真遍历大小菜单、并且断言"位置已落盘"。所以自测模式把 `UserDefaults` 重定向到独立域 `ai.micheng.spoutwhale.test`，实测跑完真实域**仍然不存在**。

---

## DSH 运行状态气泡

<img src="docs/images/bubble.png" alt="状态气泡显示：执行中… 7s / 请先读取并遵循宠物创建 Skill · 319K tok" width="620">

**零侵入**：不改 DSH、不装插件、不重启。直接读 DSH 自己写在磁盘上的**会话投影缓存**：

```
~/.dsh/storages/session_projcache_archive_manager_v2/sessions/session_*.json
~/.dsh/storages/session_projcache/sessions/session-*.json
```

每 0.7 秒扫一次，取 mtime 最新的会话，从 `record.rows.*.val` 推导状态：

| DSH 字段 | 判定 | 气泡标题 | 宠物姿态 |
| --- | --- | --- | --- |
| `userQuestions.questions.active` 非空 | 在等你 | 等你回答 N 个问题 | 等待用户（行 6） |
| `llmRetry` 非空 / `goal.failure` | 异常 | 重试中…(N) / 出错了 | 失败（行 5） |
| `sessionStats.pendingCalls` 非空 | 工具执行中 | **执行中… Ns** | 工作中（行 7） |
| `openStep.firstTokenTime` 为空 | 等首 token | 思考中… | 工作中（行 7） |
| 有 `openStep` 或 `openTurnStartSeq` | 生成中 | 生成中… | 工作中（行 7） |
| `openTurnStartSeq` 为空 | 空闲 | 空闲中 → 收起气泡 | 先播一次 review（行 8）再回空闲 |

副行显示 **会话标题 · 待办 完成/总数 · 已解码 token**。标题里的秒数是**真实工具耗时**（来自 `pendingCalls` 的起始时间戳），不是估算。

### 陈旧状态怎么办

投影里的行值**只在变化时才落盘**，所以"文件旧"不等于"状态旧"——一次 20 分钟的构建，跑完前文件一个字都不会动。但反过来，如果 DSH 被杀或崩在工具执行中途，文件就永远停在最后一刻，`pendingCalls` 永远非空，气泡会一直挂着「执行中… 3600s」。所以有两道闸：

1. **宿主在不在**（硬闸，精确）：`NSRunningApplication` 按 bundle id 查 DSH 进程，没在跑就一律当空闲。
2. **文件新鲜度**（软闸，兜底）：投影文件超过 **30 分钟**没被写过也算空闲。这个界是有意的折中：明显大于任何合理单步，又远小于"永远卡住"。

> **依赖披露**：这条通路读的是 dsh 插件 `@michengai/dsh-archive-manager` 写出的会话投影。该插件若被卸载，气泡会自动静默（宠物退回纯自主行为），不报错、不崩溃。
>
> 不想用这个功能？右键菜单里关掉「状态气泡」即可。

---

## 它是怎么做的

### ① 图集：不是让 AI 画 88 张图

<img src="docs/images/atlas.png" alt="8 列 11 行图集，逐行标注动作" width="560">

Codex 宠物协议要求 **1536×2288 的 8 列 11 行图集**（每格 192×208，`spriteVersionNumber: 2`）。最大的难点是**帧间角色一致性**——而 AI 生图最不擅长的恰恰就是这个。

所以这里的路线是：**一张参考图 + 确定性 2D 变形**。

```
参考图 (474×474)
   │  tools/sprite.mjs    抠图 · 去白边 · 连通域清理 · 反预乘颜色
   ▼
sprite.png (474×349 RGBA)
   │  tools/render.mjs    平滑位移场反向映射 + 预乘双线性 + 2×2 超采样
   │  tools/actions.mjs   11 组动作参数（弯曲/鳍/尾/喷水/仿射）
   ▼
8 × 11 格 → tools/build.mjs → spritesheet.png (1536×2288)
   │  tools/verify.mjs    逐格 alpha 包围盒 / 越界检测 / 无效帧留空校验
   ▼
```

关键在于**位移场是连续的**：体轴方向的正弦位移（振幅随离头部距离增大 → 尾部摆幅最大、头部几乎不动），叠加胸鳍/尾鳍的局部高斯旋转和整体仿射。因为是反查像素而不是切割图层，**永远不会有接缝**，也不会出现"切下来的尾巴和身体对不上"的断层。

喷水是唯一手绘的部分：一条竖直水柱 + 12 颗扇形水花，用比本体更浅的蓝，否则会和头顶糊成一个角。

### ② 桌面壳：AppKit 三层

```
PetApp    行为调度器 —— 随机动作权重、游动位移、与 DSH 状态竞争姿态优先级
PetPanel  NSPanel  —— 无边框 · 非激活 · .floating · canJoinAllSpaces
PetView   NSView   —— layer.contents 直接贴 CGImage，按 contentsRect 切格
```

姿态优先级：**CLI 指定 > DSH 真实状态 > 刚完成窗口（4 秒 review）> 自主随机**。

渲染后端从网页版的 CSS `background-position` 换成 `CALayer.contents`——图集协议和帧时长表原样照搬，所以两边的动画表现逐帧一致。

### ③ 状态：只读文件

没有什么比"读几个 JSON"更不打扰宿主的了。见 [上文](#dsh-运行状态气泡)。

---

## 命令行参数

正常使用不需要，这些都是自测/诊断用的：

| 参数 | 作用 |
| --- | --- |
| `--selftest` | 图集逐格校验：有效帧必须有内容、无效帧必须留空 |
| `--statustest` | 状态推导 10 个分支 + 4 条新鲜度闸门断言 |
| `--drivetest` | 事件链路自测：拖拽 / 点击 / 菜单 / 落盘 / 11 个姿态渲染行 / 注视命中 |
| `--at x,y` | 指定初始位置（屏幕点坐标，y 向上） |
| `--pose <key>` | 固定某个姿态 |
| `--status-dir <path>` | 用受控目录替代真实 DSH 投影（注入测试用） |
| `--level <n>` | 指定面板层级 |
| `--log <path>` | 打开日志 |
| `--force` | 跳过多实例守卫，强行再开一只 |

---

## 项目结构

```
spout-whale/
├── pet.json                 # 宠物清单（Codex 图集协议）
├── spritesheet.png          # 1536×2288 图集
├── desktop/                 # 桌面 App 源码
│   ├── main.swift           #   AppKit 窗口 + 行为调度 + 拖拽/菜单/持久化
│   ├── status.swift         #   DSH 状态读取 + 气泡窗口
│   ├── Info.plist
│   └── build.sh
├── scripts/
│   ├── install.sh           # 安装到 ~/Applications（可选 LaunchAgent 自启）
│   ├── spoutwhale-ctl.sh    # start | stop | restart | status
│   └── ai.micheng.spoutwhale.plist
├── tools/                   # 图集生成管线（见上）
└── docs/images/
```

`pet.json` + `spritesheet.png` 正是 DSH 的 `@michengai/dsh-codex-pet` 插件需要的两个文件——把这个目录放进 `~/.dsh/codex-pet/pets/`，它同时也能作为**网页版宠物**使用。

---

## 从源码重建

`build.sh` 里写死了本机验证过的组合：

- 编译器：`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc`
  （**注意**：Command Line Tools 自带的 `swiftc` 6.2.3 与 CLT 的 SDK 26.2 不匹配，会报 `this SDK is not supported by the compiler`）
- SDK：`.../Platforms/MacOSX.platform/Developer/SDKs/MacOSX15.5.sdk`
- `-module-cache-path /tmp/swift-mc`（默认缓存目录不可写）
- `-target x86_64-apple-macosx15.0 -swift-version 5`

改成你自己的路径即可。图集管线需要 `sharp`：

```bash
cd tools
node sprite.mjs && node render.mjs && node build.mjs && node verify.mjs
```

> `tools/` 里没有参考图（`src.webp`）。想重跑管线，把任意一张同风格的鲸鱼图命名为 `src.webp` 放到 `tools/` 下——`sprite.mjs` 里的几何参数是照着原图调的，换图需要重新调。

---

## 验证状态（诚实披露）

**已验证**

- `--selftest` PASS：图集 1536×2288，88 格里有效帧全部有内容、无效帧全部留空
- `--statustest` PASS：状态推导 10 个分支 + 4 条新鲜度闸门断言全部通过，且能读到实时状态
- **状态气泡端到端注入测试**：注入受控假状态，App 记录的变更流与姿态逐一吻合 —— `思考中…`→行 7、`执行中… 5s`→行 7、`等你回答`→行 6、`重试中(1)`→行 5、`空闲中`→先播行 8 再回行 0
- 真实状态读取：截图里的气泡「执行中… 7s / 请先读取并遵循宠物创建 Skill · 319K tok」与当时的真实工具耗时一致
- `--drivetest` PASS：拖拽位移精确、y 不串改、单击触发挥手、纯点击不移动窗口、右键菜单 ≥6 项含大小子菜单、位置落盘、11 个姿态各自渲染到正确行、注视在正右/正上/正左分别命中 r9c4 / r9c0 / r10c4 且死区内不触发
- 单实例守卫：连开 3 次二进制只有 1 个实例
- 桌面截图证明：窗口真的浮在其它应用之上、背景真透明（背后内容可见）、位置在屏内

**未验证（环境限制，非代码缺陷）**

- **真人鼠标端到端投递**。三条合成事件通路全部实测失败：驱动 HID-tap 连 macOS 菜单栏的 Apple 菜单都点不开；`postToPid` 报成功但 App 内本地事件监听零事件；AppleScript 直接权限违例（-10004）。所以"真人点击/拖动"目前只有**事件处理器层**证据（`--drivetest` 喂的是真实 `NSEvent`，跑的就是线上那份 `mouseDown/Dragged/Up`），**没有 OS 层证据**。
- 多显示器与运行时改分辨率。位置只在启动时夹回可见区，未监听屏幕变化事件。

---

## 许可与致谢

代码以 **MIT** 发布，见 [LICENSE](LICENSE)。

鲸鱼造型派生自作者提供的参考图（DeepSeek 风格的蓝鲸标志），仅作个人学习与桌面美化用途；商标与原始标志的权利归其所有者。如果你要用在商业场景，请自行确认授权。

**协议参考**：[petx](https://github.com/IchenDEV/petx) 的 Codex 宠物图集协议（192×208 / 8 列 / `spriteVersionNumber: 2` / rows 9–10 为 16 个注视方向）。
