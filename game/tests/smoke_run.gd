extends Node
## 冒烟测试（Smoke Test）—— 把整个游戏真的跑起来，自动玩一段，然后检查"行为是否正常"。
##
## 为什么需要它（这是验收流程里最重要的一环）：
##   单元测试只能覆盖纯逻辑类（状态机 / 伤害公式 / 帧数据 / 房间生成）。
##   而"场景接错线""节点路径写错""依赖注入顺序不对""相机绑到了上一间房的旧节点"
##   这类问题，只有真的把游戏跑起来才会暴露。
##
##   本脚本不需要任何人盯着看：它自己玩、自己断言、自己退出并返回退出码。
##   可以直接挂进 CI，也可以每次让 AI 改完代码后跑一遍。
##
## 三个阶段：
##   阶段 1  自动游玩 600 帧 —— 用脚本化输入驱动（走的正是重放系统的正式路径）
##   阶段 2  被动挨打     —— 站着不动让山贼打，验证"敌人 → 玩家"这条反向链路
##   阶段 3  调试台 + 重放文件 —— 验证所有调试命令可用、重放能存能读
##
## 运行方式：
##   .tooling/Godot_v4.7.2-stable_win64_console.exe --headless --path game res://tests/smoke_run.tscn
##
## 退出码：0 = 全部通过，1 = 有失败。

const MAIN_SCENE := "res://scenes/main.tscn"
const SEED := 20240501

# ---------- 阶段 1：自动游玩 ----------
## 总帧数（60 帧 = 1 秒）。
const TOTAL_FRAMES := 600
## 从第几帧开始主动找敌人打。
const ENGAGE_FROM := 200
## 每隔多少帧重新贴近最近的敌人（敌人会走开，不贴上去就打不中）。
const ENGAGE_INTERVAL := 60
## 贴身距离。轻击判定盒横向覆盖 6~46 像素，44 正好够得着。
const ENGAGE_DISTANCE := 44.0

# ---------- 阶段 2：被动挨打 ----------
## 最长等待帧数。
const DAMAGE_STAGE_MAX_FRAMES := 360
## 站到山贼面前的距离。山贼在 34 像素内才会出招。
const BAIT_DISTANCE := 30.0

var _main: Node2D = null
var _scripted: ReplayRecorder = null
var _frames: int = 0
var _finished: bool = false

var _checks: int = 0
var _failures: Array[String] = []

# ============================== 观测数据 ==============================
var _states_seen: Dictionary = {}
var _phases_seen: Dictionary = {}
var _hitbox_open_frames: int = 0
var _below_floor_frames: int = 0
var _outside_room_frames: int = 0
var _camera_detached_frames: int = 0
var _hits_confirmed: int = 0
var _enemy_damage_events: int = 0
var _enemy_damage_without_player_attack: int = 0
var _player_damage_events: int = 0
var _phase_events: int = 0
var _room_cleared_events: int = 0
var _console_lines: int = 0
var _max_hitstop_frames: int = 0
var _max_shake_intensity: float = 0.0
var _rooms_visited: Dictionary = {}
var _rewards_offered: int = 0
var _rewards_taken: int = 0


func _ready() -> void:
    print("\n========================================")
    print("  武侠肉鸽 · 冒烟测试")
    print("========================================")

    EventBus.hit_confirmed.connect(_on_hit_confirmed)
    EventBus.enemy_damaged.connect(_on_enemy_damaged)
    EventBus.player_damaged.connect(_on_player_damaged)
    EventBus.attack_phase_changed.connect(_on_attack_phase_changed)
    EventBus.room_cleared.connect(_on_room_cleared)
    EventBus.console_line.connect(_on_console_line)
    EventBus.upgrade_offered.connect(_on_upgrade_offered)

    var packed: PackedScene = load(MAIN_SCENE)
    _check(packed != null, "main.tscn 能被加载")
    if packed == null:
        _report()
        return

    _main = packed.instantiate()
    add_child(_main)
    await get_tree().process_frame

    _check(_main != null and is_instance_valid(_main), "main.tscn 能被实例化")
    _check(_main.player != null, "开局后玩家已经生成")
    if _main.player == null:
        _report()
        return

    _check(_main.attack_table.size() > 0, "帧数据表已载入（%d 个招式）" % _main.attack_table.size())
    _check(not _main.rooms.is_empty(), "房间路线已生成（%d 间）" % _main.rooms.size())
    _check(_main.upgrade_pool.size() > 0, "心法表已载入（%d 条）" % _main.upgrade_pool.size())
    _check(_main.run_state != null, "局内成长状态已创建")

    # 用一条"脚本化输入"驱动游戏 —— 走的正是重放系统的正式路径，
    # 所以这一步同时也验证了重放能否真的驱动游戏。
    _scripted = _build_scripted_input()
    _main.start_run(SEED, false)
    _main.player.replay_source = _scripted
    _scripted.begin_playback()
    _check(_main.player.replay_source == _scripted, "脚本化输入已经接到玩家身上")


# ============================== 阶段 1：自动游玩脚本 ==============================

## 分四个阶段喂输入，**刻意覆盖每一个状态**。
## 之前的版本每 15 帧就按一次攻击，结果 600 帧里一次 RUN 都没出现过 ——
## 自动测试的输入脚本必须"为了覆盖而设计"，不能随便写。
func _build_scripted_input() -> ReplayRecorder:
    var recorder := ReplayRecorder.new()
    recorder.start(SEED, "冒烟测试自动游玩")

    for i in range(TOTAL_FRAMES):
        var frame := PlayerInputFrame.new()

        if i < 60:
            # 阶段 A：原地不动。让起点房（没有敌人）自然清空并推进到下一间。
            pass
        elif i < 150:
            # 阶段 B：纯跑动，不出招 —— 专门保证 RUN 状态一定出现。
            frame.right = true
        elif i < 520:
            # 阶段 C：边跑边连招，不断触发取消窗口与连段。
            frame.right = true
            frame.attack_pressed = (i - 150) % 15 == 0
            frame.attack_held = true
        else:
            # 阶段 D：转身往回跑，测朝向切换。
            frame.left = true

        # 跳跃：测 JUMP 状态与空中出招
        if i == 300:
            frame.jump_pressed = true
        if i >= 300 and i < 322:
            frame.jump_held = true

        # 冲刺：测冲刺无敌帧
        if i == 420:
            frame.dash_pressed = true

        recorder.record(frame)

    return recorder


# ============================== 逐帧采样 ==============================

func _physics_process(_delta: float) -> void:
    if _finished or _main == null:
        return

    _frames += 1
    _sample()

    if _frames >= ENGAGE_FROM and _frames % ENGAGE_INTERVAL == 0:
        _engage_nearest_enemy()

    if _frames >= TOTAL_FRAMES:
        _finished = true
        _finish()


func _sample() -> void:
    var player: Player = _main.player
    if player == null or not is_instance_valid(player):
        return

    _states_seen[player.fsm.state_name()] = true
    _rooms_visited[_main.current_room_index] = true

    var phase := player.fsm.attack_phase()
    if not phase.is_empty():
        _phases_seen[phase] = true

    if player.hitbox.is_swinging():
        _hitbox_open_frames += 1

    # 穿地检测：地板顶部是 floor_y，玩家原点在脚底，不该跑到下面去
    var floor_y: float = _main.arena.floor_y
    if player.global_position.y > floor_y + 20.0:
        _below_floor_frames += 1

    # 出界检测
    var half_width: float = _main.arena.room_width * 0.5
    if absf(player.global_position.x) > half_width + 40.0:
        _outside_room_frames += 1

    # 相机必须挂在"当前这个玩家"身上。
    # 这条断言专门钉住一个真实踩过的坑：换房间时如果只 queue_free 旧玩家，
    # 旧相机在本帧仍然在组里，于是新相机拿不到房间边界，镜头会跑出房间。
    var camera := get_tree().get_first_node_in_group("game_camera") as Camera2D
    if camera == null or not player.is_ancestor_of(camera):
        _camera_detached_frames += 1

    var director: Node = _main.combat_director
    if director != null:
        _max_hitstop_frames = maxi(_max_hitstop_frames, director.hitstop.requested_frames())
        _max_shake_intensity = maxf(_max_shake_intensity, director.shake.intensity())


## 把玩家挪到最近的活敌人身边 —— 否则敌人会走开，自动游玩可能一次都打不中。
## 顺带把调试台的 tp 命令也测了。
func _engage_nearest_enemy() -> void:
    var player: Player = _main.player
    if player == null or not is_instance_valid(player):
        return

    var nearest: Node2D = null
    var best := INF
    for node in get_tree().get_nodes_in_group("enemy"):
        if not (node is Enemy):
            continue
        var enemy: Enemy = node
        if not is_instance_valid(enemy) or enemy.hurtbox.is_dead():
            continue
        var distance := absf(enemy.global_position.x - player.global_position.x)
        if distance < best:
            best = distance
            nearest = enemy

    if nearest == null:
        return

    var target_x := nearest.global_position.x - ENGAGE_DISTANCE
    var floor_y: float = _main.arena.floor_y
    _run_console("tp", PackedStringArray([str(target_x), str(floor_y)]))


# ============================== 信号观测 ==============================

func _on_hit_confirmed(_attack_id: String, _hitstop_frames: int, _shake: float, _pos: Vector2) -> void:
    _hits_confirmed += 1


func _on_enemy_damaged(_amount: int, _remaining_hp: int, _pos: Vector2) -> void:
    _enemy_damage_events += 1

    # "玩家没在出招，敌人却掉血了" —— 那只能是敌人误伤自己人。
    # 这个坑真实存在过：Hitbox.source_team 默认是 "player"，
    # 敌人忘了设成 "enemy"，结果山贼互相砍、还把训练木桩砍死，却打不到玩家。
    var player: Player = _main.player if _main != null else null
    if player == null or not is_instance_valid(player) or not player.hitbox.is_swinging():
        _enemy_damage_without_player_attack += 1


func _on_player_damaged(_amount: int, _remaining_hp: int) -> void:
    _player_damage_events += 1


func _on_attack_phase_changed(_attack_id: String, _phase: String, _frame: int) -> void:
    _phase_events += 1


func _on_room_cleared(_room_id: String) -> void:
    _room_cleared_events += 1


## 自动替玩家选第一条。
## 为什么必须在信号里同步选掉：三选一期间 GameConfig.input_locked 是 true，
## 角色会站着不动。自动测试没有人按键，不替它选的话整局就停在这里了。
func _on_upgrade_offered(_choices: Array) -> void:
    _rewards_offered += 1
    var picked := _run_console("pick", PackedStringArray(["1"]))
    if picked.contains("已选择"):
        _rewards_taken += 1


func _on_console_line(_text: String) -> void:
    _console_lines += 1


# ============================== 收尾 ==============================

func _finish() -> void:
    await get_tree().process_frame

    print("\n--- 阶段 1 检查：自动游玩 %d 帧 ---" % TOTAL_FRAMES)
    _check_stage_one()

    print("\n--- 阶段 2：被动挨打（验证敌人能打中玩家）---")
    await _run_damage_taken_stage()
    _check_stage_two()

    print("\n--- 阶段 3：调试台与重放文件 ---")
    await _check_console()
    _check_replay_file()

    print("\n--- 阶段 4：清房 → 三选一 → 自动进入下一间（真实流程）---")
    await _check_room_clear_flow()

    print("\n--- 阶段 5：走进商店房 → 开商店 → 离开 → 自动进入下一间 ---")
    await _check_shop_room_flow()

    _report()


func _check_stage_one() -> void:
    var player: Player = _main.player

    # ---------- 1. 玩家基本状态 ----------
    _check(player != null and is_instance_valid(player), "自动游玩 %d 帧后玩家仍然存在" % TOTAL_FRAMES)
    if player != null:
        _check(
            player.hurtbox.hp >= 0 and player.hurtbox.hp <= player.hurtbox.max_hp,
            "血量在合法范围内（%d / %d）" % [player.hurtbox.hp, player.hurtbox.max_hp]
        )
        _check(player.fsm.state_frame >= 0, "状态帧计数非负（当前 %d）" % player.fsm.state_frame)

    # ---------- 2. 物理没有穿模 ----------
    _check(_below_floor_frames == 0, "全程没有穿到地板下面（异常帧数 %d）" % _below_floor_frames)
    _check(_outside_room_frames == 0, "全程没有跑出房间边界（异常帧数 %d）" % _outside_room_frames)

    # ---------- 2.5 房间里的敌人必须真的打得死 ----------
    # 战斗房的敌人池曾经第一位是 training_dummy（血 9999、打不死、死了还复活），
    # 于是玩家把山贼全砍完也等不到开门。单元测试测不到"数据 × 运行时"这条链，这里补上。
    var immortal_count := 0
    for node in get_tree().get_nodes_in_group("enemy"):
        if node is Enemy and float((node as Enemy).max_hp) >= 9000.0:
            immortal_count += 1
    _check(immortal_count == 0, "场上没有打不死的木桩（%d 个）" % immortal_count)

    # ---------- 3. 相机一直挂在当前玩家身上 ----------
    _check(
        _camera_detached_frames <= 2,
        "相机始终挂在当前玩家身上（脱离帧数 %d）" % _camera_detached_frames
    )

    # ---------- 4. 状态覆盖 ----------
    for required in ["IDLE", "RUN", "ATTACK"]:
        _check(_states_seen.has(required), "自动游玩中出现过 %s 状态" % required)
    _check(
        _states_seen.has("JUMP") or _states_seen.has("FALL"),
        "自动游玩中出现过空中状态（JUMP/FALL）"
    )

    # ---------- 5. 帧数据真的在驱动战斗 ----------
    _check(_hitbox_open_frames > 0, "判定盒真的开过（%d 帧）" % _hitbox_open_frames)
    for required in ["startup", "active", "recovery"]:
        _check(_phases_seen.has(required), "招式阶段报告过 %s" % required)
    _check(
        _phase_events > 0,
        "EventBus.attack_phase_changed 真的发出过（%d 次）—— 若为 0，说明信号是死的" % _phase_events
    )

    # ---------- 6. 战斗真的发生了 ----------
    _check(_hits_confirmed > 0, "打中过目标（hit_confirmed %d 次）" % _hits_confirmed)
    _check(_enemy_damage_events > 0, "敌人真的掉血了（enemy_damaged %d 次）" % _enemy_damage_events)
    _check(
        _enemy_damage_without_player_attack == 0,
        "敌人没有互相误伤（玩家未出招却掉血的次数：%d）" % _enemy_damage_without_player_attack
    )

    # ---------- 7. 打击感链路打通 ----------
    _check(_max_hitstop_frames > 0, "命中真的触发了顿帧（最大请求 %d 帧）" % _max_hitstop_frames)
    _check(_max_shake_intensity > 0.0, "命中真的触发了震屏（最大强度 %.3f）" % _max_shake_intensity)
    _check(
        is_equal_approx(Engine.time_scale, 1.0),
        "顿帧结束后时间缩放已恢复（当前 %.3f）" % Engine.time_scale
    )

    # ---------- 8. 房间流程 ----------
    _check(_room_cleared_events > 0, "起点房被判定为清空（room_cleared %d 次）" % _room_cleared_events)
    _check(_rooms_visited.size() >= 2, "自动推进到了第 2 间房之后（访问过 %d 间）" % _rooms_visited.size())

    # ---------- 9. 局内成长 ----------
    # 三选一必须"给得出、结算得掉"。只给不结算会让整局卡在奖励面板上，
    # 而且这种卡死在单元测试里完全看不出来 —— 只有把游戏跑起来才会暴露。
    _check(
        _rewards_offered == _rewards_taken,
        "每次三选一都被结算了（给出 %d 次，结算 %d 次）" % [_rewards_offered, _rewards_taken]
    )
    if player != null and is_instance_valid(player):
        _check(
            player.hurtbox.max_hp == GameConfig.PLAYER_BASE_MAX_HP + _main.run_state.max_hp_bonus(),
            "玩家生命上限 == 基础 %d + 心法 %d（实际 %d）" % [
                GameConfig.PLAYER_BASE_MAX_HP,
                _main.run_state.max_hp_bonus(),
                player.hurtbox.max_hp,
            ]
        )


## 阶段 2：把玩家丢到山贼面前，什么都不按，专门等它打我们。
## 这一步验证的是"敌人 → 玩家"这条反向链路：敌人 AI 出招 → 判定盒 → 受击盒 → 掉血 → HURT 状态。
## 只测"玩家打敌人"是不够的 —— 挨打这条链路错了，游戏照样是坏的。
func _run_damage_taken_stage() -> void:
    var player: Player = _main.player
    if player == null or not is_instance_valid(player):
        return

    # 交出控制权，回到"真实输入"（headless 下等于什么都不按）
    player.replay_source = null
    GameConfig.input_locked = false

    var walker := await _ensure_living_walker()
    if walker == null:
        print("  · 没有找到会走会打的敌人，跳过本阶段")
        return

    # 注意：上面可能执行过 next 换房，玩家已经换了一个实例，必须重新取
    player = _main.player
    if player == null or not is_instance_valid(player):
        return

    # 站到山贼面前，然后什么都不做
    player.global_position = Vector2(walker.global_position.x - BAIT_DISTANCE, _main.arena.floor_y)
    player.velocity = Vector2.ZERO

    var before := _player_damage_events
    var elapsed := 0
    while elapsed < DAMAGE_STAGE_MAX_FRAMES and _player_damage_events == before:
        if is_instance_valid(player):
            _states_seen[player.fsm.state_name()] = true
        await get_tree().physics_frame
        elapsed += 1

    print("  · 被动挨打：等待 %d 帧，玩家受伤 %d 次" % [elapsed, _player_damage_events - before])


## 找到一只活着的"会走会打"的敌人。当前房间没有就往后翻房间。
func _ensure_living_walker() -> Enemy:
    for attempt in range(6):
        var walker := _find_living_walker()
        if walker != null:
            return walker

        if _main.current_room_index + 1 >= _main.rooms.size():
            return null
        _run_console("next", PackedStringArray())
        await get_tree().physics_frame
        await get_tree().physics_frame

    return null


func _find_living_walker() -> Enemy:
    for node in get_tree().get_nodes_in_group("enemy"):
        if not (node is Enemy):
            continue
        var enemy: Enemy = node
        if is_instance_valid(enemy) and enemy.behavior == "walker" and not enemy.hurtbox.is_dead():
            return enemy
    return null


func _check_stage_two() -> void:
    var player: Player = _main.player
    _check(_player_damage_events > 0, "敌人真的打中了玩家（player_damaged %d 次）" % _player_damage_events)
    if player != null and is_instance_valid(player):
        _check(
            player.hurtbox.hp < player.hurtbox.max_hp,
            "玩家血量真的掉了（%d / %d）" % [player.hurtbox.hp, player.hurtbox.max_hp]
        )
    _check(_states_seen.has("HURT"), "玩家进入过受击硬直 HURT 状态")


# ============================== 阶段 3：调试台 ==============================

func _check_console() -> void:
    # 必须注册过的命令（缺一条就说明某个模块的 _ready 没跑到）
    var must_exist := [
        "help", "clear", "hide",
        "seed", "restart", "rooms", "next", "check", "attacks",
        "data", "dump", "save", "replays", "replay", "quit",
        "god", "hp", "pos", "attack", "tp",
        "buffs", "give", "pick", "reward", "spawn",
        "shop", "buy", "leave",
        "hitstop", "shake", "feel",
    ]
    var missing: Array[String] = []
    for command_name in must_exist:
        if not EventBus.console_commands.has(command_name):
            missing.append(command_name)
    _check(
        missing.is_empty(),
        "调试命令全部注册（共 %d 条，关键 %d 条无缺失：%s）" % [
            EventBus.console_commands.size(),
            must_exist.size(),
            ", ".join(missing) if not missing.is_empty() else "无"
        ]
    )

    # 只运行"没有副作用"的命令。seed / restart / quit / replay 会改变局面，只检查存在性。
    var safe_to_run := ["help", "rooms", "check", "attacks", "dump", "pos", "replays", "feel", "buffs"]
    var empty_results: Array[String] = []
    for command_name in safe_to_run:
        if _run_console(command_name, PackedStringArray()).strip_edges().is_empty():
            empty_results.append(command_name)
    _check(
        empty_results.is_empty(),
        "无副作用命令都能返回输出（无输出的：%s）" % (
            ", ".join(empty_results) if not empty_results.is_empty() else "无"
        )
    )

    # 带参数的命令
    _check(
        _run_console("data", PackedStringArray(["light_1"])).contains("startup"),
        "data light_1 返回了帧数据"
    )

    # check 现在会校验"房间模板 × 敌人表"（曾经这里漏掉过一只打不死的木桩）
    var data_check_output := _run_console("check", PackedStringArray())
    _check(not data_check_output.contains("✗"), "check 报告数据表全部自洽（没有 ✗）")

    # 调试刷怪：能召出来，且**不计入清房判定**
    # （计入的话，一只打不死的木桩就能让整间房永远清不掉 —— 这正是那个卡死 bug）
    var living_before: int = _main.arena.living_enemy_count()
    var spawn_output := _run_console("spawn", PackedStringArray(["training_dummy"]))
    _check(spawn_output.contains("已刷出"), "spawn 能召出训练木桩")
    _check(
        _main.arena.living_enemy_count() == living_before,
        "调试刷出的木桩不计入清房判定（%d → %d）" % [living_before, _main.arena.living_enemy_count()]
    )
    _check(
        _run_console("spawn", PackedStringArray(["不存在的原型"])).contains("找不到"),
        "spawn 对不存在的原型给出明确提示"
    )

    # ---------- 商店：开 → 买 → 重复买被拒 → 离开 ----------
    _main.run_state.add_coins(200)
    var shop_output := _run_console("shop", PackedStringArray())
    _check(_main.stock_count() == 3, "shop 上架了 3 件（实际 %d）" % _main.stock_count())
    _check(shop_output.contains("内力"), "shop 的输出里带价格")
    _check(GameConfig.input_locked, "商店打开时输入被锁住")

    if _main.stock_count() > 0:
        var price: int = _main.stock_price(0)
        var coins_before: int = _main.run_state.coins
        _check(_run_console("buy", PackedStringArray(["1"])).contains("已买下"), "buy 1 能买下")
        _check(
            _main.run_state.coins == coins_before - price,
            "买完扣的内力正好等于标价（%d - %d）" % [coins_before, price]
        )
        _check(
            _run_console("buy", PackedStringArray(["1"])).contains("没买成"),
            "同一件买第二次会被拒绝"
        )
    _check(_run_console("leave", PackedStringArray()).contains("已离开"), "leave 能关掉商店")
    _check(not GameConfig.input_locked, "离开商店后输入解锁")
    _check(
        _run_console("help", PackedStringArray(["check"])).contains("check"),
        "help check 返回了该命令的说明"
    )
    _check(
        _run_console("help", PackedStringArray(["不存在的命令"])).contains("没有命令"),
        "help 对不存在的命令给出明确提示"
    )

    # check 命令必须报告"一切正常"，不能有 ✗
    var check_output := _run_console("check", PackedStringArray())
    _check(not check_output.contains("✗"), "check 命令没有报出任何数据问题")

    # dump 必须是合法 JSON 且字段齐全
    var dump_output := _run_console("dump", PackedStringArray())
    var parsed: Variant = JSON.parse_string(dump_output)
    _check(parsed is Dictionary, "dump 输出是合法 JSON 对象")
    if parsed is Dictionary:
        var snapshot: Dictionary = parsed
        for key in ["seed", "room_index", "player", "enemies", "run_state"]:
            _check(snapshot.has(key), "dump 快照里包含 %s 字段" % key)

    # ---------- 局内成长：give / buffs / pick ----------
    var growth_player: Player = _main.player
    var give_output := _run_console("give", PackedStringArray(["iron_body"]))
    _check(not give_output.is_empty(), "give iron_body 有返回提示")

    if growth_player != null and is_instance_valid(growth_player):
        _check(
            growth_player.hurtbox.max_hp == GameConfig.PLAYER_BASE_MAX_HP + _main.run_state.max_hp_bonus(),
            "玩家生命上限与心法加成一致（%d == %d + %d）" % [
                growth_player.hurtbox.max_hp,
                GameConfig.PLAYER_BASE_MAX_HP,
                _main.run_state.max_hp_bonus(),
            ]
        )
        _check(
            is_equal_approx(growth_player.hitbox.attack_multiplier, _main.run_state.damage_multiplier()),
            "判定盒伤害倍率已同步心法（×%.2f）" % growth_player.hitbox.attack_multiplier
        )

    _check(
        _run_console("buffs", PackedStringArray()).contains("心法"),
        "buffs 命令列出了当前心法"
    )
    _check(
        _run_console("give", PackedStringArray(["不存在的心法"])).contains("找不到"),
        "give 对不存在的心法给出明确提示"
    )
    _check(
        _run_console("pick", PackedStringArray(["1"])).contains("没有待选"),
        "没有待选奖励时 pick 给出明确提示"
    )

    # ---------- 三选一流程：真的弹一次、真的选一次 ----------
    # 为什么要临时断开自动选择：自动测试平时靠"信号里同步 pick"保证不卡住，
    # 这里要验证的恰恰是"面板弹出来、玩家按 1 之后才结算"这条正常路径。
    _check(
        not _main.should_offer_reward_for_room(0),
        "起点房不产出心法奖励"
    )
    var combat_index := -1
    for i in range(_main.rooms.size()):
        if str(_main.rooms[i].get("type_name", "")) == "COMBAT":
            combat_index = i
            break
    if combat_index >= 0:
        _check(
            _main.should_offer_reward_for_room(combat_index),
            "战斗房（第 %d 间）清空后会给心法奖励" % (combat_index + 1)
        )

    var stacks_before: int = int(_main.run_state.upgrades_taken())
    var hp_before_reward: int = growth_player.hurtbox.hp if growth_player != null and is_instance_valid(growth_player) else -1

    if EventBus.upgrade_offered.is_connected(_on_upgrade_offered):
        EventBus.upgrade_offered.disconnect(_on_upgrade_offered)

    var reward_output := _run_console("reward", PackedStringArray())
    _check(_main.pending_choice_count() > 0, "reward 命令弹出了三选一（%s）" % reward_output.strip_edges())
    _check(GameConfig.input_locked, "三选一期间角色输入被锁住")

    var pick_output := _run_console("pick", PackedStringArray(["1"]))
    _check(pick_output.contains("已选择"), "pick 1 能结算奖励")
    _check(not GameConfig.input_locked, "结算后输入锁已解开")
    _check(_main.pending_choice_count() == 0, "结算后不再有残留待选")
    _check(
        _main.run_state.upgrades_taken() == stacks_before + 1,
        "结算后心法层数 +1（%d → %d）" % [stacks_before, _main.run_state.upgrades_taken()]
    )

    if growth_player != null and is_instance_valid(growth_player):
        _check(
            growth_player.hurtbox.max_hp == GameConfig.PLAYER_BASE_MAX_HP + _main.run_state.max_hp_bonus(),
            "选完心法后生命上限仍与加成一致（%d）" % growth_player.hurtbox.max_hp
        )
        if hp_before_reward >= 0:
            _check(
                growth_player.hurtbox.hp >= hp_before_reward,
                "选心法不会让玩家掉血（%d → %d）" % [hp_before_reward, growth_player.hurtbox.hp]
            )

    EventBus.upgrade_offered.connect(_on_upgrade_offered)

    # 未知命令不能崩
    var unknown_output := _run_console("这个命令不存在", PackedStringArray())
    _check(unknown_output.is_empty(), "未知命令被安全忽略（不崩溃）")


func _check_replay_file() -> void:
    var path := "user://replays/smoke_%d.json" % SEED
    var err := _scripted.save_to_file(path)
    _check(err == OK, "脚本化输入能保存成重放文件")

    var loaded := ReplayRecorder.load_from_file(path)
    _check(loaded != null, "重放文件能被读回来")
    if loaded != null:
        _check(
            loaded.frame_count() == _scripted.frame_count(),
            "读回的帧数与保存时一致（%d）" % loaded.frame_count()
        )
        _check(loaded.seed_value == SEED, "读回的种子与保存时一致（%d）" % loaded.seed_value)

    DirAccess.remove_absolute(path)


# ============================== 阶段 4：真实清房流程 ==============================

## 强制清空当前房间，验证"清房 → 三选一 → 换房"这条异步链路。
##
## 这条链路最容易出的问题是**静默死锁**：_on_room_cleared 会 await 玩家选择，
## 而自动测试是在 upgrade_offered 信号里同步把它选掉的。
## 如果 await 的位置写在 emit 之前或之后搞错了，信号早就发过了，
## 协程永远等不到 —— 整局不再推进，但没有任何报错。
## 这种 bug 单元测试抓不到，只能靠这一段。
func _check_room_clear_flow() -> void:
    if _main == null or _main.rooms.is_empty():
        _check(false, "阶段 4 前置：main 与房间路线存在")
        return

    var room_before: int = _main.current_room_index
    var rewards_before := _rewards_offered
    var player_before: Player = _main.player

    # 如果上一间房刚好还在 0.9 秒的过场里，room_cleared 会被忽略（_advancing 守卫），
    # 所以先等它推完，避免这条测试偶发失败。
    var guard := 0
    while _main.is_advancing() and guard < 120:
        await get_tree().physics_frame
        guard += 1

    _main.debug_clear_current_room()

    # 0.9 秒的过场等待 + 换房，最多给 180 帧（3 秒）
    var waited := 0
    while waited < 180 and _main.current_room_index == room_before:
        await get_tree().physics_frame
        waited += 1

    _check(
        _main.current_room_index != room_before,
        "清房后推进到了下一间（%d → %d，等待 %d 帧）" % [
            room_before + 1, _main.current_room_index + 1, waited
        ]
    )
    _check(
        _rewards_offered == rewards_before + 1,
        "清房触发了三选一（%d → %d）" % [rewards_before, _rewards_offered]
    )
    _check(
        _rewards_taken == _rewards_offered,
        "真实流程里的三选一也被结算了（给出 %d / 结算 %d）" % [_rewards_offered, _rewards_taken]
    )
    _check(not GameConfig.input_locked, "进入下一间后输入锁已解开")
    _check(_main.pending_choice_count() == 0, "进入下一间后没有残留待选")
    _check(
        _main.player != null and is_instance_valid(_main.player),
        "换房后玩家已重新生成"
    )
    if _main.player != null and is_instance_valid(_main.player):
        _check(
            _main.player.hurtbox.hp >= 1 and _main.player.hurtbox.hp <= _main.player.hurtbox.max_hp,
            "换房后血量在合法范围（%d / %d）" % [
                _main.player.hurtbox.hp, _main.player.hurtbox.max_hp
            ]
        )
        _check(
            _main.player.hurtbox.max_hp == GameConfig.PLAYER_BASE_MAX_HP + _main.run_state.max_hp_bonus(),
            "换房后生命上限仍然带着心法加成（%d）" % _main.player.hurtbox.max_hp
        )
    if player_before != null and is_instance_valid(player_before):
        _check(player_before != _main.player, "旧玩家实例已被替换（不是原地复用）")

    # HUD 的心法栏必须显示"财运亨通"，而不是数据表里的 id `lucky_coin`。
    # 这个坑真的出现过：RunState 只认 id，HUD 直接把 id 打了出来，
    # 单元测试全绿（因为 id 确实是数据的一部分），只有人眼看画面才发现。
    var owned: Array[String] = _main.run_state.taken_ids()
    if not owned.is_empty():
        var first_id := owned[0]
        var def: Dictionary = _main.upgrade_pool.get_upgrade(first_id)
        var label := str(def.get("display_name", ""))
        var summary: String = _main.hud_summary()
        _check(
            not label.is_empty() and summary.contains(label),
            "HUD 心法栏显示中文名「%s」而不是 id「%s」" % [label, first_id]
        )


## 阶段 5：真的走进商店房，验证"开商店 → 等玩家离开 → 进下一间"这条流程不会卡死。
##
## 为什么必须真跑：商店房没有敌人，进房 1.5 秒就会被判"清空"，
## 而 _on_room_cleared 里要 await 玩家离开商店。await 挂错位置（比如先发信号再挂等待）
## 会让整局静默卡死 —— 和阶段 4 抓到的三选一死锁是同一类问题，
## 而这类问题**单元测试完全看不出来**。
func _check_shop_room_flow() -> void:
    var shop_index := -1
    for i in range(_main.rooms.size()):
        if str(_main.rooms[i].get("type_name", "")) == "SHOP":
            shop_index = i
            break

    if shop_index < 0:
        _check(true, "本局路线里没有商店房，跳过该阶段")
        return

    # 等上一阶段收尾，否则 room_cleared 会被 _advancing 守卫吞掉
    var guard := 0
    while _main.is_advancing() and guard < 180:
        await get_tree().physics_frame
        guard += 1

    _main.close_shop()  # 清掉上一阶段可能留下的面板（没开着时是空操作）
    _main.run_state.add_coins(200)
    _main._load_room(shop_index)
    _check(
        _main.current_room_index == shop_index,
        "已跳进第 %d 间（商店房）" % (shop_index + 1)
    )

    # 商店房没有敌人：1.5 秒判定清空 + 0.9 秒过场 → 开商店。最多等 6 秒。
    var waited := 0
    while waited < 360 and not _main.is_shop_open():
        await get_tree().physics_frame
        waited += 1

    _check(_main.is_shop_open(), "进商店房后自动开出了商店（等待 %d 帧）" % waited)
    _check(GameConfig.input_locked, "商店开着时角色不能动")

    var room_before: int = _main.current_room_index
    _main.close_shop()

    waited = 0
    while waited < 240 and _main.current_room_index == room_before:
        await get_tree().physics_frame
        waited += 1

    _check(
        _main.current_room_index != room_before,
        "离开商店后自动进入下一间（%d → %d）" % [room_before + 1, _main.current_room_index + 1]
    )
    _check(not GameConfig.input_locked, "离开商店后输入锁已解开")


# ============================== 工具 ==============================

## 走调试台的正式注册表执行命令 —— 这样测的是"玩家真的会敲的命令"，
## 而不是直接调用内部方法。
func _run_console(command_name: String, args: PackedStringArray) -> String:
    if not EventBus.console_commands.has(command_name):
        return ""
    var entry: Dictionary = EventBus.console_commands[command_name]
    var callback: Callable = entry.get("callable", Callable())
    if not callback.is_valid():
        return ""
    var result: Variant = callback.call(args)
    if result is String:
        return result
    return "" if result == null else str(result)


func _check(condition: bool, label: String) -> void:
    _checks += 1
    if condition:
        print("  ✓ " + label)
    else:
        print("  ✗ " + label)
        _failures.append(label)


func _report() -> void:
    print("")
    print("  --- 观测数据 ---")
    print("  状态覆盖：%s" % ", ".join(_states_seen.keys()))
    print("  招式阶段：%s" % ", ".join(_phases_seen.keys()))
    print("  判定盒开启帧数：%d" % _hitbox_open_frames)
    print("  命中次数：%d    敌人掉血事件：%d    玩家受伤事件：%d" % [
        _hits_confirmed, _enemy_damage_events, _player_damage_events
    ])
    print("  最大顿帧：%d 帧    最大震动强度：%.3f" % [_max_hitstop_frames, _max_shake_intensity])
    print("  清空房间次数：%d    访问房间数：%d    调试台输出行数：%d" % [
        _room_cleared_events, _rooms_visited.size(), _console_lines
    ])
    print("  三选一：给出 %d 次，结算 %d 次    内力：%d    心法层数：%d" % [
        _rewards_offered, _rewards_taken, _main.run_state.coins, _main.run_state.upgrades_taken()
    ])
    print("")
    print("----------------------------------------")
    print("  检查项 %d 个   失败 %d 个" % [_checks, _failures.size()])
    if _failures.is_empty():
        print("  结果：冒烟测试全部通过 ✓")
    else:
        for failure in _failures:
            print("  ✗ " + failure)
        print("  结果：冒烟测试有失败 ✗")
    print("========================================\n")

    get_tree().quit(0 if _failures.is_empty() else 1)
