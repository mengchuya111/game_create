<#
.SYNOPSIS
    把本仓库推送到 GitHub。第一次跑会自动建仓库，之后跑就是普通推送。

.DESCRIPTION
    这个脚本做四件事：
      1. 检查前置条件（git、gh、GitHub 登录状态）
      2. 确认本地仓库已初始化、且至少有一次提交
      3. 在 GitHub 上创建仓库（如果还没建）
      4. 设置 remote 并推送

    为什么用 gh 而不是让你手动建仓库：
      手动建仓库要复制粘贴 remote 地址，很容易把 https/ssh 搞错，
      而且第一次推送忘了 -u 的话，之后每次都要写全参数。

.PARAMETER RepoName
    GitHub 上的仓库名。默认 wuxia-roguelike。

.PARAMETER Visibility
    private（默认）或 public。建议先 private，确认没有敏感信息再公开。

.PARAMETER Description
    仓库简介。

.EXAMPLE
    # 第一次：建一个私有仓库并推送
    pwsh -File tools/push-to-github.ps1

.EXAMPLE
    # 建一个公开仓库，换个名字
    pwsh -File tools/push-to-github.ps1 -RepoName my-wuxia-game -Visibility public

.NOTES
    如果脚本提示"还没登录 GitHub"，先手动跑一次：
        gh auth login
    这一步必须在浏览器里完成，脚本没法替你点。
#>

[CmdletBinding()]
param(
    [string]$RepoName = 'wuxia-roguelike',
    [ValidateSet('private', 'public')]
    [string]$Visibility = 'private',
    [string]$Description = '武侠风横版 2D 肉鸽动作游戏 · Godot 4 + GDScript 可验证骨架'
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
}

function Write-Ok([string]$Text) {
    Write-Host "    [OK] $Text" -ForegroundColor Green
}

function Write-Warn2([string]$Text) {
    Write-Host "    [!]  $Text" -ForegroundColor Yellow
}

function Stop-WithHelp([string]$Problem, [string[]]$HowToFix) {
    Write-Host ''
    Write-Host "无法继续：$Problem" -ForegroundColor Red
    Write-Host ''
    Write-Host '请按顺序执行下面的命令，然后重新运行本脚本：' -ForegroundColor Yellow
    foreach ($line in $HowToFix) {
        Write-Host "    $line" -ForegroundColor White
    }
    Write-Host ''
    exit 1
}

# ---------------------------------------------------------------- 定位仓库根目录
# 脚本放在 tools/ 下，仓库根目录是它的上一级。
# 不依赖当前工作目录，所以从任何地方调用都能跑对。
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $repoRoot 'AGENTS.md'))) {
    Stop-WithHelp "在 $repoRoot 里找不到 AGENTS.md，这看起来不是本项目的根目录。" @(
        "确认脚本位于 <仓库根>/tools/push-to-github.ps1"
    )
}
Write-Host "仓库根目录：$repoRoot"

# ---------------------------------------------------------------- 1. 前置检查
Write-Step '检查前置条件'

$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) {
    Stop-WithHelp '没有找到 git。' @(
        'winget install --id Git.Git -e',
        '装完之后关掉当前终端再重开（PATH 需要刷新）'
    )
}
Write-Ok "git 已安装：$(git --version)"

$gh = Get-Command gh -ErrorAction SilentlyContinue
if (-not $gh) {
    Stop-WithHelp '没有找到 GitHub CLI（gh）。' @(
        'winget install --id GitHub.cli -e',
        '装完之后关掉当前终端再重开（PATH 需要刷新）'
    )
}
Write-Ok "gh 已安装：$(gh --version | Select-Object -First 1)"

# gh auth status 在未登录时返回非 0，用 $LASTEXITCODE 判断，不要让异常中断脚本
& gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
    Stop-WithHelp 'GitHub CLI 还没有登录。' @(
        'gh auth login',
        '  选 GitHub.com → HTTPS → 用浏览器登录（会打开网页，需要你自己点授权）',
        '登录完再运行本脚本'
    )
}
Write-Ok 'GitHub 已登录'

# ---------------------------------------------------------------- 2. 本地仓库状态
Write-Step '检查本地仓库'

Push-Location $repoRoot
try {
    & git rev-parse --git-dir *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Warn2 '当前还不是 git 仓库，正在初始化…'
        & git init | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'git init 失败' }
        Write-Ok '已初始化 git 仓库'
    } else {
        Write-Ok 'git 仓库已存在'
    }

    # 有没有提交？没有提交就没法推送。
    & git rev-parse --verify HEAD *> $null
    $hasCommit = ($LASTEXITCODE -eq 0)
    if (-not $hasCommit) {
        Write-Warn2 '还没有任何提交，正在创建第一次提交…'
        & git add -A
        if ($LASTEXITCODE -ne 0) { throw 'git add 失败' }
        & git commit -m 'chore: 初始化仓库（武侠肉鸽可验证骨架）'
        if ($LASTEXITCODE -ne 0) {
            Stop-WithHelp '创建第一次提交失败。' @(
                '常见原因：git 还没配置用户名和邮箱。执行：',
                '  git config --global user.name  "你的名字"',
                '  git config --global user.email "你的邮箱"',
                '然后重新运行本脚本'
            )
        }
        Write-Ok '已创建第一次提交'
    } else {
        $count = (& git rev-list --count HEAD).Trim()
        Write-Ok "已有 $count 次提交"
    }

    # 工作区是否干净（不干净只警告，不阻止 —— 推送已提交的内容是安全的）
    $dirty = & git status --porcelain
    if ($dirty) {
        $dirtyCount = @($dirty).Count
        Write-Warn2 "工作区有 $dirtyCount 处未提交的改动，它们不会被推送。"
        Write-Warn2 '要一起推的话，先执行： git add -A ; git commit -m "你的说明"'
    } else {
        Write-Ok '工作区干净'
    }

    # ------------------------------------------------------------ 3. 创建 GitHub 仓库
    Write-Step "检查 GitHub 上的仓库 $RepoName"

    $remoteUrl = $null
    & git remote get-url origin *> $null
    if ($LASTEXITCODE -eq 0) {
        $remoteUrl = (& git remote get-url origin).Trim()
        Write-Ok "已配置 remote origin：$remoteUrl"
    } else {
        # 先看这个仓库名在 GitHub 上是不是已经被占了
        & gh repo view $RepoName *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Warn2 "GitHub 上已经存在名为 $RepoName 的仓库，将直接关联它。"
            Write-Warn2 '如果那是别人的仓库，你会推送失败 —— 那就换个名字：-RepoName 别的名字'
            & gh repo set-default $RepoName *> $null
            $login = (& gh api user --jq .login).Trim()
            $remoteUrl = "https://github.com/$login/$RepoName.git"
            & git remote add origin $remoteUrl
            Write-Ok "已关联 remote：$remoteUrl"
        } else {
            Write-Host "    正在创建 $Visibility 仓库…" -ForegroundColor White
            # --source=. --push 会把当前仓库作为源并直接推送，顺便把 origin 配好
            & gh repo create $RepoName --$Visibility --source=. --remote=origin --push --description $Description
            if ($LASTEXITCODE -ne 0) {
                Stop-WithHelp "创建仓库 $RepoName 失败。" @(
                    '常见原因：',
                    "  · 仓库名已被占用 → 换个名字： pwsh -File tools/push-to-github.ps1 -RepoName 别的名字",
                    '  · 登录过期 → 重新跑 gh auth login',
                    '  · 网络不通 → 检查代理'
                )
            }
            Write-Ok "仓库已创建并推送完成"
            Write-Host ''
            $login = (& gh api user --jq .login).Trim()
            Write-Host "    仓库地址：https://github.com/$login/$RepoName" -ForegroundColor Green
            exit 0
        }
    }

    # ------------------------------------------------------------ 4. 推送
    Write-Step '推送到 GitHub'

    # 当前分支名（Godot 项目常把默认分支设成 main 或 master，这里按实际来）
    $branch = (& git rev-parse --abbrev-ref HEAD).Trim()
    Write-Host "    当前分支：$branch" -ForegroundColor White

    & git push -u origin $branch
    if ($LASTEXITCODE -ne 0) {
        Stop-WithHelp '推送失败。' @(
            '常见原因：',
            '  · 远端已有内容且历史不一致 → git pull --rebase origin ' + $branch,
            '  · 没有推送权限 → 确认这是你自己的仓库',
            '  · 登录过期 → gh auth login'
        )
    }

    Write-Ok '推送完成'
    Write-Host ''
    $login = (& gh api user --jq .login).Trim()
    Write-Host "    仓库地址：https://github.com/$login/$RepoName" -ForegroundColor Green
    Write-Host ''
}
finally {
    Pop-Location
}
