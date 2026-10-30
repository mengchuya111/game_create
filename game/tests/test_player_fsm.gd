extends TestCase
## 测试 PlayerFsm —— 全项目最值得写测试的一个类。
##
## 为什么：战斗手感 = 状态机的行为。帧数据配得再好，只要取消窗口判断错一帧，
## 连招就会断；无敌帧算错，玩家就会莫名掉血。
## 这些东西靠"玩"很难稳定复现，靠单元测试却一测一个准。
##
## 下面每个测试都在描述一条"手感规则"。如果哪天 AI 改代码把这个测试改挂了，
## 说明它动了你不希望它动的东西 —— 这正是测试存在的意义。
##
## 【帧号对照表】本项目统一约定：
##   tick 0 按下攻击键 → 招式在这一 tick 内启动，state_frame = 0
##   tick 1 处理帧 0（起手第一帧）
##   tick N 处理帧 N-1
##   light_1：起手 6 帧（0~5）、判定 3 帧（6~8）、收招 10 帧（9~18），总 19 帧
##            取消窗口从帧 12 开始 → 在 tick 13 处理

const TABLE_DATA := {
    "light_1": {
        "startup": 6, "active": 3, "recovery": 10,
        "cancel_from": 12, "cancel_into": ["light_2"],
        "damage": 8, "hitstop": 4,
    },
    "light_2": {
        "startup": 5, "active": 3, "recovery": 11,
        "cancel_from": 11, "cancel_into": ["light_3"],
        "damage": 10, "hitstop": 5,
    },
    "light_3": {
        "startup": 8, "active": 4, "recovery": 18,
        "cancel_from": -1, "cancel_into": [],
        "damage": 20, "hitstop": 8,
    },
}


func _make_fsm() -> PlayerFsm:
    var table := AttackTable.new()
    var err := table.load_from_dict(TABLE_DATA.duplicate(true))
    require(err == OK, "测试用帧数据表应当能加载")
    var fsm := PlayerFsm.new(table, 6, 6)
    fsm.default_attack_id = "light_1"
    return fsm


func _empty_input() -> PlayerInputFrame:
    return PlayerInputFrame.new()


func _press_attack(fsm: PlayerFsm) -> void:
    var input := PlayerInputFrame.new()
    input.attack_pressed = true
    fsm.tick(input, true, 0.0)


# ============================== 基本状态 ==============================

func test_starts_idle_facing_right() -> void:
    var fsm := _make_fsm()
    assert_eq(fsm.state, PlayerFsm.State.IDLE, "初始状态应当是 IDLE")
    assert_eq(fsm.state_frame, 0, "初始状态帧应当是 0")
    assert_eq(fsm.facing, 1, "初始朝向应当是右")


func test_run_state_on_horizontal_input() -> void:
    var fsm := _make_fsm()
    var input := PlayerInputFrame.new()
    input.right = true
    fsm.tick(input, true, 0.0)
    assert_eq(fsm.state, PlayerFsm.State.RUN, "按方向键应当进入 RUN")


func test_fall_state_when_airborne_descending() -> void:
    var fsm := _make_fsm()
    fsm.tick(_empty_input(), false, 200.0)
    assert_eq(fsm.state, PlayerFsm.State.FALL, "空中且在下落时应当是 FALL")


func test_jump_state_when_airborne_rising() -> void:
    var fsm := _make_fsm()
    fsm.tick(_empty_input(), false, -200.0)
    assert_eq(fsm.state, PlayerFsm.State.JUMP, "空中且在上时应当是 JUMP")


func test_state_name_is_readable() -> void:
    var fsm := _make_fsm()
    assert_eq(fsm.state_name(), "IDLE", "状态名应当是可读字符串，方便调试 HUD 显示")


# ============================== 出招与判定帧 ==============================

func test_attack_starts_on_press() -> void:
    var fsm := _make_fsm()
    var input := PlayerInputFrame.new()
    input.attack_pressed = true
    var result := fsm.tick(input, true, 0.0)

    assert_eq(fsm.state, PlayerFsm.State.ATTACK, "按下攻击键应当进入 ATTACK")
    var started: Variant = result.get("attack_started", null)
    require(started is AttackDef, "应当产出 attack_started 事件")
    if started is AttackDef:
        assert_eq((started as AttackDef).id, "light_1", "默认起手招式应当是 light_1")


func test_hitbox_opens_only_on_active_frames() -> void:
    var fsm := _make_fsm()
    var hitbox_frames := PackedInt32Array()

    for tick_index in range(40):
        var input := PlayerInputFrame.new()
        if tick_index == 0:
            input.attack_pressed = true
        var result := fsm.tick(input, true, 0.0)
        if bool(result.get("hitbox_open", false)):
            hitbox_frames.append(int(result.get("state_frame", -1)))

    assert_eq(hitbox_frames.size(), 3, "轻击一段的判定帧应当是 3 帧（实际 %d 帧）" % hitbox_frames.size())
    if hitbox_frames.size() == 3:
        assert_eq(hitbox_frames[0], 6, "第一个判定帧应当是第 6 帧")
        assert_eq(hitbox_frames[1], 7, "第二个判定帧应当是第 7 帧")
        assert_eq(hitbox_frames[2], 8, "第三个判定帧应当是第 8 帧")


func test_hitbox_closes_during_recovery() -> void:
    var fsm := _make_fsm()
    var opened_during_recovery := false

    for tick_index in range(40):
        var input := PlayerInputFrame.new()
        if tick_index == 0:
            input.attack_pressed = true
        var result := fsm.tick(input, true, 0.0)
        if bool(result.get("hitbox_open", false)) and int(result.get("state_frame", -1)) >= 9:
            opened_during_recovery = true

    assert_false(opened_during_recovery, "进入收招阶段（帧 9 之后）判定盒必须关闭，否则会出现'收招还能打到人'的怪事")


func test_attack_returns_to_idle_when_finished() -> void:
    var fsm := _make_fsm()
    for tick_index in range(30):
        var input := PlayerInputFrame.new()
        if tick_index == 0:
            input.attack_pressed = true
        fsm.tick(input, true, 0.0)

    assert_eq(fsm.state, PlayerFsm.State.IDLE, "轻击一段打完（19 帧）之后应当回到 IDLE")
    assert_eq(fsm.current_attack, null, "招式结束后 current_attack 应当清空")
    assert_eq(fsm.combo_index, 0, "招式结束后连段序号应当归零")


func test_attack_in_air_returns_to_fall() -> void:
    var fsm := _make_fsm()
    for tick_index in range(30):
        var input := PlayerInputFrame.new()
        if tick_index == 0:
            input.attack_pressed = true
        fsm.tick(input, false, 150.0)
    assert_eq(fsm.state, PlayerFsm.State.FALL, "空中打完招应当回到 FALL，而不是回到地面的 IDLE")


func test_attack_finished_event_is_reported() -> void:
    var fsm := _make_fsm()
    var finished_id := ""
    for tick_index in range(30):
        var input := PlayerInputFrame.new()
        if tick_index == 0:
            input.attack_pressed = true
        var result := fsm.tick(input, true, 0.0)
        if bool(result.get("attack_finished", false)):
            finished_id = str(result.get("finished_attack_id", ""))
    assert_eq(finished_id, "light_1", "招式打完时应当报告是哪个招式结束了（音效/特效要用）")


func test_attack_phase_events_are_reported() -> void:
    var fsm := _make_fsm()
    var phases: Array = []
    for tick_index in range(30):
        var input := PlayerInputFrame.new()
        if tick_index == 0:
            input.attack_pressed = true
        var result := fsm.tick(input, true, 0.0)
        var phase := str(result.get("attack_phase", ""))
        if not phase.is_empty() and not phases.has(phase):
            phases.append(phase)

    assert_has(phases, "startup", "应当报告过起手阶段")
    assert_has(phases, "active", "应当报告过判定阶段")
    assert_has(phases, "recovery", "应当报告过收招阶段")


# ============================== 连段与输入缓冲 ==============================

func test_cancel_into_next_attack_within_window() -> void:
    var fsm := _make_fsm()
    var chained_at_tick := -1

    for tick_index in range(40):
        var input := PlayerInputFrame.new()
        # tick 12 按下 → tick 13 处理帧 12（取消窗口第一帧）时接上
        if tick_index == 0 or tick_index == 12:
            input.attack_pressed = true
        var result := fsm.tick(input, true, 0.0)

        var started: Variant = result.get("attack_started", null)
        if started is AttackDef and (started as AttackDef).id == "light_2":
            chained_at_tick = tick_index
            break

    assert_eq(chained_at_tick, 13, "第 12 tick 按下攻击键，应当正好在第 13 tick（帧 12，取消窗口第一帧）接上二段")


func test_combo_index_increments_on_cancel() -> void:
    var fsm := _make_fsm()
    var combo_index_seen := -1

    for tick_index in range(40):
        var input := PlayerInputFrame.new()
        if tick_index == 0 or tick_index == 12:
            input.attack_pressed = true
        var result := fsm.tick(input, true, 0.0)
        var started: Variant = result.get("attack_started", null)
        if started is AttackDef and (started as AttackDef).id == "light_2":
            combo_index_seen = int(result.get("combo_index", -1))

    assert_eq(combo_index_seen, 1, "接上二段时连段序号应当是 1（用于连段伤害递减）")


func test_input_buffer_holds_press_exactly_at_window_edge() -> void:
    var fsm := _make_fsm()
    var chained_at_tick := -1

    for tick_index in range(40):
        var input := PlayerInputFrame.new()
        # tick 8 按下 → 缓冲 6 帧，到 tick 13 还剩 1 帧，刚好够用
        if tick_index == 0 or tick_index == 8:
            input.attack_pressed = true
        var result := fsm.tick(input, true, 0.0)
        var started: Variant = result.get("attack_started", null)
        if started is AttackDef and (started as AttackDef).id == "light_2":
            chained_at_tick = tick_index
            break

    assert_eq(chained_at_tick, 13, "提前 5 帧按下（刚好在 6 帧缓冲窗口内）应当仍能接上二段")


func test_input_buffer_expires_one_frame_too_early() -> void:
    var fsm := _make_fsm()
    var chained := false

    for tick_index in range(60):
        var input := PlayerInputFrame.new()
        # tick 7 按下 → 缓冲到 tick 13 刚好归零，差一帧就接不上
        if tick_index == 0 or tick_index == 7:
            input.attack_pressed = true
        var result := fsm.tick(input, true, 0.0)
        var started: Variant = result.get("attack_started", null)
        if started is AttackDef and (started as AttackDef).id == "light_2":
            chained = true

    assert_false(chained, "早一帧按下（缓冲刚好过期）就不应该能接上二段 —— 这就是'输入缓冲窗口'的准确边界")


func test_full_three_hit_combo() -> void:
    var fsm := _make_fsm()
    var chain: Array = []

    for tick_index in range(120):
        var input := PlayerInputFrame.new()
        # light_1 在 tick 13 接二段；light_2 从 tick 13 启动，取消窗口在 tick 25
        if tick_index == 0 or tick_index == 12 or tick_index == 24:
            input.attack_pressed = true
        var result := fsm.tick(input, true, 0.0)
        var started: Variant = result.get("attack_started", null)
        if started is AttackDef:
            chain.append((started as AttackDef).id)

    assert_int_array_eq(chain, ["light_1", "light_2", "light_3"], "三段连招应当按顺序全部接上")


func test_final_attack_cannot_be_cancelled() -> void:
    var fsm := _make_fsm()
    var chain: Array = []
    var light_3_start_tick := -1
    var gap_after_light_3 := -1

    for tick_index in range(200):
        var input := PlayerInputFrame.new()
        input.attack_pressed = true   # 一直按着攻击键
        var result := fsm.tick(input, true, 0.0)
        var started: Variant = result.get("attack_started", null)
        if started is AttackDef:
            var attack_id := (started as AttackDef).id
            chain.append(attack_id)
            if attack_id == "light_3":
                light_3_start_tick = tick_index
            elif light_3_start_tick >= 0 and gap_after_light_3 < 0:
                gap_after_light_3 = tick_index - light_3_start_tick

    assert_ge(float(chain.size()), 3.0, "一直按着攻击键至少应当能打出三段（实际 %d 段）" % chain.size())
    assert_ge(
        float(gap_after_light_3), 30.0,
        "light_3 不可取消（总 30 帧），打完之前不应该能再出招（实际间隔 %d 帧）" % gap_after_light_3
    )


# ============================== 跳跃与土狼时间 ==============================

func test_jump_emits_request_and_enters_jump() -> void:
    var fsm := _make_fsm()
    fsm.tick(_empty_input(), true, 0.0)

    var input := PlayerInputFrame.new()
    input.jump_pressed = true
    input.jump_held = true
    var result := fsm.tick(input, true, 0.0)

    assert_true(bool(result.get("jump_requested", false)), "在地面上按跳跃应当发出跳跃请求")
    assert_eq(fsm.state, PlayerFsm.State.JUMP, "按跳跃后应当进入 JUMP 状态")


func test_no_jump_while_airborne_without_coyote() -> void:
    var fsm := _make_fsm()
    for i in range(20):
        fsm.tick(_empty_input(), false, 200.0)

    var input := PlayerInputFrame.new()
    input.jump_pressed = true
    var result := fsm.tick(input, false, 200.0)
    assert_false(bool(result.get("jump_requested", false)), "土狼时间过期后空中不应该还能起跳")


func test_coyote_time_allows_late_jump() -> void:
    var fsm := _make_fsm()
    for i in range(3):
        fsm.tick(_empty_input(), true, 0.0)
    assert_true(fsm.can_jump(true), "站在地面上当然可以跳")

    for i in range(4):
        fsm.tick(_empty_input(), false, 50.0)
    assert_true(fsm.can_jump(false), "离开地面 4 帧内（土狼窗口 6 帧）仍应可以起跳")

    for i in range(10):
        fsm.tick(_empty_input(), false, 50.0)
    assert_false(fsm.can_jump(false), "离开地面超过土狼窗口后不应再能起跳")


func test_jump_cancel_only_after_cancel_window() -> void:
    var fsm := _make_fsm()
    _press_attack(fsm)

    # tick 1 处理帧 0，仍在起手阶段
    fsm.tick(_empty_input(), true, 0.0)
    assert_false(fsm.can_jump(true), "起手帧内不应该允许跳跃取消（否则招式就没有硬直了）")

    # 推进到帧 12：tick 2..12 共 11 次，处理帧 1..11，state_frame 落在 12
    for i in range(2, 13):
        fsm.tick(_empty_input(), true, 0.0)

    assert_eq(fsm.state, PlayerFsm.State.ATTACK, "此时应当还在出招中")
    assert_eq(fsm.state_frame, 12, "此时应当刚好处理完第 12 帧")
    assert_true(fsm.can_jump(true), "进入取消窗口后应当允许跳跃取消")


# ============================== 受击与死亡 ==============================

func test_hurt_interrupts_attack() -> void:
    var fsm := _make_fsm()
    _press_attack(fsm)
    assert_eq(fsm.state, PlayerFsm.State.ATTACK, "应当处于出招状态")

    fsm.apply_hurt(10)
    assert_eq(fsm.state, PlayerFsm.State.HURT, "受击应当立刻打断出招")
    assert_eq(fsm.current_attack, null, "受击后当前招式应当清空")
    assert_eq(fsm.combo_index, 0, "受击后连段应当断开")


func test_hurt_blocks_actions() -> void:
    var fsm := _make_fsm()
    fsm.apply_hurt(20)
    assert_false(fsm.can_attack(), "受击硬直期间不能出招")
    assert_false(fsm.can_jump(true), "受击硬直期间不能起跳")
    assert_false(fsm.can_dash(), "受击硬直期间不能冲刺")


func test_hurt_ends_after_configured_frames() -> void:
    var fsm := _make_fsm()
    fsm.apply_hurt(10)

    var finished := false
    for i in range(20):
        var result := fsm.tick(_empty_input(), true, 0.0)
        if bool(result.get("hurt_finished", false)):
            finished = true

    assert_true(finished, "受击硬直应当会结束")
    assert_eq(fsm.state, PlayerFsm.State.IDLE, "硬直结束后应当回到 IDLE")


func test_death_is_terminal() -> void:
    var fsm := _make_fsm()
    fsm.apply_death()

    for i in range(40):
        var input := PlayerInputFrame.new()
        input.attack_pressed = true
        input.jump_pressed = true
        input.dash_pressed = true
        fsm.tick(input, true, 0.0)

    assert_eq(fsm.state, PlayerFsm.State.DIE, "死亡状态不可逆，任何输入都不应该让它活过来")
    assert_false(fsm.can_attack(), "死亡后不能出招")
    assert_false(fsm.can_jump(true), "死亡后不能起跳")
    assert_false(fsm.can_dash(), "死亡后不能冲刺")


func test_hurt_does_not_revive_dead_player() -> void:
    var fsm := _make_fsm()
    fsm.apply_death()
    fsm.apply_hurt(10)
    assert_eq(fsm.state, PlayerFsm.State.DIE, "已经死亡时再受击不应该把状态改回 HURT")


func test_reset_clears_everything() -> void:
    var fsm := _make_fsm()
    _press_attack(fsm)
    fsm.apply_death()

    fsm.reset()

    assert_eq(fsm.state, PlayerFsm.State.IDLE, "reset 之后应当回到 IDLE")
    assert_eq(fsm.state_frame, 0, "reset 之后状态帧应当归零")
    assert_eq(fsm.current_attack, null, "reset 之后不应残留招式")
    assert_eq(fsm.combo_index, 0, "reset 之后连段序号应当归零")
    assert_eq(fsm.buffer_remaining(), 0, "reset 之后输入缓冲应当清空")
    assert_eq(fsm.facing, 1, "reset 之后朝向应当回到默认值")


# ============================== 朝向 ==============================

func test_facing_flips_when_actionable() -> void:
    var fsm := _make_fsm()
    var input := PlayerInputFrame.new()
    input.left = true
    fsm.tick(input, true, 0.0)
    assert_eq(fsm.facing, -1, "空闲时按左应当转身")


func test_facing_locks_during_attack() -> void:
    var fsm := _make_fsm()
    _press_attack(fsm)
    assert_eq(fsm.facing, 1, "出招前默认朝右")

    var input := PlayerInputFrame.new()
    input.left = true
    fsm.tick(input, true, 0.0)
    assert_eq(fsm.facing, 1, "出招期间不应因为按方向键而转身，否则连招会打反方向")


func test_facing_locks_during_hurt() -> void:
    var fsm := _make_fsm()
    fsm.apply_hurt(20)

    var input := PlayerInputFrame.new()
    input.left = true
    fsm.tick(input, true, 0.0)
    assert_eq(fsm.facing, 1, "受击硬直期间不应该转身")


# ============================== 异常输入 ==============================

func test_missing_attack_table_does_not_crash() -> void:
    var fsm := PlayerFsm.new(null, 6, 6)
    var input := PlayerInputFrame.new()
    input.attack_pressed = true
    var result := fsm.tick(input, true, 0.0)

    assert_eq(fsm.state, PlayerFsm.State.IDLE, "没有帧数据表时按攻击键不应该崩溃，也不应该进入出招状态")
    assert_eq(result.get("attack_started", null), null, "没有帧数据表时不应该产出招式")


func test_unknown_default_attack_does_not_crash() -> void:
    var fsm := _make_fsm()
    fsm.default_attack_id = "不存在的招式"
    var input := PlayerInputFrame.new()
    input.attack_pressed = true
    fsm.tick(input, true, 0.0)
    assert_eq(fsm.state, PlayerFsm.State.IDLE, "默认招式不存在时应当安全地不出招，而不是崩溃")


func test_tick_is_safe_over_many_frames() -> void:
    var fsm := _make_fsm()
    for i in range(600):
        fsm.tick(_empty_input(), i % 2 == 0, 0.0)
    assert_ge(float(fsm.state), 0.0, "连续 tick 600 帧不应该出错")


func test_attack_while_dashing_input_does_not_crash() -> void:
    var fsm := _make_fsm()
    for i in range(60):
        var input := PlayerInputFrame.new()
        input.dash_pressed = i % 7 == 0
        input.attack_pressed = i % 5 == 0
        input.jump_pressed = i % 11 == 0
        input.left = i % 3 == 0
        input.right = i % 4 == 0
        fsm.tick(input, i % 6 != 0, 40.0)
    assert_ge(float(fsm.state), 0.0, "随机乱按 60 帧也不应该出错")
