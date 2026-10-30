class_name ReplayRecorder
extends RefCounted
## 输入重放录制器 —— 纯逻辑类，可被单元测试完整覆盖。
##
## 为什么肉鸽游戏必须做重放：
##   一个 bug 出现在"第 47 秒，第 3 个房间，精英怪冲过来的瞬间"。
##   如果只能靠嘴巴描述，AI 和队友都无法复现，这个 bug 就永远修不掉。
##   有了重放，你只需要报一个种子 + 一段输入记录，任何人（包括 AI）
##   都能精确回到出问题的那一帧。
##
## 数据格式（很小：每帧只占一个整数）：
##   {
##     "version": 1,
##     "seed": 123456,
##     "frame_count": 900,
##     "frames": [0, 4, 4, 5, ...]      // 每帧一个位掩码，见 PlayerInputFrame.to_mask()
##   }

const FORMAT_VERSION := 1

## 本局种子。
var seed_value: int = 0
## 每帧的输入位掩码。
var frames: PackedInt32Array = PackedInt32Array()
## 备注，例如 "三段连招打空"。
var note: String = ""

var _recording: bool = false
var _playback_index: int = 0


## 开始录制。
func start(p_seed: int, p_note: String = "") -> void:
    seed_value = p_seed
    frames = PackedInt32Array()
    note = p_note
    _recording = true
    _playback_index = 0


## 停止录制。
func stop() -> void:
    _recording = false


func is_recording() -> bool:
    return _recording


## 记录一帧输入。只在录制中有效。
func record(input: PlayerInputFrame) -> void:
    if not _recording or input == null:
        return
    frames.append(input.to_mask())


## 已录制的帧数。
func frame_count() -> int:
    return frames.size()


## 取第 i 帧的输入。越界返回一个空输入帧。
func get_frame(index: int) -> PlayerInputFrame:
    if index < 0 or index >= frames.size():
        return PlayerInputFrame.new()
    return PlayerInputFrame.from_mask(frames[index])


# ============================== 回放 ==============================

## 开始回放，游标回到第一帧。
func begin_playback() -> void:
    _playback_index = 0


## 取下一帧输入。回放结束时返回 null。
## 调用方应当这样用：
##     var input := recorder.next_frame()
##     if input == null: 回放结束
func next_frame() -> PlayerInputFrame:
    if _playback_index >= frames.size():
        return null
    var frame := PlayerInputFrame.from_mask(frames[_playback_index])
    _playback_index += 1
    return frame


func playback_index() -> int:
    return _playback_index


func is_playback_finished() -> bool:
    return _playback_index >= frames.size()


# ============================== 序列化 ==============================

func to_dict() -> Dictionary:
    return {
        "version": FORMAT_VERSION,
        "seed": seed_value,
        "frame_count": frames.size(),
        "note": note,
        "frames": Array(frames),
    }


## 编码成 JSON 字符串。
func encode() -> String:
    return JSON.stringify(to_dict())


## 从字典解码。格式不对时返回 null。
static func from_dict(data: Dictionary) -> ReplayRecorder:
    var version := int(data.get("version", 0))
    if version != FORMAT_VERSION:
        push_warning("[ReplayRecorder] 重放格式版本不匹配：文件是 %d，当前支持 %d" % [
            version, FORMAT_VERSION
        ])
        return null

    var raw: Variant = data.get("frames", [])
    if not (raw is Array):
        push_warning("[ReplayRecorder] 重放数据的 frames 字段不是数组")
        return null

    var recorder := ReplayRecorder.new()
    recorder.seed_value = int(data.get("seed", 0))
    recorder.note = str(data.get("note", ""))
    var list: Array = raw
    var packed: PackedInt32Array = PackedInt32Array()
    for value in list:
        packed.append(int(value))
    recorder.frames = packed
    recorder._recording = false
    return recorder


## 从 JSON 字符串解码。失败返回 null。
static func decode(text: String) -> ReplayRecorder:
    if text.strip_edges().is_empty():
        return null
    var parsed: Variant = JSON.parse_string(text)
    if not (parsed is Dictionary):
        push_warning("[ReplayRecorder] 重放数据不是合法的 JSON 对象")
        return null
    var data: Dictionary = parsed
    return from_dict(data)


## 写文件。用于把出问题的对局存下来交给队友 / AI。
func save_to_file(path: String) -> Error:
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        push_error("[ReplayRecorder] 无法写入 %s（错误码 %d）" % [path, FileAccess.get_open_error()])
        return FileAccess.get_open_error()
    file.store_string(encode())
    file.close()
    return OK


## 读文件。
static func load_from_file(path: String) -> ReplayRecorder:
    if not FileAccess.file_exists(path):
        push_warning("[ReplayRecorder] 找不到重放文件：%s" % path)
        return null
    return decode(FileAccess.get_file_as_string(path))
