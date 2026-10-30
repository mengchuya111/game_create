<#
.SYNOPSIS
    一键验收：跑完三条必跑命令，并把结果和"基线"对比，判断有没有人偷偷删测试。

.DESCRIPTION
    这个项目最大的风险不是"代码写错了"，而是"测试被悄悄改弱了"——
    单元测试从 225 个变成 217 个，结论行照样打印「全部通过 ✓」。
    光看最后一行是看不出来的，必须看数字。

    所以本脚本做三件事：
      1. 按顺序跑 --import → 单元测试 → 冒烟测试
      2. 从输出里抠出「套件/方法/断言/检查项」的数量
      3. 和 tools/test-baseline.json 里的基线对比，**数字下降就报失败**

.PARAMETER UpdateBaseline
    把当前这次的结果记录为新基线。只在你**确实新增了测试**之后才用。
    注意：用它来"抹掉"测试数量下降，等于把守卫关掉。

.PARAMETER SkipImport
    跳过 --import。只改了已有文件的代码、没增删文件时可以省几秒。

.EXAMPLE
    # 日常验收（AI 改完代码，你就跑这一条）
    pwsh -File tools/verify.ps1

.EXAMPLE
    # 我确实加了新测试，把基线抬上去
    pwsh -File tools/verify.ps1 -UpdateBaseline

.NOTES
    退出码：0 = 全绿且数字没退步；1 = 有失败或有退步。
    可以直接接进 CI，也可以让 AI 每次改完自己跑一遍再交给你。
#>

[CmdletBinding()]
param(
    [switch]$UpdateBaseline,
    [switch]$SkipImport
)

# 与 push-to-github.ps1 同样的理由：PS 5.1 下 'Stop' 会把原生命令的 stderr 当终止性错误，
# 而 Godot 会把大量预期内的 ERROR/WARNING 写到 stderr（测试故意喂错误数据）。
# 那些输出必须能被我们读到并忽略，不能让脚本中断。
$ErrorActionPreference = 'Continue'

$repoRoot = Split-Path -Parent $PSScriptRoot
$gamePath = Join-Path $repoRoot 'game'
$baselinePath = Join-Path $PSScriptRoot 'test-baseline.json'

function Write-Head([string]$Text) {
    Write-Host ''
    Write-Host "===== $Text =====" -ForegroundColor Cyan
}

# 去掉 ANSI 颜色码，否则正则匹配会被转义序列干扰
function Strip-Ansi([string]$Text) {
    return ($Text -replace '\x1b\[[0-9;]*m', '')
}

if (-not (Test-Path (Join-Path $repoRoot 'AGENTS.md'))) {
    Write-Host "找不到 AGENTS.md，$repoRoot 看起来不是项目根目录" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------- 找 Godot 可执行文件
$godot = Get-ChildItem (Join-Path $repoRoot '.tooling') -Filter 'Godot_v*_console.exe' -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $godot) {
    Write-Host '在 .tooling/ 下找不到 Godot 控制台版可执行文件。' -ForegroundColor Red
    Write-Host '先跑一次安装脚本： pwsh -File tools/install-tools.ps1' -ForegroundColor Yellow
    exit 1
}
Write-Host "Godot：$($godot.FullName)"

# ---------------------------------------------------------------- ① import
if (-not $SkipImport) {
    Write-Head '① --import（重新扫描脚本类名）'
    $importOut = & $godot.FullName --headless --path $gamePath --import 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Write-Host "import 失败（退出码 $LASTEXITCODE）" -ForegroundColor Red
        Write-Host $importOut
        exit 1
    }
    Write-Host '    import 完成' -ForegroundColor Green
} else {
    Write-Host ''
    Write-Host '（已跳过 --import）' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- ② 单元测试
Write-Head '② 单元测试（纯逻辑层）'
$unitOut = Strip-Ansi (& $godot.FullName --headless --path $gamePath --script 'res://tests/run_tests.gd' 2>&1 | Out-String)
$unitExit = $LASTEXITCODE

$suites = 0; $methods = 0; $asserts = 0; $unitFails = 0
if ($unitOut -match '测试套件\s+(\d+)\s+个\s+测试方法\s+(\d+)\s+个\s+断言\s+(\d+)\s+条\s+失败\s+(\d+)\s+个') {
    $suites = [int]$Matches[1]; $methods = [int]$Matches[2]
    $asserts = [int]$Matches[3]; $unitFails = [int]$Matches[4]
    Write-Host "    套件 $suites / 方法 $methods / 断言 $asserts / 失败 $unitFails"
} else {
    Write-Host '    没能从输出里解析出结论行 —— 输出格式可能变了，请看下面的原始输出' -ForegroundColor Red
    Write-Host $unitOut
    exit 1
}

# ---------------------------------------------------------------- ③ 冒烟测试
Write-Head '③ 冒烟测试（真的把游戏跑起来自动玩）'
$smokeOut = Strip-Ansi (& $godot.FullName --headless --path $gamePath 'res://tests/smoke_run.tscn' 2>&1 | Out-String)
$smokeExit = $LASTEXITCODE

$checks = 0; $smokeFails = 0
if ($smokeOut -match '检查项\s+(\d+)\s+个\s+失败\s+(\d+)\s+个') {
    $checks = [int]$Matches[1]; $smokeFails = [int]$Matches[2]
    Write-Host "    检查项 $checks / 失败 $smokeFails"
} else {
    Write-Host '    没能解析出结论行，请看下面的原始输出' -ForegroundColor Red
    Write-Host $smokeOut
    exit 1
}

# ---------------------------------------------------------------- 基线对比
Write-Head '与基线对比'

$current = [ordered]@{
    unit_suites  = $suites
    unit_methods = $methods
    unit_asserts = $asserts
    smoke_checks = $checks
}

$regressions = @()
if (Test-Path $baselinePath) {
    # 基线解析失败必须"响亮地失败"，绝不能静默跳过对比。
    #
    # 这条是踩出来的：基线文件原本写成了「UTF-8 无 BOM + 中文说明」，
    # PS 5.1 用 Get-Content 读回来时按 GBK 解码 → 中文变乱码 → JSON 直接解析失败
    # → $base 是 null → 整个对比环节被跳过 → 脚本照样打印「验收结果：通过 ✓」。
    # 一个坏掉的守卫比没有守卫更危险：它给你虚假的安全感。
    $base = $null
    try {
        $base = Get-Content $baselinePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Host '    基线文件解析失败，无法判断测试数量有没有退步。' -ForegroundColor Red
        Write-Host "    文件：$baselinePath" -ForegroundColor Red
        Write-Host "    原因：$($_.Exception.Message)" -ForegroundColor Red
        Write-Host '    处理：跑 pwsh -File tools/verify.ps1 -UpdateBaseline 重新记录基线。' -ForegroundColor Yellow
        exit 1
    }
    foreach ($required in @('unit_suites', 'unit_methods', 'unit_asserts', 'smoke_checks')) {
        if ($null -eq $base.$required) {
            Write-Host "    基线文件缺少字段 $required，无法对比。" -ForegroundColor Red
            Write-Host '    处理：跑 pwsh -File tools/verify.ps1 -UpdateBaseline 重新记录基线。' -ForegroundColor Yellow
            exit 1
        }
    }
    $labels = @{
        unit_suites  = '单元测试套件数'
        unit_methods = '单元测试方法数'
        unit_asserts = '单元测试断言数'
        smoke_checks = '冒烟测试检查项数'
    }
    foreach ($key in $current.Keys) {
        $old = $base.$key
        $new = $current[$key]
        if ($null -eq $old) { continue }
        if ($new -lt $old) {
            Write-Host ("    {0}：{1} -> {2}  [退步]" -f $labels[$key], $old, $new) -ForegroundColor Red
            $regressions += "$($labels[$key]) 从 $old 降到 $new"
        } elseif ($new -gt $old) {
            Write-Host ("    {0}：{1} -> {2}  [增加]" -f $labels[$key], $old, $new) -ForegroundColor Green
        } else {
            Write-Host ("    {0}：{1}  [持平]" -f $labels[$key], $new) -ForegroundColor Gray
        }
    }
} else {
    Write-Host '    还没有基线文件，这次的结果将作为基线记录。' -ForegroundColor Yellow
    $UpdateBaseline = $true
}

if ($UpdateBaseline) {
    # 刻意写成**纯 ASCII、不带中文**。
    # 这个文件是给机器读的，一旦掺进中文，PS 5.1 在不带 BOM 时会按 GBK 解码，
    # JSON 直接解析失败（见上面读取处的注释）。说明文字放在脚本注释里，不放进数据文件。
    $json = [ordered]@{
        unit_suites  = $suites
        unit_methods = $methods
        unit_asserts = $asserts
        smoke_checks = $checks
    } | ConvertTo-Json
    [System.IO.File]::WriteAllText($baselinePath, $json, (New-Object System.Text.UTF8Encoding $false))
    Write-Host "    已写入基线：$baselinePath" -ForegroundColor Green
}

# ---------------------------------------------------------------- 结论
Write-Head '结论'

$failed = ($unitExit -ne 0) -or ($smokeExit -ne 0) -or ($unitFails -gt 0) -or ($smokeFails -gt 0) -or ($regressions.Count -gt 0)

Write-Host "    单元测试退出码 $unitExit    冒烟测试退出码 $smokeExit"
if ($regressions.Count -gt 0) {
    Write-Host ''
    Write-Host '    发现测试数量退步：' -ForegroundColor Red
    foreach ($r in $regressions) { Write-Host "      · $r" -ForegroundColor Red }
    Write-Host '    这不是"顺手清理"，说明有人删了测试或弱化了断言。' -ForegroundColor Red
    Write-Host '    先查清原因再提交。确认是合理删除，才用 -UpdateBaseline 更新基线。' -ForegroundColor Yellow
}

Write-Host ''
if ($failed) {
    Write-Host '验收结果：不通过 ✗' -ForegroundColor Red
    exit 1
}
Write-Host '验收结果：通过 ✓' -ForegroundColor Green
exit 0
