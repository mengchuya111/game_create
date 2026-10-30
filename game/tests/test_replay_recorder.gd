extends TestCase
## 测试 ReplayRecorder —— 种子化输入重放。
##
## 这是"把 bug 交给队友 / AI 复现"的唯一可靠手段。
## 如果录制和回放对不上，那所有"我这边复现不了"的问题就永远修不掉。


func _make_frame_pattern(count: int, rng: DeterministicRng) -> Array:
    var frames: Array = []
    for i in range(count):
        var frame := PlayerInputFrame.new()
        frame.left = rng.chance(0.3)
        frame.right = rng.chance(0.3)
        frame.jump_pressed = rng.chance(0.2)
        frame.jump_held = rng.chance(0.4)
        frame.attack_pressed = rng.chance(0.3)
        frame.attack_held = rng.chance(0.5)
        frame.dash_pressed = rng.chance(0.1)
        frames.append(frame)
    return frames


# ============================== 录制与回放 ==============================

func test_not_recording_by_default() -> void:
    var recorder := ReplayRecorder.new()
    assert_false(recorder.is_recording(), "刚创建时不应当处于录制状态")


func test_record_is_ignored_without_start() -> void:
    var recorder := ReplayRecorder.new()
    recorder.record(PlayerInputFrame.new())
    assert_eq(recorder.frame_count(), 0, "没有调用 start() 时不应该记录任何帧")


func test_stop_halts_recording() -> void:
    var recorder := ReplayRecorder.new()
    recorder.start(1)
    recorder.record(PlayerInputFrame.new())
    recorder.stop()
    recorder.record(PlayerInputFrame.new())
    assert_eq(recorder.frame_count(), 1, "stop() 之后不应该继续记录")


func test_record_and_playback_are_identical() -> void:
    var recorder := ReplayRecorder.new()
    recorder.start(12345)

    var rng := DeterministicRng.new(1)
    var recorded := _make_frame_pattern(120, rng)
    for frame in recorded:
        recorder.record(frame)

    assert_eq(recorder.frame_count(), 120, "应当记录 120 帧")

    recorder.begin_playback()
    var mismatched_at := -1
    for i in range(120):
        var played := recorder.next_frame()
        if played == null or not played.equals(recorded[i]):
            mismatched_at = i
            break

    assert_eq(mismatched_at, -1, "回放的每一帧都必须和录制时完全一致")
    assert_true(recorder.is_playback_finished(), "播完 120 帧后应当标记为结束")


func test_playback_returns_null_after_end() -> void:
    var recorder := ReplayRecorder.new()
    recorder.start(1)
    recorder.record(PlayerInputFrame.new())
    recorder.begin_playback()
    recorder.next_frame()
    assert_eq(recorder.next_frame(), null, "播放结束后再取帧应当返回 null")


func test_empty_replay_playback_is_safe() -> void:
    var recorder := ReplayRecorder.new()
    recorder.begin_playback()
    assert_eq(recorder.next_frame(), null, "空记录播放应当安全返回 null，而不是崩溃")
    assert_true(recorder.is_playback_finished(), "空记录应当直接视为播放结束")


func test_begin_playback_rewinds() -> void:
    var recorder := ReplayRecorder.new()
    recorder.start(1)
    for i in range(5):
        recorder.record(PlayerInputFrame.new())
    recorder.begin_playback()
    recorder.next_frame()
    recorder.next_frame()
    assert_eq(recorder.playback_index(), 2, "播放游标应当在第 2 帧")

    recorder.begin_playback()
    assert_eq(recorder.playback_index(), 0, "begin_playback 应当把游标倒回开头")


func test_start_resets_previous_recording() -> void:
    var recorder := ReplayRecorder.new()
    recorder.start(1)
    for i in range(10):
        recorder.record(PlayerInputFrame.new())

    recorder.start(2)
    assert_eq(recorder.frame_count(), 0, "重新 start() 应当清空上一次的记录")
    assert_eq(recorder.seed_value, 2, "种子应当被更新")


# ============================== 序列化 ==============================

func test_encode_decode_roundtrip() -> void:
    var recorder := ReplayRecorder.new()
    recorder.start(777, "三段连招打空")

    var rng := DeterministicRng.new(9)
    for frame in _make_frame_pattern(60, rng):
        recorder.record(frame)

    var text := recorder.encode()
    var restored := ReplayRecorder.decode(text)
    require(restored != null, "编码后的文本必须能被解码回来")
    if restored == null:
        return

    assert_eq(restored.seed_value, 777, "种子应当被保留")
    assert_eq(restored.note, "三段连招打空", "备注应当被保留")
    assert_eq(restored.frame_count(), 60, "帧数应当被保留")
    assert_eq(restored.frames, recorder.frames, "帧数据必须完全一致")


func test_decoded_replay_plays_back_identically() -> void:
    var recorder := ReplayRecorder.new()
    recorder.start(2024)

    var rng := DeterministicRng.new(3)
    var original := _make_frame_pattern(40, rng)
    for frame in original:
        recorder.record(frame)

    var restored := ReplayRecorder.decode(recorder.encode())
    require(restored != null, "解码应当成功")
    if restored == null:
        return

    restored.begin_playback()
    var mismatched_at := -1
    for i in range(40):
        var played := restored.next_frame()
        if played == null or not played.equals(original[i]):
            mismatched_at = i
            break
    assert_eq(mismatched_at, -1, "解码后的记录回放结果必须和原始记录一致")


func test_decode_rejects_wrong_version() -> void:
    var text := JSON.stringify({"version": 999, "seed": 1, "frames": [1, 2, 3]})
    assert_eq(ReplayRecorder.decode(text), null, "版本不匹配时应当拒绝解码，而不是带着错数据继续跑")


func test_decode_rejects_bad_json() -> void:
    assert_eq(ReplayRecorder.decode("这不是 JSON"), null, "非法 JSON 应当返回 null")
    assert_eq(ReplayRecorder.decode(""), null, "空文本应当返回 null")
    assert_eq(ReplayRecorder.decode("   "), null, "只有空白的文本应当返回 null")


func test_decode_rejects_non_array_frames() -> void:
    var text := JSON.stringify({"version": 1, "seed": 1, "frames": "oops"})
    assert_eq(ReplayRecorder.decode(text), null, "frames 不是数组时应当拒绝")


func test_decode_rejects_json_array_root() -> void:
    var text := JSON.stringify([1, 2, 3])
    assert_eq(ReplayRecorder.decode(text), null, "根节点不是对象时应当拒绝")


# ============================== 文件读写 ==============================

func test_save_and_load_file() -> void:
    var recorder := ReplayRecorder.new()
    recorder.start(4242, "文件往返测试")
    var rng := DeterministicRng.new(5)
    for frame in _make_frame_pattern(25, rng):
        recorder.record(frame)

    var path := "user://test_replay_roundtrip.json"
    var err := recorder.save_to_file(path)
    assert_eq(err, OK, "保存重放文件应当成功")

    var loaded := ReplayRecorder.load_from_file(path)
    require(loaded != null, "应当能读回刚保存的文件")
    if loaded != null:
        assert_eq(loaded.seed_value, 4242, "读回后种子应当一致")
        assert_eq(loaded.note, "文件往返测试", "读回后备注应当一致")
        assert_eq(loaded.frame_count(), 25, "读回后帧数应当一致")
        assert_eq(loaded.frames, recorder.frames, "读回后帧数据应当一致")

    DirAccess.remove_absolute(path)


func test_load_missing_file_returns_null() -> void:
    assert_eq(
        ReplayRecorder.load_from_file("user://这个文件不存在_12345.json"),
        null,
        "文件不存在时应当返回 null，而不是崩溃"
    )


# ============================== 输入帧位掩码 ==============================

func test_input_mask_roundtrip_all_fields() -> void:
    var original := PlayerInputFrame.new()
    original.left = true
    original.jump_pressed = true
    original.jump_held = true
    original.attack_held = true
    original.dash_pressed = true

    var restored := PlayerInputFrame.from_mask(original.to_mask())
    assert_true(restored.equals(original), "输入帧经过位掩码往返后应当完全一致")


func test_input_mask_roundtrip_empty() -> void:
    var original := PlayerInputFrame.new()
    var restored := PlayerInputFrame.from_mask(original.to_mask())
    assert_eq(original.to_mask(), 0, "没有任何输入时掩码应当是 0")
    assert_true(restored.equals(original), "空输入帧往返后应当仍然为空")


func test_input_mask_distinguishes_fields() -> void:
    var masks: Dictionary = {}
    var fields := ["left", "right", "jump_pressed", "jump_held", "attack_pressed", "attack_held", "dash_pressed"]
    for field in fields:
        var frame := PlayerInputFrame.new()
        frame.set(field, true)
        masks[frame.to_mask()] = field

    assert_eq(masks.size(), fields.size(), "7 个输入字段应当产生 7 个互不相同的掩码位")


func test_input_frame_dict_roundtrip() -> void:
    var original := PlayerInputFrame.new()
    original.left = true
    original.attack_pressed = true
    original.jump_held = true

    var restored := PlayerInputFrame.from_dict(original.to_dict())
    assert_true(restored.equals(original), "输入帧经过字典往返后应当完全一致")


func test_input_frame_move_axis() -> void:
    var frame := PlayerInputFrame.new()
    assert_eq(frame.move_axis(), 0, "没有方向输入时轴应当是 0")

    frame.left = true
    assert_eq(frame.move_axis(), -1, "按左应当是 -1")

    frame.left = false
    frame.right = true
    assert_eq(frame.move_axis(), 1, "按右应当是 1")

    frame.left = true
    assert_eq(frame.move_axis(), 0, "同时按左右应当视为无输入")
