extends TestCase
## UpgradePool（心法池 / 三选一抽取）的单元测试。
##
## 重点钉三件事：
##   1. 数据校验：写错一条心法不能静默进游戏，否则玩家会拿到一个"什么都不加"的奖励。
##   2. 确定性：同一个种子 + 同一间房必须抽出同样的选项，否则重放和自动测试会失真。
##   3. 排除规则：叠满的心法不能再出现，一次三选一里不能出现两条一样的。

## 一套合法的小样本，四个稀有度不同的心法。
func _valid_root() -> Dictionary:
    return {
        "_readme": ["以 _ 开头的键应被忽略"],
        "rarity_weights": {"common": 100, "rare": 40, "epic": 12},
        "upgrades": {
            "a_blade": {
                "display_name": "刀法精进",
                "description": "伤害 +15%",
                "rarity": "common",
                "max_stacks": 5,
                "effects": {"damage_multiplier": 0.15},
            },
            "b_iron": {
                "display_name": "铁布衫",
                "description": "生命 +20",
                "rarity": "common",
                "max_stacks": 3,
                "effects": {"max_hp": 20},
            },
            "c_qi": {
                "display_name": "行气诀",
                "description": "冲刺冷却 -4 帧",
                "rarity": "rare",
                "max_stacks": 3,
                "effects": {"dash_cooldown": 4},
            },
            "d_vajra": {
                "display_name": "金刚不坏",
                "description": "生命 +40，伤害 +10%",
                "rarity": "epic",
                "max_stacks": 2,
                "effects": {"max_hp": 40, "damage_multiplier": 0.1},
            },
        },
    }


func _make_pool() -> UpgradePool:
    var pool := UpgradePool.new()
    pool.load_from_dict(_valid_root())
    return pool


func _ids(choices: Array) -> Array:
    var result: Array = []
    for item in choices:
        var def: Dictionary = item
        result.append(str(def.get("id", "")))
    return result


# ============================== 加载 ==============================

func test_loads_valid_upgrades() -> void:
    var pool := _make_pool()
    assert_eq(pool.size(), 4, "应加载 4 条心法")
    assert_true(pool.has_upgrade("a_blade"), "应能按 id 找到心法")
    assert_false(pool.has_upgrade("_readme"), "以 _ 开头的键必须被当成注释跳过")
    assert_eq(pool.ids().size(), 4, "ids() 数量应一致")


func test_get_upgrade_returns_dict() -> void:
    var pool := _make_pool()
    var def := pool.get_upgrade("b_iron")
    assert_eq(str(def.get("display_name", "")), "铁布衫", "应取到正确的定义")
    assert_true(pool.get_upgrade("不存在").is_empty(), "不存在的心法应返回空字典而不是 null")


func test_invalid_upgrades_are_skipped() -> void:
    var root := {
        "rarity_weights": {"common": 1},
        "upgrades": {
            "good": {
                "display_name": "好的",
                "rarity": "common",
                "max_stacks": 1,
                "effects": {"max_hp": 10},
            },
            "no_name": {"rarity": "common", "max_stacks": 1, "effects": {"max_hp": 10}},
            "bad_stacks": {"display_name": "层数错", "rarity": "common", "max_stacks": 0, "effects": {"max_hp": 10}},
            "empty_effects": {"display_name": "空效果", "rarity": "common", "max_stacks": 1, "effects": {}},
            "text_effect": {"display_name": "文字效果", "rarity": "common", "max_stacks": 1, "effects": {"max_hp": "很多"}},
            "not_a_dict": "这不是对象",
        },
    }
    var pool := UpgradePool.new()
    pool.load_from_dict(root)

    assert_eq(pool.size(), 1, "只有 1 条合法心法应被加载")
    assert_true(pool.has_upgrade("good"), "合法心法应保留")
    assert_false(pool.has_upgrade("no_name"), "缺 display_name 应被拒绝")
    assert_false(pool.has_upgrade("bad_stacks"), "max_stacks=0 应被拒绝")
    assert_false(pool.has_upgrade("empty_effects"), "空 effects 应被拒绝")
    assert_false(pool.has_upgrade("text_effect"), "效果值不是数字应被拒绝")
    assert_false(pool.has_upgrade("not_a_dict"), "定义不是对象应被拒绝")
    assert_false(pool.load_error.is_empty(), "加载出错时 load_error 应有说明")


func test_validate_messages() -> void:
    var ok_def := {
        "id": "ok", "display_name": "好", "rarity": "common",
        "max_stacks": 1, "effects": {"max_hp": 1},
    }
    assert_eq(UpgradePool.validate(ok_def), "", "合法定义不应报错")
    assert_contains(UpgradePool.validate({
        "id": "x", "display_name": "", "rarity": "common", "max_stacks": 1, "effects": {"max_hp": 1},
    }), "display_name", "缺名字应明确指出")
    assert_contains(UpgradePool.validate({
        "id": "x", "display_name": "x", "rarity": "common", "max_stacks": 1, "effects": {},
    }), "effects", "空效果应明确指出")


# ============================== 抽取 ==============================

func test_roll_returns_requested_count() -> void:
    var pool := _make_pool()
    var state := RunState.new()
    var choices := pool.roll(12345, 1, state, 3)
    assert_eq(choices.size(), 3, "四个候选里应抽出三个")
    assert_eq(_ids(choices).size(), 3, "每条都应有 id")


func test_roll_has_no_duplicates() -> void:
    var pool := _make_pool()
    var state := RunState.new()
    for room in range(40):
        var choices := pool.roll(20240501, room, state, 3)
        var seen: Dictionary = {}
        for id in _ids(choices):
            assert_false(seen.has(id), "第 %d 间房抽出了重复心法：%s" % [room, id])
            seen[id] = true


func test_roll_is_deterministic() -> void:
    var pool := _make_pool()
    var state := RunState.new()
    var first := _ids(pool.roll(777, 3, state, 3))
    var second := _ids(pool.roll(777, 3, state, 3))
    assert_int_array_eq(first, second, "同种子同房间必须抽出完全相同的三选一")
    assert_eq(first.size(), 3, "确定性检查的前提是抽满三个")


func test_roll_changes_with_room_and_seed() -> void:
    var pool := _make_pool()
    var state := RunState.new()

    # 只断言"多次之间至少出现两种结果"，不断言具体值 ——
    # 具体值会随稀有度权重调整而变化，钉太死会让调平衡时测试全红。
    var seen: Dictionary = {}
    for i in range(20):
        seen[",".join(_ids(pool.roll(1000 + i, i, state, 3)))] = true
    assert_gt(float(seen.size()), 1.0, "不同种子/房间应能抽出不同的组合")


func test_maxed_upgrades_are_excluded() -> void:
    var pool := _make_pool()
    var state := RunState.new()

    var a := pool.get_upgrade("a_blade")
    var b := pool.get_upgrade("b_iron")
    var c := pool.get_upgrade("c_qi")
    # 把三条叠满（a 5 层、b 3 层、c 3 层）
    for _i in range(5):
        state.take_upgrade(a)
    for _i in range(3):
        state.take_upgrade(b)
    for _i in range(3):
        state.take_upgrade(c)

    var choices := pool.roll(999, 1, state, 3)
    assert_eq(choices.size(), 1, "只剩一条没叠满时应只给一条")
    assert_int_array_eq(_ids(choices), ["d_vajra"], "剩下的必须是未叠满的那条")


func test_all_maxed_returns_empty() -> void:
    var pool := _make_pool()
    var state := RunState.new()
    for id in pool.ids():
        var def := pool.get_upgrade(id)
        var max_stacks := int(def.get("max_stacks", 1))
        for _i in range(max_stacks):
            state.take_upgrade(def)

    assert_eq(pool.roll(1, 1, state, 3).size(), 0, "全部叠满时应返回空，而不是硬塞重复项")


func test_roll_count_larger_than_candidates() -> void:
    var pool := _make_pool()
    var state := RunState.new()
    var choices := pool.roll(5, 1, state, 10)
    assert_eq(choices.size(), 4, "要 10 条但只有 4 条候选时，应返回全部 4 条")


func test_empty_pool_returns_empty() -> void:
    var pool := UpgradePool.new()
    pool.load_from_dict({"upgrades": {}})
    assert_eq(pool.size(), 0, "空表应加载 0 条")
    assert_eq(pool.roll(1, 1, RunState.new(), 3).size(), 0, "空表抽取应返回空数组，不能崩")


func test_rarity_weight_reads_from_data() -> void:
    var pool := _make_pool()
    assert_almost_eq(pool.rarity_weight("a_blade"), 100.0, 0.0001, "common 权重应来自数据表")
    assert_almost_eq(pool.rarity_weight("c_qi"), 40.0, 0.0001, "rare 权重应来自数据表")
    assert_almost_eq(pool.rarity_weight("d_vajra"), 12.0, 0.0001, "epic 权重应来自数据表")
    assert_almost_eq(pool.rarity_weight("不存在"), 1.0, 0.0001, "未知心法应退回兜底权重")


# ============================== 真实数据 ==============================

func test_shipped_upgrade_data_is_valid() -> void:
    var pool := UpgradePool.new()
    var err := pool.load_from_file()
    assert_eq(err, OK, "data/upgrades.json 必须能加载，错误：%s" % pool.load_error)
    assert_gt(float(pool.size()), 5.0, "实际数据里至少应有 6 条心法")

    for id in pool.ids():
        var def := pool.get_upgrade(id)
        assert_eq(UpgradePool.validate(def), "", "数据表里的「%s」应通过校验" % id)
        var effects: Dictionary = def.get("effects", {})
        for key in effects.keys():
            var known := [
                "damage_multiplier", "max_hp", "move_speed", "dash_cooldown",
                "lifesteal", "coin_multiplier", "room_heal",
            ]
            assert_has(known, str(key), "「%s」用了未实现的效果键 %s（RunState 不会读它）" % [id, str(key)])
