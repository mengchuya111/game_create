extends TestCase
## 测试 Hitstop / ScreenShake —— 打击感三件套里的两件。
##
## 这两样东西的特点是"人眼一测就知道不对，但说不清哪里不对"。
## 所以用测试把它们的数值边界钉死，剩下的才交给手感去调。


# ============================== 顿帧 ==============================

func test_new_hitstop_is_inactive() -> void:
    var hitstop := Hitstop.new(0.05, 12)
    assert_false(hitstop.is_active(), "刚创建的顿帧控制器应当是未激活的")
    assert_eq(hitstop.remaining_frames(), 0, "初始剩余帧数应当是 0")


func test_request_activates_hitstop() -> void:
    var hitstop := Hitstop.new(0.05, 12)
    hitstop.request(4)
    assert_true(hitstop.is_active(), "请求之后应当处于顿帧状态")
    assert_eq(hitstop.remaining_frames(), 4, "剩余帧数应当等于请求的帧数")


func test_request_zero_is_ignored() -> void:
    var hitstop := Hitstop.new(0.05, 12)
    hitstop.request(0)
    assert_false(hitstop.is_active(), "请求 0 帧不应当触发顿帧")
    hitstop.request(-5)
    assert_false(hitstop.is_active(), "负数请求不应当触发顿帧")


func test_request_is_clamped_to_max_frames() -> void:
    var hitstop := Hitstop.new(0.05, 8)
    hitstop.request(999)
    assert_eq(hitstop.requested_frames(), 8, "顿帧帧数必须被裁剪到上限，否则数据配错会让游戏看起来卡死")
    assert_eq(hitstop.remaining_frames(), 8, "实际剩余帧数也应当是上限值")


func test_request_takes_longest_not_sum() -> void:
    var hitstop := Hitstop.new(0.05, 20)
    hitstop.request(4)
    hitstop.request(6)
    assert_eq(hitstop.requested_frames(), 6, "连续命中应当取更长的那个，而不是叠加（叠加会让连招节奏崩掉）")


func test_shorter_request_does_not_shorten_active_hitstop() -> void:
    var hitstop := Hitstop.new(0.05, 20)
    hitstop.request(8)
    hitstop.request(2)
    assert_eq(hitstop.remaining_frames(), 8, "更短的顿帧请求不应该缩短正在进行的长顿帧")


func test_tick_counts_down_and_finishes() -> void:
    var hitstop := Hitstop.new(0.05, 20)
    hitstop.request(6)   # 6 帧 = 0.1 秒

    assert_true(hitstop.is_active(), "刚请求完应当是激活状态")
    assert_true(hitstop.tick(0.05), "过了一半时间应当仍在顿帧")
    assert_false(hitstop.tick(0.05), "时间用完之后应当结束")
    assert_false(hitstop.is_active(), "结束之后 is_active 应当为 false")


func test_tick_returns_false_when_not_active() -> void:
    var hitstop := Hitstop.new(0.05, 12)
    assert_false(hitstop.tick(1.0), "没有顿帧时 tick 应当直接返回 false")


func test_oversized_tick_ends_hitstop() -> void:
    var hitstop := Hitstop.new(0.05, 20)
    hitstop.request(3)
    assert_false(hitstop.tick(10.0), "一次超长的时间推进也应当正常结束顿帧，而不是留下负值")


func test_cancel_stops_immediately() -> void:
    var hitstop := Hitstop.new(0.05, 20)
    hitstop.request(10)
    hitstop.cancel()
    assert_false(hitstop.is_active(), "cancel 之后应当立刻结束顿帧（玩家死亡、切场景要用）")
    assert_eq(hitstop.requested_frames(), 0, "cancel 之后请求帧数应当清零")


func test_remaining_frames_rounds_up() -> void:
    var hitstop := Hitstop.new(0.05, 20)
    hitstop.request(4)
    hitstop.tick(0.01)   # 消耗 0.6 帧
    assert_eq(hitstop.remaining_frames(), 4, "剩余 3.4 帧应当向上取整显示为 4")


# ============================== 屏幕震动 ==============================

func test_new_shake_is_inactive() -> void:
    var shake := ScreenShake.new()
    assert_false(shake.is_active(), "刚创建的震动应当是未激活的")
    assert_eq(shake.current_offset(), Vector2.ZERO, "没有震动时相机偏移必须是零向量")


func test_add_activates_shake() -> void:
    var shake := ScreenShake.new()
    shake.add(0.5)
    assert_true(shake.is_active(), "追加能量之后应当处于震动状态")
    assert_almost_eq(shake.trauma, 0.5, 0.0001, "创伤值应当等于追加量")


func test_add_clamps_to_one() -> void:
    var shake := ScreenShake.new()
    shake.add(0.7)
    shake.add(0.7)
    assert_almost_eq(shake.trauma, 1.0, 0.0001, "创伤值必须被裁剪到 1.0，否则屏幕会抖出画面")


func test_negative_add_is_ignored() -> void:
    var shake := ScreenShake.new()
    shake.add(0.5)
    shake.add(-0.3)
    assert_almost_eq(shake.trauma, 0.5, 0.0001, "负数追加不应当减少创伤值")


func test_shake_decays_to_zero() -> void:
    var shake := ScreenShake.new(14.0, 3.2, 34.0)
    shake.add(1.0)

    var steps := 0
    while shake.is_active() and steps < 1000:
        shake.tick(1.0 / 60.0)
        steps += 1

    assert_false(shake.is_active(), "震动应当随时间衰减到 0")
    assert_lt(float(steps), 100.0, "满强度震动的衰减不应当超过 100 帧（实际 %d 帧）" % steps)
    assert_gt(float(steps), 5.0, "震动不应该一帧就消失（实际 %d 帧）" % steps)


func test_offset_stays_within_max() -> void:
    # 衰减设为 0，让创伤值保持在满值，专门测边界
    var shake := ScreenShake.new(14.0, 0.0, 34.0)
    shake.add(1.0)

    var exceeded := ""
    for i in range(600):
        shake.tick(1.0 / 60.0)
        var offset := shake.current_offset()
        if absf(offset.x) > 14.001 or absf(offset.y) > 14.001:
            exceeded = "(%.3f, %.3f)" % [offset.x, offset.y]
            break

    assert_eq(exceeded, "", "相机偏移的绝对值不应该超过 max_offset，否则画面会露出黑边")


func test_offset_changes_over_time() -> void:
    var shake := ScreenShake.new(14.0, 0.0, 34.0)
    shake.add(1.0)

    var first := shake.current_offset()
    for i in range(10):
        shake.tick(1.0 / 60.0)
    var later := shake.current_offset()

    assert_ne(first, later, "震动偏移应当随时间变化，而不是一个固定值（固定值看起来像画面歪了）")


func test_intensity_is_trauma_squared() -> void:
    var shake := ScreenShake.new()
    shake.add(0.5)
    assert_almost_eq(shake.intensity(), 0.25, 0.0001, "强度应当是创伤值的平方（衰减更自然）")


func test_cancel_stops_shake() -> void:
    var shake := ScreenShake.new()
    shake.add(1.0)
    shake.cancel()
    assert_false(shake.is_active(), "cancel 之后应当立刻停止震动")
    assert_eq(shake.current_offset(), Vector2.ZERO, "停止后相机偏移应当归零")


func test_zero_decay_keeps_shaking() -> void:
    var shake := ScreenShake.new(14.0, 0.0, 34.0)
    shake.add(1.0)
    for i in range(100):
        shake.tick(1.0 / 60.0)
    assert_true(shake.is_active(), "衰减为 0 时震动应当一直持续（用于测试和特殊演出）")
