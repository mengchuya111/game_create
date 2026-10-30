extends CanvasLayer
## 游戏内调试台（按 ` 或 F1 打开）
##
## 为什么肉鸽游戏一定要有调试台：
##   你要测"第 3 段连招打精英怪会不会把它打出硬直"，
##   如果没有调试台，你得先打 4 分钟才走到精英房。
##   有了调试台，你可以直接给玩家改血量、换招式、重开指定种子、导出快照。
##
## 命令是「注册制」：任何模块都能在 _ready() 里调用
##   EventBus.register_console_command("命令名", "<参数>", "说明", Callable)
## 把自己的调试命令挂上来。所以本文件不需要认识任何具体系统。

const MAX_LINES := 300

var _panel: Control = null
var _output: RichTextLabel = null
var _input_line: LineEdit = null

var _open: bool = false
var _lines: PackedStringArray = PackedStringArray()
var _history: PackedStringArray = PackedStringArray()
var _history_index: int = -1


func _ready() -> void:
    _build_ui()
    EventBus.console_line.connect(_on_console_line)
    _register_builtin_commands()
    set_open(false)


# ============================== UI ==============================

func _build_ui() -> void:
    _panel = Control.new()
    _panel.name = "Panel"
    _panel.anchor_left = 0.0
    _panel.anchor_right = 1.0
    _panel.anchor_top = 1.0
    _panel.anchor_bottom = 1.0
    _panel.offset_left = 0.0
    _panel.offset_right = 0.0
    _panel.offset_top = -260.0
    _panel.offset_bottom = 0.0
    add_child(_panel)

    var background := ColorRect.new()
    background.name = "Background"
    background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    background.color = Color(0.04, 0.04, 0.07, 0.93)
    background.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _panel.add_child(background)

    var margin := MarginContainer.new()
    margin.name = "Margin"
    margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    margin.add_theme_constant_override("margin_left", 12)
    margin.add_theme_constant_override("margin_right", 12)
    margin.add_theme_constant_override("margin_top", 8)
    margin.add_theme_constant_override("margin_bottom", 8)
    _panel.add_child(margin)

    var vbox := VBoxContainer.new()
    vbox.name = "VBox"
    vbox.add_theme_constant_override("separation", 6)
    margin.add_child(vbox)

    _output = RichTextLabel.new()
    _output.name = "Output"
    _output.bbcode_enabled = false
    _output.scroll_following = true
    _output.size_flags_vertical = Control.SIZE_EXPAND_FILL
    _output.add_theme_font_size_override("normal_font_size", 13)
    _output.add_theme_color_override("default_color", Color(0.85, 0.93, 0.85))
    vbox.add_child(_output)

    _input_line = LineEdit.new()
    _input_line.name = "Input"
    _input_line.placeholder_text = "输入命令后回车。输入 help 查看全部命令"
    _input_line.add_theme_font_size_override("font_size", 14)
    _input_line.text_submitted.connect(_on_text_submitted)
    vbox.add_child(_input_line)


# ============================== 开关 ==============================

func _input(event: InputEvent) -> void:
    if event.is_action_pressed("toggle_console"):
        set_open(not _open)
        get_viewport().set_input_as_handled()
        return

    if _open and event.is_action_pressed("ui_cancel"):
        set_open(false)
        get_viewport().set_input_as_handled()


func set_open(value: bool) -> void:
    _open = value
    if _panel != null:
        _panel.visible = value
    # 锁住玩家输入，否则打字的时候角色会跟着乱跑
    GameConfig.input_locked = value
    if value:
        if _input_line != null:
            _input_line.grab_focus()
            _input_line.clear()
        _history_index = _history.size()
    elif _input_line != null:
        _input_line.release_focus()


func is_open() -> bool:
    return _open


# ============================== 输出 ==============================

func _on_console_line(text: String) -> void:
    _append(text)


func _append(text: String) -> void:
    for line in text.split("\n"):
        _lines.append(line)
    while _lines.size() > MAX_LINES:
        _lines.remove_at(0)
    if _output != null:
        _output.text = "\n".join(_lines)
        _output.scroll_to_line(maxi(0, _lines.size() - 1))


# ============================== 输入处理 ==============================

func _on_text_submitted(text: String) -> void:
    var trimmed := text.strip_edges()
    if not trimmed.is_empty():
        _history.append(trimmed)
        _history_index = _history.size()
    _execute(trimmed)
    if _input_line != null:
        _input_line.clear()
        _input_line.grab_focus()


func _execute(text: String) -> void:
    if text.is_empty():
        return

    _append("> " + text)

    var parts := text.split(" ", false)
    if parts.is_empty():
        return

    var command_name := parts[0]
    var args := PackedStringArray()
    for i in range(1, parts.size()):
        args.append(parts[i])

    if not EventBus.console_commands.has(command_name):
        _append("未知命令「%s」。输入 help 查看全部命令" % command_name)
        return

    var entry: Dictionary = EventBus.console_commands[command_name]
    var callback: Callable = entry.get("callable", Callable())
    if not callback.is_valid():
        _append("命令「%s」的处理器已失效" % command_name)
        return

    var result: Variant = callback.call(args)
    if result is String and not (result as String).is_empty():
        _append(result)


# ============================== 内置命令 ==============================

func _register_builtin_commands() -> void:
    EventBus.register_console_command("help", "[命令名]", "列出全部命令，或查看某条命令的说明", _cmd_help)
    EventBus.register_console_command("clear", "", "清空调试台输出", _cmd_clear)
    EventBus.register_console_command("hide", "", "关闭调试台", _cmd_hide)


func _cmd_help(args: PackedStringArray) -> String:
    if not args.is_empty():
        var target := args[0]
        if not EventBus.console_commands.has(target):
            return "没有命令「%s」" % target
        var entry: Dictionary = EventBus.console_commands[target]
        return "%s %s\n    %s" % [target, entry.get("args", ""), entry.get("help", "")]

    var names: Array = EventBus.console_commands.keys()
    names.sort()

    var lines: PackedStringArray = PackedStringArray()
    lines.append("可用命令（共 %d 条）：" % names.size())
    for command_name in names:
        var entry: Dictionary = EventBus.console_commands[command_name]
        var args_text := str(entry.get("args", ""))
        var signature := "%s %s" % [command_name, args_text]
        lines.append("  %-22s %s" % [signature, entry.get("help", "")])
    return "\n".join(lines)


func _cmd_clear(_args: PackedStringArray) -> String:
    _lines = PackedStringArray()
    if _output != null:
        _output.text = ""
    return ""


func _cmd_hide(_args: PackedStringArray) -> String:
    set_open(false)
    return ""
