class_name RewardPanel
extends CanvasLayer
## 清房奖励面板：三选一。
##
## 职责边界：只负责"把选项画出来 + 把玩家按了第几个报上去"。
## 抽什么、给什么效果，全部由 main.gd（UpgradePool + RunState）决定。
## 面板不认识心法数据，也不知道玩家当前属性 —— 这样改 UI 不会碰坏规则。
##
## 操作：数字键 1 / 2 / 3，或者直接点卡片。
## 注意：面板显示期间 GameConfig.input_locked 为 true，角色不会动，
## 但敌人和物理照常运行（不是暂停），所以别把面板当成安全区。

## 玩家选定了第几个（0 起）。
signal chosen(index: int)

const CARD_MIN_SIZE := Vector2(212.0, 132.0)
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
var _subtitle: Label = null
var _cards: HBoxContainer = null
var _choices: Array = []
var _active: bool = false


func _ready() -> void:
    layer = 8
    _build_ui()
    hide_panel()


# ============================== 对外接口 ==============================

## 显示一组选项。
## @param choices  每个元素是 data/upgrades.json 里的一条定义（含 id / display_name / description / rarity / max_stacks）
## @param subtitle 面板副标题，例如"第 3 间 · 战斗房"
func show_choices(choices: Array, subtitle: String = "") -> void:
    _choices = choices.duplicate()
    _active = not _choices.is_empty()
    if not _active:
        hide_panel()
        return

    _subtitle.text = subtitle
    _clear_cards()

    for i in range(_choices.size()):
        var def: Dictionary = _choices[i]
        _cards.add_child(_build_card(i, def))

    _root.visible = true
    set_process_unhandled_input(true)


func hide_panel() -> void:
    _active = false
    _choices = []
    if _root != null:
        _root.visible = false
    set_process_unhandled_input(false)


func is_active() -> bool:
    return _active


# ============================== UI 构建 ==============================

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
    center.name = "Center"
    center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    center.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _root.add_child(center)

    var panel := PanelContainer.new()
    panel.name = "Panel"
    panel.add_theme_stylebox_override("panel", _build_panel_style())
    center.add_child(panel)

    var margin := MarginContainer.new()
    margin.add_theme_constant_override("margin_left", 24)
    margin.add_theme_constant_override("margin_right", 24)
    margin.add_theme_constant_override("margin_top", 18)
    margin.add_theme_constant_override("margin_bottom", 18)
    panel.add_child(margin)

    var vbox := VBoxContainer.new()
    vbox.add_theme_constant_override("separation", 10)
    margin.add_child(vbox)

    var title := Label.new()
    title.text = "心 法 三 选 一"
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    title.add_theme_font_size_override("font_size", 22)
    title.add_theme_color_override("font_color", Color(0.96, 0.90, 0.72))
    vbox.add_child(title)

    _subtitle = Label.new()
    _subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _subtitle.add_theme_font_size_override("font_size", 13)
    _subtitle.add_theme_color_override("font_color", Color(0.72, 0.72, 0.68))
    vbox.add_child(_subtitle)

    _cards = HBoxContainer.new()
    _cards.name = "Cards"
    _cards.add_theme_constant_override("separation", 12)
    vbox.add_child(_cards)

    var hint := Label.new()
    hint.text = "按 1 / 2 / 3 选择，或直接点击卡片"
    hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    hint.add_theme_font_size_override("font_size", 12)
    hint.add_theme_color_override("font_color", Color(0.62, 0.62, 0.58))
    vbox.add_child(hint)


func _build_card(index: int, def: Dictionary) -> Button:
    var rarity := str(def.get("rarity", "common"))
    var color: Color = RARITY_COLORS.get(rarity, Color.WHITE)
    var rarity_name: String = RARITY_NAMES.get(rarity, rarity)
    var max_stacks := int(def.get("max_stacks", 1))

    var card := Button.new()
    card.name = "Card%d" % index
    card.custom_minimum_size = CARD_MIN_SIZE
    card.text = "%d. %s\n\n%s\n\n%s · 可叠 %d 层" % [
        index + 1,
        str(def.get("display_name", "?")),
        str(def.get("description", "")),
        rarity_name,
        max_stacks,
    ]
    card.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    card.add_theme_font_size_override("font_size", 14)
    card.add_theme_color_override("font_color", color)
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
        # 先 remove_child 再 queue_free：否则本帧内新旧卡片会同时参与布局，
        # 面板会闪一下。这个坑在 arena._clear_room() 的注释里有同样的解释。
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

    if index >= 0 and index < _choices.size():
        get_viewport().set_input_as_handled()
        _select(index)


func _on_card_pressed(index: int) -> void:
    _select(index)


func _select(index: int) -> void:
    if not _active:
        return
    if index < 0 or index >= _choices.size():
        return
    # 先关面板再发信号：信号接收方可能立刻切房间、重开一局，
    # 面板保持在屏幕上会挡住新的一局。
    hide_panel()
    chosen.emit(index)
