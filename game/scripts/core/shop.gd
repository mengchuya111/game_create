class_name Shop
extends RefCounted
## 商店房：把心法摆上货架，用内力买。
##
## 职责边界（和 UpgradePool / RewardPanel 一样的三段切分）：
##   Shop        决定"卖什么、多少钱、能不能买"（纯逻辑，可单测）
##   ShopPanel   只负责画出来 + 把玩家按了第几个报上去
##   main.gd     负责什么时候开商店、买完怎么结算到玩家身上
##
## 为什么价格按稀有度统一，而不是给每条心法单独定价：
##   心法会一直加，一条条定价没人维护得住，最后必然出现"凡品比绝品还贵"。
##   统一按稀有度定价，配合 upgrades.json 里的稀有度权重，就能保证贵的一定是稀有的。
##   真要特殊定价，在那条心法里加 "price" 字段即可覆盖（见 _price_of）。

const DEFAULT_PATH := "res://data/shop.json"
const DEFAULT_OFFER_COUNT := 3
const DEFAULT_PRICE := 10
## 货架种子的盐值。保证"同一间房的商店"和"这间房的三选一"不会抽出同样三条。
const STOCK_SALT := 977

## 稀有度 -> 价格（内力）。
var _rarity_price: Dictionary = {}
## 一次摆几件。
var _offer_count: int = DEFAULT_OFFER_COUNT
var load_error: String = ""


# ============================== 载入 ==============================

func load_from_file(path: String = DEFAULT_PATH) -> Error:
    load_error = ""
    if not FileAccess.file_exists(path):
        load_error = "找不到 %s" % path
        return ERR_FILE_NOT_FOUND

    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        load_error = "打不开 %s" % path
        return ERR_FILE_CANT_OPEN

    var text := file.get_as_text()
    file.close()

    var parsed: Variant = JSON.parse_string(text)
    if not (parsed is Dictionary):
        load_error = "%s 不是合法的 JSON 对象" % path
        return ERR_PARSE_ERROR

    load_from_dict(parsed)
    return OK if load_error.is_empty() else ERR_INVALID_DATA


func load_from_dict(root: Dictionary) -> void:
    load_error = ""
    _rarity_price = {}
    _offer_count = DEFAULT_OFFER_COUNT

    var price_table: Variant = root.get("rarity_price", {})
    if price_table is Dictionary:
        for rarity in (price_table as Dictionary).keys():
            var value: Variant = (price_table as Dictionary)[rarity]
            if not (value is int or value is float):
                load_error = "rarity_price.%s 不是数字" % str(rarity)
                continue
            if int(value) <= 0:
                load_error = "rarity_price.%s 必须大于 0" % str(rarity)
                continue
            _rarity_price[str(rarity)] = int(value)
    elif price_table != null:
        load_error = "rarity_price 必须是对象"

    var count: Variant = root.get("offer_count", DEFAULT_OFFER_COUNT)
    if count is int or count is float:
        _offer_count = maxi(1, int(count))
    else:
        load_error = "offer_count 必须是数字"


# ============================== 对外接口 ==============================

func offer_count() -> int:
    return _offer_count


## 某条心法卖多少钱。心法自带 "price" 时优先用它。
func price_of(def: Dictionary) -> int:
    var explicit: Variant = def.get("price", null)
    if explicit is int or explicit is float:
        return maxi(1, int(explicit))

    var rarity := str(def.get("rarity", "common"))
    if _rarity_price.has(rarity):
        return int(_rarity_price[rarity])
    return DEFAULT_PRICE


## 生成货架。
##
## 每条是 { id, def, price, sold }，sold 由商店自己维护 —— 买过的还留在货架上，
## 只是不能再买（灰掉比直接消失更好：玩家能看见"我刚买了什么"）。
## 复用了 UpgradePool.roll：叠满的心法不会上架，这一点和奖励三选一规则一致。
func stock(
    pool: UpgradePool,
    run_seed: int,
    room_index: int,
    state: RunState
) -> Array:
    var items: Array = []
    if pool == null:
        return items

    var picked := pool.roll(run_seed, room_index, state, _offer_count, STOCK_SALT)
    for raw in picked:
        if not (raw is Dictionary):
            continue
        var def: Dictionary = raw
        items.append({
            "id": str(def.get("id", "")),
            "def": def,
            "price": price_of(def),
            "sold": false,
        })
    return items


## 买第 index 件。
##
## @return { ok: bool, reason: String, item: Dictionary }
##   reason 是给玩家看的一句话，失败时说明为什么买不了。
func buy(items: Array, index: int, state: RunState) -> Dictionary:
    if state == null:
        return {"ok": false, "reason": "没有局内状态", "item": {}}
    if index < 0 or index >= items.size():
        return {"ok": false, "reason": "没有这件货", "item": {}}

    var item: Dictionary = items[index]
    var def: Dictionary = item.get("def", {})
    var display_name := str(def.get("display_name", item.get("id", "?")))

    if bool(item.get("sold", false)):
        return {"ok": false, "reason": "「%s」已经买过了" % display_name, "item": item}

    if state.stack_count(str(item.get("id", ""))) >= int(def.get("max_stacks", 1)):
        return {"ok": false, "reason": "「%s」已经叠满了" % display_name, "item": item}

    var price := int(item.get("price", DEFAULT_PRICE))
    if state.coins < price:
        return {
            "ok": false,
            "reason": "内力不足：需要 %d，只有 %d" % [price, state.coins],
            "item": item,
        }

    if not state.spend_coins(price):
        return {"ok": false, "reason": "内力不足", "item": item}

    if not state.take_upgrade(def):
        # 扣了钱却没拿到东西是绝对不能接受的，退回内力并报错。
        state.add_coins(price)
        return {"ok": false, "reason": "「%s」无法获得，内力已退回" % display_name, "item": item}

    item["sold"] = true
    return {"ok": true, "reason": "买下「%s」" % display_name, "item": item}
