class_name RoomGenerator
extends RefCounted
## 房间路线生成器 —— 纯逻辑类，可被单元测试完整覆盖。
##
## 肉鸽的"关卡"不是手工摆的，而是按规则拼出来的。本类负责生成一层（floor）的房间序列：
##
##     START ──► COMBAT ──► COMBAT ──► TREASURE ──► COMBAT ──► ELITE ──► BOSS
##
## 骨架阶段先做线性路线（每个房间只有一个出口），因为：
##   1. 线性路线最容易验证，测试好写；
##   2. 手感验证不需要复杂地图；
##   3. 等战斗手感确认了，再把 next 从一个 id 改成多个 id 就能升级成分支地图。
##
## AI 协作约定：
##   随机数一律走 DeterministicRng，禁止直接调用 randi()。
##   否则"同一个种子复现同一局"这个能力会立刻失效，而这正是肉鸽调试的命根子。

enum RoomType {
    START,     ## 起点，无敌人
    COMBAT,    ## 普通战斗
    ELITE,     ## 精英战，奖励更好
    TREASURE,  ## 宝箱房，无敌人
    SHOP,      ## 商店，无敌人
    BOSS,      ## 首领战
}

const TYPE_NAMES := {
    RoomType.START: "START",
    RoomType.COMBAT: "COMBAT",
    RoomType.ELITE: "ELITE",
    RoomType.TREASURE: "TREASURE",
    RoomType.SHOP: "SHOP",
    RoomType.BOSS: "BOSS",
}

const TYPE_DISPLAY_NAMES := {
    RoomType.START: "起点",
    RoomType.COMBAT: "战斗",
    RoomType.ELITE: "精英",
    RoomType.TREASURE: "宝箱",
    RoomType.SHOP: "商店",
    RoomType.BOSS: "首领",
}

## 每类房间的敌人预算（用于决定刷几只怪）。0 表示无敌人。
const ENEMY_BUDGET := {
    RoomType.START: 0,
    RoomType.COMBAT: 3,
    RoomType.ELITE: 5,
    RoomType.TREASURE: 0,
    RoomType.SHOP: 0,
    RoomType.BOSS: 8,
}

## 路线生成时的候选权重（不含起点和首领）。
const MIDDLE_WEIGHTS := [
    {"value": RoomType.COMBAT, "weight": 62.0},
    {"value": RoomType.TREASURE, "weight": 14.0},
    {"value": RoomType.ELITE, "weight": 16.0},
    {"value": RoomType.SHOP, "weight": 8.0},
]


## 生成一条房间路线。
## @param seed_value  随机种子（同一 seed 必然产出完全相同的路线）
## @param room_count  房间总数，至少 3（起点 + 至少 1 个中间房 + 首领）
## @param difficulty  难度系数，1.0 为标准。会影响精英房出现概率和敌人预算
## @return 房间字典数组，每项含 index / id / type / type_name / enemy_budget / next / prev
static func generate(seed_value: int, room_count: int = 8, difficulty: float = 1.0) -> Array:
    var count := maxi(3, room_count)
    var rng := DeterministicRng.new(seed_value)

    var types := _roll_types(rng, count, difficulty)
    var rooms: Array = []

    for i in range(count):
        var room_type: int = types[i]
        rooms.append({
            "index": i,
            "id": "room_%d" % i,
            "type": room_type,
            "type_name": TYPE_NAMES[room_type],
            "display_name": TYPE_DISPLAY_NAMES[room_type],
            "enemy_budget": int(round(float(ENEMY_BUDGET[room_type]) * difficulty)),
            "difficulty": difficulty,
            "next": [],
            "prev": [],
        })

    # 骨架阶段是线性路线：i → i+1
    for i in range(count):
        if i + 1 < count:
            rooms[i]["next"].append(rooms[i + 1]["id"])
            rooms[i + 1]["prev"].append(rooms[i]["id"])

    return rooms


## 抽取每个房间的类型，带规则约束。
static func _roll_types(rng: DeterministicRng, count: int, difficulty: float) -> Array:
    var types: Array = []
    types.append(RoomType.START)

    var middle_count := count - 2
    var shop_used := false
    var treasure_count := 0
    var max_treasure := maxi(1, int(round(float(count) / 4.0)))

    # 按难度调整精英权重：难度越高精英越多
    var elite_weight := 16.0 * clampf(difficulty, 0.5, 2.0)

    for i in range(middle_count):
        var candidates: Array = []

        for entry in MIDDLE_WEIGHTS:
            var room_type: int = entry["value"]
            var weight: float = entry["weight"]

            if room_type == RoomType.SHOP:
                # 商店一层最多一个，且不能出现在第一间
                if shop_used or i == 0:
                    continue
            elif room_type == RoomType.TREASURE:
                if treasure_count >= max_treasure:
                    continue
            elif room_type == RoomType.ELITE:
                # 第一间不出精英，给玩家一点缓冲
                if i == 0:
                    continue
                weight = elite_weight

            candidates.append({"value": room_type, "weight": weight})

        # 第一间强制普通战斗，保证开局节奏
        var picked: int
        if i == 0:
            picked = RoomType.COMBAT
        else:
            var result: Variant = rng.weighted_pick(candidates)
            picked = int(result) if result != null else RoomType.COMBAT

        if picked == RoomType.SHOP:
            shop_used = true
        elif picked == RoomType.TREASURE:
            treasure_count += 1

        types.append(picked)

    # 一层至少保一间商店。
    #
    # 为什么必须保底：商店在中段房间的权重只有 8%，8 间房算下来约四成概率一间都不出。
    # 玩家攒了一整层的内力却没有任何地方花，等于"内力"这个资源是假的 ——
    # 而商店正是它唯一的出口。保底一间比调高权重更可靠（调权重只能提高概率）。
    #
    # 替换的是**最后一间普通战斗房**：不打乱开局节奏，也不会把精英/boss 顶掉。
    if not shop_used and types.size() > 1:
        for i in range(types.size() - 1, 0, -1):
            if int(types[i]) == RoomType.COMBAT:
                types[i] = RoomType.SHOP
                break

    types.append(RoomType.BOSS)
    return types


## 校验一条路线是否合法。返回问题列表，空数组表示合法。
## 单元测试和调试台 check 命令都会用它。
static func validate(rooms: Array) -> PackedStringArray:
    var problems: PackedStringArray = PackedStringArray()

    if rooms.is_empty():
        problems.append("路线是空的")
        return problems

    if int(rooms[0]["type"]) != RoomType.START:
        problems.append("第一个房间不是 START，而是 %s" % rooms[0]["type_name"])
    if int(rooms[rooms.size() - 1]["type"]) != RoomType.BOSS:
        problems.append("最后一个房间不是 BOSS，而是 %s" % rooms[rooms.size() - 1]["type_name"])

    var known_ids: Dictionary = {}
    for room in rooms:
        known_ids[room["id"]] = true

    for room in rooms:
        for next_id in room["next"]:
            if not known_ids.has(next_id):
                problems.append("房间 %s 的出口指向了不存在的 %s" % [room["id"], next_id])
        for prev_id in room["prev"]:
            if not known_ids.has(prev_id):
                problems.append("房间 %s 的入口指向了不存在的 %s" % [room["id"], prev_id])

    # 连通性：从起点出发必须能到达所有房间
    var reachable := _reachable_ids(rooms)
    for room in rooms:
        if not reachable.has(room["id"]):
            problems.append("房间 %s 从起点不可达" % room["id"])

    # 商店不能连续出现
    for i in range(1, rooms.size()):
        if int(rooms[i]["type"]) == RoomType.SHOP and int(rooms[i - 1]["type"]) == RoomType.SHOP:
            problems.append("第 %d 和第 %d 个房间都是商店，不应该连续出现" % [i - 1, i])

    return problems


## 从起点出发做广度优先遍历，返回可达房间 id 集合。
static func _reachable_ids(rooms: Array) -> Dictionary:
    var visited: Dictionary = {}
    if rooms.is_empty():
        return visited

    var by_id: Dictionary = {}
    for room in rooms:
        by_id[room["id"]] = room

    var queue: Array = [rooms[0]["id"]]
    visited[rooms[0]["id"]] = true

    while not queue.is_empty():
        var current: String = queue.pop_front()
        if not by_id.has(current):
            # 指向了不存在的房间。这里必须跳过而不是直接索引，
            # 否则 validate() 会在"报告问题"的过程中自己先崩掉 —— 那样就没法告诉用户哪里错了。
            continue
        var room: Dictionary = by_id[current]
        for next_id in room["next"]:
            if not by_id.has(next_id):
                continue
            if not visited.has(next_id):
                visited[next_id] = true
                queue.append(next_id)

    return visited


## 把路线渲染成一行文本，方便调试台和测试失败信息里直接看。
## 例如："起点 → 战斗 → 宝箱 → 精英 → 首领"
static func describe(rooms: Array) -> String:
    var parts: PackedStringArray = PackedStringArray()
    for room in rooms:
        parts.append(str(room["display_name"]))
    return " → ".join(parts)


## 把路线压成类型序列，便于测试比较。
static func type_sequence(rooms: Array) -> PackedInt32Array:
    var result: PackedInt32Array = PackedInt32Array()
    for room in rooms:
        result.append(int(room["type"]))
    return result
