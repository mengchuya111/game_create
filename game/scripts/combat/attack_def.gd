class_name AttackDef
extends RefCounted
## 单个招式的帧数据（"帧数据表"里的一行）。
##
## 帧数据是横版动作游戏的命根子。一个招式的完整生命周期：
##
##     第 0 帧
##        │
##        ├──────── startup 起手帧 ────────▶ 动作已经出来，但还没有伤害
##        │
##        ├──────── active 判定帧 ─────────▶ 攻击盒生效，打中就有伤害
##        │
##        └──────── recovery 收招帧 ───────▶ 不能行动，这是"硬直"，也是被惩罚的窗口
##                                              │
##                                              ▼  总帧数结束，回到可行动状态
##
## cancel_from 是「取消窗口」的起点：从这一帧起玩家可以输入下一招，
## 直接打断 recovery 进入连段 —— 这是连招手感的关键，也是武侠动作游戏的核心。
##
## AI 协作约定：
##   - 本类只描述数据，不含任何游戏逻辑，不要在这里写"造成伤害"之类的代码。
##   - 所有数值来自 data/attacks.json，不要写死在代码里。

## 招式唯一 id，例如 "light_1"。
var id: String = ""
## 显示名称，用于调试台和 UI。
var display_name: String = ""

# ---------------- 帧数（单位：帧，60FPS） ----------------
## 起手帧：从按下按键到判定生效之间的帧数。越小越快。
var startup: int = 6
## 判定帧：攻击盒处于生效状态的帧数。
var active: int = 3
## 收招帧：判定结束到恢复行动之间的帧数。越大越"重"。
var recovery: int = 9

# ---------------- 取消（连段） ----------------
## 从第几帧起允许取消进下一招。-1 表示本招不可取消。
var cancel_from: int = -1
## 可以取消进哪些招式 id。
var cancel_into: PackedStringArray = PackedStringArray()

# ---------------- 伤害 ----------------
## 基础伤害值（未经防御减免）。
var damage: int = 5
## 削架势值。架势被打空目标会硬直。
var poise_damage: int = 5
## 伤害倍率，用于同一招式在不同状态下的差异。
var damage_multiplier: float = 1.0

# ---------------- 打击感 ----------------
## 命中时请求的顿帧帧数。0 表示不顿帧。
var hitstop: int = 4
## 命中时请求的震动强度（0.0 ~ 1.0）。
var shake: float = 0.25
## 命中时对目标施加的击退速度（像素/秒）。
var knockback: float = 90.0
## 命中时自身前冲的速度（像素/秒）。武侠的"贴身感"靠它。
var move_impulse: float = 60.0

# ---------------- 判定盒 ----------------
## 攻击盒相对角色原点的偏移。x 会按角色朝向自动翻转。
var hitbox_offset: Vector2 = Vector2(22.0, -8.0)
## 攻击盒尺寸。
var hitbox_size: Vector2 = Vector2(34.0, 26.0)

# ---------------- 派生 ----------------
## 总帧数 = 起手 + 判定 + 收招。由 from_dict() 自动算出，不要手工赋值。
var total_frames: int = 0


## 从 JSON 字典构造。缺失字段一律用默认值兜底，避免一个字段写错整个数据表加载失败。
static func from_dict(data: Dictionary) -> AttackDef:
    var def := AttackDef.new()

    def.id = str(data.get("id", ""))
    def.display_name = str(data.get("display_name", def.id))

    def.startup = int(data.get("startup", 6))
    def.active = int(data.get("active", 3))
    def.recovery = int(data.get("recovery", 9))

    def.cancel_from = int(data.get("cancel_from", -1))
    var raw_cancel: Variant = data.get("cancel_into", [])
    if raw_cancel is Array:
        var cancel_list: Array = raw_cancel
        for item in cancel_list:
            def.cancel_into.append(str(item))

    def.damage = int(data.get("damage", 5))
    def.poise_damage = int(data.get("poise_damage", 5))
    def.damage_multiplier = float(data.get("damage_multiplier", 1.0))

    def.hitstop = int(data.get("hitstop", 4))
    def.shake = float(data.get("shake", 0.25))
    def.knockback = float(data.get("knockback", 90.0))
    def.move_impulse = float(data.get("move_impulse", 60.0))

    def.hitbox_offset = _to_vector2(data.get("hitbox_offset"), Vector2(22.0, -8.0))
    def.hitbox_size = _to_vector2(data.get("hitbox_size"), Vector2(34.0, 26.0))

    def.recalculate_total()
    return def


## 重算总帧数。修改 startup/active/recovery 之后必须调用。
func recalculate_total() -> void:
    total_frames = startup + active + recovery


## 当前处于哪个阶段。返回 "startup" / "active" / "recovery" / "end"。
func phase_at(frame: int) -> String:
    if frame < startup:
        return "startup"
    if frame < startup + active:
        return "active"
    if frame < total_frames:
        return "recovery"
    return "end"


## 第 frame 帧攻击盒是否生效。
func is_active_frame(frame: int) -> bool:
    return frame >= startup and frame < startup + active


## 第 frame 帧是否允许取消进下一招。
func can_cancel_at(frame: int) -> bool:
    if cancel_from < 0 or cancel_into.is_empty():
        return false
    return frame >= cancel_from and frame < total_frames


## 招式是否已经打完。
func is_finished_at(frame: int) -> bool:
    return frame >= total_frames


## 当前帧的攻击盒世界偏移（已按朝向翻转）。
func hitbox_offset_for_facing(facing: int) -> Vector2:
    return Vector2(hitbox_offset.x * float(facing), hitbox_offset.y)


## 导出为字典，便于调试台 dump 和测试比对。
func to_dict() -> Dictionary:
    return {
        "id": id,
        "display_name": display_name,
        "startup": startup,
        "active": active,
        "recovery": recovery,
        "total_frames": total_frames,
        "cancel_from": cancel_from,
        "cancel_into": Array(cancel_into),
        "damage": damage,
        "poise_damage": poise_damage,
        "damage_multiplier": damage_multiplier,
        "hitstop": hitstop,
        "shake": shake,
        "knockback": knockback,
        "move_impulse": move_impulse,
        "hitbox_offset": [hitbox_offset.x, hitbox_offset.y],
        "hitbox_size": [hitbox_size.x, hitbox_size.y],
    }


## JSON 里数组会被解析成 [x, y]，统一转成 Vector2。
static func _to_vector2(value: Variant, fallback: Vector2) -> Vector2:
    if value is Vector2:
        return value
    if value is Array:
        var arr: Array = value
        if arr.size() >= 2:
            return Vector2(float(arr[0]), float(arr[1]))
    return fallback
