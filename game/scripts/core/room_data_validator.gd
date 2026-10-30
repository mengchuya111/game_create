class_name RoomDataValidator
extends RefCounted
## 房间模板 × 敌人表的跨表校验（纯逻辑，不依赖场景树 / 自动单例）。
##
## 为什么单独一个文件，而不是写在 arena.gd 里：
##   1. arena.gd 是 Node2D，`preload` 它会连带编译 hitbox / hurtbox 一整串依赖，
##      在单元测试（--script 模式，没有 EventBus 自动单例）里直接编译失败；
##   2. 这条校验是纯数据规则，测试必须能在不挂场景树的情况下喂假数据进来。
##
## 它守的是一个真实事故：COMBAT 模板的敌人池第一位是 training_dummy（打不死的木桩），
## 刷怪按 `pool[i % size]` 顺序取用 → 每间战斗房都有一个永久木桩 →
## 清房判定（所有敌人死亡）永远不成立 → 玩家把山贼砍完也等不到开门，整局卡死。

const MIN_SANE_HP := 9000


## 校验模板表与敌人表是否自洽。
## @return 问题描述列表；空数组表示没问题。
static func validate_templates(templates: Dictionary, archetypes: Dictionary) -> PackedStringArray:
    var problems := PackedStringArray()

    for type_name in templates.keys():
        var template: Variant = templates[type_name]
        if not (template is Dictionary):
            problems.append("模板 %s 不是对象" % str(type_name))
            continue

        var pool: Variant = (template as Dictionary).get("enemies", [])
        if not (pool is Array):
            problems.append("模板 %s 的 enemies 不是数组" % str(type_name))
            continue

        for item in (pool as Array):
            problems.append_array(_check_entry(str(type_name), str(item), archetypes))

    return problems


## 单个原型 id 的检查。拆出来是为了让报错信息集中在一处。
static func _check_entry(type_name: String, id: String, archetypes: Dictionary) -> PackedStringArray:
    var problems := PackedStringArray()

    if not archetypes.has(id):
        problems.append("模板 %s 引用了不存在的敌人原型「%s」" % [type_name, id])
        return problems

    var archetype: Variant = archetypes[id]
    if not (archetype is Dictionary):
        problems.append("敌人原型「%s」不是对象" % id)
        return problems

    var dict: Dictionary = archetype
    if bool(dict.get("immortal", false)):
        problems.append("模板 %s 的敌人池里有不死单位「%s」，这间房永远清不掉" % [type_name, id])
    elif float(dict.get("max_hp", 0)) >= float(MIN_SANE_HP):
        problems.append("模板 %s 的敌人「%s」血量 %d 高到打不死，这间房大概率清不掉" % [
            type_name, id, int(dict.get("max_hp", 0))
        ])

    return problems
