class_name Hitstop
extends RefCounted
## 顿帧（hitstop）控制器 —— 纯逻辑类，可被单元测试直接覆盖。
##
## 顿帧是什么：
##   命中瞬间把整个世界的时间几乎冻结几帧，然后恢复。
##   这几帧让玩家"感觉到"刀真的砍进去了，是打击感三件套之一
##   （另外两件是屏幕震动和受击音效）。没有顿帧的攻击会像在打棉花。
##
## 实现要点（也是 AI 最容易写错的地方）：
##   Engine.time_scale 会把 delta 一起缩放，所以倒计时必须按「真实时间」走。
##   如果直接用被缩放过的 delta 倒计时，顿帧会变成真的卡死。
##   本类因此把逻辑和"什么时候改 Engine.time_scale"分开：
##   本类只管纯逻辑（tick 接收真实时间），改 time_scale 由 combat_director.gd 负责。

## 顿帧期间的时间缩放。越小越接近静止。
var time_scale: float = 0.05
## 单次顿帧的最大帧数。防止数据配错导致游戏长时间卡住。
var max_frames: int = 12

var _remaining_seconds: float = 0.0
var _requested_frames: int = 0


func _init(p_time_scale: float = 0.05, p_max_frames: int = 12) -> void:
    time_scale = p_time_scale
    max_frames = maxi(1, p_max_frames)


## 请求一次顿帧。
## 连续命中时取「更长的那一个」，而不是简单叠加或覆盖 ——
## 否则一套连招打上去会出现顿帧忽长忽短、节奏断裂。
func request(frames: int) -> void:
    if frames <= 0:
        return
    var clamped := mini(frames, max_frames)
    var seconds := float(clamped) / 60.0
    if seconds > _remaining_seconds:
        _remaining_seconds = seconds
        _requested_frames = clamped


## 用「真实时间」推进。返回 true 表示本帧仍在顿帧中。
## @param real_delta 未被 Engine.time_scale 缩放的秒数
func tick(real_delta: float) -> bool:
    if _remaining_seconds <= 0.0:
        return false
    _remaining_seconds = maxf(0.0, _remaining_seconds - maxf(0.0, real_delta))
    return _remaining_seconds > 0.0


## 当前是否处于顿帧中。
func is_active() -> bool:
    return _remaining_seconds > 0.0


## 剩余顿帧数（向上取整），用于调试 HUD。
func remaining_frames() -> int:
    return int(ceil(_remaining_seconds * 60.0))


## 最近一次请求的顿帧帧数（已裁剪），用于调试 HUD。
func requested_frames() -> int:
    return _requested_frames


## 立即结束顿帧。用于玩家死亡、切场景等需要立刻恢复正常时间的场合。
func cancel() -> void:
    _remaining_seconds = 0.0
    _requested_frames = 0
