class_name PlayerFsm
extends RefCounted
## 玩家状态机 —— 纯逻辑类，不依赖场景树，因此可以被单元测试完整覆盖。
##
## 这是整个项目里最值得写测试的一个类。原因：
##   战斗手感 = 状态机的行为。帧数据配好了，但状态机取消窗口判断错了，
##   连招就会断；无敌帧算错了，玩家就会莫名掉血。
##   这些东西靠"玩"很难稳定复现，靠单元测试却一测一个准。
##
## 状态转移图：
##
##                 ┌──────────────────────────────┐
##                 ▼                              │
##      ┌─────► IDLE ◄────► RUN                    │
##      │        │  ▲                             │
##      │        ▼  │                             │
##      │      JUMP / FALL ◄──────────────────┐   │
##      │        │                            │   │
##      │        ▼                            │   │
##      │      ATTACK ──(取消窗口内按攻击)──► ATTACK(下一段)
##      │        │                            │   │
##      │        └──(打完/被取消)─────────────┘   │
##      │                                        │
##      └──────── HURT ◄──────────────────────────┘
##                 │
##                 ▼
##                DIE（终态）

enum State {
    IDLE,    ## 站立
    RUN,     ## 跑动
    JUMP,    ## 上升中
    FALL,    ## 下落中
    ATTACK,  ## 出招中
    HURT,    ## 受击硬直
    DIE,     ## 死亡（终态）
}

## 每个状态的显示名，用于调试 HUD。
const STATE_NAMES := {
    State.IDLE: "IDLE",
    State.RUN: "RUN",
    State.JUMP: "JUMP",
    State.FALL: "FALL",
    State.ATTACK: "ATTACK",
    State.HURT: "HURT",
    State.DIE: "DIE",
}

# ============================== 状态 ==============================
var state: int = State.IDLE
## 当前状态已经过的帧数（0 起）。招式的帧判定全部基于它。
var state_frame: int = 0
## 朝向：1 右，-1 左。
var facing: int = 1

# ============================== 招式 ==============================
var attack_table: AttackTable = null
## 当前正在执行的招式，不在 ATTACK 状态时为 null。
var current_attack: AttackDef = null
## 当前这一招在连段中的序号（0 = 第一招）。用于连段伤害递减。
var combo_index: int = 0
## 默认起手招式（按攻击键时从哪一招开始）。
var default_attack_id: String = "light_1"

# ============================== 输入缓冲 ==============================
## 输入缓冲窗口（帧）。玩家在收招结束前提前按键，会被记住这么多帧。
var buffer_window: int = 6
## 土狼时间窗口（帧）。
var coyote_window: int = 6

var _buffer_frames: int = 0
var _buffered_attack: String = ""
var _coyote_frames: int = 0
var _hurt_frames: int = 20
var _last_reported_phase: String = ""
var _just_entered: bool = false


func _init(p_table: AttackTable = null, p_buffer: int = 6, p_coyote: int = 6) -> void:
    attack_table = p_table
    buffer_window = maxi(0, p_buffer)
    coyote_window = maxi(0, p_coyote)


## 重置到初始状态。重开一局时必须调用。
func reset() -> void:
    state = State.IDLE
    state_frame = 0
    facing = 1
    current_attack = null
    combo_index = 0
    _buffer_frames = 0
    _buffered_attack = ""
    _coyote_frames = 0
    _last_reported_phase = ""
    _just_entered = false


# ============================== 主循环 ==============================

## 推进一帧。
## @param input             本帧输入
## @param on_floor          本帧是否站在地面
## @param vertical_velocity 本帧垂直速度（负数 = 上升），用于区分 JUMP / FALL
## @return 本帧发生的事件，供 player.gd 应用（施加冲量、开关判定盒等）
func tick(input: PlayerInputFrame, on_floor: bool, vertical_velocity: float = 0.0) -> Dictionary:
    var result := _empty_result()
    var previous_state := state

    _update_facing(input)
    _update_input_buffer(input)
    _update_coyote(on_floor)

    var frame := state_frame
    var state_before_tick := state

    match state:
        State.ATTACK:
            _tick_attack(frame, input, on_floor, result)
        State.HURT:
            _tick_hurt(frame, result)
        State.DIE:
            pass
        _:
            _tick_locomotion(input, on_floor, vertical_velocity, result)

    var entered := _just_entered
    if entered:
        _just_entered = false
    else:
        state_frame += 1

    result["state"] = state
    result["state_changed"] = state != previous_state
    result["previous_state"] = previous_state
    result["state_frame"] = frame

    # 判定盒开关：由状态机决定，player.gd 只负责照着做。
    # 这样"第几帧开始有伤害"这件事可以被单元测试直接断言。
    # 条件里的 state_before_tick == state 保证「本帧发生了状态切换」时不会误开判定盒。
    if (
        not entered
        and state == State.ATTACK
        and state_before_tick == state
        and current_attack != null
        and current_attack.is_active_frame(frame)
    ):
        result["hitbox_open"] = true
        result["hitbox_def"] = current_attack
        result["hitbox_combo_index"] = combo_index
        result["hitbox_facing"] = facing

    return result


# ============================== 外部事件 ==============================

## 受击。由 player.gd 在受击盒被命中时调用。
func apply_hurt(frames: int = 20) -> void:
    if state == State.DIE:
        return
    _hurt_frames = maxi(1, frames)
    current_attack = null
    combo_index = 0
    _last_reported_phase = ""
    _enter(State.HURT)


## 死亡。终态，只能靠 reset() 离开。
func apply_death() -> void:
    current_attack = null
    _last_reported_phase = ""
    _enter(State.DIE)


## 当前是否可以起跳。跳跃取消：出招进入取消窗口后也允许跳。
func can_jump(on_floor: bool) -> bool:
    match state:
        State.DIE, State.HURT:
            return false
        State.ATTACK:
            return current_attack != null and current_attack.can_cancel_at(state_frame)
        _:
            return on_floor or _coyote_frames > 0


## 当前是否可以出招。
func can_attack() -> bool:
    match state:
        State.DIE, State.HURT:
            return false
        State.ATTACK:
            return current_attack != null and current_attack.can_cancel_at(state_frame)
        _:
            return true


## 当前是否可以冲刺。
func can_dash() -> bool:
    return state != State.DIE and state != State.HURT


## 当前是否处于"不能被打断"的状态。
func is_committed() -> bool:
    return state == State.ATTACK or state == State.HURT or state == State.DIE


## 当前状态名（调试用）。
func state_name() -> String:
    return STATE_NAMES.get(state, "UNKNOWN")


## 当前招式的阶段名（不在出招时返回 ""）。
func attack_phase() -> String:
    if current_attack == null:
        return ""
    return current_attack.phase_at(state_frame)


## 距离输入缓冲过期还剩几帧（调试用）。
func buffer_remaining() -> int:
    return _buffer_frames


# ============================== 内部：状态推进 ==============================

func _tick_locomotion(
    input: PlayerInputFrame,
    on_floor: bool,
    vertical_velocity: float,
    result: Dictionary
) -> void:
    # 1. 出招优先于移动
    if _buffer_frames > 0:
        var attack := _resolve_default_attack()
        if attack != null:
            _buffer_frames = 0
            _start_attack(attack, false, result)
            return

    # 2. 跳跃
    if input.jump_pressed and can_jump(on_floor):
        _coyote_frames = 0
        result["jump_requested"] = true
        _enter(State.JUMP)
        return

    # 3. 冲刺
    if input.dash_pressed and can_dash():
        result["dash_requested"] = true
        _enter(State.JUMP if not on_floor else State.IDLE)
        return

    # 4. 地面 / 空中姿态
    if on_floor:
        if input.move_axis() == 0:
            _enter_if_changed(State.IDLE)
        else:
            _enter_if_changed(State.RUN)
    else:
        if vertical_velocity < 0.0:
            _enter_if_changed(State.JUMP)
        else:
            _enter_if_changed(State.FALL)


func _tick_attack(
    frame: int,
    input: PlayerInputFrame,
    on_floor: bool,
    result: Dictionary
) -> void:
    var def := current_attack
    if def == null:
        _enter(State.IDLE)
        return

    # 报告阶段变化，供音效 / 特效 / 调试使用
    var phase := def.phase_at(frame)
    if phase != _last_reported_phase:
        _last_reported_phase = phase
        result["attack_id"] = def.id
        result["attack_phase"] = phase

    # 取消窗口：接下一招
    if def.can_cancel_at(frame) and _buffer_frames > 0:
        var next := _resolve_next_attack(def)
        if next != null:
            _buffer_frames = 0
            _start_attack(next, true, result)
            return

    # 跳跃取消
    if def.can_cancel_at(frame) and input.jump_pressed and can_jump(on_floor):
        _coyote_frames = 0
        result["jump_requested"] = true
        current_attack = null
        _last_reported_phase = ""
        _enter(State.JUMP)
        return

    # 招式打完
    if def.is_finished_at(frame):
        result["attack_finished"] = true
        result["finished_attack_id"] = def.id
        current_attack = null
        combo_index = 0
        _last_reported_phase = ""
        _enter(State.IDLE if on_floor else State.FALL)


func _tick_hurt(frame: int, result: Dictionary) -> void:
    if frame >= _hurt_frames:
        result["hurt_finished"] = true
        _enter(State.IDLE)


# ============================== 内部：招式选择 ==============================

func _resolve_default_attack() -> AttackDef:
    if attack_table == null:
        return null
    if not attack_table.has_attack(default_attack_id):
        push_warning("[PlayerFsm] 默认招式「%s」不在帧数据表里" % default_attack_id)
        return null
    return attack_table.get_attack(default_attack_id)


func _resolve_next_attack(def: AttackDef) -> AttackDef:
    if attack_table == null:
        return null

    # 如果缓冲里指定了具体招式，优先用它
    if not _buffered_attack.is_empty() and def.cancel_into.has(_buffered_attack):
        return attack_table.get_attack(_buffered_attack)

    # 否则按 cancel_into 的声明顺序取第一个存在的
    for target in def.cancel_into:
        if attack_table.has_attack(target):
            return attack_table.get_attack(target)

    return null


func _start_attack(def: AttackDef, is_cancel: bool, result: Dictionary) -> void:
    current_attack = def
    combo_index = combo_index + 1 if is_cancel else 0
    _last_reported_phase = ""
    _enter(State.ATTACK)
    result["attack_started"] = def
    result["attack_id"] = def.id
    result["combo_index"] = combo_index


# ============================== 内部：缓冲与朝向 ==============================

func _update_facing(input: PlayerInputFrame) -> void:
    # 出招和受击中不允许转身，否则连招会打反方向
    if is_committed():
        return
    var axis := input.move_axis()
    if axis != 0:
        facing = axis


func _update_input_buffer(input: PlayerInputFrame) -> void:
    if input.attack_pressed:
        _buffer_frames = buffer_window
        _buffered_attack = ""
    elif _buffer_frames > 0:
        _buffer_frames -= 1


func _update_coyote(on_floor: bool) -> void:
    if on_floor:
        _coyote_frames = coyote_window
    elif _coyote_frames > 0:
        _coyote_frames -= 1


# ============================== 内部：状态切换 ==============================

## 无条件进入新状态，并把状态计时归零。
func _enter(new_state: int) -> void:
    state = new_state
    state_frame = 0
    _just_entered = true


## 只在状态不同时才切换。用于 IDLE/RUN/JUMP/FALL 这类"每帧都在判断"的状态，
## 避免每帧都重置 state_frame。
func _enter_if_changed(new_state: int) -> void:
    if state != new_state:
        _enter(new_state)


static func _empty_result() -> Dictionary:
    return {
        "state": -1,
        "previous_state": -1,
        "state_changed": false,
        "attack_started": null,
        "attack_id": "",
        "attack_phase": "",
        "attack_finished": false,
        "finished_attack_id": "",
        "combo_index": 0,
        "state_frame": 0,
        "jump_requested": false,
        "dash_requested": false,
        "hurt_finished": false,
        "hitbox_open": false,
        "hitbox_def": null,
        "hitbox_combo_index": 0,
        "hitbox_facing": 1,
    }
