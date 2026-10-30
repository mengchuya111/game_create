class_name ScreenShake
extends RefCounted
## 屏幕震动 —— 纯逻辑类，可被单元测试直接覆盖。
##
## 采用经典的 trauma（创伤）模型：
##   1. 命中时往 trauma 里"加能量"（0.0 ~ 1.0），而不是直接设一个固定位移；
##   2. 每帧按固定速度衰减；
##   3. 实际偏移 = max_offset × trauma² × 波形。
##
## 为什么用 trauma² 而不是 trauma：
##   平方让震动"一开始猛、后面快速收敛"，比线性衰减自然得多。
##   线性衰减会让屏幕在很长一段时间里持续轻微抖动，看起来像画面在漂。
##
## 为什么用正弦叠加而不是随机数：
##   随机数在高帧率下相邻两帧方向会突变，看起来像噪点闪烁；
##   多个不同频率的正弦叠加能得到平滑但有随机感的抖动，而且完全可复现。

## 当前创伤值（0.0 ~ 1.0）。
var trauma: float = 0.0
## 最大像素偏移。
var max_offset: float = 14.0
## 每秒衰减的创伤值。
var decay_per_second: float = 3.2
## 抖动频率（次/秒）。
var frequency: float = 34.0

var _elapsed: float = 0.0


func _init(p_max_offset: float = 14.0, p_decay: float = 3.2, p_frequency: float = 34.0) -> void:
    max_offset = p_max_offset
    decay_per_second = p_decay
    frequency = p_frequency


## 追加震动能量。amount 会被裁剪到 0.0 ~ 1.0 的总量。
func add(amount: float) -> void:
    trauma = clampf(trauma + maxf(0.0, amount), 0.0, 1.0)


## 推进时间并衰减。delta 应当是真实时间。
func tick(delta: float) -> void:
    _elapsed += maxf(0.0, delta)
    trauma = maxf(0.0, trauma - decay_per_second * maxf(0.0, delta))


## 当前是否还有震动。
func is_active() -> bool:
    return trauma > 0.0


## 当前帧的相机偏移量。直接赋给 Camera2D.offset。
func current_offset() -> Vector2:
    if trauma <= 0.0:
        return Vector2.ZERO

    var amount := trauma * trauma
    var phase := _elapsed * frequency

    # 两个不同频率的正弦叠加：既有方向变化，又不会像随机数那样闪烁
    var nx := sin(phase) * 0.6 + sin(phase * 2.3 + 1.7) * 0.4
    var ny := sin(phase * 1.3 + 0.5) * 0.6 + sin(phase * 2.7 + 3.1) * 0.4

    return Vector2(nx, ny) * max_offset * amount


## 当前震动强度（0.0 ~ 1.0），用于调试 HUD 和音效联动。
func intensity() -> float:
    return trauma * trauma


## 立即停止震动。
func cancel() -> void:
    trauma = 0.0
