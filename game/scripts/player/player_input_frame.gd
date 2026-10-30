class_name PlayerInputFrame
extends RefCounted
## 一帧的玩家输入快照。
##
## 为什么要单独做一个类，而不是到处读 Input.is_action_pressed()：
##   1. 重放（replay）需要把每一帧的输入存下来，才能用同一个种子复现同一局；
##   2. 状态机如果直接读全局 Input，就无法被单元测试覆盖；
##   3. 输入语义集中在这里定义一次，避免每个脚本各自理解"按下"是什么意思。
##
## 约定（很重要，AI 生成代码时最容易搞错的地方）：
##   - `*_pressed` 是「边沿」：只在按下的那一帧为 true。
##   - `*_held` 是「电平」：按住期间一直为 true。
##   跳跃需要边沿（防止按住连跳），变高跳需要电平。

const BIT_LEFT := 1 << 0
const BIT_RIGHT := 1 << 1
const BIT_JUMP_PRESSED := 1 << 2
const BIT_JUMP_HELD := 1 << 3
const BIT_ATTACK_PRESSED := 1 << 4
const BIT_ATTACK_HELD := 1 << 5
const BIT_DASH_PRESSED := 1 << 6

const MASK_ALL := 0b1111111

var left: bool = false
var right: bool = false
var jump_pressed: bool = false
var jump_held: bool = false
var attack_pressed: bool = false
var attack_held: bool = false
var dash_pressed: bool = false


## 水平输入轴：-1 左，0 无，+1 右。同时按左右时视为无输入。
func move_axis() -> int:
    if left == right:
        return 0
    return -1 if left else 1


## 打包成一个整数，用于重放录制（每帧只占一个整数，体积很小）。
func to_mask() -> int:
    var mask := 0
    if left:
        mask |= BIT_LEFT
    if right:
        mask |= BIT_RIGHT
    if jump_pressed:
        mask |= BIT_JUMP_PRESSED
    if jump_held:
        mask |= BIT_JUMP_HELD
    if attack_pressed:
        mask |= BIT_ATTACK_PRESSED
    if attack_held:
        mask |= BIT_ATTACK_HELD
    if dash_pressed:
        mask |= BIT_DASH_PRESSED
    return mask


static func from_mask(mask: int) -> PlayerInputFrame:
    var frame := PlayerInputFrame.new()
    frame.left = (mask & BIT_LEFT) != 0
    frame.right = (mask & BIT_RIGHT) != 0
    frame.jump_pressed = (mask & BIT_JUMP_PRESSED) != 0
    frame.jump_held = (mask & BIT_JUMP_HELD) != 0
    frame.attack_pressed = (mask & BIT_ATTACK_PRESSED) != 0
    frame.attack_held = (mask & BIT_ATTACK_HELD) != 0
    frame.dash_pressed = (mask & BIT_DASH_PRESSED) != 0
    return frame


func to_dict() -> Dictionary:
    return {
        "left": left,
        "right": right,
        "jump_pressed": jump_pressed,
        "jump_held": jump_held,
        "attack_pressed": attack_pressed,
        "attack_held": attack_held,
        "dash_pressed": dash_pressed,
    }


static func from_dict(data: Dictionary) -> PlayerInputFrame:
    var frame := PlayerInputFrame.new()
    frame.left = bool(data.get("left", false))
    frame.right = bool(data.get("right", false))
    frame.jump_pressed = bool(data.get("jump_pressed", false))
    frame.jump_held = bool(data.get("jump_held", false))
    frame.attack_pressed = bool(data.get("attack_pressed", false))
    frame.attack_held = bool(data.get("attack_held", false))
    frame.dash_pressed = bool(data.get("dash_pressed", false))
    return frame


## 从当前真实键盘/手柄状态采样。
static func sample() -> PlayerInputFrame:
    var frame := PlayerInputFrame.new()
    frame.left = Input.is_action_pressed("move_left")
    frame.right = Input.is_action_pressed("move_right")
    frame.jump_pressed = Input.is_action_just_pressed("jump")
    frame.jump_held = Input.is_action_pressed("jump")
    frame.attack_pressed = Input.is_action_just_pressed("attack")
    frame.attack_held = Input.is_action_pressed("attack")
    frame.dash_pressed = Input.is_action_just_pressed("dash")
    return frame


func equals(other: PlayerInputFrame) -> bool:
    if other == null:
        return false
    return to_mask() == other.to_mask()


func duplicate_frame() -> PlayerInputFrame:
    return PlayerInputFrame.from_mask(to_mask())


func _to_string() -> String:
    return "[%s%s jump=%s attack=%s dash=%s]" % [
        "L" if left else "-",
        "R" if right else "-",
        "P" if jump_pressed else ("H" if jump_held else "-"),
        "P" if attack_pressed else ("H" if attack_held else "-"),
        "P" if dash_pressed else "-",
    ]
