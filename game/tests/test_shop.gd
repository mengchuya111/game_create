extends TestCase
## Shop（商店：摆货 / 定价 / 购买结算）的单元测试。
##
## 重点钉四件事：
##   1. 定价只跟稀有度走 —— 否则心法越加越多，最后必然出现"凡品比绝品贵"。
##   2. 买不起不能扣钱（这条要是没钉住，会变成"内力凭空消失"的玄学 bug）。
##   3. 同一件不能买两次，叠满的心法不能上架。
##   4. 货架是确定性的：同种子同房间，摆出来的东西必须一样，否则没法复现。


func _pool() -> UpgradePool:
    var pool := UpgradePool.new()
    pool.load_from_dict({
        "rarity_weights": {"common": 100, "rare": 40, "epic": 12},
        "upgrades": {
            "a_blade": {
                "display_name": "刀法精进", "description": "伤害 +15%",
                "rarity": "common", "max_stacks": 5,
                "effects": {"damage_multiplier": 0.15},
            },
            "b_iron": {
                "display_name": "铁布衫", "description": "生命 +20",
                "rarity": "common", "max_stacks": 3,
                "effects": {"max_hp": 20},
            },
            "c_qi": {
                "display_name": "行气诀", "description": "冲刺冷却 -4 帧",
                "rarity": "rare", "max_stacks": 3,
                "effects": {"dash_cooldown": 4},
            },
            "d_vajra": {
                "display_name": "金刚不坏", "description": "生命 +40",
                "rarity": "epic", "max_stacks": 2,
                "effects": {"max_hp": 40},
            },
        },
    })
    return pool


func _shop() -> Shop:
    var shop := Shop.new()
    shop.load_from_dict({
        "offer_count": 3,
        "rarity_price": {"common": 10, "rare": 16, "epic": 26},
    })
    return shop


func _state(coins: int = 100) -> RunState:
    var state := RunState.new()
    state.reset()
    state.add_coins(coins)
    return state


# ============================== 定价 ==============================

func test_price_follows_rarity() -> void:
    var shop := _shop()
    assert_eq(shop.price_of({"rarity": "common"}), 10, "凡品 10")
    assert_eq(shop.price_of({"rarity": "rare"}), 16, "上品 16")
    assert_eq(shop.price_of({"rarity": "epic"}), 26, "绝品 26")


func test_explicit_price_overrides_rarity() -> void:
    var shop := _shop()
    assert_eq(shop.price_of({"rarity": "epic", "price": 5}), 5, "心法自带的 price 优先")


func test_unknown_rarity_falls_back() -> void:
    var shop := _shop()
    assert_eq(shop.price_of({"rarity": "legendary"}), Shop.DEFAULT_PRICE, "未知稀有度用默认价")


func test_price_table_validation() -> void:
    var shop := Shop.new()
    shop.load_from_dict({"rarity_price": {"common": -3}})
    assert_contains(shop.load_error, "大于 0", "负价格必须被拒绝")

    var shop2 := Shop.new()
    shop2.load_from_dict({"rarity_price": {"common": "十块"}})
    assert_contains(shop2.load_error, "不是数字", "价格写成文字必须被拒绝")


# ============================== 货架 ==============================

func test_stock_has_no_duplicates_and_uses_price_table() -> void:
    var shop := _shop()
    var state := _state()
    var items := shop.stock(_pool(), 20240501, 3, state)

    assert_eq(items.size(), 3, "应该摆 3 件")
    var seen := {}
    for item in items:
        var id := str(item["id"])
        assert_false(seen.has(id), "货架上不能出现两件一样的心法（%s）" % id)
        seen[id] = true
        assert_eq(int(item["price"]), shop.price_of(item["def"]), "价格必须来自定价表")
        assert_false(bool(item["sold"]), "刚上架时都是未售出")


## 同一个种子 + 同一间房 + 同样的成长状态，货架必须完全一样。
## 不然"看回放""自动测试"和玩家当时看到的商店就不一致了。
func test_stock_is_deterministic() -> void:
    var shop := _shop()
    var first := shop.stock(_pool(), 777, 4, _state())
    var second := shop.stock(_pool(), 777, 4, _state())

    var first_ids := PackedStringArray()
    var second_ids := PackedStringArray()
    for item in first:
        first_ids.append(str(item["id"]))
    for item in second:
        second_ids.append(str(item["id"]))
    assert_eq(first_ids, second_ids, "同种子同房间必须摆出同一批货")


## 商店货架和三选一必须不是同一批（不然玩家会觉得"商店在卖我刚放弃的那三个"）。
func test_stock_differs_from_reward_choices() -> void:
    var pool := _pool()
    var state := _state()
    var shop := _shop()

    var reward_ids := PackedStringArray()
    for def in pool.roll(20240501, 5, state, 3):
        reward_ids.append(str((def as Dictionary).get("id", "")))

    var stock_ids := PackedStringArray()
    for item in shop.stock(pool, 20240501, 5, state):
        stock_ids.append(str(item["id"]))

    # 允许偶尔有交集（候选只有 4 条），但不能完全一样
    assert_ne(stock_ids, reward_ids, "商店和三选一不应摆出完全相同的一批")


func test_full_upgrade_never_shows_up() -> void:
    var pool := _pool()
    var state := _state()
    var shop := _shop()

    # 把这条叠满
    var blade: Dictionary = pool.get_upgrade("a_blade")
    for _i in range(int(blade.get("max_stacks", 1))):
        state.take_upgrade(blade)
    assert_eq(state.stack_count("a_blade"), int(blade.get("max_stacks", 1)), "前置：已叠满")

    for seed_value in [1, 2, 3, 4, 5, 20240501]:
        for item in shop.stock(pool, seed_value, 2, state):
            assert_ne(str(item["id"]), "a_blade", "叠满的心法不能再上架")


# ============================== 购买 ==============================

func test_buy_spends_coins_and_marks_sold() -> void:
    var shop := _shop()
    var pool := _pool()
    var state := _state(50)
    var items := shop.stock(pool, 20240501, 3, state)

    var first: Dictionary = items[0]
    var price := int(first["price"])
    var id := str(first["id"])

    var result := shop.buy(items, 0, state)
    assert_true(bool(result["ok"]), "有钱应该买得成")
    assert_eq(state.coins, 50 - price, "必须扣掉标价那么多内力")
    assert_eq(state.stack_count(id), 1, "买完应该真的叠了一层")
    assert_true(bool(first["sold"]), "买完必须标记为已售出")


func test_buy_twice_is_refused() -> void:
    var shop := _shop()
    var state := _state(200)
    var items := shop.stock(_pool(), 20240501, 3, state)

    assert_true(bool(shop.buy(items, 0, state)["ok"]), "第一次应该成功")
    var coins_after := state.coins

    var second := shop.buy(items, 0, state)
    assert_false(bool(second["ok"]), "同一件不能买两次")
    assert_contains(str(second["reason"]), "买过", "要说清是已经买过了")
    assert_eq(state.coins, coins_after, "失败时不能扣钱")


func test_buy_without_enough_coins_keeps_coins() -> void:
    var shop := _shop()
    var state := _state(3)
    var items := shop.stock(_pool(), 20240501, 3, state)

    var result := shop.buy(items, 0, state)
    assert_false(bool(result["ok"]), "内力不够不能买")
    assert_contains(str(result["reason"]), "内力不足", "要说清是内力不够")
    assert_eq(state.coins, 3, "买不起的时候一分都不能扣")
    assert_eq(state.upgrades_taken(), 0, "买不起也不能白送心法")


func test_buy_out_of_range_is_safe() -> void:
    var shop := _shop()
    var state := _state()
    var items := shop.stock(_pool(), 20240501, 3, state)

    assert_false(bool(shop.buy(items, -1, state)["ok"]), "负索引不能崩")
    assert_false(bool(shop.buy(items, 99, state)["ok"]), "越界索引不能崩")
    assert_eq(state.coins, 100, "越界不能扣钱")
