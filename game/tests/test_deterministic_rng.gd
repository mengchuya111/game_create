extends TestCase
## 测试 DeterministicRng —— 肉鸽游戏"同种子复现同一局"的地基。
##
## 这一组测试如果挂了，说明"用种子复现 bug"这个能力已经失效，
## 后面所有调试都会变得极其痛苦。所以它必须永远是绿的。
##
## 顺带说明：写这个类的时候真踩了两个坑，下面的测试就是专门钉住它们的：
##   坑 1：设完 seed 又设 state = 0 → 所有种子产出同一序列（见 test_different_seeds_diverge）
##   坑 2：类内裸调用与全局函数重名的方法 → 悄悄用了全局随机状态（见 test_shuffle_is_deterministic）


func test_same_seed_produces_same_sequence() -> void:
    var a := DeterministicRng.new(1234)
    var b := DeterministicRng.new(1234)
    var mismatched_at := -1
    for i in range(200):
        if a.next_int(1, 1000000) != b.next_int(1, 1000000):
            mismatched_at = i
            break
    assert_eq(mismatched_at, -1, "同一个种子必须产出完全相同的随机序列")


func test_different_seeds_diverge() -> void:
    var a := DeterministicRng.new(1)
    var b := DeterministicRng.new(2)
    var differences := 0
    for i in range(50):
        if a.next_int(1, 1000000) != b.next_int(1, 1000000):
            differences += 1
    assert_gt(float(differences), 40.0, "不同种子必须产出不同序列（实际只差 %d 次）—— 若为 0，说明种子被 state=0 废掉了" % differences)


func test_seed_zero_is_usable() -> void:
    var a := DeterministicRng.new(0)
    var b := DeterministicRng.new(0)
    var differences := 0
    for i in range(20):
        if a.next_int(0, 1000000) != b.next_int(0, 1000000):
            differences += 1
    assert_eq(differences, 0, "种子 0 也必须是一个合法且可复现的种子")


func test_seed_is_exposed() -> void:
    var rng := DeterministicRng.new(4321)
    assert_eq(rng.seed_value, 4321, "种子应当能被读出来（HUD 和调试命令要显示它）")


func test_reseed_restarts_sequence() -> void:
    var rng := DeterministicRng.new(999)
    var first: Array = []
    for i in range(10):
        first.append(rng.next_int(0, 1000))

    rng.reseed(999)
    var second: Array = []
    for i in range(10):
        second.append(rng.next_int(0, 1000))

    assert_int_array_eq(second, first, "重新设置同一个种子后，序列应当从头再来")
    assert_eq(rng.draw_count(), 10, "reseed 之后抽取计数应当归零后重新累计")


func test_draw_count_tracks_calls() -> void:
    var rng := DeterministicRng.new(5)
    assert_eq(rng.draw_count(), 0, "初始抽取次数应当是 0")
    rng.next_int(1, 10)
    assert_eq(rng.draw_count(), 1, "next_int 之后计数应当是 1")
    rng.next_float()
    assert_eq(rng.draw_count(), 2, "next_float 之后计数应当是 2")
    rng.pick([1, 2, 3])
    assert_eq(rng.draw_count(), 3, "pick 内部也应当走本类的抽取路径并计数（若为 2，说明 pick 调到了全局 randi_range）")


func test_next_int_stays_in_bounds() -> void:
    var rng := DeterministicRng.new(7)
    var out_of_bounds := -1
    for i in range(500):
        var value := rng.next_int(3, 9)
        if value < 3 or value > 9:
            out_of_bounds = value
            break
    assert_eq(out_of_bounds, -1, "next_int 的结果必须落在闭区间 [3, 9] 内")


func test_next_int_handles_reversed_bounds() -> void:
    var rng := DeterministicRng.new(11)
    var out_of_bounds := -1
    for i in range(200):
        var value := rng.next_int(9, 3)
        if value < 3 or value > 9:
            out_of_bounds = value
            break
    assert_eq(out_of_bounds, -1, "上下界写反时应当自动交换，而不是返回越界值")


func test_next_int_single_value_range() -> void:
    var rng := DeterministicRng.new(11)
    assert_eq(rng.next_int(5, 5), 5, "区间只有一个值时应当稳定返回那个值")


func test_next_float_range_is_bounded() -> void:
    var rng := DeterministicRng.new(13)
    var out_of_bounds := -1.0
    for i in range(500):
        var value := rng.next_float_range(-2.0, 3.0)
        if value < -2.0 or value >= 3.0:
            out_of_bounds = value
            break
    assert_almost_eq(out_of_bounds, -1.0, 0.0001, "next_float_range 的结果必须落在 [from, to) 内")


func test_chance_extremes() -> void:
    var rng := DeterministicRng.new(3)
    assert_false(rng.chance(0.0), "概率为 0 时永远不应该命中")
    assert_true(rng.chance(1.0), "概率为 1 时永远应该命中")
    assert_true(rng.chance(5.0), "概率大于 1 时应当被裁剪为必定命中")
    assert_false(rng.chance(-1.0), "概率小于 0 时应当被裁剪为必定不命中")


func test_pick_empty_returns_null() -> void:
    var rng := DeterministicRng.new(3)
    assert_eq(rng.pick([]), null, "从空数组里取元素应当返回 null，而不是崩溃")


func test_pick_only_returns_elements_from_source() -> void:
    var rng := DeterministicRng.new(3)
    var source: Array = ["a", "b", "c"]
    var seen: Dictionary = {}
    for i in range(200):
        seen[rng.pick(source)] = true
    assert_eq(seen.size(), 3, "抽取 200 次应当三个元素都出现过（实际 %d 种）" % seen.size())


func test_weighted_pick_skips_zero_weight() -> void:
    var rng := DeterministicRng.new(42)
    var entries: Array = [
        {"value": "never", "weight": 0.0},
        {"value": "always", "weight": 10.0},
    ]
    var wrong_pick := ""
    for i in range(300):
        var picked: Variant = rng.weighted_pick(entries)
        if picked != "always":
            wrong_pick = str(picked)
            break
    assert_eq(wrong_pick, "", "权重为 0 的选项不应该被抽到")


func test_weighted_pick_respects_ratio() -> void:
    var rng := DeterministicRng.new(2024)
    var entries: Array = [
        {"value": "common", "weight": 9.0},
        {"value": "rare", "weight": 1.0},
    ]
    var common_count := 0
    var total := 4000
    for i in range(total):
        if rng.weighted_pick(entries) == "common":
            common_count += 1
    var ratio := float(common_count) / float(total)
    assert_between(ratio, 0.86, 0.94, "9:1 的权重应当产出大约 90%% 的 common（实际 %.3f）" % ratio)


func test_weighted_pick_all_zero_falls_back() -> void:
    var rng := DeterministicRng.new(42)
    var entries: Array = [
        {"value": "a", "weight": 0.0},
        {"value": "b", "weight": 0.0},
    ]
    var result: Variant = rng.weighted_pick(entries)
    assert_true(result == "a" or result == "b", "全零权重时应当退化为等概率，而不是返回 null")


func test_weighted_pick_empty_returns_null() -> void:
    var rng := DeterministicRng.new(42)
    assert_eq(rng.weighted_pick([]), null, "空权重表应当返回 null")


func test_weighted_pick_is_deterministic() -> void:
    var a := DeterministicRng.new(777)
    var b := DeterministicRng.new(777)
    var entries: Array = [
        {"value": "combat", "weight": 62.0},
        {"value": "elite", "weight": 16.0},
        {"value": "treasure", "weight": 14.0},
        {"value": "shop", "weight": 8.0},
    ]
    var seq_a: Array = []
    var seq_b: Array = []
    for i in range(50):
        seq_a.append(a.weighted_pick(entries))
        seq_b.append(b.weighted_pick(entries))
    assert_eq(seq_a, seq_b, "加权抽取也必须可复现（房间类型生成就靠它）")


func test_weighted_pick_custom_weight_key() -> void:
    var rng := DeterministicRng.new(42)
    var entries: Array = [
        {"value": "never", "chance": 0.0},
        {"value": "always", "chance": 5.0},
    ]
    var wrong_pick := ""
    for i in range(100):
        if rng.weighted_pick(entries, "chance") != "always":
            wrong_pick = "别的值"
            break
    assert_eq(wrong_pick, "", "应当支持自定义权重字段名")


func test_shuffle_is_deterministic_and_lossless() -> void:
    var rng_a := DeterministicRng.new(2024)
    var rng_b := DeterministicRng.new(2024)
    var list_a: Array = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    var list_b: Array = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

    rng_a.shuffle_array(list_a)
    rng_b.shuffle_array(list_b)

    assert_eq(
        list_a, list_b,
        "同一种子的洗牌结果必须一致 —— 若不一致，说明 shuffle_array 调到了全局随机函数（坑 2）"
    )
    list_a.sort()
    assert_eq(list_a, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], "洗牌不能丢元素或产生重复")


func test_shuffle_actually_shuffles() -> void:
    var rng := DeterministicRng.new(31337)
    var original: Array = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    var list := original.duplicate()
    rng.shuffle_array(list)
    assert_ne(list, original, "洗牌之后顺序应当发生变化（否则就是没洗）")


func test_shuffle_empty_and_single_are_safe() -> void:
    var rng := DeterministicRng.new(1)
    var empty: Array = []
    rng.shuffle_array(empty)
    assert_eq(empty.size(), 0, "空数组洗牌应当安全")

    var single: Array = [42]
    rng.shuffle_array(single)
    assert_eq(single, [42], "单元素数组洗牌后应当不变")


func test_state_roundtrip_continues_sequence() -> void:
    var rng := DeterministicRng.new(555)
    for i in range(7):
        rng.next_int(0, 100)

    var snapshot := rng.to_dict()
    var expected := rng.next_int(0, 1000000)

    var restored := DeterministicRng.new(0)
    restored.from_dict(snapshot)
    assert_eq(restored.draw_count(), int(snapshot["draw_count"]), "抽取计数应当被恢复")
    assert_eq(restored.seed_value, 555, "种子应当被恢复")

    var actual := restored.next_int(0, 1000000)
    assert_eq(actual, expected, "从快照恢复后应当接着产出相同的后续随机数（存档功能依赖这一点）")


func test_state_roundtrip_repeatedly() -> void:
    var rng := DeterministicRng.new(8080)
    var snapshot := rng.to_dict()
    var first_batch: Array = []
    for i in range(10):
        first_batch.append(rng.next_int(0, 100000))

    var restored := DeterministicRng.new(0)
    restored.from_dict(snapshot)
    var second_batch: Array = []
    for i in range(10):
        second_batch.append(restored.next_int(0, 100000))

    assert_int_array_eq(second_batch, first_batch, "从同一快照恢复多次，应当每次都产出同一批后续随机数")
