extends Camera2D
## 跟随相机（注册到 "game_camera" 组）
##
## 分工（很重要，不要搞混）：
##   - position：本脚本负责。做朝向预判（look-ahead），让镜头略微朝角色面朝的方向偏移。
##   - offset：combat_director.gd 负责。屏幕震动直接写 offset。
##   两者分开，震动就不会被跟随逻辑每帧覆盖掉。
##
## 相机挂在 Player 节点下，所以位置天然跟随。本脚本只加"预判"和"房间边界限制"。

## 朝向预判的最大偏移距离（像素）。
@export var look_ahead_distance: float = 26.0
## 预判偏移的插值速度。
@export var look_ahead_speed: float = 4.0
## 房间左边界（世界坐标）。
@export var bounds_min_x: float = -100000.0
## 房间右边界（世界坐标）。
@export var bounds_max_x: float = 100000.0

var _current_look_ahead: float = 0.0
var _facing: int = 1


func _ready() -> void:
    add_to_group("game_camera")
    if not position_smoothing_enabled:
        position_smoothing_enabled = true
        position_smoothing_speed = 8.0


## 由 player.gd 每帧告知当前朝向。
func set_facing(new_facing: int) -> void:
    _facing = new_facing


## 由 arena.gd 在房间生成后调用，把镜头限制在房间内。
func set_bounds(min_x: float, max_x: float) -> void:
    bounds_min_x = min_x
    bounds_max_x = max_x


func _process(delta: float) -> void:
    var desired := look_ahead_distance * float(_facing)
    _current_look_ahead = lerpf(_current_look_ahead, desired, clampf(look_ahead_speed * delta, 0.0, 1.0))

    var target_x := _current_look_ahead
    var world_x := global_position.x + target_x
    if world_x < bounds_min_x:
        target_x += bounds_min_x - world_x
    elif world_x > bounds_max_x:
        target_x -= world_x - bounds_max_x

    position.x = target_x
