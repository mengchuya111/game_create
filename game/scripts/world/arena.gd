extends Node2D
## 房间 / 竞技场。
##
## 骨架阶段用代码生成矩形平台，而不是 TileMapLayer —— 原因是：
##   TileMap 需要一个 TileSet 资源，而 TileSet 需要美术切好的图。
##   在还没有美术资源的时候，用代码生成矩形能让"能不能打"这件事先跑起来。
##   正式项目里这一层会换成 TileMapLayer，由美术在编辑器里绘制。
##
## 但「布局是数据」这个结构要保留：平台坐标写在 data/rooms.json 里，不是写死在这里。

const ROOMS_DATA_PATH := "res://data/rooms.json"
const ENEMIES_DATA_PATH := "res://data/enemies.json"
const ENEMY_SCENE := preload("res://scenes/enemy.tscn")

## 房间宽度（世界坐标）。
var room_width: float = 1280.0
## 地面顶部 y 坐标。
var floor_y: float = 180.0
## 墙高。
var wall_height: float = 420.0

## 当前房间数据。
var room_data: Dictionary = {}
## 帧数据表（注入）。
var attack_table: AttackTable = null

var _templates: Dictionary = {}
var _archetypes: Dictionary = {}
var _enemies: Array[Enemy] = []
var _cleared: bool = false
var _empty_timer: float = 0.0


func _ready() -> void:
    add_to_group("arena")
    _load_templates()
    EventBus.enemy_died.connect(_on_enemy_died)


func _load_templates() -> void:
    _templates = _load_json_section(ROOMS_DATA_PATH, "templates")
    _archetypes = _load_json_section(ENEMIES_DATA_PATH, "")

    var rooms_root := _load_json(ROOMS_DATA_PATH)
    room_width = float(rooms_root.get("room_width", room_width))
    floor_y = float(rooms_root.get("floor_y", floor_y))
    wall_height = float(rooms_root.get("wall_height", wall_height))


## 构建一个房间。
func build(p_attack_table: AttackTable, p_room: Dictionary) -> void:
    attack_table = p_attack_table
    room_data = p_room
    _cleared = false
    _empty_timer = 0.0

    _clear_room()
    _build_geometry()
    _spawn_enemies()


func _clear_room() -> void:
    for child in get_children():
        # 必须先 remove_child 再 queue_free。
        # 只调用 queue_free 的话，旧节点要到本帧结束才真正消失，
        # 于是 main.gd 紧接着调用 clamp_camera_to_room() 时，
        # get_first_node_in_group("game_camera") 还会找到**上一间房的旧相机** ——
        # 新房间的相机拿不到边界，镜头就会跑出房间。
        remove_child(child)
        child.queue_free()
    _enemies.clear()


# ============================== 几何 ==============================

func _build_geometry() -> void:
    var wall_color := Color(0.16, 0.14, 0.20)
    var floor_color := Color(0.24, 0.21, 0.28)
    var platform_color := Color(0.30, 0.26, 0.34)

    # 地面
    _add_block("Floor", Vector2(0.0, floor_y + 20.0), Vector2(room_width, 40.0), floor_color)

    # 左右墙
    var wall_x := room_width * 0.5 + 10.0
    var wall_center_y := floor_y - wall_height * 0.5
    _add_block("WallLeft", Vector2(-wall_x, wall_center_y), Vector2(20.0, wall_height), wall_color)
    _add_block("WallRight", Vector2(wall_x, wall_center_y), Vector2(20.0, wall_height), wall_color)

    # 天花板，防止跳太高飞出画面
    _add_block(
        "Ceiling",
        Vector2(0.0, floor_y - wall_height),
        Vector2(room_width, 20.0),
        wall_color
    )

    # 平台（数据驱动）
    var template := _template_for_room()
    var platforms: Variant = template.get("platforms", [])
    if platforms is Array:
        var list: Array = platforms
        for i in range(list.size()):
            var item: Variant = list[i]
            if not (item is Array):
                continue
            var entry: Array = item
            if entry.size() < 4:
                push_warning("[Arena] data/rooms.json 里第 %d 个平台的格式不对，应为 [x, y, 宽, 高]" % i)
                continue
            _add_block(
                "Platform%d" % i,
                Vector2(float(entry[0]), float(entry[1])),
                Vector2(float(entry[2]), float(entry[3])),
                platform_color
            )


func _add_block(node_name: String, center: Vector2, size: Vector2, color: Color) -> void:
    var body := StaticBody2D.new()
    body.name = node_name
    body.position = center
    body.collision_layer = 1
    body.collision_mask = 0

    var shape := CollisionShape2D.new()
    var rect := RectangleShape2D.new()
    rect.size = size
    shape.shape = rect
    body.add_child(shape)

    var visual := ColorRect.new()
    visual.offset_left = -size.x * 0.5
    visual.offset_top = -size.y * 0.5
    visual.offset_right = size.x * 0.5
    visual.offset_bottom = size.y * 0.5
    visual.color = color
    visual.mouse_filter = Control.MOUSE_FILTER_IGNORE
    body.add_child(visual)

    add_child(body)


# ============================== 刷怪 ==============================

func _spawn_enemies() -> void:
    var budget := int(room_data.get("enemy_budget", 0))
    if budget <= 0:
        return

    var template := _template_for_room()
    var pool: Variant = template.get("enemies", [])
    var pool_list: Array = pool if pool is Array else []

    # 用房间序号 + 本局种子派生随机数，保证同一局同一房间刷怪位置一致
    var rng := DeterministicRng.new(int(room_data.get("index", 0)) * 7919 + GameConfig.run_seed)

    for i in range(budget):
        if pool_list.is_empty():
            push_warning("[Arena] 房间 %s 有敌人预算 %d 但模板没有 enemies 列表，跳过刷怪"
                % [str(room_data.get("id", "?")), budget])
            return

        var archetype_id := str(pool_list[i % pool_list.size()])
        var archetype: Dictionary = _archetypes.get(archetype_id, {})

        if archetype.is_empty():
            push_warning("[Arena] data/enemies.json 里没有原型「%s」，跳过" % archetype_id)
            continue

        # 打不死的原型（training_dummy）绝对不能进需要清空的房间：
        # 清房判定是"所有敌人死亡"，它永远不死 → 这间房永远清不掉 → 整局卡死。
        # 数据里已经清过一次（战斗房第一位原来就是木桩），代码这层是防止有人再加回去。
        if bool(archetype.get("immortal", false)):
            push_warning("[Arena] 房间 %s 的敌人池里有不死单位「%s」，已跳过；练手感请用调试台 spawn 命令"
                % [str(room_data.get("id", "?")), archetype_id])
            continue

        var enemy: Enemy = ENEMY_SCENE.instantiate()
        enemy.name = "Enemy_%d" % i
        enemy.apply_archetype(archetype)
        enemy.position = Vector2(rng.next_float_range(-420.0, 420.0), floor_y)
        add_child(enemy)
        enemy.setup(attack_table)
        _enemies.append(enemy)


func _template_for_room() -> Dictionary:
    var type_name := str(room_data.get("type_name", "COMBAT"))
    var template: Variant = _templates.get(type_name, {})
    return template if template is Dictionary else {}


# ============================== 调试刷怪 ==============================

## 调试用：在指定 x 处单独刷一只敌人。
##
## 刻意**不写进 `_enemies`**：清房判定遍历的是 `_enemies`，把一只打不死的木桩放进去，
## 这间房就永远清不掉 —— 这正是之前那个 bug 的成因。调试刷出来的东西只是"练习靶"。
func spawn_debug_enemy(archetype_id: String, x: float) -> Enemy:
    var archetype: Dictionary = _archetypes.get(archetype_id, {})
    if archetype.is_empty():
        return null

    var enemy: Enemy = ENEMY_SCENE.instantiate()
    enemy.name = "DebugEnemy_%d" % get_child_count()
    enemy.apply_archetype(archetype)
    enemy.position = Vector2(x, floor_y)
    add_child(enemy)
    enemy.setup(attack_table)
    return enemy


## 所有可用的敌人原型 id，给调试台补全和报错提示用。
func enemy_archetype_ids() -> PackedStringArray:
    var ids := PackedStringArray()
    for id in _archetypes.keys():
        ids.append(str(id))
    return ids


# ============================== 数据校验 ==============================

## 校验当前载入的房间模板 × 敌人表。
##
## 规则本身在 RoomDataValidator（纯逻辑，可单测）里；这里只是把载入的数据喂进去。
## 不要把校验逻辑写回本文件 —— arena 是 Node2D，测试环境里 preload 它会编译失败。
func validate_data() -> PackedStringArray:
    return RoomDataValidator.validate_templates(_templates, _archetypes)


# ============================== 清空判定 ==============================

func _process(delta: float) -> void:
    if _cleared:
        return

    if _enemies.is_empty():
        _empty_timer += delta
        if _empty_timer >= 1.5:
            _mark_cleared()
        return

    var alive := 0
    for enemy in _enemies:
        if is_instance_valid(enemy) and not enemy.hurtbox.is_dead():
            alive += 1

    if alive == 0:
        _mark_cleared()


func _mark_cleared() -> void:
    if _cleared:
        return
    _cleared = true
    EventBus.room_cleared.emit(str(room_data.get("id", "room_0")))


func _on_enemy_died(_world_pos: Vector2) -> void:
    # 立刻检查一次，避免等下一帧
    pass


# ============================== 相机边界 ==============================

## 把镜头限制在当前房间内。
## 必须在玩家（相机是它的子节点）生成之后调用，否则会设置到旧的相机上。
func clamp_camera_to_room() -> void:
    var camera := get_tree().get_first_node_in_group("game_camera") as Camera2D
    if camera == null or not camera.has_method("set_bounds"):
        return
    var half := room_width * 0.5
    camera.call("set_bounds", -half + 120.0, half - 120.0)


# ============================== 工具 ==============================

func living_enemy_count() -> int:
    var alive := 0
    for enemy in _enemies:
        if is_instance_valid(enemy) and not enemy.hurtbox.is_dead():
            alive += 1
    return alive


func enemy_snapshots() -> Array:
    var result: Array = []
    for enemy in _enemies:
        if is_instance_valid(enemy):
            result.append(enemy.snapshot())
    return result


func _load_json(path: String) -> Dictionary:
    if not FileAccess.file_exists(path):
        push_error("[Arena] 找不到数据文件：%s" % path)
        return {}
    var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
    if not (parsed is Dictionary):
        push_error("[Arena] 数据文件不是合法 JSON 对象：%s" % path)
        return {}
    var data: Dictionary = parsed
    return data


func _load_json_section(path: String, section: String) -> Dictionary:
    var root := _load_json(path)
    if section.is_empty():
        return root
    var value: Variant = root.get(section, {})
    return value if value is Dictionary else {}
