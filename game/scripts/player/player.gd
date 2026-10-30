class_name Player
extends CharacterBody2D
## 玩家角色。
##
## 职责边界（AI 协作时务必遵守，这是最容易写乱的地方）：
##   本文件 = 把状态机的决策「翻译」成物理动作和判定盒开关。
##   本文件不决定「能不能出招」「第几帧开始有伤害」——
##   那些在 player_fsm.gd 里，因为只有放在纯逻辑类里才能被单元测试验证。
##
## 所以如果你想让"轻击更快一点"，改的是 data/attacks.json，不是这个文件。

# ============================== 手感常量 ==============================
## 起跳初速度（负数 = 向上）。
const JUMP_VELOCITY: float = -430.0
## 冲刺速度。
const DASH_SPEED: float = 430.0
## 冲刺持续帧数。
const DASH_FRAMES: int = 11
## 冲刺冷却帧数。
const DASH_COOLDOWN_FRAMES: int = 24
## 受击硬直帧数。
const HURT_FRAMES: int = 18
## 架势被打空时额外增加的受击硬直帧数。
const STAGGER_EXTRA_FRAMES: int = 12
## 出招前冲速度的每帧衰减。
const LUNGE_DECAY: float = 0.82
## 松开跳跃键后额外的重力倍率（实现"按多久跳多高"）。
const JUMP_CUT_GRAVITY_SCALE: float = 1.9

# ============================== 节点引用 ==============================
@onready var visual: Node2D = $Visual
@onready var hitbox: Hitbox = $Hitbox
@onready var hurtbox: Hurtbox = $Hurtbox
@onready var camera: Camera2D = $Camera2D

# ============================== 逻辑 ==============================
## 状态机（纯逻辑）。
var fsm := PlayerFsm.new()
## 帧数据表，由 main.gd 注入。
var attack_table: AttackTable = null
## 输入录制器，由 main.gd 注入。为 null 时不录制。
var recorder: ReplayRecorder = null
## 重放数据源。不为 null 时，输入完全来自重放，键盘无效。
var replay_source: ReplayRecorder = null

var _dash_frames_left: int = 0
var _dash_cooldown: int = 0
var _lunge_velocity: float = 0.0
var _god_mode: bool = false

# ============================== 局内成长 ==============================
## 本局的成长状态，由 main.gd 注入。为 null 时全部按基础数值行动（单元测试/单场景调试）。
var run_state: RunState = null
## 伤害倍率，喂给 Hitbox.attack_multiplier。
var _damage_multiplier: float = 1.0
## 移速倍率。
var _move_scale: float = 1.0
## 冲刺冷却缩减帧数。
var _dash_cooldown_bonus: int = 0
## 吸血比例。
var _lifesteal: float = 0.0


func _ready() -> void:
    add_to_group("player")
    hurtbox.team = "player"
    # 显式声明阵营。Hitbox.source_team 默认就是 "player"，但写出来更清楚：
    # 判定命中规则是"只打不同阵营"，所以这一行决定了玩家会不会误伤自己。
    hitbox.source_team = "player"
    hurtbox.invuln_frames_on_hit = GameConfig.HURT_INVULN_FRAMES
    hurtbox.reset()
    hurtbox.took_damage.connect(_on_took_damage)
    hurtbox.stagger_requested.connect(_on_stagger_requested)
    hurtbox.died.connect(_on_died)
    # 吸血心法靠这条信号生效。监听的是"敌人掉血"而不是"我打中了谁"，
    # 因为 EventBus.hit_confirmed 不区分攻击方，而 enemy_damaged 只会在敌人身上发出。
    EventBus.enemy_damaged.connect(_on_enemy_damaged)
    _register_console_commands()


## 由 main.gd 调用，注入依赖。
func setup(p_attack_table: AttackTable, p_recorder: ReplayRecorder = null) -> void:
    attack_table = p_attack_table
    recorder = p_recorder
    fsm.attack_table = attack_table
    fsm.buffer_window = GameConfig.INPUT_BUFFER_FRAMES
    fsm.coyote_window = GameConfig.COYOTE_FRAMES
    fsm.reset()


## 重开一局时调用。
## 注意：这里**不动 global_position**。出生点由 main.gd 决定（arena.floor_y），
## 如果这里把坐标清零，玩家会掉到地板下面去。
## 需要挪位置请传 spawn_position，或者调用方自己设 position。
func reset_player(spawn_position: Variant = null) -> void:
    if spawn_position is Vector2:
        global_position = spawn_position
    velocity = Vector2.ZERO
    _dash_frames_left = 0
    _dash_cooldown = 0
    _lunge_velocity = 0.0
    fsm.reset()
    hurtbox.reset()
    hitbox.end_swing()
    replay_source = null


## 应用本局的心法成长。
##
## 为什么生命值要由调用方"带过来"（carried_hp / carried_max_hp）：
##   换房间会重新实例化玩家，新实例的血量是场景默认的满血。
##   如果这里无条件按上限补满，玩家每过一关就自动回满血 ——
##   看起来像"关卡奖励"，实际上把回春类心法和血量管理全废掉了。
##
## @param state          本局成长状态
## @param carried_hp      上一间房结束时的血量；-1 表示这是新生成（按满血）
## @param carried_max_hp  上一间房结束时的生命上限；-1 表示用当前上限
func apply_run_state(state: RunState, carried_hp: int = -1, carried_max_hp: int = -1) -> void:
    run_state = state
    if state == null:
        return

    _damage_multiplier = state.damage_multiplier()
    _move_scale = state.move_speed_multiplier()
    _dash_cooldown_bonus = state.dash_cooldown_reduction()
    _lifesteal = state.lifesteal()

    var new_max: int = GameConfig.PLAYER_BASE_MAX_HP + state.max_hp_bonus()
    var old_max: int = carried_max_hp if carried_max_hp > 0 else hurtbox.max_hp
    hurtbox.max_hp = new_max

    if carried_hp >= 0:
        # 生命上限变高的那一部分直接补给玩家（"变厚"），而不是按比例保留。
        # 否则加了 40 上限、血却还是原来那些，玩家会觉得这颗心法没生效。
        var bonus_heal := maxi(0, new_max - old_max)
        hurtbox.hp = clampi(carried_hp + bonus_heal, 1, new_max)
    else:
        hurtbox.hp = new_max

    hitbox.attack_multiplier = _damage_multiplier


## 治疗。绕不过 Hurtbox —— 血量只能由它改（见 AGENTS.md 规矩 2）。
func heal(amount: int) -> int:
    return hurtbox.heal(amount)


func _physics_process(delta: float) -> void:
    var input := _read_input()
    var result := fsm.tick(input, is_on_floor(), velocity.y)

    _apply_gravity(delta, input)
    _apply_horizontal(input)
    _apply_jump(result)
    _apply_dash(result)
    _apply_attack_lunge(result)
    _sync_hitbox(result)
    _relay_events(result)
    _sync_visual()
    _sync_camera()

    move_and_slide()


## 把状态机报告出来的事件转发到事件总线。
## 状态机是纯逻辑类，不能直接引用 Autoload，所以由本文件负责"转播"。
func _relay_events(result: Dictionary) -> void:
    var phase := str(result.get("attack_phase", ""))
    if not phase.is_empty():
        EventBus.attack_phase_changed.emit(
            str(result.get("attack_id", "")), phase, int(result.get("state_frame", 0))
        )


# ============================== 输入 ==============================

func _read_input() -> PlayerInputFrame:
    if GameConfig.input_locked:
        return PlayerInputFrame.new()

    if replay_source != null:
        var replay_frame := replay_source.next_frame()
        if replay_frame == null:
            EventBus.console_line.emit("[重放] 播放结束（共 %d 帧）" % replay_source.frame_count())
            replay_source = null
            return PlayerInputFrame.new()
        if replay_source.is_playback_finished():
            EventBus.console_line.emit("[重放] 播放结束（共 %d 帧）" % replay_source.frame_count())
            replay_source = null
        return replay_frame

    var frame := PlayerInputFrame.sample()
    if recorder != null and recorder.is_recording():
        recorder.record(frame)
    return frame


# ============================== 物理 ==============================

func _apply_gravity(delta: float, input: PlayerInputFrame) -> void:
    if is_on_floor():
        if velocity.y > 0.0:
            velocity.y = 0.0
        return

    var gravity := GameConfig.GRAVITY
    # 上升途中松开跳跃键 → 加重力，让跳跃高度随按键时长变化
    if velocity.y < 0.0 and not input.jump_held:
        gravity *= JUMP_CUT_GRAVITY_SCALE

    velocity.y = minf(velocity.y + gravity * delta, GameConfig.MAX_FALL_SPEED)


func _apply_horizontal(input: PlayerInputFrame) -> void:
    if fsm.state == PlayerFsm.State.DIE:
        velocity.x = move_toward(velocity.x, 0.0, 900.0 * get_physics_process_delta_time())
        return

    # 1. 冲刺优先
    if _dash_frames_left > 0:
        velocity.x = DASH_SPEED * float(fsm.facing)
        return

    # 2. 出招前冲惯性（制造"贴身"感）
    if absf(_lunge_velocity) > 2.0:
        velocity.x = _lunge_velocity
        _lunge_velocity *= LUNGE_DECAY
        return
    _lunge_velocity = 0.0

    # 3. 出招 / 受击期间不接受移动输入，但会逐渐停下
    if fsm.state == PlayerFsm.State.ATTACK or fsm.state == PlayerFsm.State.HURT:
        velocity.x = move_toward(velocity.x, 0.0, 1200.0 * get_physics_process_delta_time())
        return

    # 4. 正常移动
    velocity.x = float(input.move_axis()) * GameConfig.MOVE_SPEED * _move_scale


func _apply_jump(result: Dictionary) -> void:
    if not bool(result.get("jump_requested", false)):
        return
    velocity.y = JUMP_VELOCITY
    _dash_frames_left = 0


func _apply_dash(result: Dictionary) -> void:
    if _dash_cooldown > 0:
        _dash_cooldown -= 1

    if _dash_frames_left > 0:
        _dash_frames_left -= 1
        return

    if bool(result.get("dash_requested", false)) and _dash_cooldown <= 0:
        _dash_frames_left = DASH_FRAMES
        _dash_cooldown = maxi(
            GameConfig.MIN_DASH_COOLDOWN_FRAMES,
            DASH_COOLDOWN_FRAMES - _dash_cooldown_bonus
        )
        _lunge_velocity = 0.0
        # 冲刺带无敌帧 —— 这是横版动作游戏"翻滚躲招"的核心
        hurtbox.invuln_frames = maxi(hurtbox.invuln_frames, DASH_FRAMES)


func _apply_attack_lunge(result: Dictionary) -> void:
    var started: Variant = result.get("attack_started", null)
    if started is AttackDef:
        var def: AttackDef = started
        _lunge_velocity = def.move_impulse * float(fsm.facing)
        _dash_frames_left = 0


# ============================== 判定盒 ==============================

func _sync_hitbox(result: Dictionary) -> void:
    if bool(result.get("hitbox_open", false)):
        var def: Variant = result.get("hitbox_def", null)
        if def is AttackDef:
            var attack: AttackDef = def
            var combo := int(result.get("hitbox_combo_index", 0))
            # 同一段挥击内不重置命中记录，保证一次挥击只打一次；
            # 连段切到下一招时重置，允许再打一次。
            if (
                not hitbox.is_swinging()
                or hitbox.attack_def != attack
                or hitbox.combo_index != combo
            ):
                # 每次挥击都重新写一遍倍率：心法在房间之间才变化，
                # 但显式写入能避免"上一局的高倍率残留到这一局"这类脏状态。
                hitbox.attack_multiplier = _damage_multiplier
                hitbox.begin_swing(attack, combo, int(result.get("hitbox_facing", fsm.facing)))
            return

    if hitbox.is_swinging():
        hitbox.end_swing()


# ============================== 表现 ==============================

func _sync_visual() -> void:
    visual.scale.x = float(fsm.facing)
    visual.modulate = Color.WHITE

    if fsm.state == PlayerFsm.State.DIE:
        visual.modulate = Color(0.45, 0.45, 0.45, 0.75)
        visual.rotation = deg_to_rad(80.0 * float(fsm.facing))
        return

    visual.rotation = 0.0

    # 无敌帧闪烁：让玩家看得出"现在打不到我"
    if hurtbox.is_invulnerable():
        var blink := int(Time.get_ticks_msec() / 70) % 2 == 0
        visual.modulate.a = 0.4 if blink else 1.0

    # 起手帧给一点前倾，让出招更有"预备感"
    if fsm.state == PlayerFsm.State.ATTACK and fsm.current_attack != null:
        if fsm.current_attack.phase_at(fsm.state_frame) == "startup":
            visual.scale.x *= 0.92


func _sync_camera() -> void:
    if camera != null and camera.has_method("set_facing"):
        camera.set_facing(fsm.facing)


# ============================== 事件 ==============================

func _on_took_damage(_amount: int, _remaining_hp: int, attacker: Hitbox) -> void:
    if _god_mode:
        return
    fsm.apply_hurt(HURT_FRAMES)
    var knockback := hurtbox.knockback_vector(attacker)
    velocity = knockback
    _dash_frames_left = 0
    _lunge_velocity = 0.0


func _on_stagger_requested(_amount: int) -> void:
    if _god_mode or hurtbox.is_dead():
        return
    # 架势打空时覆盖普通受击硬直，取更长时长而不是重复叠加。
    fsm.apply_hurt(HURT_FRAMES + STAGGER_EXTRA_FRAMES)


func _on_died() -> void:
    fsm.apply_death()


## 敌人掉血 → 按吸血比例回血。
## 小数值取整后为 0 时不治疗，避免每刀都触发一次治疗事件把 HUD 刷爆。
func _on_enemy_damaged(amount: int, _remaining_hp: int, _world_pos: Vector2) -> void:
    if _lifesteal <= 0.0 or hurtbox.is_dead() or amount <= 0:
        return
    var healed := int(floor(float(amount) * _lifesteal))
    if healed > 0:
        hurtbox.heal(healed)


# ============================== 调试命令 ==============================

func _register_console_commands() -> void:
    # 玩家每换一间房都会重新实例化，而这些命令必须指向"当前这个玩家"，
    # 所以统一用 replace = true 刻意覆盖，避免每次换房刷一堆重复注册警告。
    _register_command("god", "", "开关无敌模式", _cmd_god)
    _register_command("hp", "<数值>", "设置玩家血量", _cmd_hp)
    _register_command("pos", "", "打印玩家当前坐标和状态", _cmd_pos)
    _register_command("attack", "<招式id>", "切换默认起手招式", _cmd_attack)
    _register_command("tp", "<x> <y>", "把玩家传送到指定坐标", _cmd_tp)


func _register_command(cmd_name: String, args: String, help: String, callback: Callable) -> void:
    EventBus.register_console_command(cmd_name, args, help, callback, true)


func _cmd_god(_args: PackedStringArray) -> String:
    _god_mode = not _god_mode
    if _god_mode:
        hurtbox.invuln_frames = 1 << 30
        return "无敌模式：开"
    hurtbox.invuln_frames = 0
    return "无敌模式：关"


func _cmd_hp(args: PackedStringArray) -> String:
    if args.is_empty():
        return "当前血量 %d / %d" % [hurtbox.hp, hurtbox.max_hp]
    var value := clampi(int(args[0]), 0, hurtbox.max_hp)
    hurtbox.hp = value
    if value == 0:
        hurtbox.dead = true
        hurtbox.died.emit()
        EventBus.player_died.emit()
    return "血量设为 %d / %d" % [hurtbox.hp, hurtbox.max_hp]


func _cmd_pos(_args: PackedStringArray) -> String:
    return "位置=(%.1f, %.1f)  速度=(%.1f, %.1f)  状态=%s  帧=%d  连段=%d" % [
        global_position.x, global_position.y,
        velocity.x, velocity.y,
        fsm.state_name(), fsm.state_frame, fsm.combo_index,
    ]


func _cmd_attack(args: PackedStringArray) -> String:
    if args.is_empty():
        return "用法：attack <招式id>。当前默认招式：%s" % fsm.default_attack_id
    if attack_table == null or not attack_table.has_attack(args[0]):
        return "找不到招式「%s」。可用：%s" % [args[0], ", ".join(Array(attack_table.ids())) if attack_table != null else "（帧数据表未加载）"]
    fsm.default_attack_id = args[0]
    return "默认起手招式改为「%s」" % args[0]


func _cmd_tp(args: PackedStringArray) -> String:
    if args.size() < 2:
        return "用法：tp <x> <y>"
    global_position = Vector2(float(args[0]), float(args[1]))
    velocity = Vector2.ZERO
    return "已传送到 (%.1f, %.1f)" % [global_position.x, global_position.y]
