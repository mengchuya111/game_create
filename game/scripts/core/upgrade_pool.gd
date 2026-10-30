class_name UpgradePool
extends RefCounted
## 心法池：加载 data/upgrades.json，校验数据，并按权重抽取三选一。
##
## 为什么"抽卡"必须写成纯逻辑类：
##   肉鸽的随机性直接决定这一局好不好玩，也直接决定 bug 能不能复现。
##   抽卡一旦依赖场景树（比如从中取玩家当前的运气值），就没法在测试里
##   用同一个种子跑一万次来统计稀有度分布。
##
## AI 协作约定：
##   - 随机数一律走 DeterministicRng，禁止 randf / randi / shuffle（见 AGENTS.md 规矩 4）。
##   - 抽取结果必须只依赖 (本局种子, 房间序号, 已获得心法数) 三个输入，
##     不许掺入时间、帧数、对象地址 —— 否则回放同一局会抽到不同的牌。
##   - 新增字段时同步改 validate()，否则错的数据会静默进游戏。

const DEFAULT_PATH := "res://data/upgrades.json"
## 稀有度未知时使用的兜底权重。
const DEFAULT_RARITY_WEIGHT := 1.0
## 抽取种子的混入系数。改动它会让所有老种子的三选一结果变化，慎改。
const SEED_ROOM_FACTOR := 7919
const SEED_TAKEN_FACTOR := 104729
## 商店货架用的盐值系数（见 roll 的 salt 参数）。取一个质数，保证和上面两个不成倍数关系。
const SEED_SALT_FACTOR := 15485863

## 心法定义：id -> Dictionary。
var _defs: Dictionary = {}
## 文件里的顺序，保证抽取结果稳定。
var _order: PackedStringArray = PackedStringArray()
## 稀有度权重。
var _rarity_weights: Dictionary = {}
## 最近一次加载的错误描述（空字符串表示没问题）。
var load_error: String = ""


## 从 JSON 文件加载。返回 OK 或具体错误码。
func load_from_file(path: String = DEFAULT_PATH) -> Error:
    load_error = ""
    if not FileAccess.file_exists(path):
        load_error = "找不到数据文件：%s" % path
        push_error("[UpgradePool] " + load_error)
        return ERR_FILE_NOT_FOUND

    var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
    if not (parsed is Dictionary):
        load_error = "不是合法的 JSON 对象：%s" % path
        push_error("[UpgradePool] " + load_error)
        return ERR_PARSE_ERROR

    load_from_dict(parsed as Dictionary)
    return OK if load_error.is_empty() else ERR_INVALID_DATA


## 从已解析的字典加载。单元测试用这个入口，不需要真实文件。
func load_from_dict(root: Dictionary) -> void:
    load_error = ""
    _defs.clear()
    _order.clear()
    _rarity_weights.clear()

    var weights: Variant = root.get("rarity_weights", {})
    if weights is Dictionary:
        _rarity_weights = (weights as Dictionary).duplicate(true)

    var raw: Variant = root.get("upgrades", {})
    if not (raw is Dictionary):
        load_error = "upgrades 字段不是对象"
        push_error("[UpgradePool] " + load_error)
        return

    var upgrades: Dictionary = raw
    for key in upgrades.keys():
        var id := str(key)
        # 以 _ 开头的键一律当注释（与 attacks.json 的约定一致）
        if id.begins_with("_"):
            continue

        var value: Variant = upgrades[key]
        if not (value is Dictionary):
            load_error = "心法「%s」的定义不是对象" % id
            push_warning("[UpgradePool] " + load_error)
            continue

        var def: Dictionary = (value as Dictionary).duplicate(true)
        def["id"] = id

        var problem := validate(def)
        if not problem.is_empty():
            load_error = problem
            push_warning("[UpgradePool] " + problem)
            continue

        _defs[id] = def
        _order.append(id)


## 校验一条心法定义。返回空字符串表示合法，否则返回问题描述。
## 这条规则和 AttackTable.validate 是同一个思路：数据错误要在加载时喊出来，
## 而不是等到玩家身上出现 NaN 属性再回头查。
static func validate(def: Dictionary) -> String:
    var id := str(def.get("id", ""))
    if id.is_empty():
        return "心法缺少 id"

    if str(def.get("display_name", "")).strip_edges().is_empty():
        return "心法「%s」缺少 display_name" % id

    if str(def.get("rarity", "")).strip_edges().is_empty():
        return "心法「%s」缺少 rarity" % id

    if int(def.get("max_stacks", 0)) < 1:
        return "心法「%s」的 max_stacks 必须 ≥ 1" % id

    var effects: Variant = def.get("effects", {})
    if not (effects is Dictionary):
        return "心法「%s」的 effects 必须是对象" % id
    var effect_dict: Dictionary = effects
    if effect_dict.is_empty():
        return "心法「%s」的 effects 不能为空" % id

    for key in effect_dict.keys():
        var value: Variant = effect_dict[key]
        if not (value is float or value is int):
            return "心法「%s」的效果 %s 必须是数字" % [id, str(key)]

    return ""


func size() -> int:
    return _defs.size()


func ids() -> PackedStringArray:
    return _order.duplicate()


func has_upgrade(id: String) -> bool:
    return _defs.has(id)


## 取一条定义。不存在时返回空字典（不要返回 null，调用方到处判空很容易漏）。
func get_upgrade(id: String) -> Dictionary:
    var value: Variant = _defs.get(id, {})
    return value if value is Dictionary else {}


## 某条心法的稀有度权重。
func rarity_weight(id: String) -> float:
    var def := get_upgrade(id)
    var rarity := str(def.get("rarity", ""))
    return maxf(0.0, float(_rarity_weights.get(rarity, DEFAULT_RARITY_WEIGHT)))


## 抽 count 条不重复的心法给玩家三选一。
## 叠满的、数据非法的自动排除；候选不足时返回实际能给的条数（可能为空）。
## @param run_seed  本局种子
## @param room_index 当前房间序号
## @param state     当前局内状态，用来剔除叠满的心法并参与种子派生
## @param count     想给几个选项
## @param salt      额外盐值。商店货架复刻同一套抽取逻辑，但必须和"奖励三选一"
##                  给出不同的结果 —— 同一个种子 + 同一间房如果两处都抽到同样三条，
##                  玩家就会觉得"商店在卖我刚放弃的那三个"。默认 0 保持原行为。
func roll(
    run_seed: int,
    room_index: int,
    state: RunState,
    count: int = 3,
    salt: int = 0
) -> Array:
    var result: Array = []
    if count <= 0 or _defs.is_empty():
        return result

    var candidates: Array = []
    for id in _order:
        var def := get_upgrade(id)
        if def.is_empty():
            continue
        if state != null and state.stack_count(id) >= int(def.get("max_stacks", 1)):
            continue
        candidates.append({"weight": rarity_weight(id), "value": def})

    if candidates.is_empty():
        return result

    var rng := DeterministicRng.new(_derive_seed(run_seed, room_index, state, salt))

    var take := mini(count, candidates.size())
    for _i in range(take):
        var picked: Variant = rng.weighted_pick(candidates)
        if not (picked is Dictionary):
            break
        result.append(picked)
        _remove_picked(candidates, picked)

    return result


## 派生抽取种子。
## 只混三个数：本局种子、房间序号、已获得心法数。
## 不掺帧数和时间 —— 否则"看回放"和"自动测试"会抽到和当时不同的三选一。
func _derive_seed(run_seed: int, room_index: int, state: RunState, salt: int = 0) -> int:
    var taken := state.upgrades_taken() if state != null else 0
    var mixed := (
        run_seed
        + maxi(0, room_index) * SEED_ROOM_FACTOR
        + taken * SEED_TAKEN_FACTOR
        + salt * SEED_SALT_FACTOR
    )
    return mixed & 0x7FFFFFFF


## 从候选里去掉刚抽中的那条，保证一次三选一里不出现重复项。
func _remove_picked(candidates: Array, picked: Dictionary) -> void:
    var picked_id := str(picked.get("id", ""))
    for i in range(candidates.size() - 1, -1, -1):
        var entry: Variant = candidates[i]
        if not (entry is Dictionary):
            candidates.remove_at(i)
            continue
        var entry_dict: Dictionary = entry
        var value: Variant = entry_dict.get("value", {})
        if value is Dictionary and str((value as Dictionary).get("id", "")) == picked_id:
            candidates.remove_at(i)
