class_name TestCase
extends RefCounted
## 极简单元测试框架 —— 不依赖任何第三方插件。
##
## 为什么自己写而不用 GUT 之类的插件：
##   1. 插件需要额外下载安装，初学者容易卡在这一步；
##   2. 我们要测的是"纯逻辑类"，用不到引擎的场景能力，50 行就够了；
##   3. 依赖越少，AI 越不容易改坏。
##
## 用法：继承本类，写 test_ 开头的方法，然后由 tests/run_tests.gd 统一跑。
##
##     extends TestCase
##
##     func test_something() -> void:
##         assert_eq(1 + 1, 2, "加法应该是对的")

## 断言总数。
var assertions: int = 0
## 失败信息列表。
var failures: PackedStringArray = PackedStringArray()
## 当前正在执行的测试方法名。
var current_test: String = ""


## 跑完本类里所有 test_ 开头的方法，返回统计结果。
func run_all() -> Dictionary:
    var method_names: PackedStringArray = PackedStringArray()
    for method in get_method_list():
        var method_name := str(method.get("name", ""))
        if method_name.begins_with("test_"):
            method_names.append(method_name)
    method_names.sort()

    assertions = 0
    failures = PackedStringArray()

    before_all()
    for method_name in method_names:
        current_test = method_name
        before_each()
        call(method_name)
        after_each()
    after_all()

    return {
        "name": _suite_name(),
        "tests": method_names.size(),
        "assertions": assertions,
        "failures": failures,
    }


func _suite_name() -> String:
    var script := get_script() as Script
    if script == null:
        return "UnknownSuite"
    return script.resource_path.get_file().get_basename()


# ============================== 钩子 ==============================

func before_all() -> void:
    pass


func after_all() -> void:
    pass


func before_each() -> void:
    pass


func after_each() -> void:
    pass


# ============================== 断言 ==============================

func check(condition: bool, message: String) -> bool:
    assertions += 1
    if not condition:
        failures.append("%s :: %s" % [current_test, message])
        return false
    return true


func assert_true(value: bool, message: String = "") -> bool:
    return check(value, _with_message(message, "期望为 true，实际为 false"))


func assert_false(value: bool, message: String = "") -> bool:
    return check(not value, _with_message(message, "期望为 false，实际为 true"))


func assert_eq(actual: Variant, expected: Variant, message: String = "") -> bool:
    var ok: bool = actual == expected
    return check(ok, _with_message(
        message,
        "期望 [%s]，实际 [%s]" % [_describe(expected), _describe(actual)]
    ))


func assert_ne(actual: Variant, unexpected: Variant, message: String = "") -> bool:
    return check(actual != unexpected, _with_message(
        message,
        "期望不等于 [%s]，但实际就是它" % _describe(unexpected)
    ))


func assert_almost_eq(actual: float, expected: float, tolerance: float = 0.0001, message: String = "") -> bool:
    return check(absf(actual - expected) <= tolerance, _with_message(
        message,
        "期望约等于 %.4f（容差 %.4f），实际 %.4f" % [expected, tolerance, actual]
    ))


func assert_gt(actual: float, threshold: float, message: String = "") -> bool:
    return check(actual > threshold, _with_message(
        message, "期望大于 %.4f，实际 %.4f" % [threshold, actual]
    ))


func assert_ge(actual: float, threshold: float, message: String = "") -> bool:
    return check(actual >= threshold, _with_message(
        message, "期望大于等于 %.4f，实际 %.4f" % [threshold, actual]
    ))


func assert_lt(actual: float, threshold: float, message: String = "") -> bool:
    return check(actual < threshold, _with_message(
        message, "期望小于 %.4f，实际 %.4f" % [threshold, actual]
    ))


func assert_le(actual: float, threshold: float, message: String = "") -> bool:
    return check(actual <= threshold, _with_message(
        message, "期望小于等于 %.4f，实际 %.4f" % [threshold, actual]
    ))


func assert_between(actual: float, low: float, high: float, message: String = "") -> bool:
    return check(actual >= low and actual <= high, _with_message(
        message, "期望在 [%.4f, %.4f] 之间，实际 %.4f" % [low, high, actual]
    ))


func assert_contains(haystack: String, needle: String, message: String = "") -> bool:
    return check(haystack.contains(needle), _with_message(
        message, "期望文本包含「%s」，实际文本是「%s」" % [needle, haystack]
    ))


func assert_has(collection: Variant, key: Variant, message: String = "") -> bool:
    var found := false
    if collection is Dictionary:
        var dict: Dictionary = collection
        found = dict.has(key)
    elif collection is Array:
        var arr: Array = collection
        found = arr.has(key)
    elif collection is PackedStringArray:
        var packed: PackedStringArray = collection
        found = packed.has(str(key))
    return check(found, _with_message(
        message, "期望集合里有 [%s]，但找不到" % _describe(key)
    ))


## 逐元素比较两个整数数组。比直接比较更可靠（不依赖容器类型是否一致）。
func assert_int_array_eq(actual: Array, expected: Array, message: String = "") -> bool:
    if actual.size() != expected.size():
        return check(false, _with_message(
            message,
            "数组长度不同：期望 %d 个 %s，实际 %d 个 %s" % [
                expected.size(), _describe(expected), actual.size(), _describe(actual)
            ]
        ))
    for i in range(expected.size()):
        if int(actual[i]) != int(expected[i]):
            return check(false, _with_message(
                message,
                "第 %d 个元素不同：期望 %s，实际 %s" % [
                    i, _describe(expected), _describe(actual)
                ]
            ))
    return check(true, "")


## 只要失败就直接结束当前测试方法，用于"前置条件不成立就别往下测了"。
func require(condition: bool, message: String) -> void:
    if not check(condition, message):
        push_error("[测试前置条件失败] %s :: %s" % [current_test, message])


func _with_message(message: String, fallback: String) -> String:
    if message.is_empty():
        return fallback
    return "%s —— %s" % [message, fallback]


func _describe(value: Variant) -> String:
    if value == null:
        return "null"
    if value is Array:
        var arr: Array = value
        var parts: PackedStringArray = PackedStringArray()
        for item in arr:
            parts.append(_describe(item))
        return "[" + ", ".join(parts) + "]"
    if value is PackedInt32Array:
        var packed: PackedInt32Array = value
        var parts2: PackedStringArray = PackedStringArray()
        for item in packed:
            parts2.append(str(item))
        return "[" + ", ".join(parts2) + "]"
    return str(value)
