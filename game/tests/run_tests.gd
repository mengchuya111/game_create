extends SceneTree
## 无头测试入口。
##
## 运行方式（在仓库根目录）：
##     .tooling/Godot_v4.7.2-stable_win64_console.exe --headless --path game --script res://tests/run_tests.gd
##
## 退出码：0 = 全部通过，1 = 有失败。
## 这个退出码让 CI（GitHub Actions）能自动判断这次改动有没有把东西改坏 ——
## 这是"AI 改代码、人来验收"这套流程里最重要的一道自动防线。

const TEST_SCRIPTS := [
    preload("res://tests/test_deterministic_rng.gd"),
    preload("res://tests/test_attack_table.gd"),
    preload("res://tests/test_damage.gd"),
    preload("res://tests/test_player_fsm.gd"),
    preload("res://tests/test_hitstop_shake.gd"),
    preload("res://tests/test_replay_recorder.gd"),
    preload("res://tests/test_room_generator.gd"),
    preload("res://tests/test_run_state.gd"),
    preload("res://tests/test_upgrade_pool.gd"),
    preload("res://tests/test_room_data.gd"),
    preload("res://tests/test_shop.gd"),
]


func _initialize() -> void:
    print("")
    print("========================================")
    print("  武侠肉鸽 · 骨架单元测试")
    print("========================================")

    var total_tests := 0
    var total_assertions := 0
    var all_failures: PackedStringArray = PackedStringArray()
    var suites_run := 0

    for script in TEST_SCRIPTS:
        var suite: TestCase = script.new()
        var report: Dictionary = suite.run_all()

        suites_run += 1
        total_tests += int(report["tests"])
        total_assertions += int(report["assertions"])

        var failures: PackedStringArray = report["failures"]
        var suite_name := str(report["name"])

        if failures.is_empty():
            print("  [通过] %-28s %2d 个测试 / %3d 条断言" % [
                suite_name, int(report["tests"]), int(report["assertions"])
            ])
        else:
            print("  [失败] %-28s %2d 个测试 / %3d 条断言 / %d 个失败" % [
                suite_name, int(report["tests"]), int(report["assertions"]), failures.size()
            ])
            for failure in failures:
                all_failures.append("  %s" % failure)
                print("         ✗ %s" % failure)

    print("----------------------------------------")
    print("  测试套件 %d 个   测试方法 %d 个   断言 %d 条   失败 %d 个" % [
        suites_run, total_tests, total_assertions, all_failures.size()
    ])

    if all_failures.is_empty():
        print("  结果：全部通过 ✓")
        print("========================================")
        print("")
        quit(0)
        return

    print("  结果：有失败 ✗")
    print("========================================")
    print("")
    quit(1)
