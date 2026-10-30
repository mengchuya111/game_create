class_name RunState
extends RefCounted
## 一局之内的成长状态（纯逻辑，不依赖场景树，可被单元测试直接验证）。
##
## 职责：记录这一局玩家获得了哪些心法（强化）、攒了多少内力、杀了多少敌人，
## 并把这些累积结果换算成具体的属性倍率，交给 player.gd 应用。
##
## 为什么单独抽成一个类，而不是在 player.gd 里加一堆 var：
##   1. 肉鸽的成长是"跨房间"的，玩家每换一间房都会被重新实例化，
##      状态挂在玩家身上会丢（这是本项目踩过的坑，见 README「换房间之后自动测试突然不动了」）。
##   2. 属性换算（叠层、上限、封顶）是纯算术，写成 RefCounted 才能被单元测试穷举。
##
## AI 协作约定：
##   - 本类不读场景、不发信号、不碰 EventBus，只做数据与算术。
##   - 新增一种效果时，必须同时做三件事：改 effects 的键名、在 stats() 里算进去、
##     在 tests/test_run_state.gd 里补断言。少一步就会变成"看起来加了，实际没生效"。
##   - 上限常量改之前先想清楚：这些值决定"一局能滚到多强"，属于平衡性，不是手感。

# ============================== 数值上限 ==============================
## 伤害加成上限（+200%）。防止无限叠伤把 Boss 变成纸。
const DAMAGE_BONUS_CAP: float = 2.0
## 移速加成上限（+80%）。再高会穿模、跳平台会失控。
const MOVE_BONUS_CAP: float = 0.8
## 吸血比例上限。吸血不封顶会让"站着对砍"变成唯一解。
const LIFESTEAL_CAP: float = 0.5
## 内力获取加成上限（+300%）。
const COIN_BONUS_CAP: float = 3.0

# ============================== 局内数据 ==============================
## 当前持有的内力（货币）。本次只用于展示与后续商店，暂不消耗。
var coins: int = 0
## 累计击杀数。
var kills: int = 0
## 累计清空的房间数。
var rooms_cleared: int = 0

## 每种心法的叠层数：id -> int。
var _stacks: Dictionary = {}
## 每种心法的效果定义：id -> Dictionary，重算总和时用。
var _effects: Dictionary = {}
## 获得顺序，用于 UI 按取得顺序展示。
var _order: Array[String] = []
## 效果总和缓存：key -> float。获得新强化时重算，避免每帧遍历。
var _totals: Dictionary = {}


## 清空成"新的一局"。start_run() 必须调用。
func reset() -> void:
    coins = 0
    kills = 0
    rooms_cleared = 0
    _stacks.clear()
    _effects.clear()
    _order.clear()
    _totals.clear()


# ============================== 收获 ==============================

## 记录一次击杀，并按当前内力加成结算收益。
## @return 实际获得的内力（已乘加成、向下取整，至少 1）
func register_kill(base_coins: int) -> int:
    kills += 1
    var gained := 0
    if base_coins > 0:
        gained = maxi(1, int(round(float(base_coins) * coin_multiplier())))
        coins += gained
    return gained


## 直接加内力（调试、宝箱、结算用）。
func add_coins(amount: int) -> void:
    coins += maxi(0, amount)


## 花钱。内力不足返回 false，且不会扣成负数。
## 负数金额视为调用方写错了，直接拒绝 —— 静默当成"花 0 块"会让价格配置错误查不出来。
func spend_coins(amount: int) -> bool:
    if amount < 0:
        push_warning("[RunState] spend_coins 收到了负数金额 %d，已忽略" % amount)
        return false
    if amount == 0:
        return true
    if coins < amount:
        return false
    coins -= amount
    return true


## 记录清空一间房。
func register_room_cleared() -> void:
    rooms_cleared += 1


# ============================== 心法 ==============================

## 获得一层心法。叠满或数据非法时返回 false。
## @param def data/upgrades.json 里的一条定义（必须含 id / max_stacks / effects）
func take_upgrade(def: Dictionary) -> bool:
    var id := str(def.get("id", ""))
    if id.is_empty():
        push_warning("[RunState] 心法缺少 id，已忽略")
        return false

    var max_stacks := int(def.get("max_stacks", 1))
    if max_stacks <= 0:
        max_stacks = 1
    if stack_count(id) >= max_stacks:
        return false

    _stacks[id] = stack_count(id) + 1
    if not _order.has(id):
        _order.append(id)
    var effects: Variant = def.get("effects", {})
    if effects is Dictionary:
        _effects[id] = (effects as Dictionary).duplicate(true)
    _recalculate_totals()
    return true


## 某种心法当前叠了几层。
func stack_count(id: String) -> int:
    return int(_stacks.get(id, 0))


## 一共获得了多少层心法（跨所有种类）。
func upgrades_taken() -> int:
    var total := 0
    for id in _stacks.keys():
        total += int(_stacks[id])
    return total


## 已获得的心法 id，按取得顺序。
func taken_ids() -> Array[String]:
    return _order.duplicate()


## 某个效果键的当前总和。
func effect_total(key: String) -> float:
    return float(_totals.get(key, 0.0))


# ============================== 属性换算 ==============================

## 伤害倍率（1.0 = 未加成）。直接喂给 Hitbox.attack_multiplier。
func damage_multiplier() -> float:
    return 1.0 + clampf(effect_total("damage_multiplier"), 0.0, DAMAGE_BONUS_CAP)


## 生命上限加成（点数）。
func max_hp_bonus() -> int:
    return maxi(0, int(round(effect_total("max_hp"))))


## 移速倍率（1.0 = 未加成）。
func move_speed_multiplier() -> float:
    return 1.0 + clampf(effect_total("move_speed"), 0.0, MOVE_BONUS_CAP)


## 冲刺冷却减少的帧数。
func dash_cooldown_reduction() -> int:
    return maxi(0, int(round(effect_total("dash_cooldown"))))


## 吸血比例（0.0 ~ LIFESTEAL_CAP）。
func lifesteal() -> float:
    return clampf(effect_total("lifesteal"), 0.0, LIFESTEAL_CAP)


## 内力获取倍率。
func coin_multiplier() -> float:
    return 1.0 + clampf(effect_total("coin_multiplier"), 0.0, COIN_BONUS_CAP)


## 每间房清空后回复的生命值。
func room_heal() -> int:
    return maxi(0, int(round(effect_total("room_heal"))))


## 当前所有属性的一份快照，给 HUD / 调试台 / dump 用。
func stats() -> Dictionary:
    return {
        "damage_multiplier": damage_multiplier(),
        "max_hp_bonus": max_hp_bonus(),
        "move_speed_multiplier": move_speed_multiplier(),
        "dash_cooldown_reduction": dash_cooldown_reduction(),
        "lifesteal": lifesteal(),
        "coin_multiplier": coin_multiplier(),
        "room_heal": room_heal(),
    }


## 一行文字描述当前成长，给 HUD 用。没有强化时返回"尚无"。
func describe_upgrades() -> String:
    if _order.is_empty():
        return "尚无"
    var parts: PackedStringArray = PackedStringArray()
    for id in _order:
        parts.append("%s×%d" % [id, stack_count(id)])
    return "、".join(parts)


## 导出快照。
func snapshot() -> Dictionary:
    return {
        "coins": coins,
        "kills": kills,
        "rooms_cleared": rooms_cleared,
        "stacks": _stacks.duplicate(),
        "stats": stats(),
    }


# ============================== 内部实现 ==============================

## 重算全部效果总和。
## 为什么不"每次取属性时遍历所有心法"：
##   HUD 每帧都会读 stats()，遍历字典在多心法时会变成每帧几十次字典查找。
##   叠层时整表重算一次（心法种类只有十来个，成本可以忽略），之后都是 O(1) 读取。
##
## 为什么是"重算"而不是"累加"：
##   同一颗心法叠两层时，如果每次获得都往 _totals 里累加"定义值 × 层数"，
##   第一层加 1 份、第二层又加 2 份，总和会变成 3 份 —— 叠层数越多错得越离谱。
##   整表重算从根上避免这类错误。
func _recalculate_totals() -> void:
    _totals.clear()
    for id in _effects.keys():
        var effects: Dictionary = _effects[id]
        var stacks := float(stack_count(str(id)))
        for key in effects.keys():
            var value: Variant = effects[key]
            if not (value is float or value is int):
                push_warning("[RunState] 心法「%s」的效果 %s 不是数字，已忽略" % [str(id), str(key)])
                continue
            _totals[key] = float(_totals.get(key, 0.0)) + float(value) * stacks
