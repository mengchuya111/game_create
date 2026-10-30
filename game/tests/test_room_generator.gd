extends TestCase
## 测试 RoomGenerator —— 房间路线生成。
##
## 肉鸽的"关卡"是生成的，所以它必须满足一堆硬性规则：
## 有起点、有首领、所有房间可达、商店不扎堆、非战斗房不刷怪。
## 这些规则一旦破了，玩家会走到一个走不出去的地图 —— 这是最难受的 bug 之一。


func test_generate_is_deterministic() -> void:
    var a := RoomGenerator.generate(12345, 8, 1.0)
    var b := RoomGenerator.generate(12345, 8, 1.0)
    assert_eq(RoomGenerator.type_sequence(a), RoomGenerator.type_sequence(b), "同一种子必须产出完全相同的路线")
    assert_eq(RoomGenerator.describe(a), RoomGenerator.describe(b), "路线描述也应当一致")


func test_different_seeds_give_varied_routes() -> void:
    var seen: Dictionary = {}
    for seed_value in range(1, 40):
        var rooms := RoomGenerator.generate(seed_value, 10, 1.0)
        seen[RoomGenerator.describe(rooms)] = true
    assert_gt(float(seen.size()), 3.0, "不同种子应当产出多种不同路线（实际 %d 种）" % seen.size())


func test_route_starts_with_start_and_ends_with_boss() -> void:
    for seed_value in [1, 2, 3, 100, 999, 20240501]:
        var rooms := RoomGenerator.generate(seed_value, 8, 1.0)
        assert_eq(
            int(rooms[0]["type"]), RoomGenerator.RoomType.START,
            "种子 %d：第一个房间必须是起点" % seed_value
        )
        assert_eq(
            int(rooms[rooms.size() - 1]["type"]), RoomGenerator.RoomType.BOSS,
            "种子 %d：最后一个房间必须是首领房" % seed_value
        )


func test_room_count_is_respected() -> void:
    for count in [3, 5, 8, 12]:
        var rooms := RoomGenerator.generate(42, count, 1.0)
        assert_eq(rooms.size(), count, "应当生成 %d 个房间" % count)


func test_minimum_room_count_is_enforced() -> void:
    var rooms := RoomGenerator.generate(42, 1, 1.0)
    assert_ge(float(rooms.size()), 3.0, "房间数少于 3 时应当被抬到 3（起点 + 中间 + 首领）")


func test_room_ids_are_unique() -> void:
    var rooms := RoomGenerator.generate(31, 12, 1.0)
    var ids: Dictionary = {}
    for room in rooms:
        ids[room["id"]] = true
    assert_eq(ids.size(), rooms.size(), "每个房间的 id 必须唯一")


func test_generated_routes_pass_validation() -> void:
    for seed_value in range(1, 30):
        var rooms := RoomGenerator.generate(seed_value, 8, 1.0)
        var problems := RoomGenerator.validate(rooms)
        for problem in problems:
            assert_true(false, "种子 %d 的路线不合法：%s" % [seed_value, problem])


func test_all_rooms_are_reachable() -> void:
    for seed_value in range(1, 20):
        var rooms := RoomGenerator.generate(seed_value, 10, 1.0)
        var unreachable := false
        for problem in RoomGenerator.validate(rooms):
            if problem.contains("不可达"):
                unreachable = true
        assert_false(unreachable, "种子 %d 存在从起点走不到的房间" % seed_value)


func test_linear_route_connects_neighbours() -> void:
    var rooms := RoomGenerator.generate(7, 6, 1.0)
    for i in range(rooms.size()):
        if i + 1 < rooms.size():
            assert_eq(rooms[i]["next"], [rooms[i + 1]["id"]], "第 %d 个房间的出口应当指向下一个" % i)
        if i > 0:
            assert_eq(rooms[i]["prev"], [rooms[i - 1]["id"]], "第 %d 个房间的入口应当指向上一个" % i)
        if i == 0:
            assert_eq(rooms[i]["prev"].size(), 0, "起点不应该有入口")
        if i == rooms.size() - 1:
            assert_eq(rooms[i]["next"].size(), 0, "首领房不应该有出口")


func test_no_consecutive_shops() -> void:
    for seed_value in range(1, 60):
        var rooms := RoomGenerator.generate(seed_value, 10, 1.0)
        for i in range(1, rooms.size()):
            var both_shop := (
                int(rooms[i]["type"]) == RoomGenerator.RoomType.SHOP
                and int(rooms[i - 1]["type"]) == RoomGenerator.RoomType.SHOP
            )
            assert_false(both_shop, "种子 %d 出现了连续两间商店" % seed_value)


func test_first_middle_room_is_combat() -> void:
    for seed_value in range(1, 40):
        var rooms := RoomGenerator.generate(seed_value, 8, 1.0)
        assert_eq(
            int(rooms[1]["type"]), RoomGenerator.RoomType.COMBAT,
            "种子 %d：第一间中间房应当是普通战斗，给玩家一点开局缓冲" % seed_value
        )


func test_at_most_one_shop_per_floor() -> void:
    for seed_value in range(1, 60):
        var rooms := RoomGenerator.generate(seed_value, 12, 1.0)
        var shop_count := 0
        for room in rooms:
            if int(room["type"]) == RoomGenerator.RoomType.SHOP:
                shop_count += 1
        assert_le(float(shop_count), 1.0, "种子 %d 出现了 %d 间商店，一层最多一间" % [seed_value, shop_count])


func test_non_combat_rooms_have_no_enemies() -> void:
    var rooms := RoomGenerator.generate(11, 10, 1.0)
    for room in rooms:
        var room_type := int(room["type"])
        var peaceful := (
            room_type == RoomGenerator.RoomType.START
            or room_type == RoomGenerator.RoomType.TREASURE
            or room_type == RoomGenerator.RoomType.SHOP
        )
        if peaceful:
            assert_eq(int(room["enemy_budget"]), 0, "非战斗房间（%s）不应该有敌人预算" % room["type_name"])


func test_enemy_budget_scales_with_difficulty() -> void:
    var easy := RoomGenerator.generate(5, 10, 1.0)
    var hard := RoomGenerator.generate(5, 10, 2.0)
    var compared := 0
    for i in range(easy.size()):
        if int(easy[i]["type"]) != int(hard[i]["type"]):
            continue
        compared += 1
        assert_ge(
            float(int(hard[i]["enemy_budget"])), float(int(easy[i]["enemy_budget"])),
            "同类型房间在难度 2.0 下的敌人预算不应低于难度 1.0（第 %d 间）" % i
        )
    assert_gt(float(compared), 0.0, "应当至少有一间同类型房间可以比较")


func test_difficulty_is_recorded_in_rooms() -> void:
    var rooms := RoomGenerator.generate(3, 6, 1.5)
    for room in rooms:
        assert_almost_eq(float(room["difficulty"]), 1.5, 0.0001, "难度系数应当写进每个房间数据里")


func test_room_indices_are_sequential() -> void:
    var rooms := RoomGenerator.generate(3, 7, 1.0)
    for i in range(rooms.size()):
        assert_eq(int(rooms[i]["index"]), i, "房间序号应当是连续的，从 0 开始")


# ============================== 校验函数的健壮性 ==============================

func test_validate_empty_route() -> void:
    var problems := RoomGenerator.validate([])
    assert_eq(problems.size(), 1, "空路线应当报出 1 个问题")


func test_validate_detects_bad_next_target() -> void:
    var rooms := RoomGenerator.generate(1, 6, 1.0)
    rooms[0]["next"].append("ghost_room")
    var found := false
    for problem in RoomGenerator.validate(rooms):
        if problem.contains("ghost_room"):
            found = true
    assert_true(found, "校验应当能发现指向不存在房间的出口")


func test_validate_detects_bad_prev_target() -> void:
    var rooms := RoomGenerator.generate(1, 6, 1.0)
    rooms[2]["prev"].append("ghost_room")
    var found := false
    for problem in RoomGenerator.validate(rooms):
        if problem.contains("ghost_room"):
            found = true
    assert_true(found, "校验应当能发现指向不存在房间的入口")


func test_validate_detects_wrong_first_room() -> void:
    var rooms := RoomGenerator.generate(1, 6, 1.0)
    rooms[0]["type"] = RoomGenerator.RoomType.COMBAT
    rooms[0]["type_name"] = "COMBAT"
    var found := false
    for problem in RoomGenerator.validate(rooms):
        if problem.contains("START"):
            found = true
    assert_true(found, "校验应当能发现第一个房间不是起点")


func test_validate_detects_wrong_last_room() -> void:
    var rooms := RoomGenerator.generate(1, 6, 1.0)
    rooms[rooms.size() - 1]["type"] = RoomGenerator.RoomType.COMBAT
    rooms[rooms.size() - 1]["type_name"] = "COMBAT"
    var found := false
    for problem in RoomGenerator.validate(rooms):
        if problem.contains("BOSS"):
            found = true
    assert_true(found, "校验应当能发现最后一个房间不是首领房")


func test_validate_detects_unreachable_room() -> void:
    var rooms := RoomGenerator.generate(1, 6, 1.0)
    # 把最后一个房间从链上摘下来，它应当变得不可达
    rooms[rooms.size() - 2]["next"] = []
    var found := false
    for problem in RoomGenerator.validate(rooms):
        if problem.contains("不可达"):
            found = true
    assert_true(found, "校验应当能发现被摘出链外的房间")


# ============================== 输出格式 ==============================

func test_describe_is_readable() -> void:
    var rooms := RoomGenerator.generate(1, 5, 1.0)
    var text := RoomGenerator.describe(rooms)
    assert_contains(text, "起点", "路线描述应当包含起点")
    assert_contains(text, "首领", "路线描述应当包含首领")
    assert_contains(text, "→", "路线描述应当用箭头连接各房间")


func test_type_sequence_matches_rooms() -> void:
    var rooms := RoomGenerator.generate(8, 7, 1.0)
    var sequence := RoomGenerator.type_sequence(rooms)
    assert_eq(sequence.size(), rooms.size(), "类型序列的长度应当和房间数一致")
    for i in range(rooms.size()):
        assert_eq(sequence[i], int(rooms[i]["type"]), "第 %d 个类型应当对得上" % i)


func test_type_names_are_defined_for_all_types() -> void:
    var all_types := [
        RoomGenerator.RoomType.START,
        RoomGenerator.RoomType.COMBAT,
        RoomGenerator.RoomType.ELITE,
        RoomGenerator.RoomType.TREASURE,
        RoomGenerator.RoomType.SHOP,
        RoomGenerator.RoomType.BOSS,
    ]
    for room_type in all_types:
        assert_has(RoomGenerator.TYPE_NAMES, room_type, "每个房间类型都必须有英文名")
        assert_has(RoomGenerator.TYPE_DISPLAY_NAMES, room_type, "每个房间类型都必须有中文名")
        assert_has(RoomGenerator.ENEMY_BUDGET, room_type, "每个房间类型都必须定义敌人预算")


## 一层必须至少有一间商店。
##
## 商店里卖的就是内力唯一能花出去的东西。如果一层里一间商店都没有，
## "攒内力"这件事就完全没有意义 —— 而商店原本只有 8% 权重，约四成概率一间都不出。
func test_every_run_has_a_shop() -> void:
    for seed_value in [1, 2, 3, 7, 42, 777, 20240501, 999983]:
        var rooms := RoomGenerator.generate(seed_value, 8, 1.0)
        var shop_count := 0
        for room in rooms:
            if int(room["type"]) == RoomGenerator.RoomType.SHOP:
                shop_count += 1
        assert_ge(
            float(shop_count),
            1.0,
            "种子 %d 的一层里一间商店都没有，玩家攒的内力就无处可花" % seed_value
        )
