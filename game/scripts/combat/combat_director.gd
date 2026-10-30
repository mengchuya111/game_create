extends Node
## 战斗演出总控（挂在 main.tscn 上，注册到 "combat_director" 组）
##
## 职责：
##   1. 监听 EventBus.hit_confirmed，触发顿帧和屏幕震动；
##   2. 把顿帧换算成 Engine.time_scale，结束后恢复；
##   3. 把震屏偏移交给 Camera2D。
##
## 为什么需要这个中间层：
##   让「命中」和「演出」彻底解耦。受击盒只管发一个信号，
##   它不知道有没有震屏、有没有音效、有没有粒子。
##   以后要加"命中时慢镜头""命中时手柄震动"，只改这里，不用碰战斗逻辑。
##
## 这是 AI 协作里最容易被写错的文件之一，重点在 _process 里的真实时间换算。

## 顿帧控制器（纯逻辑，见 hitstop.gd）。
var hitstop := Hitstop.new()
## 屏幕震动控制器（纯逻辑，见 screen_shake.gd）。
var shake := ScreenShake.new()

var _camera: Camera2D = null


func _ready() -> void:
    add_to_group("combat_director")

    hitstop.time_scale = GameConfig.HITSTOP_TIME_SCALE
    hitstop.max_frames = GameConfig.HITSTOP_MAX_FRAMES

    shake.max_offset = GameConfig.SHAKE_MAX_OFFSET
    shake.decay_per_second = GameConfig.SHAKE_DECAY
    shake.frequency = GameConfig.SHAKE_FREQUENCY

    EventBus.hit_confirmed.connect(_on_hit_confirmed)
    _register_console_commands()


func _exit_tree() -> void:
    # 场景切换 / 重开时一定要把时间缩放恢复，否则整个游戏会一直是慢动作
    Engine.time_scale = 1.0


func _on_hit_confirmed(
    _attack_id: String,
    hitstop_frames: int,
    shake_amount: float,
    _world_pos: Vector2
) -> void:
    hitstop.request(hitstop_frames)
    shake.add(shake_amount)


func _process(delta: float) -> void:
    # delta 已经被 Engine.time_scale 缩放过了。
    # 必须还原成真实时间，否则顿帧期间倒计时也会变慢，几帧的顿帧会变成真的卡死。
    var real_delta := delta / maxf(Engine.time_scale, 0.0001)

    if hitstop.tick(real_delta):
        Engine.time_scale = hitstop.time_scale
    elif not is_equal_approx(Engine.time_scale, 1.0):
        Engine.time_scale = 1.0

    shake.tick(real_delta)
    _apply_camera_shake()


func _apply_camera_shake() -> void:
    var cam := _resolve_camera()
    if cam == null:
        return
    cam.offset = shake.current_offset()


func _resolve_camera() -> Camera2D:
    if is_instance_valid(_camera):
        return _camera
    _camera = get_tree().get_first_node_in_group("game_camera") as Camera2D
    return _camera


## 给调试 HUD 用的一行摘要。
func debug_summary() -> String:
    return "顿帧 %d/%d 帧   震动 %.2f" % [
        hitstop.remaining_frames(),
        hitstop.requested_frames(),
        shake.intensity(),
    ]


# ============================== 调试命令 ==============================

func _register_console_commands() -> void:
    EventBus.register_console_command(
        "hitstop", "<帧数>", "手动触发一次顿帧，用来单独感受顿帧时长", _cmd_hitstop
    )
    EventBus.register_console_command(
        "shake", "<0~1>", "手动触发一次屏幕震动", _cmd_shake
    )
    EventBus.register_console_command(
        "feel", "", "按当前配置依次演示 2/4/6/8 帧顿帧，用来调手感", _cmd_feel
    )


func _cmd_hitstop(args: PackedStringArray) -> String:
    if args.is_empty():
        return "用法：hitstop <帧数>"
    var frames := int(args[0])
    hitstop.request(frames)
    return "顿帧 %d 帧" % frames


func _cmd_shake(args: PackedStringArray) -> String:
    if args.is_empty():
        return "用法：shake <0~1>"
    var amount := clampf(float(args[0]), 0.0, 1.0)
    shake.add(amount)
    return "震动强度 %.2f" % amount


func _cmd_feel(_args: PackedStringArray) -> String:
    _run_feel_demo()
    return "开始手感演示：2 / 4 / 6 / 8 帧顿帧各一次，注意感受区别"


func _run_feel_demo() -> void:
    for frames in [2, 4, 6, 8]:
        hitstop.request(frames)
        shake.add(0.15 + float(frames) * 0.03)
        # 用真实时间等待，避免被自己的 time_scale 拖慢
        await get_tree().create_timer(GameConfig.frames_to_seconds(30), true, false, true).timeout
