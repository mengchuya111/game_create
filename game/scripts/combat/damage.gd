class_name Damage
extends RefCounted
## 伤害与架势计算公式。纯函数集合，不依赖场景树，可被单元测试完整覆盖。
##
## 设计原则：战斗公式必须是纯函数。
##   - 输入数值，输出数值，不读写任何全局状态、不改血量、不发信号。
##   - 这样它才能被自动化测试验证，也才能被策划放心地调。
##
## 数值策划可以直接改下面这几个常量，改完跑一次测试就知道有没有把平衡性搞坏。

## 暴击伤害倍率。
const CRIT_MULTIPLIER: float = 1.5
## 防御减伤的基准值。defense = 100 时伤害减半。
const DEFENSE_BASE: float = 100.0
## 连段伤害递减的每段系数。
const COMBO_DECAY: float = 0.9
## 连段伤害递减的下限比例，防止连到后面伤害归零。
const COMBO_FLOOR: float = 0.4


## 计算一次伤害。
## @param base               招式基础伤害
## @param attack_multiplier  攻击方倍率（buff、装备、词条）
## @param target_defense     受击方防御值
## @param is_crit            是否暴击
## @return 最终伤害，至少为 1（只要 base > 0）
static func compute(
    base: int,
    attack_multiplier: float = 1.0,
    target_defense: int = 0,
    is_crit: bool = false
) -> int:
    if base <= 0:
        return 0
    if attack_multiplier <= 0.0:
        return 0

    var raw := float(base) * attack_multiplier
    var defense := maxf(0.0, float(target_defense))
    var mitigated := raw * (DEFENSE_BASE / (DEFENSE_BASE + defense))

    if is_crit:
        mitigated *= CRIT_MULTIPLIER

    return maxi(1, int(round(mitigated)))


## 结算架势值。
## 返回 { "remaining": float, "staggered": bool }
## staggered 为 true 表示架势被打空，目标应该进入硬直。
static func apply_poise(current_poise: float, poise_damage: int) -> Dictionary:
    var remaining := current_poise - float(maxi(0, poise_damage))
    return {
        "remaining": maxf(0.0, remaining),
        "staggered": remaining <= 0.0,
    }


## 架势值随时间恢复。
## @param current_poise 当前架势
## @param max_poise     架势上限
## @param regen_per_sec 每秒恢复量
## @param delta         经过的秒数
static func regen_poise(
    current_poise: float,
    max_poise: float,
    regen_per_sec: float,
    delta: float
) -> float:
    if current_poise >= max_poise:
        return max_poise
    return minf(max_poise, current_poise + maxf(0.0, regen_per_sec) * delta)


## 连段伤害递减。
## 连得越长单次伤害越低，防止"一套连招秒杀 Boss"这种破坏体验的情况。
## @param combo_index 这是连段中的第几招（从 0 开始）
static func combo_scale(combo_index: int) -> float:
    if combo_index <= 0:
        return 1.0
    return maxf(COMBO_FLOOR, pow(COMBO_DECAY, float(combo_index)))


## 击退速度随目标"重量"衰减。重的敌人被击退得更少。
## @param base_knockback 招式配置的击退速度
## @param target_weight  目标重量，1.0 为标准
static func knockback_for_weight(base_knockback: float, target_weight: float) -> float:
    if target_weight <= 0.0:
        return base_knockback
    return base_knockback / target_weight
