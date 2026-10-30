extends Node
## 自动演示驱动（录制用）—— 让游戏自己玩一段，配合 Movie Maker 导出截图/视频。
##
## 为什么单独做一个文件而不是塞进冒烟测试：
##   冒烟测试的目标是"覆盖每一个状态并断言"，它的输入脚本是刻意不自然的
##   （每 60 帧把人瞬移到敌人身边）。演示要的是"看起来像人在玩"的连贯画面，
##   两者的输入脚本目标相反，混在一起两边都会做不好。
##
## 输入是"自适应"的：每帧读取场上敌人位置，远了就走、近了就砍。
## 不是预先录好的固定脚本 —— 因为预先写死的脚本踩过一个坑：
##   出招会锁移动（_apply_horizontal 第 3 条），"每 16 帧按一次攻击"等于把人钉在原地，
##   结果是 5 秒里一步没挪、零命中。自适应驱动不会有这个问题。
##
## 用法：
##   .tooling/Godot_v4.7.2-stable_win64_console.exe --path game \
##       res://tests/demo_play.tscn --write-movie out/f.png --fixed-fps 60 --quit-after 900
##
## 不加 --write-movie 时就是普通窗口，可以直接盯着看。

const MAIN_SCENE := "res://scenes/main.tscn"
const SEED := 20240501

## 总帧数（60 帧 = 1 秒）。
const TOTAL_FRAMES := 900
## 到这个帧数还没自然清房，就直接判清空（保证一定能演示到三选一）。
const FORCE_CLEAR_AT := 640
## 三选一弹出后停留多少帧再选，留出观看时间。
const PICK_DELAY := 60
## 够得着的距离。轻击判定盒横向覆盖 6~46 像素。
const REACH := 42.0
## 进入这个距离就不再前压，开始出招。
const ENGAGE_RANGE := 44.0

var _main: Node2D = null
var _scripted: ReplayRecorder = null
var _frames: int = 0
var _clear_done: bool = false
var _pick_at: int = -1
var _finished: bool = false
var _attack_cd: int = 0
var _dash_cd: int = 0


## 自适应输入源：冒充 ReplayRecorder 交给玩家，玩家每帧来问一次"这一帧按什么"。
## 这样生产代码一行都不用改，演示走的仍然是重放的正式通路。
class LiveDriver extends ReplayRecorder:
    var host: Node = null

    func next_frame() -> PlayerInputFrame:
        if host == null:
            return PlayerInputFrame.new()
        return host.compute_frame()

    ## 永不结束 —— 输入是现算的，没有"帧数用完"这回事。
    func is_playback_finished() -> bool:
        return false

    func frame_count() -> int:
        return host.get("_frames") if host != null else 0


func _ready() -> void:
    var packed: PackedScene = load(MAIN_SCENE)
    if packed == null:
        push_error("[演示] 无法加载 main.tscn")
        get_tree().quit(1)
        return

    _main = packed.instantiate()
    add_child(_main)
    await get_tree().process_frame

    var driver := LiveDriver.new()
    driver.host = self
    _scripted = driver

    _main.start_run(SEED, false)
    _main.player.replay_source = _scripted

    EventBus.upgrade_offered.connect(_on_upgrade_offered)


## 每帧现算一次输入。玩家在 _physics_process 里调用。
func compute_frame() -> PlayerInputFrame:
    var frame := PlayerInputFrame.new()
    var player: Player = _main.player if _main != null else null
    if player == null or not is_instance_valid(player):
        return frame

    var enemy := _nearest_enemy(player)

    if _attack_cd > 0:
        _attack_cd -= 1
    if _dash_cd > 0:
        _dash_cd -= 1

    if enemy == null:
        # 没敌人就慢慢往前晃，等下一间房
        frame.right = true
        return frame

    var dx: float = enemy.global_position.x - player.global_position.x
    var distance := absf(dx)

    if distance > 240.0 and _dash_cd <= 0 and player.fsm.state_name() != "ATTACK":
        # 距离太远，冲一段过去
        frame.dash_pressed = true
        _dash_cd = 90
        if dx > 0.0:
            frame.right = true
        else:
            frame.left = true
        return frame

    if distance > ENGAGE_RANGE:
        # 走过去。注意朝向由输入决定，所以不能一边出招一边走
        if dx > 0.0:
            frame.right = true
        else:
            frame.left = true
        return frame

    # 进入攻击距离：站定出招。间隔 8 帧连点，凑出三段连招
    if _attack_cd <= 0:
        frame.attack_pressed = true
        frame.attack_held = true
        _attack_cd = 8
    else:
        frame.attack_held = true
    return frame


func _nearest_enemy(player: Player) -> Node2D:
    var nearest: Node2D = null
    var best := INF
    for node in get_tree().get_nodes_in_group("enemy"):
        if not (node is Enemy):
            continue
        var enemy: Enemy = node
        if not is_instance_valid(enemy) or enemy.hurtbox.is_dead():
            continue
        var d: float = absf(enemy.global_position.x - player.global_position.x)
        if d < best:
            best = d
            nearest = enemy
    return nearest


func _physics_process(_delta: float) -> void:
    if _finished or _main == null:
        return

    _frames += 1

    if not _clear_done and _frames >= FORCE_CLEAR_AT:
        var remaining: int = _main.arena.living_enemy_count()
        if remaining > 0:
            _clear_done = true
            _main.debug_clear_current_room()
            print("[演示] 第 %d 帧：场上还剩 %d 个，直接判清房" % [_frames, remaining])

    if _pick_at > 0 and _frames >= _pick_at:
        _pick_at = -1
        if _main.choose_upgrade(0):
            print("[演示] 第 %d 帧：选择第 1 项" % _frames)

    if _frames >= TOTAL_FRAMES:
        _finished = true
        get_tree().quit(0)


func _on_upgrade_offered(choices: Array) -> void:
    _clear_done = true
    if choices.is_empty():
        return
    _pick_at = _frames + PICK_DELAY
    print("[演示] 第 %d 帧：弹出三选一（%d 项）" % [_frames, choices.size()])
