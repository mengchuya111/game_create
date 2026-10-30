class_name Hurtbox
extends Area2D
## 受击判定盒。
##
## 负责：血量、架势值、无敌帧、伤害结算、把结果广播到 EventBus。
## 不负责：播放特效、屏幕震动、顿帧 —— 那些由 combat_director.gd 监听信号完成。
##
## AI 协作约定：
##   任何"扣血"都必须经过本文件，禁止在别处直接改 hp。
##   这样"无敌帧""架势硬直""死亡"这些规则才不会漏掉。

const LAYER_HITBOX := 1 << 3
const LAYER_HURTBOX := 1 << 4

## 阵营："player" 或 "enemy"。
@export var team: String = "enemy"
## 最大生命值。
@export var max_hp: int = 100
## 防御值。100 点防御 = 伤害减半。
@export var defense: int = 0
## 架势上限。架势被打空会进入硬直。
@export var max_poise: float = 40.0
## 重量。越重被击退得越少。
@export var weight: float = 1.0
## 受击后无敌帧数。
@export var invuln_frames_on_hit: int = 0

## 当前生命值。
var hp: int = 100
## 当前架势值。
var poise: float = 40.0
## 剩余无敌帧数。
var invuln_frames: int = 0
## 是否已死亡。
var dead: bool = false

## 受击时发出。参数：伤害值、剩余血量、攻击方
signal took_damage(amount: int, remaining_hp: int, attacker: Hitbox)
## 死亡时发出。
signal died()
## 架势被打空时发出。由 player.gd / enemy.gd 连接后驱动自己的硬直状态。
signal stagger_requested(amount: int)


func _ready() -> void:
    collision_layer = LAYER_HURTBOX
    collision_mask = LAYER_HITBOX
    monitoring = false
    monitorable = true
    reset()


## 重置到满血满架势。重开一局时调用。
func reset() -> void:
    hp = max_hp
    poise = max_poise
    invuln_frames = 0
    dead = false


func _physics_process(delta: float) -> void:
    if invuln_frames > 0:
        invuln_frames -= 1
    if dead:
        return
    poise = Damage.regen_poise(poise, max_poise, GameConfig.POISE_REGEN_PER_SEC, delta)


func is_invulnerable() -> bool:
    return invuln_frames > 0


func is_dead() -> bool:
    return dead


func hp_ratio() -> float:
    if max_hp <= 0:
        return 0.0
    return float(hp) / float(max_hp)


## 受到一次攻击。由 Hitbox 调用 —— 这是唯一的扣血入口。
func receive_hit(hitbox: Hitbox) -> void:
    if dead or is_invulnerable():
        return
    if hitbox == null or hitbox.attack_def == null:
        return

    var def := hitbox.attack_def

    # 1. 伤害计算（连段递减 → 防御减免）
    var combo_multiplier := Damage.combo_scale(hitbox.combo_index)
    var amount := Damage.compute(
        def.damage,
        hitbox.attack_multiplier * combo_multiplier,
        defense,
        false
    )

    # 2. 架势结算
    var poise_result := Damage.apply_poise(poise, def.poise_damage)
    poise = poise_result["remaining"]
    var staggered: bool = poise_result["staggered"]

    # 3. 扣血
    hp = maxi(0, hp - amount)

    # 4. 无敌帧
    if invuln_frames_on_hit > 0:
        invuln_frames = maxi(invuln_frames, invuln_frames_on_hit)

    # 5. 广播
    var world_pos := global_position
    took_damage.emit(amount, hp, hitbox)
    EventBus.hit_confirmed.emit(def.id, def.hitstop, def.shake, world_pos)

    if team == "player":
        EventBus.player_damaged.emit(amount, hp)
    else:
        EventBus.enemy_damaged.emit(amount, hp, world_pos)

    if hp <= 0:
        dead = true
        died.emit()
        if team == "player":
            EventBus.player_died.emit()
        else:
            EventBus.enemy_died.emit(world_pos)

    # 6. 硬直交给目标自己处理（本类不认识状态机）
    if staggered:
        stagger_requested.emit(amount)


## 治疗。这是除了 receive_hit 之外唯一允许改血量的入口。
## 为什么不让 player.gd 直接写 hp：那样会绕过死亡判定、上限 clamp 和事件广播，
## 出现"血条回满了但 HUD 不知道"这类问题（见 AGENTS.md 规矩 2）。
##
## @return 实际回复量（满血时为 0）
func heal(amount: int) -> int:
    if dead or amount <= 0:
        return 0
    var before := hp
    hp = mini(max_hp, hp + amount)
    var healed := hp - before
    if healed > 0 and team == "player":
        EventBus.player_healed.emit(healed, hp)
    return healed


## 计算"如果现在被打，会掉多少血"，不实际扣血。
## 用于 UI 预览和单元测试。
func preview_damage(def: AttackDef, attack_multiplier: float = 1.0, combo_index: int = 0) -> int:
    return Damage.compute(
        def.damage,
        attack_multiplier * Damage.combo_scale(combo_index),
        defense,
        false
    )


## 施加击退。由 player.gd / enemy.gd 连接 hitbox 后调用。
func knockback_vector(hitbox: Hitbox) -> Vector2:
    if hitbox == null or hitbox.attack_def == null:
        return Vector2.ZERO
    var speed := Damage.knockback_for_weight(hitbox.attack_def.knockback, weight)
    return Vector2(speed * float(hitbox.facing), -speed * 0.25)


## 状态快照，用于调试台 dump 和自动化测试断言。
func snapshot() -> Dictionary:
    return {
        "team": team,
        "hp": hp,
        "max_hp": max_hp,
        "poise": poise,
        "max_poise": max_poise,
        "defense": defense,
        "invuln_frames": invuln_frames,
        "dead": dead,
    }
