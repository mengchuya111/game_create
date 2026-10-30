class_name AttackTable
extends RefCounted
## 帧数据表 —— 所有招式的集合，从 data/attacks.json 载入。
##
## 这是「数据驱动」的样板：改招式手感不需要改代码，只改 JSON。
## 策划（包括不会写代码的人）可以直接编辑 data/attacks.json 调数值。
##
## AI 协作约定：
##   - 新增招式只能加在 data/attacks.json 里，不要在代码里 new AttackDef()。
##   - load_from_dict() 会做合法性校验，数据写错会明确报出是哪一条、错在哪。

const DEFAULT_PATH := "res://data/attacks.json"

var _defs: Dictionary = {}
## 最后一次加载的数据文件路径，便于调试台显示。
var source_path: String = ""


## 从 JSON 文件载入。
func load_from_file(path: String = DEFAULT_PATH) -> Error:
    source_path = path

    if not FileAccess.file_exists(path):
        push_error("[AttackTable] 找不到帧数据文件：%s" % path)
        return ERR_FILE_NOT_FOUND

    var text := FileAccess.get_file_as_string(path)
    if text.strip_edges().is_empty():
        push_error("[AttackTable] 帧数据文件为空：%s" % path)
        return ERR_FILE_CANT_READ

    var parsed: Variant = JSON.parse_string(text)
    if not (parsed is Dictionary):
        push_error("[AttackTable] 帧数据文件不是合法的 JSON 对象：%s" % path)
        return ERR_PARSE_ERROR

    var data: Dictionary = parsed
    return load_from_dict(data)


## 从已经解析好的字典载入。单元测试直接用这个，不需要读写文件。
func load_from_dict(data: Dictionary) -> Error:
    _defs.clear()
    var problems: PackedStringArray = PackedStringArray()

    for key in data.keys():
        # 以下划线开头的键是注释 / 说明字段（例如 "_readme"），不是招式数据，直接跳过。
        # 这样数据文件里就能写中文说明，而不会把加载器搞崩。
        if str(key).begins_with("_"):
            continue

        var raw: Variant = data[key]
        if not (raw is Dictionary):
            problems.append("条目「%s」不是一个对象" % key)
            continue

        var entry: Dictionary = (raw as Dictionary).duplicate(true)
        if not entry.has("id"):
            entry["id"] = str(key)

        var def := AttackDef.from_dict(entry)
        if def.id.is_empty():
            def.id = str(key)

        var problem := validate(def)
        if not problem.is_empty():
            problems.append(problem)
            continue

        _defs[def.id] = def

    if not problems.is_empty():
        for p in problems:
            push_error("[AttackTable] 数据有问题：" + p)
        return ERR_INVALID_DATA

    if _defs.is_empty():
        push_error("[AttackTable] 帧数据表里一条有效招式都没有")
        return ERR_INVALID_DATA

    return OK


## 校验单条招式数据是否合法。返回空字符串表示合法，否则返回问题描述。
## 这是给"AI 生成的数据表"兜底的关键：数值配错了要立刻报出来，而不是运行到一半才崩。
static func validate(def: AttackDef) -> String:
    if def.id.is_empty():
        return "存在一条没有 id 的招式"
    if def.startup < 0:
        return "招式「%s」的 startup 不能为负数（当前 %d）" % [def.id, def.startup]
    if def.active <= 0:
        return "招式「%s」的 active 必须大于 0（当前 %d）" % [def.id, def.active]
    if def.recovery < 0:
        return "招式「%s」的 recovery 不能为负数（当前 %d）" % [def.id, def.recovery]
    if def.damage < 0:
        return "招式「%s」的 damage 不能为负数（当前 %d）" % [def.id, def.damage]
    if def.hitstop < 0:
        return "招式「%s」的 hitstop 不能为负数（当前 %d）" % [def.id, def.hitstop]
    if def.cancel_from >= 0 and def.cancel_from > def.total_frames:
        return "招式「%s」的 cancel_from（%d）超过了总帧数（%d），这个取消窗口永远不会触发" % [
            def.id, def.cancel_from, def.total_frames
        ]
    if def.hitbox_size.x <= 0.0 or def.hitbox_size.y <= 0.0:
        return "招式「%s」的判定盒尺寸必须为正数" % def.id
    for target in def.cancel_into:
        if target == def.id:
            return "招式「%s」的 cancel_into 指向了自己，会造成无限连段" % def.id
    return ""


## 取一条招式。找不到返回 null，并打一条警告。
func get_attack(id: String) -> AttackDef:
    if not _defs.has(id):
        push_warning("[AttackTable] 找不到招式：%s" % id)
        return null
    return _defs[id]


## 不做警告的版本，用于"探测是否存在"。
func has_attack(id: String) -> bool:
    return _defs.has(id)


## 所有招式 id。
func ids() -> PackedStringArray:
    var result: PackedStringArray = PackedStringArray()
    for key in _defs.keys():
        result.append(str(key))
    result.sort()
    return result


## 招式数量。
func size() -> int:
    return _defs.size()


## 校验整张表的连段引用是否都指向存在的招式。
## 返回问题列表，空数组表示全部正常。用于单元测试和调试台 check 命令。
func find_broken_cancel_targets() -> PackedStringArray:
    var problems: PackedStringArray = PackedStringArray()
    for key in _defs.keys():
        var def: AttackDef = _defs[key]
        for target in def.cancel_into:
            if not _defs.has(target):
                problems.append("招式「%s」的 cancel_into 指向了不存在的招式「%s」" % [def.id, target])
    return problems


## 从某招出发，按 cancel_into 做广度优先遍历，返回能到达的所有招式 id。
## 用于验证"连段图"没有断链。返回结果包含起点自身。
func reachable_from(start_id: String) -> PackedStringArray:
    var visited: PackedStringArray = PackedStringArray()
    if not _defs.has(start_id):
        return visited

    var queue: Array[String] = [start_id]
    visited.append(start_id)

    while not queue.is_empty():
        var current: String = queue.pop_front()
        var def: AttackDef = _defs[current]
        for target in def.cancel_into:
            if _defs.has(target) and not visited.has(target):
                visited.append(target)
                queue.append(target)

    return visited
