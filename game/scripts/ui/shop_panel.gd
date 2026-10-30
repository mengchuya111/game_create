class_name ShopPanel
extends CanvasLayer
## 商店面板：三件货，内力买。
##
## 职责边界：只负责"把货摆出来 + 把玩家按了第几个报上去"。
## 卖什么、多少钱、买不买得起，全部由 Shop（纯逻辑）判定 —— 面板不碰规则。
##
## 操作：数字键 1 / 2 / 3 购买，Esc / 4 / 空格 离开，或者直接点卡片 / 点离开按钮。

## 玩家点了第几个（0 起）。
signal buy_requested(index: int)
## 玩家要走了。
signal closed

const CARD_MIN_SIZE := Vector2(206.0, 128.0)
const RARITY_COLORS := {
    "common": Color(0.86, 0.86, 0.80),
    "rare": Color(0.55, 0.78, 1.0),
    "epic": Color(0.92, 0.68, 1.0),
}
const RARITY_NAMES := {
    "common": "凡品",
    "rare": "上品",
    "epic": "绝品",
}

var _root: Control = null
var _coins_label: Label = null
var _hint_label: Label = null
var _cards: HBoxContainer = null
var _items: Array = []
var _active: bool = false


func _ready() -> void:
    layer = 8
    _build_ui()
    hide_panel()


# ============================== 对外接口 ==============================

## 显示货架。
## @param items   Shop.stock() 的返回值（每项含 id / def / price / sold）
## @param coins   玩家当前内力
## @param subtitle 副标题，例如"第 5 间 · 商店"
func show_stock(items: Array, coins: int, subtitle: String = "") -> void:
    _items = items
    _active = true
    _rebuild(subtitle, coins, "")
    _root.visible = true
    set_process_unhandled_input(true)


## 重新绘制（买完一件之后调，用来刷新"已售出"和内力量）。
func refresh(items: Array, coins: int, message: String = "") -> void:
    _items = items
    if not _active:
        return
    _rebuild(_subtitle(), coins, message)


func hide_panel() -> void:
    _active = false
    if _root != null:
        _root.visible = false
    set_process_unhandled_input(false)


func is_active() -> bool:
    return _active


# ============================== UI 构建 ==============================

func _subtitle() -> String:
    if _root == null:
        return ""
    var node := _root.find_child("Subtitle", true, false)
    return str((node as Label).text) if node is Label else ""


func _build_ui() -> void:
    _root = Control.new()
    _root.name = "Root"
    _root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    _root.mouse_filter = Control.MOUSE_FILTER_STOP
    add_child(_root)

    var dim := ColorRect.new()
    dim.name = "Dim"
    dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    dim.color = Color(0.03, 0.03, 0.05, 0.78)
    dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _root.add_child(dim)

    var center := CenterContainer.new()
    center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    center.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _root.add_child(center)

    var panel := PanelContainer.new()
    panel.add_theme_stylebox_override("panel", _build_panel_style())
    center.add_child(panel)

    var margin := MarginContainer.new()
    margin.add_theme_constant_override("margin_left", 24)
    margin.add_theme_constant_override("margin_right", 24)
    margin.add_theme_constant_override("margin_top", 18)
    margin.add_theme_constant_override("margin_bottom", 18)
    panel.add_child(margin)

    var vbox := VBoxContainer.new()
    vbox.add_theme_constant_override("separation", 8)
    margin.add_child(vbox)

    var title := Label.new()
    title.text = "商 店"
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    title.add_theme_font_size_override("font_size", 22)
    title.add_theme_color_override("font_color", Color(0.96, 0.90, 0.72))
    vbox.add_child(title)

    var subtitle := Label.new()
    subtitle.name = "Subtitle"
    subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    subtitle.add_theme_font_size_override("font_size", 13)
    subtitle.add_theme_color_override("font_color", Color(0.72, 0.72, 0.68))
    vbox.add_child(subtitle)

    _coins_label = Label.new()
    _coins_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _coins_label.add_theme_font_size_override("font_size", 15)
    _coins_label.add_theme_color_override("font_color", Color(0.98, 0.82, 0.36))
    vbox.add_child(_coins_label)

    _cards = HBoxContainer.new()
    _cards.add_theme_constant_override("separation", 12)
    vbox.add_child(_cards)

    _hint_label = Label.new()
    _hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _hint_label.add_theme_font_size_override("font_size", 12)
    _hint_label.add_theme_color_override("font_color", Color(0.70, 0.70, 0.66))
    vbox.add_child(_hint_label)

    var leave := Button.new()
    leave.text = "离开商店（Esc）"
    leave.add_theme_font_size_override("font_size", 13)
    leave.pressed.connect(_request_close)
    vbox.add_child(leave)


func _rebuild(subtitle: String, coins: int, message: String) -> void:
    var subtitle_node := _root.find_child("Subtitle", true, false)
    if subtitle_node is Label:
        (subtitle_node as Label).text = subtitle
    _coins_label.text = "内力 %d" % coins

    _clear_cards()
    for i in range(_items.size()):
        _cards.add_child(_build_card(i, _items[i], coins))

    if message.is_empty():
        _hint_label.text = "按 1 / 2 / 3 购买，Esc 离开"
        _hint_label.add_theme_color_override("font_color", Color(0.70, 0.70, 0.66))
    else:
        _hint_label.text = message
        _hint_label.add_theme_color_override("font_color", Color(0.95, 0.80, 0.45))


func _build_card(index: int, item: Dictionary, coins: int) -> Button:
    var def: Dictionary = item.get("def", {})
    var rarity := str(def.get("rarity", "common"))
    var color: Color = RARITY_COLORS.get(rarity, Color.WHITE)
    var rarity_name: String = RARITY_NAMES.get(rarity, rarity)
    var price := int(item.get("price", 0))
    var sold := bool(item.get("sold", false))
    var affordable := coins >= price

    var status := ""
    var text_color := color
    if sold:
        status = "已售出"
        text_color = Color(0.45, 0.45, 0.45)
    elif not affordable:
        # 买不起也要能看：卡片照常显示，只是灰掉并写明差多少。
        status = "内力不足（还差 %d）" % (price - coins)
        text_color = Color(0.55, 0.52, 0.48)

    var card := Button.new()
    card.name = "Card%d" % index
    card.custom_minimum_size = CARD_MIN_SIZE
    card.disabled = sold
    card.text = "%d. %s\n\n%s\n\n%s · %d 内力%s" % [
        index + 1,
        str(def.get("display_name", "?")),
        str(def.get("description", "")),
        rarity_name,
        price,
        ("\n" + status) if not status.is_empty() else "",
    ]
    card.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    card.add_theme_font_size_override("font_size", 14)
    card.add_theme_color_override("font_color", text_color)
    card.add_theme_color_override("font_hover_color", Color.WHITE)
    card.add_theme_color_override("font_pressed_color", Color(0.8, 0.8, 0.8))
    card.pressed.connect(_on_card_pressed.bind(index))
    return card


func _build_panel_style() -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = Color(0.10, 0.09, 0.12, 0.97)
    style.border_color = Color(0.62, 0.52, 0.28, 0.9)
    style.set_border_width_all(2)
    style.set_corner_radius_all(6)
    style.content_margin_left = 6.0
    style.content_margin_right = 6.0
    return style


func _clear_cards() -> void:
    if _cards == null:
        return
    for child in _cards.get_children():
        _cards.remove_child(child)
        child.queue_free()


# ============================== 输入 ==============================

func _unhandled_input(event: InputEvent) -> void:
    if not _active:
        return
    if not (event is InputEventKey):
        return
    var key := event as InputEventKey
    if not key.pressed or key.echo:
        return

    var index := -1
    match key.physical_keycode:
        KEY_1, KEY_KP_1:
            index = 0
        KEY_2, KEY_KP_2:
            index = 1
        KEY_3, KEY_KP_3:
            index = 2

    if index >= 0 and index < _items.size():
        get_viewport().set_input_as_handled()
        buy_requested.emit(index)
        return

    if key.physical_keycode in [KEY_ESCAPE, KEY_4, KEY_KP_4, KEY_SPACE]:
        get_viewport().set_input_as_handled()
        _request_close()


func _on_card_pressed(index: int) -> void:
    if not _active:
        return
    buy_requested.emit(index)


func _request_close() -> void:
    if not _active:
        return
    # 先关面板再发信号：接收方可能立刻切房间，面板留在屏幕上会挡住下一间房。
    hide_panel()
    closed.emit()
