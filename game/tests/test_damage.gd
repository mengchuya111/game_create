extends TestCase
## 测试 Damage —— 伤害与架势公式。
##
## 这一组是"数值策划的护栏"：改公式、改常量之后跑一遍，
## 立刻知道有没有把某个极端情况搞崩（比如伤害变成 0、防御越高伤害反而越高）。


# ============================== compute ==============================

func test_zero_or_negative_base_deals_no_damage() -> void:
    assert_eq(Damage.compute(0), 0, "基础伤害为 0 时不应该打出伤害")
    assert_eq(Damage.compute(-5), 0, "负数基础伤害不应该变成治疗")


func test_zero_multiplier_deals_no_damage() -> void:
    assert_eq(Damage.compute(10, 0.0), 0, "倍率为 0 时不应该打出伤害")


func test_no_defense_returns_full_damage() -> void:
    assert_eq(Damage.compute(10, 1.0, 0), 10, "没有防御时应当打出全额伤害")


func test_negative_defense_is_treated_as_zero() -> void:
    assert_eq(Damage.compute(10, 1.0, -50), 10, "负数防御应当按 0 处理，不能变成增伤")


func test_defense_100_halves_damage() -> void:
    assert_eq(Damage.compute(100, 1.0, 100), 50, "100 点防御应当把伤害减半")


func test_defense_300_quarters_damage() -> void:
    assert_eq(Damage.compute(100, 1.0, 300), 25, "300 点防御应当把伤害减到四分之一")


func test_damage_never_drops_below_one() -> void:
    var result := Damage.compute(1, 1.0, 999999)
    assert_eq(result, 1, "只要基础伤害大于 0，最终伤害至少为 1（否则会出现'打不动'的死局）")


func test_crit_multiplies_by_1_5() -> void:
    assert_eq(Damage.compute(100, 1.0, 0, true), 150, "暴击应当是 1.5 倍伤害")


func test_multiplier_applies_before_defense() -> void:
    var with_multiplier := Damage.compute(10, 2.0, 100)
    assert_eq(with_multiplier, 10, "10 伤害 × 2 倍率 = 20，再过 100 防御减半 = 10")


func test_higher_defense_never_increases_damage() -> void:
    var previous := Damage.compute(100, 1.0, 0)
    var monotonic := true
    for defense in range(0, 500, 25):
        var current := Damage.compute(100, 1.0, defense)
        if current > previous:
            monotonic = false
            break
        previous = current
    assert_true(monotonic, "防御越高伤害只能越低，不能出现反弹")


func test_fractional_multiplier_rounds() -> void:
    assert_eq(Damage.compute(10, 0.5), 5, "0.5 倍率应当是 5")
    assert_eq(Damage.compute(7, 0.5), 4, "3.5 应当四舍五入到 4")


# ============================== 架势 ==============================

func test_apply_poise_not_broken() -> void:
    var result := Damage.apply_poise(40.0, 10)
    assert_almost_eq(float(result["remaining"]), 30.0, 0.001, "架势应当减少 10")
    assert_false(bool(result["staggered"]), "架势还有剩就不该硬直")


func test_apply_poise_exactly_broken() -> void:
    var result := Damage.apply_poise(10.0, 10)
    assert_almost_eq(float(result["remaining"]), 0.0, 0.001, "架势刚好清零")
    assert_true(bool(result["staggered"]), "架势归零应当触发硬直")


func test_apply_poise_overkill_clamps_to_zero() -> void:
    var result := Damage.apply_poise(5.0, 999)
    assert_almost_eq(float(result["remaining"]), 0.0, 0.001, "架势不能变成负数")
    assert_true(bool(result["staggered"]), "过量削架势也应当触发硬直")


func test_apply_poise_negative_damage_does_not_heal() -> void:
    var result := Damage.apply_poise(10.0, -50)
    assert_almost_eq(float(result["remaining"]), 10.0, 0.001, "负数削架势不应该变成回架势")


func test_regen_poise_clamps_to_max() -> void:
    var value := Damage.regen_poise(38.0, 40.0, 100.0, 1.0)
    assert_almost_eq(value, 40.0, 0.001, "架势恢复不能超过上限")


func test_regen_poise_at_max_stays() -> void:
    var value := Damage.regen_poise(40.0, 40.0, 100.0, 1.0)
    assert_almost_eq(value, 40.0, 0.001, "满架势时恢复应当保持满值")


func test_regen_poise_accumulates_over_time() -> void:
    var value := Damage.regen_poise(0.0, 100.0, 12.0, 0.5)
    assert_almost_eq(value, 6.0, 0.001, "每秒恢复 12 点，0.5 秒应当恢复 6 点")


# ============================== 连段递减 ==============================

func test_combo_scale_first_hit_is_full() -> void:
    assert_almost_eq(Damage.combo_scale(0), 1.0, 0.0001, "第一招不打折")


func test_combo_scale_decreases() -> void:
    var first := Damage.combo_scale(1)
    var second := Damage.combo_scale(2)
    var third := Damage.combo_scale(3)
    assert_lt(second, first, "连得越长伤害越低")
    assert_lt(third, second, "递减应当持续")
    assert_almost_eq(first, 0.9, 0.0001, "第二招应当是 0.9 倍")


func test_combo_scale_has_floor() -> void:
    var very_long := Damage.combo_scale(100)
    assert_almost_eq(very_long, Damage.COMBO_FLOOR, 0.0001, "连段伤害递减应当有下限，不能归零")
    assert_gt(very_long, 0.0, "下限必须大于 0")


func test_combo_scale_negative_index_is_full() -> void:
    assert_almost_eq(Damage.combo_scale(-1), 1.0, 0.0001, "负数序号应当按第一招处理")


# ============================== 击退 ==============================

func test_knockback_for_standard_weight() -> void:
    assert_almost_eq(Damage.knockback_for_weight(100.0, 1.0), 100.0, 0.001, "标准重量不改变击退")


func test_heavier_target_gets_less_knockback() -> void:
    var light := Damage.knockback_for_weight(100.0, 0.5)
    var heavy := Damage.knockback_for_weight(100.0, 4.0)
    assert_gt(light, heavy, "轻的目标应当被击退得更远")
    assert_almost_eq(heavy, 25.0, 0.001, "4 倍重量的目标击退应当只有四分之一")


func test_zero_weight_does_not_divide_by_zero() -> void:
    var result := Damage.knockback_for_weight(100.0, 0.0)
    assert_almost_eq(result, 100.0, 0.001, "重量为 0 时应当回退到基础击退，而不是除以零得到无穷大")
