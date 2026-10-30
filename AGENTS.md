# AGENTS.md —— 给 AI 编程助手的项目宪法

> **这份文件是写给 AI 看的，不是写给人看的。**
> 每次让 AI 改代码之前，确保它读到了这份文件（大多数工具会自动读根目录的 `AGENTS.md`）。
>
> 人看的文档在 [`docs/`](docs/) 目录，从 [`docs/00-学习路线.md`](docs/00-学习路线.md) 开始。

---

## 0. 30 秒速览

| 项 | 值 |
|---|---|
| 项目 | 武侠风横版 2D 肉鸽动作游戏（参考《死亡细胞》） |
| 引擎 | **Godot 4.7.2-stable**（版本必须锁死，小版本间场景文件可能不兼容） |
| 语言 | **GDScript only**。禁止引入 C#、GDExtension、任何第三方插件 |
| 项目根目录 | `game/`（**所有 Godot 命令都必须带 `--path game`**） |
| 缩进 | **4 个空格**。禁止 Tab |
| 编码 | UTF-8，换行 LF（由 `.gitattributes` 强制） |
| 注释语言 | **中文** |
| 当前状态 | 可验证骨架已跑通：225 个单元测试 + 96 项冒烟检查全绿 |

---

## 1. 你必须会跑的命令

改完任何代码，**按顺序跑完这三条**。不要只说"改好了"，要把完整输出贴出来。

```bash
# Godot 可执行文件（在 .tooling/ 下，已被 gitignore，不进版本库）
GODOT=".tooling/Godot_v4.7.2-stable_win64_console.exe"

# ① 新增或删除了 .gd / .tscn 文件之后必须跑，否则 class_name 互相引用会解析失败
"$GODOT" --headless --path game --import

# ② 单元测试（纯逻辑层）。全绿退出码 0，有失败退出码 1
"$GODOT" --headless --path game --script res://tests/run_tests.gd

# ③ 冒烟测试（真的把游戏跑起来自动玩）。全绿退出码 0，有失败退出码 1
"$GODOT" --headless --path game res://tests/smoke_run.tscn
```

只改了一个文件、想快速查语法（不做完整检查）：

```bash
"$GODOT" --headless --path game --check-only --script res://scripts/player/player_fsm.gd
```

人想自己玩一下：

```bash
"$GODOT" --path game
```

想录一段演示画面（游戏自己打，走的是重放输入通路）：

```bash
"$GODOT" --path game res://tests/demo_play.tscn \
    --write-movie shots/demo/d.png --fixed-fps 60 --quit-after 900
```

`shots/` 已被 gitignore。**注意 `tests/demo_play.gd` 的输入是"每帧现算"的自适应驱动，
不是预先写死的脚本**——原因见第 6 节陷阱清单里"出招会锁移动"那一条。

**验收标准：② 和 ③ 的退出码都必须是 0。** 有一个不是 0 就不算完成，不要提交。

### 测试输出里哪些 ERROR / WARNING 是正常的

单元测试会故意构造错误输入来验证容错逻辑，下面这些**是预期的，不是失败**：

```
[AttackTable] 帧数据表里一条有效招式都没有
数据有问题：条目「oops」
active 必须大于 0
找不到帧数据文件
[PlayerFsm] 默认招式「不存在的招式」不在帧数据表里
Parse JSON failed
重放格式版本不匹配：文件是 999
找不到重放文件
```

判断是否真的失败，**只看最后一行结论和退出码**：

```
测试套件 11 个   测试方法 225 个   断言 1407 条   失败 0 个
结果：全部通过 ✓
```

---

## 2. 目录结构与所有权

```text
dream_start/
├── AGENTS.md              ← 本文件
├── README.md
├── docs/                  ← 给人看的文档
├── tools/                 ← 环境安装 / 推送到 GitHub 的脚本
└── game/                  ← Godot 项目根（--path game）
    ├── project.godot
    ├── data/              ← 数据层：纯 JSON，改数值不碰代码
    ├── scenes/            ← 场景层：只负责摆节点、挂脚本
    ├── scripts/
    │   ├── core/          ← 骨架：配置、事件总线、RNG、局内成长、主流程
    │   ├── combat/        ← 战斗：帧数据、伤害、判定、打击感
    │   ├── player/        ← 玩家：输入、状态机、节点
    │   ├── world/         ← 关卡：房间生成、竞技场、敌人
    │   ├── camera/        ← 相机
    │   ├── ui/            ← 界面：奖励面板 / 商店面板（只显示，不含规则）
    │   └── debug/         ← 验收工具：HUD、调试台、重放
    └── tests/             ← 测试：单元测试 + 冒烟测试
```

### 文件所有权（改动前先确认）

| 目录 | 谁负责 | AI 可以自由改吗 |
|---|---|---|
| `scripts/combat/` | 战斗负责人 | 可以，但改了公式必须同步改 `tests/test_damage.gd` |
| `scripts/player/` | 角色负责人 | 可以，但改了状态机必须同步改 `tests/test_player_fsm.gd` |
| `scripts/world/` + `data/rooms.json` | 关卡负责人 | 可以 |
| `data/attacks.json` | 手感负责人 | **改数值随时可以，改字段名要先问** |
| `data/upgrades.json` | 数值 / 系统负责人 | **改数值随时可以，改效果键名要先问**（键名对应 `RunState` 里的方法） |
| `data/shop.json` | 数值负责人 | 改价格随时可以（只影响内力消耗） |
| `data/enemies.json` | 关卡 / 数值负责人 | 改数值可以；**`immortal: true` 的原型绝不能出现在房间模板里**（见陷阱 8） |
| `scripts/ui/` | 界面负责人 | 可以，但不要在这里写规则（面板只负责显示和转发按键） |
| `scenes/*.tscn` | **同一时间只能一个人改** | **改之前必须先说明，改完必须跑冒烟测试** |
| `scripts/core/` | 架构负责人 | **要改必须先说明理由** |
| `tests/` | 所有人 | **只许增加，不许删除或弱化已有断言** |

---

## 3. 六条硬性架构规矩

### 规矩 1：能写成纯逻辑的，必须写成纯逻辑

**所有游戏规则写在 `extends RefCounted` 的类里，不写在 `extends Node` 的类里。**

```gdscript
# ✅ 正确：纯逻辑类，不需要场景树，单元测试能直接 new 出来跑
class_name PlayerFsm
extends RefCounted

func tick(input: PlayerInputFrame, on_floor: bool, vertical_velocity: float) -> Dictionary:
    ...
```

```gdscript
# ❌ 错误：规则和节点混在一起，没法单测
class_name Player
extends CharacterBody2D

func _physics_process(delta: float) -> void:
    if Input.is_action_just_pressed("attack") and _can_attack():
        ...
```

判断标准很简单：**如果你写的逻辑需要"把游戏跑起来"才能测，那它写错地方了。**

目前已经这样拆好的类（照抄它们的写法）：

| 纯逻辑类 | 职责 | 对应测试 |
|---|---|---|
| `PlayerFsm` | 玩家状态机、连段、取消窗口、输入缓冲 | `test_player_fsm.gd` |
| `AttackDef` / `AttackTable` | 帧数据定义与校验 | `test_attack_table.gd` |
| `Damage` | 伤害公式、韧性、连段衰减 | `test_damage.gd` |
| `Hitstop` / `ScreenShake` | 顿帧与震屏的计时模型 | `test_hitstop_shake.gd` |
| `RoomGenerator` | 肉鸽房间路线生成 | `test_room_generator.gd` |
| `RunState` | 局内成长：心法叠层、属性换算、内力结算 | `test_run_state.gd` |
| `UpgradePool` | 心法池加载、校验、按权重抽三选一 | `test_upgrade_pool.gd` |
| `Shop` | 商店摆货、按稀有度定价、购买结算 | `test_shop.gd` |
| `RoomDataValidator` | 房间模板 × 敌人表的跨表校验 | `test_room_data.gd` |
| `DeterministicRng` | 确定性随机数 | `test_deterministic_rng.gd` |
| `ReplayRecorder` / `PlayerInputFrame` | 输入录制与回放 | `test_replay_recorder.gd` |

### 规矩 2：只有 `Hurtbox` 能改血量

`hp` 只能通过 `Hurtbox.receive_hit(hitbox)` 修改。**任何其他地方都不许直接写 `hp = ...`。**

原因：`receive_hit` 里集中处理了无敌帧、防御减伤、韧性、死亡判定、以及所有事件的广播。绕过它就等于绕过全部规则。

血量变化必须广播事件，不许静默修改：

```gdscript
EventBus.player_damaged.emit(amount, remaining_hp)
EventBus.enemy_damaged.emit(amount, remaining_hp, world_pos)
EventBus.hit_confirmed.emit(attack_id, hitstop_frames, shake, world_pos)
```

### 规矩 3：判定盒必须显式声明阵营

```gdscript
hitbox.source_team = "player"   # 玩家
hitbox.source_team = "enemy"    # 敌人
```

**这是踩过的真坑**：`Hitbox.source_team` 的默认值是 `"player"`，而命中规则是"只打不同阵营的目标"。敌人忘了设置会导致两个后果——敌人的攻击打不到玩家，同时敌人之间互相误伤。

新增任何带攻击能力的角色，**必须**在 `_ready()` 里设置这一行。

### 规矩 4：禁止使用 Godot 全局随机函数

```gdscript
# ❌ 全部禁止
randi()  randf()  randi_range()  randf_range()  randomize()  shuffle()

# ✅ 一律使用项目自己的确定性随机数
var rng := DeterministicRng.new(GameConfig.run_seed)
var damage := rng.next_int(8, 12)
var offset := rng.next_float_range(-420.0, 420.0)
var loot := rng.weighted_pick(entries)
```

原因：肉鸽游戏必须能**用种子完整复现一局**。用了全局随机函数，同一个种子每次跑出来的关卡都不一样，bug 就没法复现，自动测试也没法断言。

> ⚠️ **还有一个更隐蔽的陷阱**：在 `DeterministicRng` 类**内部**写裸的 `randi_range(...)`，GDScript 会把它解析成 `@GlobalScope` 的全局函数，而不是你自己的方法——于是随机数既不可复现，也不会被计数。
> 所以该类内部的方法一律命名为 `next_int` / `next_float` / `next_float_range`，**故意避开全局函数名**。你在这个类里加新方法时也要遵守这个命名规则。

### 规矩 5：手感数值不许硬编码

所有影响手感的数字集中放在两处：

- `scripts/core/game_config.gd` —— 全局的（重力、移速、顿帧强度、无敌帧数……）
- `data/attacks.json` —— 单招的（起手帧、判定帧、收招帧、伤害、顿帧、震屏……）

```gdscript
# ❌ 错误
if hitstop_frames > 12:
    hitstop_frames = 12

# ✅ 正确
if hitstop_frames > GameConfig.HITSTOP_MAX_FRAMES:
    hitstop_frames = GameConfig.HITSTOP_MAX_FRAMES
```

**唯一例外**：`const` 常量可以写在类顶部（如 `Hitbox.LAYER_HITBOX`），因为它们不参与手感调优。

### 规矩 6：新增一种心法效果，必须同时改三处

局内成长的数值全在 `data/upgrades.json`，但**光写数据不会生效**。加一个新效果键（例如"暴击率"）时要同时改：

1. `data/upgrades.json` —— 写出带该键的心法；
2. `scripts/core/run_state.gd` —— 在 `stats()` 区域加一个读取方法，并接上封顶常量；
3. `tests/test_run_state.gd` —— 补断言，并在 `test_upgrade_pool.gd` 的"已知效果键"白名单里登记。

漏掉第 2 步的表现是"玩家拿到了心法，但什么都没变"；漏掉第 3 步的表现是"以后改坏了没人知道"。
另外 `reward_panel.gd` 会自动读 `display_name` / `description`，不用改 UI。

---

## 4. 碰撞层分配表

**这张表是契约，不许私自改。**

| 层号 | 位掩码 | 用途 | 谁在用 |
|---|---|---|---|
| 1 | `1 << 0` = 1 | 地形 | 地板、平台、墙 |
| 2 | `1 << 1` = 2 | 玩家身体 | `player.tscn` 的 CharacterBody2D |
| 3 | `1 << 2` = 4 | 敌人身体 | `enemy.tscn` 的 CharacterBody2D |
| 4 | `1 << 3` = 8 | 攻击判定 | `Hitbox`（`LAYER_HITBOX`） |
| 5 | `1 << 4` = 16 | 受击判定 | `Hurtbox`（`LAYER_HURTBOX`） |

规则：

- `Hitbox`：`collision_layer = LAYER_HITBOX`，`collision_mask = LAYER_HURTBOX`（**只关心受击盒**）
- `Hurtbox`：`collision_layer = LAYER_HURTBOX`，`collision_mask = 0`（**被动挨打，不主动检测**）
- 角色身体：`collision_layer` 用自己的层，`collision_mask = 1`（只和地形碰撞）

阵营区分**不靠碰撞层，靠 `team` 字符串**（`"player"` / `"enemy"`）。这是刻意选择：以后加"中立单位""友军"时不用改碰撞层，改字符串就行。

---

## 5. 帧数据约定

```json
{
  "light_1": {
    "display_name": "轻击一段",
    "startup": 6,
    "active": 3,
    "recovery": 10,
    "cancel_from": 12,
    "cancel_into": ["light_2"],
    "damage": 8,
    "hitstop": 4,
    "shake": 0.22,
    "knockback": 120.0,
    "hitbox_offset": [26.0, -20.0],
    "hitbox_size": [40.0, 30.0]
  }
}
```

| 字段 | 含义 | 约束 |
|---|---|---|
| `startup` | 起手帧（出招到判定生效） | ≥ 1 |
| `active` | 判定帧（判定盒开启的帧数） | ≥ 1 |
| `recovery` | 收招帧（判定结束到能动） | ≥ 0 |
| `cancel_from` | 从第几帧起可以取消接下一招 | 0 或 `startup + 1` ~ `total_frames`；0 表示不可取消 |
| `cancel_into` | 可以取消成哪些招式 | 数组，元素必须是**表里存在的招式 id** |
| `total_frames` | **不写**，由 `startup + active + recovery` 自动算出 | 加载时校验 |

**帧的编号方式（最容易搞错的地方）**：

- 按下攻击键的那一帧 = `state_frame 0`，该帧不递增
- 从下一帧起，第 N 帧处理的是 `state_frame = N - 1`
- `phase_at(frame)` 返回 `"startup"` / `"active"` / `"recovery"` / `"end"`
- `light_1` 的判定盒在 tick 7/8/9 开启，对应帧序号 6/7/8
- 取消窗口 `cancel_from = 12`，在第 13 个 tick 生效

改帧数据之后**必须跑** `test_attack_table.gd`，它会校验上面每一条约束，并检查所有 `cancel_into` 指向的招式真实存在。

### JSON 注释约定

JSON 不支持注释，所以**以 `_` 开头的键一律被当作注释跳过**：

```json
{
  "_readme": ["这是说明文字，加载器会跳过", "第二行说明"],
  "light_1": { ... }
}
```

加载器（`AttackTable.load_from_dict`）会 `continue` 掉所有 `_` 前缀的键。加注释请用这个方式，**不要**用 `//` 或 `#`，那会让 JSON 解析失败。

---

## 6. 代码风格

```gdscript
class_name Foo
extends RefCounted
## 类文档：用一两句话说明这个类是干什么的、边界在哪里。
## 如果有反直觉的设计，一定要在这里解释为什么。

## 常量用大写
const MAX_COUNT := 8

## 成员变量加类型标注
var count: int = 0
var speed: float = 190.0

## 公开方法在前，私有方法在后，用分隔注释分段
func do_something(input: int) -> int:
    if input <= 0:
        push_warning("[Foo] input 必须为正数，已忽略")
        return 0
    return input * 2

# ============================== 内部实现 ==============================

func _helper() -> void:
    pass
```

硬性要求：

1. **缩进 4 个空格**，不许用 Tab。
2. **所有变量和返回值都要标注类型**（`var x: int = 0`，`func f() -> void`）。
3. **公开方法写文档注释**（`##` 开头），说清楚"做什么"和"边界条件"。
4. **函数名用蛇形命名**（`load_from_file`），类名用大驼峰（`AttackTable`），常量用全大写。
5. **注释写"为什么"，不写"是什么"**。`i += 1  # 加一` 是废话；`# 输入缓冲要在状态机之前递减，否则缓冲窗口会多一帧` 才有价值。
6. **不许留调试垃圾**：`print("here")`、被注释掉的大段旧代码、临时变量，提交前删干净。
7. **不许"顺手重构"**。只改你被要求改的部分。看到不顺眼的代码先记下来问人，不要自己动手。

---

## 7. 禁止清单（AI 绝对不能做的事）

### 🚫 禁止改动的文件

| 文件 | 原因 |
|---|---|
| `game/project.godot` | 改错会导致项目打不开。**改之前必须先问人。** |
| `game/.godot/` | Godot 自动生成的缓存，已在 `.gitignore` 里，**永远不要碰** |
| `*.uid` 文件 | Godot 自动生成的脚本 UID，**必须提交，但不要手改** |
| `.gitignore` / `.gitattributes` | 改错会导致整个仓库的文件状态混乱 |

### 🚫 禁止的行为

1. **禁止引入第三方依赖**：不装插件、不加 `addons/`、不用 GDExtension、不改用 C#。
2. **禁止删除或弱化测试**：`tests/` 里的断言只许增加。如果某个断言过不了，说明代码错了，**不是测试错了**。
3. **禁止使用全局随机函数**：见规矩 4。
4. **禁止在 `_process` 里做判定**：所有游戏判定写在 `_physics_process` 里（固定 60 帧/秒），`_process` 只做纯视觉表现。判定放 `_process` 会导致不同帧率下行为不一致。
5. **禁止在信号回调里直接改 `monitoring`**：见下面"已知陷阱"第 2 条。
6. **禁止用 `await` 写游戏逻辑**：`await` 会让代码时序不可预测，测试无法复现。逻辑必须写成"每帧 tick 一次"的形式。
7. **禁止把 `Engine.time_scale` 当成"暂停"用**：顿帧必须按真实时间倒数，见下面第 1 条。
8. **禁止在 `hitbox.gd` / `hurtbox.gd` 里写特效、音效、震屏**：它们只负责"算伤害 + 发信号"，演出由 `combat_director.gd` 监听信号完成。
9. **禁止一次改超过 3 个文件**。改动面越大，人越没法审。
10. **禁止声称"已完成"而不跑测试**。必须贴出 ② 和 ③ 两条命令的完整输出。

---

## 8. 已知陷阱（都是真踩过的，务必先读）

### 陷阱 1：顿帧必须按真实时间倒数

```gdscript
# ❌ 错误：顿帧期间 time_scale = 0.05，delta 也被缩放成 1/20，
#         结果顿帧会持续 20 倍的时间，游戏像卡死了
func _process(delta: float) -> void:
    hitstop.tick(delta)

# ✅ 正确：除以 time_scale，还原成真实经过的时间
func _process(delta: float) -> void:
    var real_delta := delta / maxf(Engine.time_scale, 0.0001)
    hitstop.tick(real_delta)
```

另外：顿帧请求取**最大值**而不是累加。同时打中 3 个敌人，顿帧是 8 帧，不是 24 帧。

并且 `_exit_tree()` 里必须还原 `Engine.time_scale = 1.0`，否则退出游戏后编辑器也会变慢。

### 陷阱 2：不能在信号回调里改 `monitoring`

```gdscript
# ❌ 错误：如果 end_swing() 是在 area_entered 信号回调里被调用的
#         （例如敌人被打死时），这一行会报错，而且**是静默失败**：
#         ERROR: Function blocked during in/out signal.
#         结果是判定盒一直开着，敌人死了还在挨打。
func end_swing() -> void:
    monitoring = false
```

正确做法在 `hitbox.gd` 里：`attack_def = null` **立即**生效（判定盒当场打不到人），物理层面的 `monitoring` 用 `call_deferred` 延迟一帧关闭，并用一个 token 防止"同一帧内先关再开"被误关。

### 陷阱 3：换房间时必须把重放数据源接回去

玩家是 `Arena` 的子节点，`Arena.build()` 会清空所有子节点，所以**每换一间房玩家都会重新实例化**。新玩家的 `replay_source` 是 `null`，必须由 `main._load_room()` 从旧玩家身上取出来重新接上，否则换房之后回放和自动测试都会"角色突然站着不动"。

同理，玩家在 `_ready()` 里注册的调试命令（`god` / `hp` / `pos` / `attack` / `tp`）每次换房都会重新注册一遍。这类"命令必须指向当前实例"的重复注册是**刻意覆盖**，注册时传 `replace = true`，不要让它刷警告。

### 陷阱 4：新增脚本文件后必须重新 import

Godot 用 `.godot/global_script_class_cache.cfg` 记录所有 `class_name`。新增 `.gd` 文件后不跑 `--import`，其他脚本引用它时会报：

```
Parse Error: Could not resolve script "res://tests/test_xxx.gd"
Could not find type "TestCase"
```

**加完文件第一件事就是跑 `--import`。**

### 陷阱 5：测试类的"预期错误"

单元测试会故意喂错误数据来验证容错分支，控制台里会出现一堆 `ERROR:` 和 `WARNING:`。**不要试图"修掉"它们**，也不要因为它们存在就认为测试失败。只看最后的结论行和退出码。

### 陷阱 6：出招会锁移动，自动输入别"边跑边连按攻击"

`player.gd` 的 `_apply_horizontal` 有三层优先级：冲刺 > 前冲惯性 > **出招期间不接受移动输入**。
所以"一边按右键一边每 16 帧按一次攻击"的自动脚本，实际是**站着不动连续出招**——
演示录出来 5 秒一步没挪、零命中，看起来像游戏坏了，其实输入脚本写错了。

写自动演示/自动测试的输入时，必须留出**纯移动的帧段**（`tests/demo_play.gd` 里的做法是
"距离大于出招范围就只按方向，进入范围才出招"）。

### 陷阱 7：未知类型的值不能 `:=` 推断

从 `main`（类型是 `Node2D`）往下取属性时，`_main.arena` 是 `Variant`，`var x := _main.arena.某方法()` 会直接**解析失败**：

```
Parse Error: Cannot infer the type of "remaining" variable because the value doesn't have a set type.
```

要么写显式类型 `var remaining: int = ...`，要么给引用加类型标注。这个报错发生在**解析期**，
脚本根本不会执行——但如果用 `--write-movie` 录演示，录制会照常跑完 900 帧空画面，不留意就白录了。
**录完必须自己看一眼帧。**

### 陷阱 8：打不死的单位绝不能进"需要清空的房间"

清房判定是"这个房间里的敌人都死了"。塞一个`打不死`的进去，这间房就**永远清不掉**，
整局卡在那里 —— 玩家砍完最后一个山贼，门就是不开。

这不是假设：`data/rooms.json` 的 COMBAT 模板原来写着
`["training_dummy", "bandit", "bandit", "bandit"]`，而刷怪是 `pool[i % size]` 顺序取用，
所以**每间战斗房的第 0 号敌人都是训练木桩**（血 9999、不反击、死后自动复活）。

现在有三道防线，改数据时别绕过它们：
1. `data/enemies.json` 里木桩带 `"immortal": true`；`arena._spawn_enemies()` 见到就跳过并 `push_warning`；
2. `RoomDataValidator.validate_templates()` 做跨表校验，`check` 命令会打出来；
3. `test_room_data.gd` 是回归守卫，`tests/` 只许增加不许弱化。

要练手感请用调试台 `spawn training_dummy` —— 它刷出来的敌人**不进 `_enemies` 列表**，
所以不影响清房判定。

### 陷阱 9：中文 `.ps1` 脚本必须存成「UTF-8 with BOM」

`tools/` 下的 PowerShell 脚本里写了中文提示。如果存成 **UTF-8 无 BOM**，
Windows PowerShell 会按系统 ANSI 代码页（简中是 GBK）去读它，中文字符被解码成乱码，
**乱码字节里可能凑出引号或括号，直接把脚本的语法结构冲垮**，报的是这种驴唇不对马嘴的错：

```
函数参数列表中缺少")"。
表达式或语句中包含意外的标记"宸插垱寤虹涓€娆℃彁浜?"。
```

注意报错信息本身就是乱码——看到这种"错误消息里带乱码"的情况，先怀疑文件编码，别去数括号。

```powershell
# 转成 UTF-8 with BOM（$true 就是"带 BOM"）
$utf8Bom = New-Object System.Text.UTF8Encoding $true
$text = [System.IO.File]::ReadAllText($path, (New-Object System.Text.UTF8Encoding $false))
[System.IO.File]::WriteAllText($path, $text, $utf8Bom)
```

改完用解析器验一遍（比直接运行安全，不会执行副作用）：

```powershell
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
$errors   # 空数组 = 语法正确
```

同理，`game/` 里的 `.gd` / `.json` 也是 UTF-8，但 Godot 自己认 UTF-8，**不带 BOM 反而更安全**
（带 BOM 的 `.gd` 有时会让首行解析出问题）。所以：**只有 `.ps1` 加 BOM，其他文件不加。**

---

## 9. 提交前检查清单

复制这份清单，逐条打勾后再提交：

```markdown
- [ ] 我跑过 `--import`（如果新增/删除了 .gd 或 .tscn 文件）
- [ ] `run_tests.gd` 退出码为 0，且测试数量没有减少
- [ ] `smoke_run.tscn` 退出码为 0
- [ ] 我为新增的逻辑补了单元测试（至少 2 条反向用例）
- [ ] 我没有删除或弱化任何已有断言
- [ ] 我没有硬编码手感数值（都放进了 game_config.gd 或 data/*.json）
- [ ] 我没有用全局随机函数
- [ ] 新增的攻击单位都设置了 `hitbox.source_team`
- [ ] 我改动的文件不超过 3 个，且都是任务允许改的
- [ ] 我删掉了所有调试用的 print 和注释掉的旧代码
- [ ] 缩进是 4 个空格，不是 Tab
- [ ] 我在提交信息里写清楚了"改了什么"和"为什么"
```

---

## 10. 调试台命令参考

游戏里按 `` ` ``（反引号）或 `F1` 打开调试台。**这是团队验收的主要工具。**

| 命令 | 用法 | 说明 |
|---|---|---|
| `help` | `help [命令名]` | 列出全部命令，或查某一条的说明 |
| `seed` | `seed 20240501` | 设置随机种子（决定房间路线和敌人位置） |
| `restart` | `restart` | 用当前种子重开一局 |
| `rooms` | `rooms` | 打印本局的房间路线 |
| `next` | `next` | 直接跳到下一间房（**验收时最常用**） |
| `tp` | `tp 120 180` | 把角色传送到坐标 (x, y) |
| `hp` | `hp 50` | 设置血量 |
| `god` | `god` | 开关无敌模式 |
| `pos` | `pos` | 打印当前位置、状态、朝向 |
| `attack` | `attack light_2` | 切换起手招式（测单招手感用） |
| `check` | `check` | **校验全部数据表**，有 ✗ 就是数据配错了 |
| `attacks` | `attacks` | 列出所有招式及其帧数 |
| `data` | `data light_1` | 打印某一招的完整帧数据 |
| `dump` | `dump` | 导出当前完整状态为 JSON（可直接贴给 AI） |
| `save` | `save` | 保存当前这一局的重放文件 |
| `replays` | `replays` | 列出已保存的重放 |
| `replay` | `replay <文件名>` | 播放一个重放 |
| `buffs` | `buffs` | 查看本局已得心法、叠层与属性加成明细 |
| `give` | `give iron_body` | 直接获得一条心法（**验收成长系统最常用**） |
| `reward` | `reward` | 立刻弹出一次三选一，不用真的清房 |
| `pick` | `pick 2` | 代替玩家按 2，结算当前待选奖励 |
| `shop` | `shop` | 立刻开一次商店（不用真的走到商店房） |
| `buy` | `buy 1` | 买下货架第 1 件，验证扣内力 |
| `leave` | `leave` | 离开商店 |
| `spawn` | `spawn training_dummy` | 在身前刷一只敌人（**不进清房判定**，专门用来练手感） |
| `hitstop` | `hitstop 8` | 手动触发顿帧 |
| `shake` | `shake 0.5` | 手动触发震屏 |
| `feel` | `feel` | 依次播放 4 档打击感强度（调手感用） |
| `quit` | `quit` | 退出游戏 |
| `clear` / `hide` | | 清屏 / 关闭调试台 |

### 键盘操作

| 按键 | 功能 |
|---|---|
| `A` `D` / `←` `→` | 左右移动 |
| `W` `S` / `↑` `↓` | 上/下（预留） |
| `空格` / `K` | 跳跃 |
| `J` | 攻击 |
| `L` | 冲刺 |
| `` ` `` / `F1` | 开关调试台 |
| `F2` | 开关调试 HUD |
| `R` | 重开一局 |

---

## 11. 接到任务时的标准流程

1. **先读，再写。** 把要改的文件和它对应的测试文件都读一遍。不要凭猜测改代码。
2. **确认边界。** 任务里写"只允许改 X"，就真的只改 X。需要改别的文件时先说明理由。
3. **能写纯逻辑就写纯逻辑。** 规则进 `RefCounted`，节点层只做接线。
4. **先写测试，再写实现**（至少同时写）。测试写不出来，说明需求还没想清楚，先问人。
5. **跑 `--import` → `run_tests.gd` → `smoke_run.tscn`。**
6. **输出报告**，包含四段：
   - 改了哪些文件，每处为什么
   - 三条命令的**完整输出**
   - 新增/修改了哪些测试
   - **不确定的地方**（宁可说"这里我不确定"，也不要含糊过去）

---

## 12. 诚实声明

这个项目里的 AI 无法验证"代码写得对不对"，只能验证"行为对不对"。

- **AI 能保证的**：跑过的测试全绿、行为符合验收标准、改动范围受控。
- **AI 不能保证的**：架构是否合理、手感是否好玩、以后会不会难扩展、有没有想不到的边界情况。

所以：**人必须读 diff。** 不看 diff 直接合并 AI 的改动，是这个项目最大的风险来源。
