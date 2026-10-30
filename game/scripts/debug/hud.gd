extends CanvasLayer
## 调试 HUD。
##
## 显示当前这一局的「体检数据」：种子、房间、状态机状态、帧数、顿帧、震动、FPS。
## 调手感的时候盯着这个看，比盯着角色看有用得多 ——
## 你能直接看到"这一下顿了几帧""现在是起手帧还是判定帧"。
##
## 按 F2 可以切换显示 / 隐藏（见 _unhandled_input）。

var _label: Label = null
var _visible: bool = true


func _ready() -> void:
    _label = Label.new()
    _label.position = Vector2(12.0, 8.0)
    _label.add_theme_font_size_override("font_size", 13)
    _label.add_theme_color_override("font_color", Color(0.94, 0.93, 0.84))
    _label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.95))
    _label.add_theme_constant_override("outline_size", 5)
    add_child(_label)


func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventKey:
        var key := event as InputEventKey
        if key.pressed and not key.echo and key.physical_keycode == KEY_F2:
            _visible = not _visible
            get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
    if _label == null:
        return
    _label.visible = _visible and GameConfig.show_debug_hud
    if not _label.visible:
        return
    _label.text = _compose_text()


func _compose_text() -> String:
    var lines: PackedStringArray = PackedStringArray()

    lines.append("FPS %d   种子 %d" % [Engine.get_frames_per_second(), GameConfig.run_seed])

    var main_node := get_tree().get_first_node_in_group("main")
    if main_node != null and main_node.has_method("hud_summary"):
        lines.append(str(main_node.call("hud_summary")))

    var player := get_tree().get_first_node_in_group("player")
    if player != null and player is Player:
        var p: Player = player
        var hp_text := "%d / %d" % [p.hurtbox.hp, p.hurtbox.max_hp]
        var poise_text := "%.0f / %.0f" % [p.hurtbox.poise, p.hurtbox.max_poise]
        lines.append("血量 %s   架势 %s" % [hp_text, poise_text])
        lines.append("状态 %s  帧 %d  朝向 %s  连段 %d" % [
            p.fsm.state_name(),
            p.fsm.state_frame,
            "右" if p.fsm.facing > 0 else "左",
            p.fsm.combo_index,
        ])
        var attack := p.fsm.current_attack
        if attack != null:
            var phase := attack.phase_at(p.fsm.state_frame)
            var phase_cn := {"startup": "起手", "active": "判定", "recovery": "收招", "end": "结束"}
            lines.append("招式 %s  %s  %d/%d 帧" % [
                attack.display_name,
                phase_cn.get(phase, phase),
                p.fsm.state_frame + 1,
                attack.total_frames,
            ])
        if p.hurtbox.invuln_frames > 0:
            lines.append("无敌帧 %d" % p.hurtbox.invuln_frames)

    var director := get_tree().get_first_node_in_group("combat_director")
    if director != null and director.has_method("debug_summary"):
        lines.append(str(director.call("debug_summary")))

    var arena := get_tree().get_first_node_in_group("arena")
    if arena != null and arena.has_method("living_enemy_count"):
        lines.append("场上敌人 %d" % int(arena.call("living_enemy_count")))

    lines.append("按 ` 或 F1 打开调试台   F2 隐藏本面板")
    return "\n".join(lines)
