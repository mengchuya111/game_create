extends Node
## 全局常量与调试开关（Autoload 名称：GameConfig）
##
## AI 协作约定：
##   1. 本文件只放「数值常量」和「调试开关」，不要在这里写游戏逻辑。
##   2. 所有影响手感的数字（重力、顿帧、震屏、输入宽容度）必须集中在这里
##      或 data/*.json，禁止散落在各个脚本里 —— 否则策划无法调参。
##   3. 改动本文件的数字后，必须跑一遍 tests/run_tests.gd，确认没有测试失败。

# ============================== 物理 ==============================
## 重力加速度（像素/秒²）。武侠横版动作游戏通常比平台跳跃更"重"一些。
const GRAVITY: float = 1500.0
## 下落终端速度，防止角色下落过快穿过地形。
const MAX_FALL_SPEED: float = 720.0
## 角色基础移动速度（像素/秒）。
const MOVE_SPEED: float = 190.0

# ============================== 输入宽容度 ==============================
## 输入缓冲窗口（帧）。玩家提前按下的攻击键会被记住这么多帧。
## 这是"手感跟手"的关键：60FPS 下 6 帧 = 100 毫秒。
const INPUT_BUFFER_FRAMES: int = 6
## 土狼时间（帧）。离开平台后仍允许起跳的宽容帧数。
const COYOTE_FRAMES: int = 6

# ============================== 打击感 ==============================
## 顿帧时的时间缩放。0.05 表示世界几乎静止，只保留一点点动感。
const HITSTOP_TIME_SCALE: float = 0.05
## 顿帧允许的最大帧数，防止某个招式配错数值导致游戏卡死。
const HITSTOP_MAX_FRAMES: int = 12
## 屏幕震动最大像素偏移。
const SHAKE_MAX_OFFSET: float = 14.0
## 震动能量（trauma）每秒衰减速度，数值越大衰减越快。
const SHAKE_DECAY: float = 3.2
## 震动抖动频率（次/秒）。
const SHAKE_FREQUENCY: float = 34.0

# ============================== 战斗 ==============================
## 受击后的无敌帧数，防止一次攻击连续多次判定。
const HURT_INVULN_FRAMES: int = 30
## 体力/架势值恢复速度（点/秒）。
const POISE_REGEN_PER_SEC: float = 12.0

# ============================== 局内成长 ==============================
## 玩家的基础生命上限（不含心法加成）。
## 这是唯一权威来源：player.tscn 里的 max_hp 只是编辑器默认值，
## apply_run_state() 会用本常量 + 心法加成重新算一遍，避免两边改漏一边。
const PLAYER_BASE_MAX_HP: int = 100
## 每间房清空后给几个选项（三选一）。
const REWARD_CHOICE_COUNT: int = 3
## 冲刺冷却的下限帧数。心法怎么叠都不许突破它，否则可以无限冲刺。
const MIN_DASH_COOLDOWN_FRAMES: int = 6

# ============================== 调试开关 ==============================
## 总开关：关掉后所有调试功能失效。
var debug_enabled: bool = true
## 显示碰撞盒（红色=攻击判定，蓝色=受击判定）。
var show_hitboxes: bool = true
## 显示左上角调试信息（状态、帧数、种子）。
var show_debug_hud: bool = true
## 是否打印帧数据切换日志。
var verbose_frame_log: bool = false

# ============================== 运行时 ==============================
## 当前这一局的随机种子。所有随机行为都必须从它派生。
var run_seed: int = 0
## 输入锁。调试台打开、过场动画、暂停时置 true，玩家角色会忽略键盘。
var input_locked: bool = false


func _ready() -> void:
    _ensure_input_actions()


## 保证输入动作存在。
## 即使 project.godot 的输入映射被误删，游戏也不会因为缺少动作而报错。
## 只有当动作完全不存在时才创建，避免和 project.godot 里的定义重复。
func _ensure_input_actions() -> void:
    var defaults: Dictionary = {
        "move_left": [KEY_A, KEY_LEFT],
        "move_right": [KEY_D, KEY_RIGHT],
        "move_up": [KEY_W, KEY_UP],
        "move_down": [KEY_S, KEY_DOWN],
        "jump": [KEY_SPACE, KEY_K],
        "attack": [KEY_J],
        "dash": [KEY_L],
        "toggle_console": [KEY_QUOTELEFT, KEY_F1],
        "restart": [KEY_R],
    }
    for action in defaults.keys():
        if InputMap.has_action(action):
            continue
        InputMap.add_action(action)
        for keycode in defaults[action]:
            var ev := InputEventKey.new()
            ev.physical_keycode = keycode
            InputMap.action_add_event(action, ev)


## 帧数转秒。所有"帧"为单位的配置在运行时都要经过它换算。
static func frames_to_seconds(frames: int) -> float:
    return float(frames) / 60.0


## 秒转帧数（向下取整）。
static func seconds_to_frames(seconds: float) -> int:
    return int(floor(seconds * 60.0))
