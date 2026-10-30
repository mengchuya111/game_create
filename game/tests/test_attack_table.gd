extends TestCase
## 测试 AttackDef / AttackTable —— 帧数据表。
##
## 这一组测试同时承担一个重要职责：**校验仓库里真实发货的 data/attacks.json**。
## 只要有人（或 AI）把数据改错了，跑一次测试就会立刻报出来是哪一条、错在哪。

const VALID_DATA := {
    "light_1": {
        "id": "light_1",
        "display_name": "轻击·一段",
        "startup": 6,
        "active": 3,
        "recovery": 10,
        "cancel_from": 12,
        "cancel_into": ["light_2"],
        "damage": 8,
        "poise_damage": 6,
        "hitstop": 4,
        "shake": 0.22,
        "knockback": 70.0,
        "move_impulse": 70.0,
        "hitbox_offset": [26, -20],
        "hitbox_size": [40, 30],
    },
    "light_2": {
        "id": "light_2",
        "startup": 5,
        "active": 3,
        "recovery": 11,
        "cancel_from": -1,
        "cancel_into": [],
        "damage": 10,
        "hitstop": 5,
        "hitbox_offset": [28, -22],
        "hitbox_size": [42, 30],
    },
}


func _make_table() -> AttackTable:
    var table := AttackTable.new()
    var err := table.load_from_dict(VALID_DATA.duplicate(true))
    require(err == OK, "测试用的帧数据表应当能加载成功")
    return table


# ============================== 加载与字段 ==============================

func test_load_from_dict_computes_total_frames() -> void:
    var table := _make_table()
    var def := table.get_attack("light_1")
    require(def != null, "应当能取到 light_1")
    if def == null:
        return
    assert_eq(def.total_frames, 19, "总帧数应当等于 起手6 + 判定3 + 收招10 = 19")


func test_json_array_converts_to_vector2() -> void:
    var table := _make_table()
    var def := table.get_attack("light_1")
    require(def != null, "应当能取到 light_1")
    if def == null:
        return
    assert_eq(def.hitbox_offset, Vector2(26, -20), "JSON 数组应当被转成 Vector2")
    assert_eq(def.hitbox_size, Vector2(40, 30), "判定盒尺寸应当被正确解析")


func test_missing_optional_fields_use_defaults() -> void:
    var table := AttackTable.new()
    var err := table.load_from_dict({"bare": {"startup": 4, "active": 2, "recovery": 4}})
    assert_eq(err, OK, "只给必要字段也应当能加载")
    var def := table.get_attack("bare")
    require(def != null, "应当能取到 bare")
    if def == null:
        return
    assert_eq(def.id, "bare", "没有写 id 时应当用字典的 key 兜底")
    assert_eq(def.damage, 5, "缺失的 damage 应当用默认值 5")
    assert_eq(def.cancel_from, -1, "缺失的 cancel_from 应当默认不可取消")


func test_missing_id_falls_back_to_key() -> void:
    var table := AttackTable.new()
    table.load_from_dict({"my_attack": {"startup": 3, "active": 2, "recovery": 3}})
    assert_true(table.has_attack("my_attack"), "字典 key 应当被当作招式 id")


# ============================== 阶段判定 ==============================

func test_phase_at_boundaries() -> void:
    var table := _make_table()
    var def := table.get_attack("light_1")
    require(def != null, "应当能取到 light_1")
    if def == null:
        return

    assert_eq(def.phase_at(0), "startup", "第 0 帧应当是起手")
    assert_eq(def.phase_at(5), "startup", "第 5 帧仍然是起手（起手共 6 帧：0~5）")
    assert_eq(def.phase_at(6), "active", "第 6 帧应当是判定的第一帧")
    assert_eq(def.phase_at(8), "active", "第 8 帧是判定的最后一帧")
    assert_eq(def.phase_at(9), "recovery", "第 9 帧进入收招")
    assert_eq(def.phase_at(18), "recovery", "第 18 帧是收招的最后一帧")
    assert_eq(def.phase_at(19), "end", "第 19 帧招式已经结束")


func test_is_active_frame() -> void:
    var table := _make_table()
    var def := table.get_attack("light_1")
    require(def != null, "应当能取到 light_1")
    if def == null:
        return

    assert_false(def.is_active_frame(5), "第 5 帧还没到判定")
    assert_true(def.is_active_frame(6), "第 6 帧判定开始")
    assert_true(def.is_active_frame(7), "第 7 帧在判定中")
    assert_true(def.is_active_frame(8), "第 8 帧判定结束")
    assert_false(def.is_active_frame(9), "第 9 帧判定已经关闭")


func test_can_cancel_at() -> void:
    var table := _make_table()
    var def := table.get_attack("light_1")
    require(def != null, "应当能取到 light_1")
    if def == null:
        return

    assert_false(def.can_cancel_at(11), "第 11 帧还没进取消窗口")
    assert_true(def.can_cancel_at(12), "第 12 帧进入取消窗口")
    assert_true(def.can_cancel_at(18), "收招最后一帧仍可取消")
    assert_false(def.can_cancel_at(19), "招式结束后不再是取消窗口")


func test_no_cancel_when_cancel_from_is_negative() -> void:
    var table := _make_table()
    var def := table.get_attack("light_2")
    require(def != null, "应当能取到 light_2")
    if def == null:
        return
    for frame in range(30):
        if def.can_cancel_at(frame):
            assert_true(false, "cancel_from = -1 的招式在任何帧都不应该可取消（第 %d 帧却可以）" % frame)
            return
    assert_true(true, "不可取消的招式全程都没有取消窗口")


func test_is_finished_at() -> void:
    var table := _make_table()
    var def := table.get_attack("light_1")
    require(def != null, "应当能取到 light_1")
    if def == null:
        return
    assert_false(def.is_finished_at(18), "第 18 帧还没打完")
    assert_true(def.is_finished_at(19), "第 19 帧打完了")


func test_hitbox_offset_flips_with_facing() -> void:
    var table := _make_table()
    var def := table.get_attack("light_1")
    require(def != null, "应当能取到 light_1")
    if def == null:
        return
    assert_eq(def.hitbox_offset_for_facing(1), Vector2(26, -20), "朝右时判定盒在右边")
    assert_eq(def.hitbox_offset_for_facing(-1), Vector2(-26, -20), "朝左时判定盒应当镜像到左边，y 不变")


# ============================== 校验 ==============================

func test_validate_rejects_zero_active_frames() -> void:
    var bad := AttackDef.from_dict({"id": "bad", "startup": 3, "active": 0, "recovery": 3})
    var problem := AttackTable.validate(bad)
    assert_true(problem.contains("active"), "active = 0 的招式应当被拒绝，并指出是 active 有问题")


func test_validate_rejects_negative_startup() -> void:
    var bad := AttackDef.from_dict({"id": "bad", "startup": -1, "active": 3, "recovery": 3})
    assert_true(AttackTable.validate(bad).contains("startup"), "负数起手帧应当被拒绝")


func test_validate_rejects_cancel_window_beyond_total() -> void:
    var bad := AttackDef.from_dict({
        "id": "bad", "startup": 3, "active": 3, "recovery": 3,
        "cancel_from": 99, "cancel_into": ["x"],
    })
    var problem := AttackTable.validate(bad)
    assert_true(problem.contains("cancel_from"), "取消窗口超过总帧数应当被拒绝（这个窗口永远不会触发）")


func test_validate_rejects_self_cancel() -> void:
    var bad := AttackDef.from_dict({
        "id": "loop", "startup": 3, "active": 3, "recovery": 3,
        "cancel_from": 6, "cancel_into": ["loop"],
    })
    var problem := AttackTable.validate(bad)
    assert_true(problem.contains("自己"), "指向自己的取消会造成无限连段，应当被拒绝")


func test_load_reports_invalid_entry() -> void:
    var table := AttackTable.new()
    var err := table.load_from_dict({"broken": {"id": "broken", "startup": 1, "active": 0, "recovery": 1}})
    assert_eq(err, ERR_INVALID_DATA, "数据非法时 load_from_dict 应当返回错误码，而不是静默忽略")


func test_load_rejects_non_dictionary_entry() -> void:
    var table := AttackTable.new()
    var err := table.load_from_dict({"oops": 123})
    assert_eq(err, ERR_INVALID_DATA, "条目不是对象时应当报错")


func test_load_rejects_empty_table() -> void:
    var table := AttackTable.new()
    var err := table.load_from_dict({})
    assert_eq(err, ERR_INVALID_DATA, "一条有效招式都没有时应当报错")


# ============================== 连段图 ==============================

func test_find_broken_cancel_targets() -> void:
    var table := AttackTable.new()
    table.load_from_dict({
        "a": {"startup": 3, "active": 2, "recovery": 3, "cancel_from": 5, "cancel_into": ["not_exist"]},
    })
    var problems := table.find_broken_cancel_targets()
    assert_eq(problems.size(), 1, "应当检测出 1 个断掉的连段引用")
    if problems.size() == 1:
        assert_contains(problems[0], "not_exist", "报错信息里应当指出缺失的招式 id")


func test_reachable_from_follows_chain() -> void:
    var table := AttackTable.new()
    table.load_from_dict({
        "a": {"startup": 3, "active": 2, "recovery": 3, "cancel_from": 5, "cancel_into": ["b"]},
        "b": {"startup": 3, "active": 2, "recovery": 3, "cancel_from": 5, "cancel_into": ["c"]},
        "c": {"startup": 3, "active": 2, "recovery": 3},
    })
    var reachable := table.reachable_from("a")
    assert_eq(reachable.size(), 3, "从 a 出发应当能到达 a/b/c 三招")
    assert_has(reachable, "a", "可达集合应当包含起点自身")
    assert_has(reachable, "b", "可达集合应当包含 b")
    assert_has(reachable, "c", "可达集合应当包含 c")


func test_reachable_from_unknown_returns_empty() -> void:
    var table := _make_table()
    assert_eq(table.reachable_from("不存在").size(), 0, "起点不存在时应当返回空集合")


func test_ids_are_sorted() -> void:
    var table := _make_table()
    var ids := table.ids()
    assert_eq(ids.size(), 2, "应当有 2 个招式")
    assert_eq(ids[0], "light_1", "id 列表应当排好序，便于阅读和比对")


# ============================== 真实数据文件 ==============================

func test_shipped_data_file_loads() -> void:
    var table := AttackTable.new()
    var err := table.load_from_file("res://data/attacks.json")
    assert_eq(err, OK, "仓库里的 data/attacks.json 必须能成功加载")
    assert_gt(float(table.size()), 0.0, "发货的帧数据表不能是空的")


func test_shipped_data_passes_validation() -> void:
    var table := AttackTable.new()
    if table.load_from_file("res://data/attacks.json") != OK:
        require(false, "帧数据表加载失败，后面的校验没有意义")
        return

    for attack_id in table.ids():
        var def := table.get_attack(attack_id)
        if def == null:
            continue
        var problem := AttackTable.validate(def)
        assert_eq(problem, "", "招式「%s」的数据不合法：%s" % [attack_id, problem])


func test_shipped_data_has_no_broken_cancel_targets() -> void:
    var table := AttackTable.new()
    if table.load_from_file("res://data/attacks.json") != OK:
        require(false, "帧数据表加载失败")
        return
    var problems := table.find_broken_cancel_targets()
    for problem in problems:
        assert_true(false, "连段引用断链：" + problem)
    if problems.is_empty():
        assert_true(true, "所有 cancel_into 都指向存在的招式")


func test_shipped_light_combo_is_fully_connected() -> void:
    var table := AttackTable.new()
    if table.load_from_file("res://data/attacks.json") != OK:
        require(false, "帧数据表加载失败")
        return
    if not table.has_attack("light_1"):
        require(false, "发货数据里应当有 light_1 这个起手招式")
        return

    var reachable := table.reachable_from("light_1")
    assert_ge(float(reachable.size()), 3.0, "从 light_1 出发应当能连出至少 3 段（实际 %d 段）" % reachable.size())


func test_shipped_data_missing_file_returns_error() -> void:
    var table := AttackTable.new()
    var err := table.load_from_file("res://data/这个文件不存在.json")
    assert_eq(err, ERR_FILE_NOT_FOUND, "文件不存在时应当返回明确的错误码，而不是崩溃")
