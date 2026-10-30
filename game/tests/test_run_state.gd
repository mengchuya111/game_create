extends TestCase
## RunState（局内成长）的单元测试。
##
## 这个类决定了"玩家越打越强"这件事到底有没有生效。
## 属性换算写错的表现非常隐蔽 —— 游戏照样能玩，只是心法拿了没用，
## 或者叠两层心法直接变成三倍效果。所以这里把叠层、上限、封顶逐条钉死。

const BLADE := {
    "id": "blade_edge",
    "display_name": "刀法精进",
    "rarity": "common",
    "max_stacks": 5,
    "effects": {"damage_multiplier": 0.15},
}

const IRON := {
    "id": "iron_body",
    "display_name": "铁布衫",
    "rarity": "common",
    "max_stacks": 5,
    "effects": {"max_hp": 20},
}


# ============================== 初始状态 ==============================

func test_new_run_has_no_bonus() -> void:
    var state := RunState.new()
    assert_eq(state.coins, 0, "新开一局内力应为 0")
    assert_eq(state.kills, 0, "新开一局击杀应为 0")
    assert_eq(state.upgrades_taken(), 0, "新开一局不应有任何心法")
    assert_almost_eq(state.damage_multiplier(), 1.0, 0.0001, "未加成时伤害倍率应为 1.0")
    assert_almost_eq(state.move_speed_multiplier(), 1.0, 0.0001, "未加成时移速倍率应为 1.0")
    assert_almost_eq(state.lifesteal(), 0.0, 0.0001, "未加成时吸血应为 0")
    assert_eq(state.max_hp_bonus(), 0, "未加成时生命上限加成为 0")
    assert_eq(state.describe_upgrades(), "尚无", "没有心法时描述应为「尚无」")


func test_reset_clears_everything() -> void:
    var state := RunState.new()
    state.take_upgrade(BLADE)
    state.add_coins(50)
    state.register_kill(3)
    state.register_room_cleared()
    state.reset()

    assert_eq(state.upgrades_taken(), 0, "reset 后心法应清空")
    assert_eq(state.coins, 0, "reset 后内力应清空")
    assert_eq(state.kills, 0, "reset 后击杀应清零")
    assert_eq(state.rooms_cleared, 0, "reset 后房间计数应清零")
    assert_almost_eq(state.damage_multiplier(), 1.0, 0.0001, "reset 后伤害倍率应回到 1.0")


# ============================== 叠层 ==============================

func test_stack_accumulates_effect() -> void:
    var state := RunState.new()
    assert_true(state.take_upgrade(BLADE), "第一次获得应成功")
    assert_almost_eq(state.damage_multiplier(), 1.15, 0.0001, "一层刀法应为 +15%")

    assert_true(state.take_upgrade(BLADE), "第二次获得应成功")
    assert_eq(state.stack_count("blade_edge"), 2, "应叠到 2 层")
    # 这条断言专门防"每获得一层就把之前的总和再累加一遍"的写法：
    # 那种写法下两层会得到 1 + 0.15 + 0.30 = 1.45，而正确值是 1.30。
    assert_almost_eq(state.damage_multiplier(), 1.30, 0.0001, "两层刀法应为 +30%，不是 +45%")


func test_max_stacks_is_enforced() -> void:
    var state := RunState.new()
    var small := {
        "id": "limited",
        "display_name": "限量心法",
        "rarity": "rare",
        "max_stacks": 2,
        "effects": {"max_hp": 10},
    }
    assert_true(state.take_upgrade(small), "第一层应成功")
    assert_true(state.take_upgrade(small), "第二层应成功")
    assert_false(state.take_upgrade(small), "第三层应被拒绝（已叠满）")
    assert_eq(state.stack_count("limited"), 2, "叠满后层数不应增加")
    assert_eq(state.max_hp_bonus(), 20, "叠满后加成应为 2×10，不能继续涨")


func test_missing_id_is_rejected() -> void:
    var state := RunState.new()
    assert_false(state.take_upgrade({}), "没有 id 的心法应被拒绝")
    assert_false(state.take_upgrade({"max_stacks": 1, "effects": {"max_hp": 10}}), "没有 id 时应拒绝")
    assert_eq(state.upgrades_taken(), 0, "非法数据不应污染状态")


func test_multiple_effects_on_one_upgrade() -> void:
    var state := RunState.new()
    var hybrid := {
        "id": "vajra_body",
        "display_name": "金刚不坏",
        "rarity": "epic",
        "max_stacks": 2,
        "effects": {"max_hp": 40, "damage_multiplier": 0.10},
    }
    state.take_upgrade(hybrid)
    assert_eq(state.max_hp_bonus(), 40, "复合心法的生命加成应生效")
    assert_almost_eq(state.damage_multiplier(), 1.10, 0.0001, "复合心法的伤害加成应生效")


# ============================== 封顶 ==============================

func test_damage_bonus_is_capped() -> void:
    var state := RunState.new()
    var huge := {
        "id": "huge",
        "display_name": "离谱心法",
        "rarity": "epic",
        "max_stacks": 10,
        "effects": {"damage_multiplier": 1.0},
    }
    for _i in range(10):
        state.take_upgrade(huge)
    assert_almost_eq(
        state.damage_multiplier(),
        1.0 + RunState.DAMAGE_BONUS_CAP,
        0.0001,
        "伤害加成必须被封顶拦住（上限 +%d%%）" % int(RunState.DAMAGE_BONUS_CAP * 100.0)
    )


func test_lifesteal_is_capped() -> void:
    var state := RunState.new()
    var drain := {
        "id": "drain",
        "display_name": "吸血",
        "rarity": "rare",
        "max_stacks": 20,
        "effects": {"lifesteal": 0.1},
    }
    for _i in range(10):
        state.take_upgrade(drain)
    assert_almost_eq(state.lifesteal(), RunState.LIFESTEAL_CAP, 0.0001, "吸血比例必须封顶")


func test_move_speed_is_capped() -> void:
    var state := RunState.new()
    var fast := {
        "id": "fast",
        "display_name": "疾行",
        "rarity": "rare",
        "max_stacks": 10,
        "effects": {"move_speed": 0.2},
    }
    for _i in range(10):
        state.take_upgrade(fast)
    assert_almost_eq(
        state.move_speed_multiplier(),
        1.0 + RunState.MOVE_BONUS_CAP,
        0.0001,
        "移速加成必须封顶，否则角色会跳穿平台"
    )


# ============================== 内力 ==============================

func test_kill_reward_uses_coin_multiplier() -> void:
    var state := RunState.new()
    assert_eq(state.register_kill(3), 3, "无加成时击杀 3 内力应拿 3")

    var greedy := {
        "id": "lucky_coin",
        "display_name": "财运",
        "rarity": "common",
        "max_stacks": 2,
        "effects": {"coin_multiplier": 0.5},
    }
    state.take_upgrade(greedy)
    state.take_upgrade(greedy)
    assert_almost_eq(state.coin_multiplier(), 2.0, 0.0001, "两层财运应让内力翻倍")
    assert_eq(state.register_kill(3), 6, "翻倍后击杀 3 内力应拿 6")
    assert_eq(state.coins, 9, "内力应累计（3 + 6）")
    assert_eq(state.kills, 2, "击杀数应累计")


func test_zero_reward_kill_does_not_give_coins() -> void:
    var state := RunState.new()
    assert_eq(state.register_kill(0), 0, "内力为 0 的敌人不应给钱（训练木桩靠这条防刷）")
    assert_eq(state.coins, 0, "内力不应变化")
    assert_eq(state.kills, 1, "击杀数仍然要记")


func test_spend_coins_never_goes_negative() -> void:
    var state := RunState.new()
    state.add_coins(10)
    assert_true(state.spend_coins(4), "内力足够时应花费成功")
    assert_eq(state.coins, 6, "应剩 6")
    assert_false(state.spend_coins(100), "内力不足时应失败")
    assert_eq(state.coins, 6, "失败时不应扣钱")
    assert_false(state.spend_coins(-5), "负数花费应被视为非法")
    assert_eq(state.coins, 6, "非法花费不应改数值")


# ============================== 快照 ==============================

func test_snapshot_contains_stats() -> void:
    var state := RunState.new()
    state.take_upgrade(BLADE)
    state.take_upgrade(IRON)
    state.add_coins(7)
    state.register_kill(3)

    var snap := state.snapshot()
    assert_has(snap, "coins", "快照应有内力")
    assert_has(snap, "kills", "快照应有击杀数")
    assert_has(snap, "stats", "快照应有属性")
    assert_eq(int(snap["coins"]), 10, "内力应为 7+3")

    var stats: Dictionary = snap["stats"]
    assert_almost_eq(float(stats["damage_multiplier"]), 1.15, 0.0001, "快照里的伤害倍率应正确")
    assert_eq(int(stats["max_hp_bonus"]), 20, "快照里的生命加成应正确")


func test_describe_upgrades_lists_stacks() -> void:
    var state := RunState.new()
    state.take_upgrade(BLADE)
    state.take_upgrade(BLADE)
    assert_contains(state.describe_upgrades(), "blade_edge×2", "描述里应包含心法 id 和层数")
