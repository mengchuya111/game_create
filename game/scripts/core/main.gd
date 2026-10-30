extends Node2D
## 游戏入口。负责装配所有系统、管理一局的生命周期。
##
## 装配顺序（很重要，顺序错了会出现"相机没绑上""数据没加载"这类问题）：
##   1. 载入帧数据表
##   2. 注册调试命令
##   3. 连接全局信号
##   4. 生成房间路线
##   5. 每个房间：arena 建几何 → 刷怪 → 生成玩家 → 注入依赖 → 绑相机边界
##
## AI 协作约定：
##   本文件只做"装配"和"流程"，不要在这里写战斗逻辑。
##   如果你发现自己在 main.gd 里写 if 判断某个招式怎么样，那逻辑放错文件了。
##
## 局内成长（心法三选一）的职责划分：
##   UpgradePool 决定"抽哪三条"（纯逻辑，可单测）
##   RunState    决定"叠起来是什么属性"（纯逻辑，可单测）
##   RewardPanel 决定"长什么样、玩家按了第几个"（纯 UI）
##   本文件只负责把它们串起来，以及决定"什么时候该发奖励"。

## 三选一被解决时发出（无论玩家选了还是调试命令跳过了）。
## 用自定义信号而不是 EventBus：这是 main 自己的流程控制，不应该广播给全世界。
signal reward_resolved(index: int)
## 玩家离开商店。有一个 await 挂在上面，所以必须无条件发一次。
signal shop_closed

const PLAYER_SCENE := preload("res://scenes/player.tscn")
## 一层有几个房间。
const ROOM_COUNT: int = 8
## 默认种子。固定种子让第一次运行就是可复现的。
const DEFAULT_SEED: int = 20240501
## 重放文件存放目录。
const REPLAY_DIR: String = "user://replays"
## 心法配置表路径。
const UPGRADES_PATH: String = "res://data/upgrades.json"
## 商店配置表路径（货架数量、按稀有度定价）。
const SHOP_PATH: String = "res://data/shop.json"
## 哪些房间清空后给心法奖励。起点房没有敌人，宝箱/商店另行设计，不给。
const REWARD_ROOM_TYPES: Array[String] = ["COMBAT", "ELITE", "BOSS"]

@onready var arena: Node2D = $Arena
@onready var combat_director: Node = $CombatDirector
@onready var hud_layer: CanvasLayer = $HUD
@onready var console_layer: CanvasLayer = $DebugConsole

## 帧数据表。
var attack_table := AttackTable.new()
## 本局的成长状态（内力、心法、属性加成）。
var run_state := RunState.new()
## 心法池（三选一抽取）。
var upgrade_pool := UpgradePool.new()
## 商店（摆货、定价、结算购买）。
var shop := Shop.new()
## 输入录制器。
var recorder := ReplayRecorder.new()
## 当前这层的房间路线。
var rooms: Array = []
## 当前所在房间序号。
var current_room_index: int = 0
## 玩家实例。
var player: Player = null
## 最近一次保存的重放路径。
var last_replay_path: String = ""

## 三选一面板。
var _reward_panel: RewardPanel = null
## 当前待选的三条心法。
var _pending_choices: Array = []
## 奖励流程令牌。重开一局时 +1，让还在 await 的旧流程自己退出。
var _reward_token: int = 0

## 商店面板。
var _shop_panel: ShopPanel = null
## 当前货架（Shop.stock() 的返回值，含 sold 状态）。
var _shop_items: Array = []

var _advancing: bool = false
var _run_over: bool = false


func _ready() -> void:
    add_to_group("main")

    _load_attack_table()
    _load_upgrade_pool()
    _load_shop()
    _build_reward_panel()
    _build_shop_panel()
    _register_console_commands()

    EventBus.room_cleared.connect(_on_room_cleared)
    EventBus.restart_requested.connect(_on_restart_requested)
    EventBus.player_died.connect(_on_player_died)
    EventBus.enemy_defeated.connect(_on_enemy_defeated)

    _ensure_replay_dir()
    start_run(DEFAULT_SEED)


# ============================== 装配 ==============================

func _load_upgrade_pool() -> void:
    var err := upgrade_pool.load_from_file(UPGRADES_PATH)
    if err != OK:
        # 不是致命错误：没有心法表时游戏照样能打，只是没有局内成长。
        EventBus.console_line.emit("[数据警告] 心法表加载失败：%s" % upgrade_pool.load_error)
        return
    EventBus.console_line.emit("[数据] 载入 %d 条心法" % upgrade_pool.size())


func _build_reward_panel() -> void:
    _reward_panel = RewardPanel.new()
    _reward_panel.name = "RewardPanel"
    add_child(_reward_panel)
    _reward_panel.chosen.connect(_on_reward_chosen)


func _load_shop() -> void:
    var err := shop.load_from_file(SHOP_PATH)
    if err != OK:
        # 和心法表一样：商店挂了不影响打怪，只是进商店房没东西可买。
        EventBus.console_line.emit("[数据警告] 商店配置加载失败：%s" % shop.load_error)
        return
    EventBus.console_line.emit("[数据] 商店：每次上架 %d 件，按稀有度定价" % shop.offer_count())


func _build_shop_panel() -> void:
    _shop_panel = ShopPanel.new()
    _shop_panel.name = "ShopPanel"
    add_child(_shop_panel)
    _shop_panel.buy_requested.connect(buy_shop_item)
    _shop_panel.closed.connect(_on_shop_closed)


func _load_attack_table() -> void:
    var err := attack_table.load_from_file()
    if err != OK:
        push_error("[Main] 帧数据表加载失败（错误码 %d），请检查 game/data/attacks.json" % err)
        EventBus.console_line.emit("[致命] 帧数据表加载失败，错误码 %d" % err)
        return

    for problem in attack_table.find_broken_cancel_targets():
        EventBus.console_line.emit("[数据警告] " + problem)

    EventBus.console_line.emit("[数据] 载入 %d 个招式：%s" % [
        attack_table.size(), ", ".join(Array(attack_table.ids()))
    ])


## 开一局。
## @param run_seed 随机种子
## @param record   是否录制输入。回放时传 false，否则会覆盖掉正在播放的记录。
func start_run(run_seed: int, record: bool = true) -> void:
    GameConfig.run_seed = run_seed
    GameConfig.input_locked = false
    Engine.time_scale = 1.0

    _advancing = false
    _run_over = false

    # 让上一局可能还在 await 的奖励流程失效。
    # 不加这个令牌的话：玩家在选奖励时输入 restart，旧协程醒来之后会把新局直接
    # 推进到下一间房 —— 表现为"重开一局直接跳过了第一间"。
    _reward_token += 1
    _pending_choices = []
    if _reward_panel != null:
        _reward_panel.hide_panel()
    # 唤醒可能还挂在奖励 await 上的旧协程，让它读到新 token 后立刻退出。
    reward_resolved.emit(-1)

    # 商店同理：重开一局时货架必须清空，并且把可能挂着的 await 唤醒。
    _shop_items = []
    if _shop_panel != null:
        _shop_panel.hide_panel()
    shop_closed.emit()

    run_state.reset()

    rooms = RoomGenerator.generate(run_seed, ROOM_COUNT, 1.0)
    current_room_index = 0

    for problem in RoomGenerator.validate(rooms):
        EventBus.console_line.emit("[路线警告] " + problem)

    EventBus.console_line.emit("[开局] 种子 %d" % run_seed)
    EventBus.console_line.emit("[路线] " + RoomGenerator.describe(rooms))

    if record:
        recorder.start(run_seed)
    else:
        recorder.stop()

    _load_room(0)


func _load_room(index: int) -> void:
    current_room_index = clampi(index, 0, rooms.size() - 1)
    var room: Dictionary = rooms[current_room_index]

    # 换房间会重新实例化玩家，所以先把"正在播放的重放"记下来，装好之后重新接上。
    # 不接的话，换房之后重放就断了 —— 表现是"自动测试跑到第二间房就不动了"，
    # 或者"看回放时过了一个房间角色就站着不动"。
    var carried_replay: ReplayRecorder = null
    if player != null and is_instance_valid(player):
        carried_replay = player.replay_source

    # 血量也要跨房间带过去。不带的后果不是"回满血"这么简单：
    # 新实例按场景默认值生成，心法加的生命上限和当前血量全部丢失。
    var carried_hp: int = -1
    var carried_max_hp: int = -1
    if player != null and is_instance_valid(player) and not player.hurtbox.is_dead():
        carried_hp = player.hurtbox.hp
        carried_max_hp = player.hurtbox.max_hp

    # 玩家是 arena 的子节点，arena.build() 会清空所有子节点，
    # 所以这里不需要单独 queue_free 玩家，但必须先把引用置空，避免指向已释放的节点。
    player = null
    arena.build(attack_table, room)

    player = PLAYER_SCENE.instantiate()
    player.position = Vector2(-380.0, arena.floor_y)
    arena.add_child(player)
    player.setup(attack_table, recorder)
    player.replay_source = carried_replay
    # 必须在 setup() 之后：setup 会 fsm.reset()，但不会动 hurtbox，
    # 而 apply_run_state() 要用到 attack_table 之外的成长数据。
    player.apply_run_state(run_state, carried_hp, carried_max_hp)
    player.hurtbox.died.connect(_on_player_died)

    # 相机是玩家的子节点，必须在玩家生成之后才能绑定房间边界
    arena.clamp_camera_to_room()

    EventBus.console_line.emit("[房间] %d/%d %s  敌人预算 %d" % [
        current_room_index + 1, rooms.size(), room["display_name"], room["enemy_budget"]
    ])


# ============================== 流程 ==============================

func _on_room_cleared(room_id: String) -> void:
    if _advancing or _run_over:
        return
    _advancing = true
    var token := _reward_token

    EventBus.console_line.emit("[流程] %s 已清空" % room_id)
    run_state.register_room_cleared()
    await get_tree().create_timer(0.9).timeout

    # 这 0.9 秒里玩家可能死了、也可能输入了 restart。两种情况下都不能再推进。
    if not is_inside_tree() or _run_over or token != _reward_token:
        return

    _apply_room_heal()

    # 商店房没有敌人，进房 1.5 秒后就会被判"清空"。
    # 这里把它拦下来：先开商店，等玩家自己离开，再放行到下一间。
    if _is_shop_room():
        await _open_shop()
        if not is_inside_tree() or _run_over or token != _reward_token:
            return
    elif _should_offer_reward():
        await _offer_reward()
        if not is_inside_tree() or _run_over or token != _reward_token:
            return

    if current_room_index + 1 < rooms.size():
        _load_room(current_room_index + 1)
        _advancing = false
    else:
        EventBus.console_line.emit("[流程] 通关！输入 restart 重开一局")
        _advancing = false


## 这间房清空后是否给心法奖励。
func _should_offer_reward() -> bool:
    return should_offer_reward_for_room(current_room_index)


# ============================== 商店 ==============================

## 当前房间是不是商店。
func _is_shop_room() -> bool:
    if rooms.is_empty():
        return false
    return str(rooms[current_room_index].get("type_name", "")) == "SHOP"


## 打开商店并一直等到玩家离开。
##
## 和 _offer_reward 一样要防那个时序坑：如果有人在信号里同步关掉了商店，
## 等执行到 await 时信号已经发过去了，协程会永久挂起。所以显示之后要再查一次还开着没。
func _open_shop() -> void:
    if not open_shop_now():
        return
    if _shop_panel != null and not _shop_panel.is_active():
        return
    await shop_closed


## 摆货并显示商店，不等待结果。调试台 shop 命令和自动测试走这个入口。
## @return 是否真的开出了商店（心法全叠满、数据没载入时为 false）
func open_shop_now() -> bool:
    _shop_items = shop.stock(upgrade_pool, GameConfig.run_seed, current_room_index, run_state)
    if _shop_items.is_empty():
        EventBus.console_line.emit("[商店] 没有可卖的心法（可能都叠满了）")
        return false

    GameConfig.input_locked = true
    if _shop_panel != null:
        _shop_panel.show_stock(_shop_items, run_state.coins, "第 %d 间 · 商店" % (current_room_index + 1))
    EventBus.console_line.emit("[商店] 上架：%s" % describe_stock())
    return true


## 买第 index 件（0 起）。唯一的结算入口：面板点击、数字键、调试台 buy、自动测试都走它。
func buy_shop_item(index: int) -> bool:
    var result: Dictionary = shop.buy(_shop_items, index, run_state)
    var reason := str(result.get("reason", ""))

    if not bool(result.get("ok", false)):
        EventBus.console_line.emit("[商店] " + reason)
        if _shop_panel != null and _shop_panel.is_active():
            _shop_panel.refresh(_shop_items, run_state.coins, reason)
        return false

    var item: Dictionary = result.get("item", {})
    var def: Dictionary = item.get("def", {})
    var id := str(def.get("id", ""))

    EventBus.upgrade_taken.emit(id, run_state.stack_count(id))
    EventBus.coins_changed.emit(run_state.coins)
    _apply_run_state_to_player()

    EventBus.console_line.emit("[商店] %s（剩余内力 %d）" % [reason, run_state.coins])
    if _shop_panel != null and _shop_panel.is_active():
        _shop_panel.refresh(_shop_items, run_state.coins, reason)
    return true


## 关闭商店。面板"离开"、调试台 leave、玩家死亡时都走这里。
##
## 商店没开着时直接返回：否则重复调用会多发一次 shop_closed，
## 把别处（比如下一间房刚打开的商店）正在等的协程提前唤醒。
func close_shop() -> void:
    if not is_shop_open():
        return
    _shop_panel.hide_panel()
    _on_shop_closed()


## 商店是不是正开着。自动测试用它当"商店已弹出"的判据 ——
## 不要用 stock_count()：关掉之后货架数据还在（就是为了让调试台还能念一遍），
## 拿它判断会导致"商店早就关了还以为是开着的"。
func is_shop_open() -> bool:
    return _shop_panel != null and _shop_panel.is_active()


func _on_shop_closed() -> void:
    # 只有商店开着的时候才该解锁输入。否则"关一次商店"会把别处锁的输入也解开。
    if _shop_panel != null and GameConfig.input_locked:
        GameConfig.input_locked = false
    shop_closed.emit()


## 当前货架的文字描述，给调试台和日志用。
func describe_stock() -> String:
    var parts := PackedStringArray()
    for i in range(_shop_items.size()):
        var item: Dictionary = _shop_items[i]
        var def: Dictionary = item.get("def", {})
        parts.append("%d) %s %d 内力%s" % [
            i + 1,
            str(def.get("display_name", "?")),
            int(item.get("price", 0)),
            "（已售）" if bool(item.get("sold", false)) else "",
        ])
    return "  ".join(parts)


## 当前货架件数。调试台与自动测试用。
func stock_count() -> int:
    return _shop_items.size()


## 货架上第 index 件的价格。自动测试用（断言"扣的钱等于标价"）。
func stock_price(index: int) -> int:
    if index < 0 or index >= _shop_items.size():
        return 0
    var item: Dictionary = _shop_items[index]
    return int(item.get("price", 0))


## 指定房间是否属于"清空给心法"的类型。
## 单独暴露成公开方法，是为了让冒烟测试能直接断言规则本身，
## 而不必真的花几分钟把某间房打完才验证"这间房该不该给奖励"。
func should_offer_reward_for_room(index: int) -> bool:
    if upgrade_pool.size() <= 0:
        return false
    if index < 0 or index >= rooms.size():
        return false
    var room: Dictionary = rooms[index]
    return REWARD_ROOM_TYPES.has(str(room.get("type_name", "")))


## 回春类心法：清房后回血。
func _apply_room_heal() -> void:
    var amount := run_state.room_heal()
    if amount <= 0:
        return
    if player == null or not is_instance_valid(player) or player.hurtbox.is_dead():
        return
    var healed := player.heal(amount)
    if healed > 0:
        EventBus.console_line.emit("[心法] 回春：回复 %d 点生命" % healed)


## 弹出三选一，并一直等到玩家做出选择。
##
## 这里有一个容易踩的时序坑：如果监听 upgrade_offered 的一方（自动测试）在信号里
## 同步调用了 choose_upgrade()，那么等本函数执行到 await 时，信号已经发过了 ——
## await 会永远等下去，整局卡死。
## 所以 emit 之后必须再检查一次 _pending_choices 是否已经被清空。
func _offer_reward() -> void:
    if not _present_reward():
        return
    if _pending_choices.is_empty():
        return
    await reward_resolved


## 抽取并显示三选一，但不等待结果。
## @return 是否真的弹出了选项（心法全叠满时返回 false）
func _present_reward() -> bool:
    if rooms.is_empty():
        return false
    _pending_choices = upgrade_pool.roll(
        GameConfig.run_seed,
        current_room_index,
        run_state,
        GameConfig.REWARD_CHOICE_COUNT
    )
    if _pending_choices.is_empty():
        EventBus.console_line.emit("[奖励] 心法全部叠满，本间房无奖励")
        return false

    GameConfig.input_locked = true

    var room_name := str(rooms[current_room_index].get("display_name", "房间"))
    if _reward_panel != null:
        _reward_panel.show_choices(_pending_choices, "第 %d 间 · %s" % [
            current_room_index + 1, room_name
        ])

    EventBus.upgrade_offered.emit(_pending_choices)
    EventBus.console_line.emit("[奖励] 三选一：%s" % _describe_choices())
    return true


## 当前有几条待选奖励。调试台与自动测试用。
func pending_choice_count() -> int:
    return _pending_choices.size()


func _describe_choices() -> String:
    var parts: PackedStringArray = PackedStringArray()
    for i in range(_pending_choices.size()):
        var def: Dictionary = _pending_choices[i]
        parts.append("%d) %s" % [i + 1, str(def.get("display_name", "?"))])
    return "  ".join(parts)


## 玩家选定了第 index 条（0 起）。越界或没有待选项时返回 false。
## 这是唯一能"结算奖励"的入口：面板、调试台 pick 命令、自动测试都走它。
func choose_upgrade(index: int) -> bool:
    if _pending_choices.is_empty():
        return false
    if index < 0 or index >= _pending_choices.size():
        return false

    var def: Dictionary = _pending_choices[index]
    var id := str(def.get("id", ""))
    var display_name := str(def.get("display_name", id))

    if run_state.take_upgrade(def):
        EventBus.upgrade_taken.emit(id, run_state.stack_count(id))
        EventBus.console_line.emit("[奖励] 获得「%s」（%d 层）" % [
            display_name, run_state.stack_count(id)
        ])
    else:
        EventBus.console_line.emit("[奖励] 「%s」已叠满，本次奖励作废" % display_name)

    _pending_choices = []
    GameConfig.input_locked = false
    if _reward_panel != null:
        _reward_panel.hide_panel()

    _apply_run_state_to_player()
    reward_resolved.emit(index)
    return true


## 把当前成长应用到"活着的这个玩家"身上。
## 换房间时由 _load_room 处理，这里只处理"同一间房里属性变了"（选完奖励）。
func _apply_run_state_to_player() -> void:
    if player == null or not is_instance_valid(player):
        return
    player.apply_run_state(run_state, player.hurtbox.hp, player.hurtbox.max_hp)


func _on_reward_chosen(index: int) -> void:
    # 面板自己也连着这个信号。choose_upgrade 里已经做了空值保护，
    # 所以调试台先选掉、面板再发一次信号时不会重复结算。
    choose_upgrade(index)


func _on_enemy_defeated(_world_pos: Vector2, coins: int) -> void:
    var gained := run_state.register_kill(coins)
    if gained > 0:
        EventBus.coins_changed.emit(run_state.coins)


## 是否正处于"清房 → 奖励 → 换房"的过渡中。调试台和自动测试用。
func is_advancing() -> bool:
    return _advancing


## 调试 / 自动测试用：跳过打怪，直接把当前房间标记为清空。
## 走的是正式信号 room_cleared，所以奖励、换房、血量继承全部按真实流程执行 ——
## 这正是它存在的意义：不测这条路径，就只能在"清完一间房"时才暴露死锁。
func debug_clear_current_room() -> void:
    if rooms.is_empty():
        return
    EventBus.room_cleared.emit(str(rooms[current_room_index].get("id", "debug_room")))


func _on_player_died() -> void:
    if _run_over:
        return
    _run_over = true
    recorder.stop()
    # 死亡时三选一可能正开着。不收掉面板的话，玩家会卡在"看着奖励面板慢慢死"。
    # 清空之后补发一次 reward_resolved，让还在 await 的协程醒来自行退出，
    # 否则每死一次就泄漏一个永远挂起的协程。
    if not _pending_choices.is_empty():
        _pending_choices = []
        GameConfig.input_locked = false
        if _reward_panel != null:
            _reward_panel.hide_panel()
        reward_resolved.emit(-1)

    # 商店可能也开着。不关的话，玩家会盯着货架慢慢死。
    if _shop_panel != null and _shop_panel.is_active():
        close_shop()

    EventBus.console_line.emit("[死亡] 本局结束。种子 %d。输入 restart 重开" % GameConfig.run_seed)
    _save_replay("death_%d" % GameConfig.run_seed)


func _on_restart_requested(new_seed: int) -> void:
    var target_seed := new_seed
    if target_seed == 0:
        target_seed = int(Time.get_unix_time_from_system()) & 0x7FFFFFFF
    start_run(target_seed)


# ============================== 给 HUD 用 ==============================

func hud_summary() -> String:
    if rooms.is_empty():
        return "（尚未开局）"
    var room: Dictionary = rooms[current_room_index]
    return "房间 %d/%d  %s  剩余敌人 %d\n内力 %d   击杀 %d   伤害 ×%.2f   移速 ×%.2f\n心法：%s" % [
        current_room_index + 1,
        rooms.size(),
        room.get("display_name", "?"),
        int(arena.living_enemy_count()),
        run_state.coins,
        run_state.kills,
        run_state.damage_multiplier(),
        run_state.move_speed_multiplier(),
        _owned_upgrade_text(),
    ]


## 已获得的心法，给 HUD 显示用。
##
## 为什么不直接用 RunState.describe_upgrades()：
##   RunState 是纯逻辑类，只认 id，不认识"财运亨通"这种显示名 —— 它连数据表都不该读。
##   所以 id → 显示名的翻译必须留在 main（它手里同时有 run_state 和 upgrade_pool）。
##   之前 HUD 直接打了 describe_upgrades()，玩家看到的是 `lucky_coin×1`。
func _owned_upgrade_text() -> String:
    var ids: Array[String] = run_state.taken_ids()
    if ids.is_empty():
        return "尚无"

    var parts := PackedStringArray()
    for id in ids:
        var def: Dictionary = upgrade_pool.get_upgrade(id)
        # 数据表加载失败时 def 是空的，退回显示 id —— 宁可难看也别显示空白
        var label := str(def.get("display_name", id))
        if label.is_empty():
            label = id
        parts.append("%s×%d" % [label, run_state.stack_count(id)])
    return "  ".join(parts)


# ============================== 重放 ==============================

func _ensure_replay_dir() -> void:
    DirAccess.make_dir_recursive_absolute(REPLAY_DIR)


func _save_replay(file_name: String) -> String:
    if recorder.frame_count() <= 0:
        EventBus.console_line.emit("[重放] 没有可保存的记录")
        return ""

    var path := "%s/%s.json" % [REPLAY_DIR, file_name]
    var err := recorder.save_to_file(path)
    if err != OK:
        EventBus.console_line.emit("[重放] 保存失败，错误码 %d" % err)
        return ""

    last_replay_path = path
    EventBus.console_line.emit("[重放] 已保存 %d 帧 → %s" % [recorder.frame_count(), path])
    EventBus.console_line.emit("       把它交给队友或 AI，就能精确复现这一局")
    return path


func _list_replays() -> PackedStringArray:
    var result: PackedStringArray = PackedStringArray()
    var dir := DirAccess.open(REPLAY_DIR)
    if dir == null:
        return result
    dir.list_dir_begin()
    var file_name := dir.get_next()
    while file_name != "":
        if not dir.current_is_dir() and file_name.ends_with(".json"):
            result.append(file_name)
        file_name = dir.get_next()
    dir.list_dir_end()
    result.sort()
    return result


func _start_replay(rec: ReplayRecorder) -> void:
    if rec == null or rec.frame_count() <= 0:
        EventBus.console_line.emit("[重放] 记录为空，无法播放")
        return

    start_run(rec.seed_value, false)
    if player != null:
        player.replay_source = rec
        rec.begin_playback()
    EventBus.console_line.emit("[重放] 开始播放：种子 %d，共 %d 帧" % [rec.seed_value, rec.frame_count()])


# ============================== 调试命令 ==============================

func _register_console_commands() -> void:
    EventBus.register_console_command("seed", "<整数>", "用指定种子重开一局", _cmd_seed)
    EventBus.register_console_command("restart", "", "换一个新种子重开一局", _cmd_restart)
    EventBus.register_console_command("rooms", "", "打印本层的房间路线", _cmd_rooms)
    EventBus.register_console_command("next", "", "跳过当前房间，直接进入下一间", _cmd_next)
    EventBus.register_console_command("check", "", "校验帧数据表和房间路线是否合法", _cmd_check)
    EventBus.register_console_command("attacks", "", "列出所有招式及其总帧数", _cmd_attacks)
    EventBus.register_console_command("data", "<招式id>", "打印某招的完整帧数据", _cmd_data)
    EventBus.register_console_command("dump", "", "导出当前局面快照（JSON）", _cmd_dump)
    EventBus.register_console_command("save", "[文件名]", "保存本次输入记录，用于复现 bug", _cmd_save)
    EventBus.register_console_command("replays", "", "列出已保存的输入记录", _cmd_replays)
    EventBus.register_console_command("replay", "<文件名>", "播放一条已保存的输入记录", _cmd_replay)
    EventBus.register_console_command("buffs", "", "查看本局心法与属性加成", _cmd_buffs)
    EventBus.register_console_command("give", "<心法id>", "直接获得一条心法（调试用）", _cmd_give)
    EventBus.register_console_command("pick", "<1~3>", "选择当前的三选一奖励", _cmd_pick)
    EventBus.register_console_command("reward", "", "立刻弹出一次三选一（调试用）", _cmd_reward)
    EventBus.register_console_command("spawn", "<原型id> [距离]", "在身前单独刷一只敌人（不计入清房）", _cmd_spawn)
    EventBus.register_console_command("shop", "", "立刻开一次商店（调试用）", _cmd_shop)
    EventBus.register_console_command("buy", "<1~3>", "买下货架上的第 n 件", _cmd_buy)
    EventBus.register_console_command("leave", "", "离开商店", _cmd_leave)
    EventBus.register_console_command("quit", "", "退出游戏", _cmd_quit)


func _cmd_seed(args: PackedStringArray) -> String:
    if args.is_empty():
        return "用法：seed <整数>。当前种子 %d" % GameConfig.run_seed
    var value := int(args[0])
    start_run(value)
    return "已用种子 %d 重开" % value


func _cmd_restart(_args: PackedStringArray) -> String:
    start_run(0)
    return "已用新种子 %d 重开" % GameConfig.run_seed


func _cmd_rooms(_args: PackedStringArray) -> String:
    if rooms.is_empty():
        return "（尚未生成路线）"
    var lines: PackedStringArray = PackedStringArray()
    lines.append("本层路线（种子 %d）：" % GameConfig.run_seed)
    for i in range(rooms.size()):
        var room: Dictionary = rooms[i]
        var marker := "◀ 当前" if i == current_room_index else ""
        lines.append("  %d. %-6s 敌人预算 %d  %s" % [
            i + 1, room["type_name"], room["enemy_budget"], marker
        ])
    return "\n".join(lines)


func _cmd_next(_args: PackedStringArray) -> String:
    # 待选奖励没结算就走人，会留下一个"面板还在、输入被锁"的僵局。
    if not _pending_choices.is_empty():
        return "先选完心法（按 1/2/3，或输入 pick <序号>）"
    if current_room_index + 1 >= rooms.size():
        return "已经是最后一间了"
    _load_room(current_room_index + 1)
    return "已进入第 %d 间" % (current_room_index + 1)


func _cmd_check(_args: PackedStringArray) -> String:
    var lines: PackedStringArray = PackedStringArray()

    lines.append("帧数据表：%d 个招式" % attack_table.size())
    var broken := attack_table.find_broken_cancel_targets()
    if broken.is_empty():
        lines.append("  连段引用：全部有效")
    else:
        for problem in broken:
            lines.append("  ✗ " + problem)

    for attack_id in attack_table.ids():
        var def := attack_table.get_attack(attack_id)
        if def == null:
            continue
        var problem := AttackTable.validate(def)
        if not problem.is_empty():
            lines.append("  ✗ " + problem)

    var route_problems := RoomGenerator.validate(rooms)
    if route_problems.is_empty():
        lines.append("房间路线：合法（%d 间）" % rooms.size())
    else:
        for problem in route_problems:
            lines.append("  ✗ " + problem)

    var data_problems: PackedStringArray = arena.validate_data()
    if data_problems.is_empty():
        lines.append("房间模板 × 敌人表：自洽")
    else:
        for problem in data_problems:
            lines.append("  ✗ " + problem)

    return "\n".join(lines)


func _cmd_attacks(_args: PackedStringArray) -> String:
    var lines: PackedStringArray = PackedStringArray()
    lines.append("招式一览（起手/判定/收招 = 总帧数）：")
    for attack_id in attack_table.ids():
        var def := attack_table.get_attack(attack_id)
        if def == null:
            continue
        var cancel_text := "不可取消"
        if def.cancel_from >= 0:
            cancel_text = "第 %d 帧起可接 %s" % [def.cancel_from, ", ".join(Array(def.cancel_into))]
        lines.append("  %-14s %d/%d/%d = %d 帧  %s" % [
            def.id, def.startup, def.active, def.recovery, def.total_frames, cancel_text
        ])
    return "\n".join(lines)


func _cmd_data(args: PackedStringArray) -> String:
    if args.is_empty():
        return "用法：data <招式id>"
    if not attack_table.has_attack(args[0]):
        return "找不到招式「%s」" % args[0]
    return JSON.stringify(attack_table.get_attack(args[0]).to_dict(), "  ")


func _cmd_dump(_args: PackedStringArray) -> String:
    var snapshot := {
        "seed": GameConfig.run_seed,
        "room_index": current_room_index,
        "room": rooms[current_room_index] if current_room_index < rooms.size() else {},
        "time_scale": Engine.time_scale,
    }

    if player != null and is_instance_valid(player):
        snapshot["player"] = {
            "position": [player.global_position.x, player.global_position.y],
            "velocity": [player.velocity.x, player.velocity.y],
            "state": player.fsm.state_name(),
            "state_frame": player.fsm.state_frame,
            "facing": player.fsm.facing,
            "combo_index": player.fsm.combo_index,
            "current_attack": player.fsm.current_attack.id if player.fsm.current_attack != null else "",
            "hurtbox": player.hurtbox.snapshot(),
        }

    snapshot["enemies"] = arena.enemy_snapshots()
    snapshot["run_state"] = run_state.snapshot()
    return JSON.stringify(snapshot, "  ")


func _cmd_save(args: PackedStringArray) -> String:
    var file_name := "manual_%d" % GameConfig.run_seed
    if not args.is_empty():
        file_name = args[0]
    var path := _save_replay(file_name)
    if path.is_empty():
        return "保存失败"
    return "已保存到 %s" % path


func _cmd_replays(_args: PackedStringArray) -> String:
    var files := _list_replays()
    if files.is_empty():
        return "还没有任何记录。用 save 保存当前这一局"
    var lines: PackedStringArray = PackedStringArray()
    lines.append("已保存的记录（%d 条）：" % files.size())
    for file_name in files:
        lines.append("  " + file_name)
    lines.append("用 replay <文件名> 播放")
    return "\n".join(lines)


func _cmd_replay(args: PackedStringArray) -> String:
    if args.is_empty():
        return "用法：replay <文件名>。用 replays 查看有哪些"
    var file_name := args[0]
    if not file_name.ends_with(".json"):
        file_name += ".json"
    var rec := ReplayRecorder.load_from_file("%s/%s" % [REPLAY_DIR, file_name])
    if rec == null:
        return "无法读取 %s" % file_name
    _start_replay(rec)
    return "正在播放 %s" % file_name


func _cmd_buffs(_args: PackedStringArray) -> String:
    var lines: PackedStringArray = PackedStringArray()
    lines.append("内力 %d   击杀 %d   清空房间 %d" % [
        run_state.coins, run_state.kills, run_state.rooms_cleared
    ])
    lines.append("心法：%s" % run_state.describe_upgrades())
    lines.append("伤害 ×%.2f   移速 ×%.2f   吸血 %.0f%%   内力 ×%.2f   清房回血 %d" % [
        run_state.damage_multiplier(),
        run_state.move_speed_multiplier(),
        run_state.lifesteal() * 100.0,
        run_state.coin_multiplier(),
        run_state.room_heal(),
    ])
    lines.append("生命上限 %d（基础 %d + 心法 %d）" % [
        GameConfig.PLAYER_BASE_MAX_HP + run_state.max_hp_bonus(),
        GameConfig.PLAYER_BASE_MAX_HP,
        run_state.max_hp_bonus(),
    ])
    lines.append("冲刺冷却 %d 帧（基础 %d，心法 -%d，下限 %d）" % [
        maxi(GameConfig.MIN_DASH_COOLDOWN_FRAMES, Player.DASH_COOLDOWN_FRAMES - run_state.dash_cooldown_reduction()),
        Player.DASH_COOLDOWN_FRAMES,
        run_state.dash_cooldown_reduction(),
        GameConfig.MIN_DASH_COOLDOWN_FRAMES,
    ])
    return "\n".join(lines)


func _cmd_give(args: PackedStringArray) -> String:
    if args.is_empty():
        return "用法：give <心法id>。可用：%s" % ", ".join(Array(upgrade_pool.ids()))
    var id := args[0]
    if not upgrade_pool.has_upgrade(id):
        return "找不到心法「%s」。可用：%s" % [id, ", ".join(Array(upgrade_pool.ids()))]

    var def := upgrade_pool.get_upgrade(id)
    var display_name := str(def.get("display_name", id))
    if not run_state.take_upgrade(def):
        return "「%s」已叠满（%d / %d 层）" % [
            display_name, run_state.stack_count(id), int(def.get("max_stacks", 1))
        ]

    EventBus.upgrade_taken.emit(id, run_state.stack_count(id))
    _apply_run_state_to_player()
    return "获得「%s」，当前 %d 层" % [display_name, run_state.stack_count(id)]


## 调试用：立刻开一次商店，不用真的走到商店房。
func _cmd_shop(_args: PackedStringArray) -> String:
    if not open_shop_now():
        return "没有可卖的心法（可能都叠满了）"
    return "上架 %d 件：%s" % [_shop_items.size(), describe_stock()]


## 买货架上第 n 件（1 起，和玩家按的数字键一致）。
func _cmd_buy(args: PackedStringArray) -> String:
    if _shop_items.is_empty():
        return "商店没开。先用 shop 打开"
    if args.is_empty():
        return "用法：buy <1~%d>。当前货架：%s" % [_shop_items.size(), describe_stock()]

    var index := int(args[0]) - 1
    if not buy_shop_item(index):
        # 具体原因（内力不足 / 已售出）已经由 buy_shop_item 打到控制台了
        return "没买成，看上一行的原因。当前货架：%s" % describe_stock()
    return "已买下，剩余内力 %d。货架：%s" % [run_state.coins, describe_stock()]


## 离开商店。
func _cmd_leave(_args: PackedStringArray) -> String:
    if _shop_panel == null or not _shop_panel.is_active():
        return "商店没开"
    close_shop()
    return "已离开商店"


## 调试用：在玩家身前单独刷一只敌人。
## 练打击感（召一只打不死的木桩随便砍）、或者复现"某个敌人打不到"时用它。
func _cmd_spawn(args: PackedStringArray) -> String:
    var ids: PackedStringArray = arena.enemy_archetype_ids()
    if args.is_empty():
        return "用法：spawn <原型id> [距离]。可用：%s" % ", ".join(Array(ids))

    var id := args[0]
    if not ids.has(id):
        return "找不到敌人原型「%s」。可用：%s" % [id, ", ".join(Array(ids))]

    var offset := 90.0
    if args.size() >= 2:
        offset = float(args[1])

    var facing := 1
    if player != null and is_instance_valid(player):
        facing = player.fsm.facing
    var x := (player.position.x if player != null and is_instance_valid(player) else 0.0) + offset * float(facing)

    var enemy: Enemy = arena.spawn_debug_enemy(id, x)
    if enemy == null:
        return "刷怪失败：原型「%s」数据为空" % id
    return "已刷出「%s」于 x=%.0f（不计入清房判定，可用 god 或直接砍）" % [id, x]


func _cmd_pick(args: PackedStringArray) -> String:
    if _pending_choices.is_empty():
        return "现在没有待选的奖励"
    var options_text := _describe_choices()
    if args.is_empty():
        return "用法：pick <1~%d>。当前选项：%s" % [_pending_choices.size(), options_text]

    var index := int(args[0]) - 1
    if not choose_upgrade(index):
        return "序号越界，应为 1~%d。当前选项：%s" % [_pending_choices.size(), options_text]
    return "已选择第 %d 项" % (index + 1)


## 强制弹出一次三选一。调试和自动测试用 ——
## 否则想验证奖励面板，得先手动清掉一整间战斗房。
func _cmd_reward(_args: PackedStringArray) -> String:
    if not _pending_choices.is_empty():
        return "已有待选奖励：%s" % _describe_choices()
    if not _present_reward():
        return "没有可给的心法（可能已全部叠满）"
    # 自动测试会在 upgrade_offered 信号里同步选掉，所以这里要重新读一次状态。
    if _pending_choices.is_empty():
        return "三选一已弹出并结算"
    return "三选一：%s  用 pick <序号> 选择" % _describe_choices()


func _cmd_quit(_args: PackedStringArray) -> String:
    get_tree().quit()
    return ""
