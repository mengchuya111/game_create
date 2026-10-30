extends TestCase
## 房间表 × 敌人表的「跨表」校验。
##
## 为什么单独写一个套件：单张表自己都是合法的，错误出在**表与表之间**。
##
## 真实事故（这次就是它）：
##   data/rooms.json 的 COMBAT 模板敌人池是 ["training_dummy", "bandit", "bandit", "bandit"]，
##   arena.gd 的刷怪是 `pool_list[i % pool_list.size()]` 按顺序循环取用 →
##   每间战斗房的第 0 号敌人都是 training_dummy（max_hp 9999，打不死、自动复活）。
##   而清房判定是"所有敌人死亡"，于是**玩家把山贼全砍完也永远等不到开门**。
##
##   当时 205 个单元测试全绿、冒烟测试全绿 —— 因为冒烟测试最后是用
##   `debug_clear_current_room()` 强行清房的，恰好跳过了"真的把敌人打完"这条路径。

const ROOMS_PATH := "res://data/rooms.json"
const ENEMIES_PATH := "res://data/enemies.json"


func _parse(path: String) -> Dictionary:
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        return {}
    var text := file.get_as_text()
    file.close()
    var parsed: Variant = JSON.parse_string(text)
    return parsed if parsed is Dictionary else {}


## 去掉以 _ 开头的注释键（数据表里用 _readme 写说明）。
func _strip_comments(root: Dictionary) -> Dictionary:
    var result := {}
    for key in root.keys():
        if str(key).begins_with("_"):
            continue
        result[key] = root[key]
    return result


# ============================== 真实数据 ==============================

func test_real_data_files_are_parsable() -> void:
    var rooms := _parse(ROOMS_PATH)
    var enemies := _parse(ENEMIES_PATH)
    assert_has(rooms, "templates", "rooms.json 必须有 templates")
    assert_gt(float(enemies.size()), 0.0, "enemies.json 不能为空")


func test_real_templates_are_consistent() -> void:
    var rooms := _parse(ROOMS_PATH)
    var enemies := _parse(ENEMIES_PATH)
    var templates: Variant = rooms.get("templates", {})
    var archetypes := _strip_comments(enemies)

    assert_true(templates is Dictionary, "templates 必须是对象")
    if not (templates is Dictionary):
        return

    var problems: PackedStringArray = RoomDataValidator.validate_templates(templates, archetypes)
    assert_eq(problems.size(), 0, "真实数据不应有跨表问题，实际：%s" % "\n".join(problems))


## 每一间会刷怪的房间，敌人必须真的能被打死。
## 这条是上面那个卡死 bug 的回归守卫：只要有人把 training_dummy 加回任何模板，这里立刻红。
func test_every_spawnable_enemy_can_die() -> void:
    var rooms := _parse(ROOMS_PATH)
    var enemies := _parse(ENEMIES_PATH)
    var templates: Variant = rooms.get("templates", {})
    var archetypes := _strip_comments(enemies)
    if not (templates is Dictionary):
        assert_true(false, "templates 必须是对象")
        return

    for type_name in templates.keys():
        var template: Dictionary = templates[type_name]
        var pool: Variant = template.get("enemies", [])
        if not (pool is Array):
            continue
        for item in (pool as Array):
            var id := str(item)
            var archetype: Variant = archetypes.get(id, {})
            assert_true(archetype is Dictionary, "模板 %s 引用了不存在的原型「%s」" % [type_name, id])
            if not (archetype is Dictionary):
                continue
            var dict: Dictionary = archetype
            assert_false(
                bool(dict.get("immortal", false)),
                "模板 %s 里不能有不死单位「%s」，否则这间房永远清不掉" % [type_name, id]
            )
            assert_lt(
                float(dict.get("max_hp", 0)),
                9000.0,
                "模板 %s 里的「%s」血量高到打不死" % [type_name, id]
            )


## 会反击的敌人必须给内力，否则"打怪 → 攒钱 → 变强"这个循环断了。
func test_defeatable_enemies_reward_coins() -> void:
    var enemies := _parse(ENEMIES_PATH)
    var archetypes := _strip_comments(enemies)
    for id in archetypes.keys():
        var dict: Dictionary = archetypes[id]
        if bool(dict.get("immortal", false)):
            continue
        assert_gt(
            float(dict.get("coin_reward", 0)),
            0.0,
            "原型「%s」打死了却不给内力，经济循环会断" % str(id)
        )


# ============================== 校验器本身 ==============================

func test_detects_immortal_in_pool() -> void:
    var templates := {
        "COMBAT": {"enemies": ["dummy", "bandit"]},
    }
    var archetypes := {
        "dummy": {"max_hp": 9999, "immortal": true},
        "bandit": {"max_hp": 60},
    }
    var problems: PackedStringArray = RoomDataValidator.validate_templates(templates, archetypes)
    assert_eq(problems.size(), 1, "应报出 1 个问题")
    assert_contains(problems[0], "不死单位", "报错要说清是「打不死」这件事")


func test_detects_unknown_archetype() -> void:
    var templates := {"COMBAT": {"enemies": ["nobody"]}}
    var archetypes := {"bandit": {"max_hp": 60}}
    var problems: PackedStringArray = RoomDataValidator.validate_templates(templates, archetypes)
    assert_eq(problems.size(), 1, "应报出 1 个问题")
    assert_contains(problems[0], "不存在", "报错要指出原型不存在")


func test_tolerates_empty_and_malformed() -> void:
    var archetypes := {"bandit": {"max_hp": 60}}
    assert_eq(RoomDataValidator.validate_templates({}, archetypes).size(), 0, "空模板表不算错")
    assert_eq(
        RoomDataValidator.validate_templates({"START": {"enemies": []}}, archetypes).size(),
        0,
        "没敌人的房间不算错"
    )
    assert_eq(
        RoomDataValidator.validate_templates({"BAD": {"enemies": "bandit"}}, archetypes).size(),
        1,
        "enemies 写成字符串应被指出"
    )
