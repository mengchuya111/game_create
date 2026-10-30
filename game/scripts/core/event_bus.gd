extends Node
## 全局事件总线（Autoload 名称：EventBus）
##
## 用途：让互不认识的模块通过信号通信，避免互相持有引用、避免循环依赖。
##
## AI 协作约定：
##   1. 信号只描述「已经发生的事实」，不要用信号传递命令。
##      好例子：hit_confirmed（打中了）
##      坏例子：please_play_sound（去放个音效）
##   2. 新增信号时，必须在本文件写清注释：谁发出、谁接收、参数含义。
##   3. 不要在这里写任何逻辑代码，这里只有信号声明。

# ============================== 战斗 ==============================
## 玩家受伤。发出方：player.gd。接收方：HUD、音效、震屏。
signal player_damaged(amount: int, remaining_hp: int)

## 玩家死亡。发出方：player.gd。接收方：main.gd。
signal player_died()

## 命中确认 —— 打击感的核心入口。
## 顿帧、震屏、打击音效、命中特效全部监听这一个信号。
## 发出方：hurtbox.gd。接收方：combat_director.gd、音效系统。
## @param attack_id      造成伤害的招式 id
## @param hitstop_frames 请求的顿帧帧数
## @param shake          请求的震动强度（0~1）
## @param world_pos      命中点的世界坐标
signal hit_confirmed(attack_id: String, hitstop_frames: int, shake: float, world_pos: Vector2)

## 敌人受伤（用于伤害数字、受击闪白）。
signal enemy_damaged(amount: int, remaining_hp: int, world_pos: Vector2)

## 敌人死亡。
signal enemy_died(world_pos: Vector2)

## 敌人被击败（可结算收益）。发出方：enemy.gd。接收方：main.gd。
## @param world_pos 死亡位置
## @param coins     该敌人携带的内力（复活型木桩为 0）
signal enemy_defeated(world_pos: Vector2, coins: int)

## 玩家受到治疗。发出方：hurtbox.gd。接收方：HUD、音效。
signal player_healed(amount: int, remaining_hp: int)

# ============================== 局内成长 ==============================
## 三选一奖励已刷新。发出方：main.gd。接收方：奖励面板、自动测试。
## @param choices 心法定义数组（每项含 id / display_name / description / rarity / max_stacks）
signal upgrade_offered(choices: Array)

## 玩家选定了一条心法。发出方：main.gd。接收方：HUD、音效。
## @param upgrade_id 心法 id
## @param stacks     获得之后的总层数
signal upgrade_taken(upgrade_id: String, stacks: int)

## 内力变化。发出方：main.gd。接收方：HUD。
signal coins_changed(total: int)

# ============================== 招式状态（调试用） ==============================
## 招式阶段变化。phase 取值："startup" / "active" / "recovery" / "end"。
signal attack_phase_changed(attack_id: String, phase: String, frame: int)

# ============================== 流程 ==============================
## 房间清空。发出方：arena.gd。
signal room_cleared(room_id: String)

## 请求重开一局。发出方：debug_console.gd。接收方：main.gd。
## new_seed 为 0 表示换一个新随机种子。
signal restart_requested(new_seed: int)

# ============================== 调试 ==============================
## 调试台输出一行文本。发出方：任意模块。接收方：debug_console.gd。
signal console_line(text: String)

# ============================== 调试台命令注册表 ==============================
## 各系统在 _ready() 里调用 register_console_command() 注册自己的调试命令。
##
## 为什么放在 EventBus 而不是 DebugConsole 里：
##   节点 _ready() 的先后顺序取决于场景树顺序，如果注册表在 DebugConsole 里，
##   先 ready 的系统注册的命令会丢失。放在 Autoload 里可以彻底避免这个时序问题。
var console_commands: Dictionary = {}


## 注册一条调试台命令。
## @param cmd_name 命令名（玩家在调试台里输入的第一个词）
## @param args     参数说明，例如 "<0~1>"，没有参数就传 ""
## @param help     一句话说明，会在 help 命令里显示
## @param callback 收到命令时调用，签名 func(args: PackedStringArray) -> String
##                 返回值会打印到调试台；返回空字符串表示不输出
## @param replace  true 表示"允许覆盖同名命令，且不报警告"。
##                 玩家每换一间房都会重新实例化，god / hp / pos / attack / tp
##                 这些命令必须指向"当前这个玩家"，所以是刻意覆盖，不是重复注册错误。
##                 不传这个参数时，重复注册会打警告 —— 那通常说明真的写错了。
func register_console_command(
    cmd_name: String,
    args: String,
    help: String,
    callback: Callable,
    replace: bool = false
) -> void:
    if console_commands.has(cmd_name) and not replace:
        push_warning("[EventBus] 调试命令重复注册：%s（后注册的会覆盖前者）" % cmd_name)
    console_commands[cmd_name] = {
        "name": cmd_name,
        "args": args,
        "help": help,
        "callable": callback,
    }
