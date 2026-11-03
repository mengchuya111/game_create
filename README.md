# 武侠肉鸽 · 可验证骨架

> 一款**武侠风格的横版 2D 肉鸽动作游戏**（参考《死亡细胞》）。
> 这个仓库目前是一个**能跑、能测、能被 AI 安全修改的骨架**，不是完整游戏。

**仓库地址**：<https://github.com/mengchuya111/game_create>

克隆：

```bash
git clone git@github.com:mengchuya111/game_create.git
```

[![Godot](https://img.shields.io/badge/Godot-4.7.2-478CBF?logo=godotengine&logoColor=white)](https://godotengine.org/)
[![Language](https://img.shields.io/badge/language-GDScript-355570)](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/)
[![Tests](https://img.shields.io/badge/tests-225%20passed-brightgreen)]()
[![Smoke](https://img.shields.io/badge/smoke%20test-96%20passed-brightgreen)]()

---

## 这个仓库解决什么问题

四个不会写代码的人，想用 AI 做一款动作游戏。**最大的风险不是"AI 写不出代码"，而是"AI 改坏了代码，而你们看不出来"。**

所以这个骨架的重点不是玩法有多丰富，而是**每一处改动都能被自动验证**：

| 手段 | 覆盖什么 | 数量 |
|---|---|---|
| **单元测试** | 纯逻辑：状态机、伤害公式、帧数据、房间生成、局内成长、重放 | **225 个测试 / 1407 条断言** |
| **冒烟测试** | 接线：真的把游戏跑起来自动玩 600 帧，再做"被动挨打""调试台检查""清房→三选一→换房" | **96 项检查** |
| **游戏内调试台** | 人手动验证：31 条命令，可传送、可改血量、可发奖励、可导出完整状态 JSON | **31 条命令** |
| **确定性随机** | 同一个种子永远跑出同一局，bug 可复现 | 全项目零全局随机 |
| **输入重放** | 把一局操作录下来，任何人在任何机器上重放同一局 | 版本化 JSON 格式 |

**当前状态：全部通过。** 这不是"我觉得没问题"，是每次改完都会自动跑出来的结果。

---

## 快速开始

### 1. 拿到代码

```bash
git clone <仓库地址>
cd dream_start
```

### 2. 装 Godot（唯一必须手动装的工具）

**推荐跑仓库里的脚本** —— 它会自动下载、校验版本，并且在某个下载源不通时**自动换下一个源**：

```powershell
powershell -File tools\install-tools.ps1
```

也可以手动装：去 [Godot 官网](https://godotengine.org/download/windows/) 下载 **4.7.2-stable** 的 Windows 版，
把 `Godot_v4.7.2-stable_win64.exe` 和 `Godot_v4.7.2-stable_win64_console.exe`
两个文件放进仓库根目录的 `.tooling/` 文件夹里。

> ⚠️ **国内网络注意**：`github.com` 和 `downloads.godotengine.org` 经常出现
> **"HTTP 头能拿到、但一开始传数据就卡死"** 的情况 —— 所以"能 ping 通"不代表能下载。
> 脚本会自动改用 GitHub 加速源（实测约 0.24 MB/s，82 MB 约 6 分钟）。
> 三个源都失败时，脚本会直接打印可以手动打开的加速链接。
> 详见 [docs/01-工具清单.md](docs/01-工具清单.md) 第 5 节。

> `.tooling/` 已经被 `.gitignore` 排除，**不进版本库**（Godot 二进制有 170MB+）。
> 每个人自己装一份，但**版本号必须完全一致**。

> ⚠️ 本机只装了 Windows PowerShell 5.1，**没有 `pwsh`（PowerShell 7）**。
> 上面用 `powershell` 是刻意的。

### 3. 跑起来看看

```powershell
.tooling\Godot_v4.7.2-stable_win64.exe --path game
```

| 按键 | 功能 |
|---|---|
| `A` `D` | 左右移动 |
| `空格` / `K` | 跳跃 |
| `J` | 攻击（连按可以打出三段连招） |
| `L` | 冲刺 |
| `1` `2` `3` | 清房后选择心法（也可以直接点卡片）／商店里购买对应商品 |
| `Esc` | 离开商店 |
| `` ` `` / `F1` | **打开调试台**（最常用） |
| `F2` | 打开调试 HUD |
| `R` | 重开一局 |

进游戏后按 `` ` ``，输入 `next` 跳到战斗房，就能打到敌人了。

### 4. 跑测试（改完代码必做）

```powershell
$GODOT = ".tooling\Godot_v4.7.2-stable_win64_console.exe"

# 新增了 .gd / .tscn 文件之后必须先跑这一步
& $GODOT --headless --path game --import

# 单元测试
& $GODOT --headless --path game --script res://tests/run_tests.gd

# 冒烟测试
& $GODOT --headless --path game res://tests/smoke_run.tscn
```

两条命令都返回 `0` 才算通过。看到 `ERROR:` 不要慌，先看最后的结论行——
单元测试会**故意**构造错误输入来验证容错逻辑，那些报错是预期的（完整清单见 [AGENTS.md](AGENTS.md#测试输出里哪些-error--warning-是正常的)）。

**懒得记这三条？跑这一条就行：**

```powershell
powershell -File tools\verify.ps1
```

它按顺序跑完三条命令，解析出套件 / 方法 / 断言 / 检查项的数量，和 `tools/test-baseline.json`
里的基线对比，最后给你一句话结论。

**它专门抓一种肉眼看不出来的问题**：单元测试从 225 个变成 217 个时，结论行**照样**打印
「全部通过 ✓」。只有对比数字才看得出来。数字掉了它就直接报失败，并告诉你哪一项退步了。

确实新增了测试之后，用 `-UpdateBaseline` 把基线抬上去：

```powershell
powershell -File tools\verify.ps1 -UpdateBaseline
```

> ⚠️ 本机只装了 Windows PowerShell 5.1，**没有 `pwsh`（PowerShell 7）**。
> 上面用 `powershell` 是刻意的；如果你装了 pwsh，换成 `pwsh` 也一样。

### 5. 录一段演示（截图 / 视频）

不想自己打，想让游戏自己打一段给你看：

```powershell
# 生成逐帧 PNG 到 shots/demo/（Godot 自带的 Movie Maker，不需要装录屏软件）
& $GODOT --path game res://tests/demo_play.tscn --write-movie shots/demo/d.png --fixed-fps 60 --quit-after 900
```

`tests/demo_play.gd` 是**自适应输入**：每帧读场上敌人位置，远了走过去、近了就连招，
15 秒里会自然打完一间房、弹出三选一、进下一间房。不加 `--write-movie` 就是普通窗口，可以直接盯着看。

> 注意它是"现算输入"而不是预先录好的脚本。写死的脚本踩过坑：出招会锁移动
> （`player.gd` 的 `_apply_horizontal` 第 3 条），"每 16 帧按一次攻击"等于把人钉在原地，
> 5 秒下来零命中。改别人写的自动演示脚本时先想到这一点。


---

## 仓库结构

```text
dream_start/
├── AGENTS.md          ← 【给 AI 看】项目宪法：命令、架构规矩、禁止清单、已知陷阱
├── README.md          ← 本文件
├── docs/              ← 【给人看】文档
│   ├── 00-学习路线.md     不会写代码的人，需要学什么、学多久
│   ├── 01-工具清单.md     装哪些工具、多少钱、一键安装脚本
│   ├── 02-AI协作工作流.md  几个人怎么分工、怎么给 AI 派活、怎么读 diff
│   └── 03-验收清单.md      怎么判断一个功能到底做对了没有
├── tools/
│   ├── install-tools.ps1   自动下载 Godot + 检查环境
│   └── push-to-github.ps1  一键推送到 GitHub
└── game/              ← Godot 项目根目录
    ├── project.godot
    ├── data/          ← 纯 JSON 配置：招式帧数据、敌人原型、房间模板
    ├── scenes/        ← 场景：main / player / enemy
    ├── scripts/
    │   ├── core/      ← 配置、事件总线、确定性随机、主流程
    │   ├── combat/    ← 帧数据、伤害公式、判定盒、顿帧、震屏
    │   ├── player/    ← 输入帧、状态机、玩家节点
    │   ├── world/     ← 房间生成、竞技场、敌人
    │   ├── camera/    ← 相机跟随
    │   └── debug/     ← HUD、调试台、重放录制
    └── tests/         ← 单元测试 + 冒烟测试
```

---

## 已经做好的东西

### 手感（打击感三件套都在）

- **顿帧（hitstop）**：命中瞬间冻结画面。请求取最大值而非累加——同时打中 3 个敌人是 8 帧，不是 24 帧。
- **震屏（screen shake）**：trauma 模型，`offset = 最大偏移 × trauma² × 波形`。用正弦叠加而不是随机数，所以**可复现**。
- **连招取消**：轻击一段 → 二段 → 三段，每段有自己的取消窗口。帧数据在 `data/attacks.json` 里，改数值不用碰代码。

### 角色控制

- 输入缓冲 6 帧、土狼时间 6 帧（离开平台后还有 6 帧可以跳）
- 冲刺 11 帧，带无敌帧和 24 帧冷却
- 受击硬直 18 帧 + 30 帧无敌，避免被连击锁死
- 跳跃有"松键截断"（短按跳得矮）

### 肉鸽骨架

- 8 间房的路线生成，房间类型有起点/战斗/精英/宝箱/商店/首领
- 全部基于种子，同一个种子永远生成同一条路线
- 房间是数据驱动的（`data/rooms.json`），换布局不用改代码

### 局内成长（心法三选一）

- 每间战斗/精英/首领房清空后弹出 **3 条心法**，数字键 `1` `2` `3` 或点卡片选择
- 10 条心法、三档稀有度（凡品 / 上品 / 绝品），可叠层，叠满自动从池子里移除
- 效果：伤害、生命上限、移速、冲刺冷却、吸血、内力加成、清房回血
- 击杀山贼掉"内力"（本局货币，商店的地基）；内力数量受"财运"类心法影响
- **种子决定抽卡**：同一个种子 + 同一间房 + 同样的已得心法数，永远抽到同样的三条
- 数据在 `data/upgrades.json`；叠层换算在 `scripts/core/run_state.gd`；
  抽卡在 `scripts/core/upgrade_pool.gd`。三者都有单元测试

调试台里可以用 `give blade_edge` 直接拿心法、`reward` 强制弹一次三选一、`buffs` 看当前属性。

### 商店房（内力终于有地方花了）

- 一层**保底一间**商店。走进去自动开，数字键 `1` `2` `3` 购买，`Esc` 离开
- 卖的是同一套心法，价格**只按稀有度定**：凡品 10 / 上品 16 / 绝品 26 内力
  （心法要特殊定价，在 `data/upgrades.json` 对应条目里加 `"price"` 即可覆盖）
- 买不起的卡片会灰掉并写明"还差多少"；买过的标"已售出"，不会重复扣钱
- 商店货架和三选一**不是同一批**（抽取用了不同的盐值）—— 否则玩家会觉得
  "商店在卖我刚放弃的那三个"
- 定价在 `data/shop.json`；摆货与结算在 `scripts/core/shop.gd`（纯逻辑，有单元测试）

调试台里可以用 `shop` 随时开一次商店、`buy 1` 买第一件、`leave` 离开。

### 验收工具（这部分是团队每天真正在用的）

- **调试台**：31 条命令，`next` 跳房间、`tp` 传送、`check` 校验数据表、`give` 发心法、`dump` 导出完整状态 JSON
- **重放系统**：把一局输入录成 JSON 文件，可回放、可发给队友复现 bug
- **确定性随机**：`DeterministicRng` 全部走自己的 `next_int` / `next_float`，不用 Godot 全局随机函数

---

## 这个骨架真实抓到过的 bug

这四条是**已经发生过的**，写在这里是为了说明"为什么需要自动测试"，不是为了炫技：

**① 敌人打不到玩家，却互相误伤**

`Hitbox.source_team` 的默认值是 `"player"`，而命中规则是"只打不同阵营的目标"。敌人忘了设置这一行，结果山贼的攻击判定为"自己人"打玩家 → 不生效；同时山贼之间阵营相同……但木桩也是 `"enemy"`——于是**山贼把训练木桩砍死了，玩家却毫发无伤**。

代码审查完全看不出来。是冒烟测试跑起来后，发现"敌人掉了 14 次血，玩家一次没掉"才抓到的。

**② 判定盒关不掉，敌人死了还在挨打**

`hitbox.end_swing()` 里直接写 `monitoring = false`。当它是在 `area_entered` 信号回调内部被调用时（敌人被打死的那一刻），Godot 会报：

```
ERROR: Function blocked during in/out signal. Use set_deferred("monitoring", true/false).
```

而且这是**静默失败**——判定盒一直开着。改成 `call_deferred` + token 机制解决。

**③ 换房间之后自动测试突然不动了**

玩家是 `Arena` 的子节点，换房时 `Arena.build()` 会清空所有子节点，**玩家被重新实例化**。新玩家的 `replay_source` 是 `null`，于是重放和自动测试都失去了输入，角色站着不动。

**这三个 bug 有一个共同点：单元测试全绿，代码看起来完全正确。**

**④ HUD 上写着 `lucky_coin×1`**

`RunState` 是纯逻辑类，只认识 id（`lucky_coin`），不认识显示名（「财运亨通」）。
HUD 图省事直接调了 `run_state.describe_upgrades()`，于是玩家看到的是**数据表里的键名**。

两百多个单元测试全绿——因为 id 确实是数据的一部分，断言"拿到了 lucky_coin"完全成立。
是录演示视频时逐帧看画面才发现的。修法是把 id → 显示名的翻译留在 `main.gd`
（它手里同时有 `run_state` 和 `upgrade_pool`），并加了一条冒烟检查钉死它。

**⑤ 打完所有山贼，门却永远不开**

`data/rooms.json` 里战斗房的敌人池是 `["training_dummy", "bandit", "bandit", "bandit"]`，
而刷怪是 `pool[i % pool.size()]` 按顺序循环取用 —— 于是**每间战斗房的第 0 号敌人都是训练木桩**
（血 9999、不反击、死了自动复活）。清房判定是"所有敌人死亡"，所以玩家把山贼全砍光也等不到开门。

单元测试和冒烟测试当时都是全绿的：冒烟测试最后用 `debug_clear_current_room()` 强行清房，
恰好绕过了"真的把敌人打完"这条路径。录演示视频时看到"场上还剩 1 个"卡住才发现。

修法不是改一行数据就完事：给木桩加了 `immortal: true` 标记、刷怪时跳过并报警、
`check` 命令增加跨表校验、新增 `test_room_data.gd`（跨表校验 + "不死单位不能进清房房间"回归守卫）、
冒烟测试也加了一条"场上没有打不死的木桩"。

**这五个 bug 有一个共同点：单元测试全绿，代码看起来完全正确。**

---

## 给 AI 派活的标准姿势

改任何代码之前，确保 AI 读到了 [`AGENTS.md`](AGENTS.md)。派活时用四段式模板（详见 [docs/00-学习路线.md](docs/00-学习路线.md#3-给-ai-提需求的模板)）：

```markdown
## 上下文
- 相关文件：game/scripts/player/player_fsm.gd、game/scripts/player/player.gd
- 现有架构：状态机在 PlayerFsm（extends RefCounted）里，不依赖场景树，可被单测
- 当前行为：冲刺没有无敌帧

## 目标
给冲刺加入 8 帧无敌 + 12 帧冷却

## 约束
- 只允许改 player_fsm.gd 和 player.gd
- 数值必须写进 game_config.gd
- 不要动 .tscn 场景文件，不要重构无关代码

## 验收标准
1. 冲刺中被打中，血量不变；冲刺结束后第 1 帧被打中，正常掉血
2. 冷却期间按冲刺键无效
3. 补单元测试，至少 2 条反向用例
4. 跑 run_tests.gd 和 smoke_run.tscn，把完整输出贴给我
```

**四段缺一不可。** 缺哪一段，AI 就会在哪一段自由发挥——而自由发挥的部分通常不是你要的。

---

## 一条硬性要求

> **必须至少有一个人读每一份 AI 的 diff。**

不看 diff 直接合并，是这个项目最大的风险来源。上面那三个 bug 说明了一个事实：**测试能保证"没坏"，但保证不了"设计合理"。**

如果没有人读 diff，这个项目大概会在 **2-4 个月**内陷入"能跑但没人敢改"的状态。这不是危言耸听，是这类协作方式的常见结局。

---

## 许可

未定。等团队商量。
