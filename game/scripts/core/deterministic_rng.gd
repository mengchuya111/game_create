class_name DeterministicRng
extends RefCounted
## 可复现的随机数生成器。
##
## 为什么不能直接用 randf() / randi()：
##   Godot 的全局随机函数依赖一个全局状态，任何一处调用都会影响后面的结果。
##   肉鸽游戏必须能"用同一个种子复现同一局"，所以所有随机行为都必须走这个类。
##
## 用法：
##     var rng := DeterministicRng.new(12345)
##     var n := rng.next_int(1, 6)
##
## ⚠️ 两个已经踩过的坑（写这个类的时候真踩了，见 tests/test_deterministic_rng.gd）：
##
##   坑 1：设置 seed 之后又设置 state = 0，会把种子彻底废掉。
##        Godot 的 RandomNumberGenerator.seed 设值时会自己算好内部状态，
##        如果紧接着写 state = 0，所有种子都会退化成同一个序列 ——
##        表面上看"随机数正常"，实际上每个种子跑出来一模一样。
##        本类因此**只设 seed，绝不手动改 state**（除非是从存档恢复）。
##
##   坑 2：本类的方法名如果和 Godot 的全局随机函数重名，类内部裸调用会解析到全局函数。
##        例如类内写 randi_range(0, i)，实际调用的是 @GlobalScope.randi_range，
##        用的是全局随机状态 —— 于是"可复现"直接失效，而且不报任何错。
##        本类因此刻意用 next_int / next_float 这类**不会与全局函数重名**的名字。
##        请保持这个约定：不要把它们改回 randi_range / randf。

## 本局使用的种子。
var seed_value: int = 0

## 已经抽取过的随机数个数。用于断言"同一序列"和排查不同步。
var _draw_count: int = 0

var _rng := RandomNumberGenerator.new()


func _init(initial_seed: int = 0) -> void:
    reseed(initial_seed)


## 重置种子，并把抽取计数归零。
## 注意：只设置 seed，不要再写 _rng.state = 0（那会废掉种子，见类文档「坑 1」）。
func reseed(new_seed: int) -> void:
    seed_value = new_seed
    _rng.seed = new_seed
    _draw_count = 0


## 抽取一个 [from, to] 闭区间内的整数（含两端）。
## 名字刻意不叫 randi_range，避免和 Godot 全局函数撞名（见类文档「坑 2」）。
func next_int(from: int, to: int) -> int:
    _draw_count += 1
    if from > to:
        var tmp := from
        from = to
        to = tmp
    return _rng.randi_range(from, to)


## 抽取一个 [0.0, 1.0) 的浮点数。
func next_float() -> float:
    _draw_count += 1
    return _rng.randf()


## 抽取一个 [from, to) 的浮点数。
func next_float_range(from: float, to: float) -> float:
    _draw_count += 1
    return _rng.randf_range(from, to)


## 按概率返回 true。probability 取值 0.0 ~ 1.0。
func chance(probability: float) -> bool:
    return next_float() < clampf(probability, 0.0, 1.0)


## 从数组里随机取一个元素。空数组返回 null。
func pick(source: Array) -> Variant:
    if source.is_empty():
        return null
    return source[next_int(0, source.size() - 1)]


## 按权重取一个元素。
## entries 形如：[{ "weight": 3, "value": "combat" }, ...]
## weight_key 可自定义权重字段名。
## 全部权重 <= 0 时退化为等概率抽取。
func weighted_pick(entries: Array, weight_key: String = "weight") -> Variant:
    if entries.is_empty():
        return null

    var total: float = 0.0
    for entry in entries:
        total += maxf(0.0, float(entry.get(weight_key, 1.0)))

    if total <= 0.0:
        var fallback: Variant = pick(entries)
        if fallback is Dictionary:
            var fallback_dict: Dictionary = fallback
            return fallback_dict.get("value", null)
        return fallback

    var roll: float = next_float() * total
    var accumulated: float = 0.0
    for entry in entries:
        accumulated += maxf(0.0, float(entry.get(weight_key, 1.0)))
        if roll < accumulated:
            return entry.get("value", null)

    # 浮点误差兜底
    return entries[entries.size() - 1].get("value", null)


## 原地洗牌（Fisher-Yates），结果只依赖本对象的种子。
func shuffle_array(source: Array) -> void:
    for i in range(source.size() - 1, 0, -1):
        var j := next_int(0, i)
        var tmp: Variant = source[i]
        source[i] = source[j]
        source[j] = tmp


## 已经抽取过的随机数个数。
func draw_count() -> int:
    return _draw_count


## 导出一份快照，便于存档 / 调试复现。
func to_dict() -> Dictionary:
    return {
        "seed": seed_value,
        "state": _rng.state,
        "draw_count": _draw_count,
    }


## 从快照恢复。用于存档后继续跑出完全相同的后续随机序列。
## 这里是唯一允许手动写 state 的地方：先设 seed 建立内部结构，再用 state 精确还原位置。
func from_dict(data: Dictionary) -> void:
    seed_value = int(data.get("seed", 0))
    _rng.seed = seed_value
    _rng.state = int(data.get("state", 0))
    _draw_count = int(data.get("draw_count", 0))
