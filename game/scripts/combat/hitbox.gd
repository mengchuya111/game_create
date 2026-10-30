class_name Hitbox
extends Area2D
## 攻击判定盒。
##
## 生命周期由 player.gd / enemy.gd 根据帧数据驱动：
##   begin_swing() → 判定帧内每帧检测 → end_swing()
##
## 一次挥击内同一个目标只结算一次伤害（_hit_this_swing 记录），
## 否则判定帧有 3 帧就会打出 3 倍伤害 —— 这是新手最常见的伤害 bug。
##
## AI 协作约定：
##   不要在本文件里写"播放特效""播放音效"。
##   本文件只负责"算伤害 + 发信号"，演出由 combat_director.gd 监听信号完成。

## 碰撞层约定（见 AGENTS.md「碰撞层分配表」）
##   第 4 层 = 攻击判定，第 5 层 = 受击判定
const LAYER_HITBOX := 1 << 3
const LAYER_HURTBOX := 1 << 4

## 本次挥击使用的招式数据。
var attack_def: AttackDef = null
## 连段序号，用于伤害递减。
var combo_index: int = 0
## 攻击方朝向。
var facing: int = 1
## 攻击方阵营："player" 或 "enemy"。只打不同阵营的目标。
var source_team: String = "player"
## 攻击方倍率（装备、buff、词条）。
var attack_multiplier: float = 1.0

var _hit_this_swing: Array[Hurtbox] = []
var _shape_node: CollisionShape2D = null
## 判定盒开关的操作序号。用于让"延迟关闭"不会覆盖掉同一帧里新开的判定盒。
var _swing_token: int = 0


func _ready() -> void:
    collision_layer = LAYER_HITBOX
    collision_mask = LAYER_HURTBOX
    monitoring = false
    monitorable = false
    _ensure_shape_node()
    if not area_entered.is_connected(_on_area_entered):
        area_entered.connect(_on_area_entered)


## 开始一次挥击。判定盒位置和尺寸会按帧数据自动设置。
func begin_swing(def: AttackDef, p_combo_index: int = 0, p_facing: int = 1) -> void:
    if def == null:
        push_warning("[Hitbox] begin_swing 收到了 null 招式，已忽略")
        return
    attack_def = def
    combo_index = p_combo_index
    facing = p_facing
    _hit_this_swing.clear()
    _apply_geometry()
    _swing_token += 1
    monitoring = true


## 结束挥击，关闭判定。
##
## ⚠️ 这里为什么用"延迟关闭"而不是直接 `monitoring = false`：
##   Godot 不允许在 area_entered / area_exited 信号回调内部修改 monitoring。
##   直接改会报 `Function blocked during in/out signal`，而且**是静默失败** ——
##   判定盒会一直开着，敌人已经死了还在挨打。
##   这个坑只有把游戏真的跑起来才会暴露（见 tests/smoke_run.gd）。
##
## 为什么还要一个 token：
##   延迟调用在本帧末尾执行。如果同一帧里"先关再开"（取消后立刻接下一段），
##   那次延迟关闭会把刚打开的判定盒又关掉。token 保证只有最后一次操作生效。
##
## 注意：`attack_def = null` 是**立即**生效的，所以判定盒从这一刻起就已经打不到人了，
## 只是物理层面的 monitoring 晚一帧关闭而已。
func end_swing() -> void:
    attack_def = null
    _hit_this_swing.clear()
    _swing_token += 1
    if not monitoring:
        return
    if is_inside_tree():
        call_deferred("_finish_disable", _swing_token)
    else:
        monitoring = false


func _finish_disable(token: int) -> void:
    # 这一帧里又开了一次新挥击，就不要关了
    if token != _swing_token:
        return
    monitoring = false


## 判定盒当前是否开启。
func is_swinging() -> bool:
    return attack_def != null and monitoring


## 本次挥击已经命中的目标数量（调试 HUD 用）。
func hit_count() -> int:
    return _hit_this_swing.size()


func _apply_geometry() -> void:
    if attack_def == null:
        return
    position = attack_def.hitbox_offset_for_facing(facing)
    _ensure_shape_node()
    if _shape_node == null:
        return
    var rect := RectangleShape2D.new()
    rect.size = attack_def.hitbox_size
    _shape_node.shape = rect


func _ensure_shape_node() -> void:
    if _shape_node != null and is_instance_valid(_shape_node):
        return
    _shape_node = get_node_or_null("CollisionShape2D") as CollisionShape2D
    if _shape_node == null:
        # 场景里没画碰撞形状时自动补一个，避免"忘了在编辑器里加节点"导致判定盒失效
        _shape_node = CollisionShape2D.new()
        _shape_node.name = "CollisionShape2D"
        add_child(_shape_node)


func _on_area_entered(area: Area2D) -> void:
    if attack_def == null:
        return

    var hurt := area as Hurtbox
    if hurt == null:
        return
    if hurt.team == source_team:
        return
    if _hit_this_swing.has(hurt):
        return
    if hurt.is_invulnerable():
        return
    if hurt.is_dead():
        return

    _hit_this_swing.append(hurt)
    hurt.receive_hit(self)
