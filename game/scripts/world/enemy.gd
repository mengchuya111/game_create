class_name Enemy
extends CharacterBody2D
## 敌人 / 训练木桩。
##
## 骨架阶段先做「训练木桩」：不会反击、血很厚、死了会自动复活。
## 它的唯一用途是让你反复验证打击感（顿帧够不够、震屏过不过、连段顺不顺）。
##
## 为什么先做木桩而不是先做 AI：
##   手感调优需要几百次重复攻击同一个目标。如果目标会走会反击，
##   你每次测试的条件都不一样，调出来的数值就是噪音。
##   先把木桩调爽，再接 AI —— 这个顺序不能反。

## 架势被打空后的硬直帧数。
const STAGGER_FRAMES: int = 20
## 硬直期间水平速度的衰减速率（像素/秒²）。让敌人"被打退后滑一段再停"。
const STAGGER_FRICTION: float = 600.0

## 行为模式："dummy" 木桩（默认）/ "walker" 会走会打的简单敌人
@export var behavior: String = "dummy"
## 木桩死后多久复活（秒）。0 表示不复活。
@export var respawn_delay: float = 1.2
## 移动速度（walker 模式）。
@export var move_speed: float = 70.0
## 察觉范围（walker 模式）。
@export var detect_range: float = 220.0
## 生命上限。由 archetype 数据覆盖。
@export var max_hp: int = 60
## 防御值。100 点防御 = 伤害减半。
@export var defense: int = 0
## 重量。数值越大越难被击退（击退距离 = 基础击退 / 重量）。由 archetype 数据覆盖。
@export var weight: float = 1.0
## 架势上限。架势被打空会进入一段无法行动的硬直。由 archetype 数据覆盖。
@export var max_poise: float = 40.0
## 击杀后掉落的"内力"（本局货币）。0 表示不给 —— 复活型木桩必须设 0，
## 否则玩家可以靠反复打死木桩无限刷内力。
@export var coin_reward: int = 0

@onready var visual: Node2D = $Visual
@onready var body_rect: ColorRect = $Visual/Body
@onready var hp_bar_bg: ColorRect = $Visual/HpBarBg
@onready var hp_bar: ColorRect = $Visual/HpBar
@onready var hurtbox: Hurtbox = $Hurtbox
@onready var hitbox: Hitbox = $Hitbox

## 该敌人使用的招式 id（walker 模式）。
@export var attack_id: String = "enemy_swipe"
## 攻击间隔帧数。
@export var attack_interval_frames: int = 90

var attack_table: AttackTable = null
var _player: Node2D = null
var _respawn_timer: float = 0.0
var _attack_cooldown: int = 0
var _attack_frames_left: int = 0
var _current_attack: AttackDef = null
var _flash_timer: float = 0.0
## 架势被打空后的剩余硬直帧数。
var _stagger_frames: int = 0


func _ready() -> void:
    add_to_group("enemy")
    hurtbox.team = "enemy"
    # ⚠️ 这一行绝对不能漏。
    # Hitbox.source_team 的默认值是 "player"，而判定命中规则是"只打不同阵营的目标"。
    # 不设置的话会出现两个极其难查的后果：
    #   1. 山贼的刀打不到玩家（玩家也是 "player" 阵营，被判定为"自己人"）；
    #   2. 山贼会互相误伤、还会把训练木桩砍死。
    # 这个 bug 在代码里完全看不出来，只有把游戏真的跑起来才会暴露
    # （见 tests/smoke_run.gd 的阶段 2）。
    hitbox.source_team = "enemy"
    hurtbox.max_hp = max_hp
    hurtbox.defense = defense
    hurtbox.weight = weight
    hurtbox.max_poise = max_poise
    hurtbox.reset()
    hurtbox.took_damage.connect(_on_took_damage)
    hurtbox.died.connect(_on_died)
    # 架势被打空 → 进入硬直。这个信号以前发了没人听（死信号），现在接上了。
    hurtbox.stagger_requested.connect(_on_stagger_requested)
    _update_body_color()
    _update_hp_bar()


## 应用敌人原型数据（来自 data/enemies.json）。
## 必须在 add_child() 之前调用，因为 _ready() 会用这些数值初始化受击盒。
func apply_archetype(data: Dictionary) -> void:
    behavior = str(data.get("behavior", behavior))
    max_hp = int(data.get("max_hp", max_hp))
    defense = int(data.get("defense", defense))
    weight = float(data.get("weight", weight))
    max_poise = float(data.get("max_poise", max_poise))
    move_speed = float(data.get("move_speed", move_speed))
    detect_range = float(data.get("detect_range", detect_range))
    attack_id = str(data.get("attack_id", attack_id))
    attack_interval_frames = int(data.get("attack_interval_frames", attack_interval_frames))
    respawn_delay = float(data.get("respawn_delay", respawn_delay))
    coin_reward = int(data.get("coin_reward", coin_reward))


## 由 arena.gd 调用，注入依赖。
func setup(p_attack_table: AttackTable) -> void:
    attack_table = p_attack_table


func _physics_process(delta: float) -> void:
    if _flash_timer > 0.0:
        _flash_timer -= delta
        if _flash_timer <= 0.0:
            _update_body_color()

    if hurtbox.is_dead():
        _respawn_timer -= delta
        if respawn_delay > 0.0 and _respawn_timer <= 0.0:
            _respawn()
        velocity.x = 0.0
        _apply_gravity(delta)
        move_and_slide()
        return

    # 架势被打空的硬直：期间不移动、不出招、也不结算攻击冷却。
    # 注意重力照常施加，否则敌人会浮在半空中。
    if _stagger_frames > 0:
        _stagger_frames -= 1
        velocity.x = move_toward(velocity.x, 0.0, STAGGER_FRICTION * delta)
        _apply_gravity(delta)
        move_and_slide()
        return

    if behavior == "walker":
        _tick_walker(delta)
    else:
        velocity.x = 0.0
        _apply_gravity(delta)

    _tick_attack()
    _sync_hitbox()
    move_and_slide()


## 架势被打空：打断当前出招，进入一段无法行动的硬直。
##
## 为什么要"取最大值"而不是累加：
##   连续攻击会让硬直帧数不断叠加，敌人被永久锁死，玩家体验变成"打木桩"。
##   取最大值保证"打空架势"这个事件有明确、可预期的效果时长。
func _on_stagger_requested(_amount: int) -> void:
    _stagger_frames = maxi(_stagger_frames, STAGGER_FRAMES)
    # 打断出招：清掉当前招式并立刻关掉判定盒，否则硬直期间还能打人
    _attack_frames_left = 0
    _current_attack = null
    if hitbox.is_swinging():
        hitbox.end_swing()
    velocity.x = 0.0


func _apply_gravity(delta: float) -> void:
    if is_on_floor():
        if velocity.y > 0.0:
            velocity.y = 0.0
        return
    velocity.y = minf(velocity.y + GameConfig.GRAVITY * delta, GameConfig.MAX_FALL_SPEED)


func _tick_walker(_delta: float) -> void:
    _apply_gravity(_delta)
    var target := _resolve_player()
    if target == null:
        velocity.x = 0.0
        return

    var offset := target.global_position.x - global_position.x
    if absf(offset) > detect_range:
        velocity.x = 0.0
        return

    var facing := 1 if offset > 0.0 else -1
    visual.scale.x = float(facing)

    # 靠近到攻击距离就停下出招
    if absf(offset) < 34.0 and _attack_cooldown <= 0 and _attack_frames_left <= 0:
        _start_attack()
        velocity.x = 0.0
        return

    if absf(offset) > 28.0:
        velocity.x = float(facing) * move_speed
    else:
        velocity.x = 0.0


func _tick_attack() -> void:
    if _attack_cooldown > 0:
        _attack_cooldown -= 1
    if _attack_frames_left > 0:
        _attack_frames_left -= 1


func _start_attack() -> void:
    if attack_table == null or not attack_table.has_attack(attack_id):
        return
    _current_attack = attack_table.get_attack(attack_id)
    _attack_frames_left = _current_attack.total_frames
    _attack_cooldown = attack_interval_frames


func _sync_hitbox() -> void:
    if _current_attack == null or _attack_frames_left <= 0:
        if hitbox.is_swinging():
            hitbox.end_swing()
        return

    var elapsed := _current_attack.total_frames - _attack_frames_left
    if _current_attack.is_active_frame(elapsed):
        if not hitbox.is_swinging():
            var facing := 1 if visual.scale.x >= 0.0 else -1
            hitbox.begin_swing(_current_attack, 0, facing)
    elif hitbox.is_swinging():
        hitbox.end_swing()


func _resolve_player() -> Node2D:
    if is_instance_valid(_player):
        return _player
    _player = get_tree().get_first_node_in_group("player") as Node2D
    return _player


# ============================== 受击表现 ==============================

func _on_took_damage(_amount: int, _remaining_hp: int, attacker: Hitbox) -> void:
    _flash_timer = 0.09
    body_rect.color = Color(2.0, 2.0, 2.0, 1.0)  # 受击闪白
    _update_hp_bar()

    # 击退：木桩也会被推动，这样才看得出招式的"推力"
    if behavior == "dummy" and attacker != null:
        velocity = hurtbox.knockback_vector(attacker)


func _on_died() -> void:
    _respawn_timer = respawn_delay
    visual.modulate = Color(0.4, 0.4, 0.4, 0.5)
    if hitbox.is_swinging():
        hitbox.end_swing()
    # 收益结算放在这里而不是 hurtbox：受击盒是通用组件，
    # 不该知道"敌人值多少内力"这种玩法数据。
    if coin_reward > 0:
        EventBus.enemy_defeated.emit(global_position, coin_reward)


func _respawn() -> void:
    hurtbox.reset()
    visual.modulate = Color.WHITE
    velocity = Vector2.ZERO
    _update_hp_bar()
    _update_body_color()


func _update_body_color() -> void:
    if behavior == "walker":
        body_rect.color = Color(0.35, 0.55, 0.95, 1.0)
    else:
        body_rect.color = Color(0.55, 0.45, 0.35, 1.0)


func _update_hp_bar() -> void:
    if hp_bar == null:
        return
    var ratio := hurtbox.hp_ratio()
    hp_bar.scale.x = maxf(0.001, ratio)
    # 血条从左边开始收缩，而不是从中心
    hp_bar.position.x = hp_bar_bg.position.x


func snapshot() -> Dictionary:
    var data := hurtbox.snapshot()
    data["behavior"] = behavior
    data["position"] = [global_position.x, global_position.y]
    return data
