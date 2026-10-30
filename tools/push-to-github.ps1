<#
.SYNOPSIS
    把本仓库推送到 GitHub。自动适配"HTTPS 连不上 github.com，但 SSH 能通"的网络环境。

.DESCRIPTION
    这个脚本专门处理国内常见的网络情况：github.com 的 443 端口 TCP 能握手，
    但 TLS 之后的数据被拦掉，表现为"网页打不开 / git push 卡住超时"。
    而 SSH（22 或 443 端口）通常是通的。

    脚本会：
      1. 检查前置条件（git / gh / 网络）
      2. 自动探测该用 HTTPS 还是 SSH 推送
      3. 确认本地仓库已初始化且有提交
      4. 创建 GitHub 仓库（需要 gh 已登录）或提示你去网页建
      5. 配好 remote 并推送

.PARAMETER RepoName
    GitHub 上的仓库名。默认 wuxia-roguelike。

.PARAMETER Visibility
    private（默认）或 public。建议先 private。

.PARAMETER Protocol
    auto（默认，自动探测）/ ssh / https。网络受限时用 ssh。

.PARAMETER SkipCreate
    仓库已经在网页上建好了，跳过创建步骤直接推送。

.PARAMETER Diagnose
    只做网络诊断，不推送。搞不清网络状况时先跑这个。

.PARAMETER Description
    仓库简介。

.EXAMPLE
    # 先看清楚网络能通什么
    pwsh -File tools/push-to-github.ps1 -Diagnose

.EXAMPLE
    # 已经在网页上建好空仓库，直接推（推荐）
    pwsh -File tools/push-to-github.ps1 -SkipCreate

.EXAMPLE
    # 强制走 SSH（网络受限时）
    pwsh -File tools/push-to-github.ps1 -Protocol ssh
#>

[CmdletBinding()]
param(
    [string]$RepoName = 'wuxia-roguelike',
    [ValidateSet('private', 'public')]
    [string]$Visibility = 'private',
    [ValidateSet('auto', 'ssh', 'https')]
    [string]$Protocol = 'auto',
    [switch]$SkipCreate,
    [switch]$Diagnose,
    [string]$Description = '武侠风横版 2D 肉鸽动作游戏 · Godot 4 + GDScript 可验证骨架'
)

# 这里刻意用 'Continue' 而不是 'Stop'。
#
# 原因：Windows PowerShell 5.1 下，$ErrorActionPreference = 'Stop' 会把
# **原生命令写到 stderr 的内容**当成终止性错误。而 git / gh / ssh 都会往 stderr 写正常信息
# —— 最典型的是 `ssh -T git@github.com`，认证成功时它往 stderr 打印
# "Hi xxx! You've successfully authenticated, but GitHub does not provide shell access."，
# 退出码是 1。用 'Stop' 会让脚本在这个"其实成功"的地方直接中断（已实测踩到）。
#
# 所以：错误处理一律显式检查 $LASTEXITCODE，需要终止时调用 Stop-WithHelp。
$ErrorActionPreference = 'Continue'

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
}
function Write-Ok([string]$Text)    { Write-Host "    [OK] $Text" -ForegroundColor Green }
function Write-Warn2([string]$Text) { Write-Host "    [!]  $Text" -ForegroundColor Yellow }
function Write-Info([string]$Text)  { Write-Host "    $Text" -ForegroundColor Gray }

function Stop-WithHelp([string]$Problem, [string[]]$HowToFix) {
    Write-Host ''
    Write-Host "无法继续：$Problem" -ForegroundColor Red
    Write-Host ''
    Write-Host '请按顺序执行下面的命令，然后重新运行本脚本：' -ForegroundColor Yellow
    foreach ($line in $HowToFix) { Write-Host "    $line" -ForegroundColor White }
    Write-Host ''
    exit 1
}

# 探测某个 URL 是否真的能用。
# 注意：这里必须测"能不能拿到 HTTP 响应"，不能只测 TCP 端口通不通 ——
# 被拦的网络里，TCP 三次握手经常是成功的，卡死在后面的 TLS 阶段。
function Test-HttpReachable([string]$Url, [int]$TimeoutSec = 8) {
    try {
        # 显式 -ErrorAction Stop：全局是 Continue，不这样写 try/catch 抓不到失败
        $null = Invoke-WebRequest -Uri $Url -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------- 定位仓库根目录
# 脚本放在 tools/ 下，仓库根目录是它的上一级。
# 不依赖当前工作目录，所以从任何地方调用都能跑对。
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $repoRoot 'AGENTS.md'))) {
    Stop-WithHelp "在 $repoRoot 里找不到 AGENTS.md，这看起来不是本项目的根目录。" @(
        '确认脚本位于 <仓库根>/tools/push-to-github.ps1'
    )
}
Write-Host "仓库根目录：$repoRoot"

# ---------------------------------------------------------------- 0. 诊断模式
if ($Diagnose) {
    Write-Step '网络诊断：GitHub 各端点可达性'
    Write-Info 'HTTPS 到 github.com 被拦时 TCP 握手仍会成功，所以必须测真实 HTTP 响应。'
    Write-Host ''
    $endpoints = @(
        @{ n = 'api.github.com';      u = 'https://api.github.com' },
        @{ n = 'github.com';          u = 'https://github.com' },
        @{ n = 'codeload.github.com'; u = 'https://codeload.github.com' }
    )
    foreach ($e in $endpoints) {
        $ok = 0
        for ($i = 1; $i -le 2; $i++) { if (Test-HttpReachable $e.u) { $ok++ } }
        $color = if ($ok -gt 0) { 'Green' } else { 'Red' }
        Write-Host ("    {0,-24} {1}" -f $e.n, $(if ($ok -gt 0) { '通' } else { '不通' })) -ForegroundColor $color
    }

    Write-Host ''
    Write-Host '    SSH 通道（GitHub 给受限网络准备的）：' -ForegroundColor White
    $probe = ssh -T -p 443 git@ssh.github.com -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes 2>&1 | Out-String
    $sshAuthed = ($probe -match 'successfully authenticated')
    if ($sshAuthed) {
        Write-Host '      ssh.github.com:443   通，且已认证' -ForegroundColor Green
    } elseif ($probe -match 'Permission denied') {
        Write-Host '      ssh.github.com:443   SSH 通，但公钥没加到 GitHub' -ForegroundColor Yellow
    } else {
        Write-Host '      ssh.github.com:443   不通' -ForegroundColor Red
    }

    Write-Host ''
    Write-Host '    结论：' -ForegroundColor White
    $httpsOk = Test-HttpReachable 'https://github.com'
    if (-not $httpsOk -and $sshAuthed) {
        Write-Host '      HTTPS 到 github.com 被拦，但 SSH 可用。' -ForegroundColor Green
        Write-Host '      → 用 SSH 推送： pwsh -File tools/push-to-github.ps1 -Protocol ssh' -ForegroundColor Green
    } elseif ($httpsOk) {
        Write-Host '      HTTPS 正常，用默认参数跑即可。' -ForegroundColor Green
    } else {
        Write-Host '      HTTPS 和 SSH 都不通。请先打开代理 / VPN 再重跑。' -ForegroundColor Red
    }
    exit 0
}

# ---------------------------------------------------------------- 1. 前置检查
Write-Step '检查前置条件'

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Stop-WithHelp '没有找到 git。' @('winget install --id Git.Git -e', '装完关掉终端重开（PATH 要刷新）')
}
Write-Ok "git 已安装：$(git --version)"

$ghCmd = Get-Command gh -ErrorAction SilentlyContinue
$ghAuthed = $false
if ($ghCmd) {
    & gh auth status *> $null
    $ghAuthed = ($LASTEXITCODE -eq 0)
    if ($ghAuthed) { Write-Ok 'gh 已安装并登录' }
    else { Write-Warn2 'gh 已安装但未登录（不影响 SSH 推送，只影响自动建仓库）' }
} else {
    Write-Warn2 '没有安装 gh（不影响 SSH 推送，只影响自动建仓库）'
}

# ---------------------------------------------------------------- 2. 选协议
Write-Step '确定推送协议'

$httpsOk = Test-HttpReachable 'https://github.com'
$sshProbe = ssh -T -p 443 git@ssh.github.com -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes 2>&1 | Out-String
$sshOk = ($sshProbe -match 'successfully authenticated')

Write-Info "HTTPS 到 github.com：$(if ($httpsOk) { '通' } else { '不通' })"
Write-Info "SSH（443 端口）：    $(if ($sshOk) { '通，且已认证' } else { '不通或未认证' })"

$useSsh = $false
switch ($Protocol) {
    'ssh'   { $useSsh = $true }
    'https' { $useSsh = $false }
    'auto'  {
        if ($httpsOk) { $useSsh = $false }
        elseif ($sshOk) { $useSsh = $true }
        else {
            Stop-WithHelp 'HTTPS 和 SSH 都连不上 GitHub。' @(
                '先打开你的代理 / VPN，然后重跑本脚本。',
                '或者先诊断： pwsh -File tools/push-to-github.ps1 -Diagnose'
            )
        }
    }
}

if ($useSsh -and -not $sshOk) {
    Stop-WithHelp '要求走 SSH，但 SSH 认证没通过。' @(
        '检查公钥是否已加到 GitHub：',
        '  Get-Content $env:USERPROFILE\.ssh\id_rsa.pub',
        '粘到 https://github.com/settings/keys 之后自测：',
        '  ssh -T -p 443 git@ssh.github.com'
    )
}

if ($useSsh) {
    # 把 github.com 的 HTTPS 地址全部改写为 SSH。
    # 这样即使某个子模块或工具内部写死了 https 地址，也不会再撞上被拦的 HTTPS。
    git config --global url."git@github.com:".insteadOf "https://github.com/"
    Write-Ok '已配置 git：github.com 的 HTTPS 地址自动改写为 SSH'
} else {
    Write-Ok '将使用 HTTPS 推送'
}

# ---------------------------------------------------------------- 3. 本地仓库
Write-Step '检查本地仓库'

Push-Location $repoRoot
try {
    & git rev-parse --git-dir *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Warn2 '当前还不是 git 仓库，正在初始化…'
        & git init -b main | Out-Null
        Write-Ok '已初始化 git 仓库'
    } else {
        Write-Ok 'git 仓库已存在'
    }

    & git rev-parse --verify HEAD *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Warn2 '还没有任何提交，正在创建第一次提交…'
        & git add -A
        & git commit -m 'chore: 初始化仓库（武侠肉鸽可验证骨架）'
        if ($LASTEXITCODE -ne 0) {
            Stop-WithHelp '创建第一次提交失败。' @(
                '常见原因：git 还没配置用户名和邮箱。执行：',
                '  git config --global user.name  "你的名字"',
                '  git config --global user.email "你的邮箱"'
            )
        }
        Write-Ok '已创建第一次提交'
    } else {
        Write-Ok "已有 $((& git rev-list --count HEAD).Trim()) 次提交"
    }

    $dirty = & git status --porcelain
    if ($dirty) {
        Write-Warn2 "工作区有 $(@($dirty).Count) 处未提交的改动，它们不会被推送。"
    } else {
        Write-Ok '工作区干净'
    }

    # ------------------------------------------------------------ 4. 确定仓库地址
    Write-Step "确定仓库地址：$RepoName"

    $owner = $null
    if ($ghAuthed) {
        $owner = (& gh api user --jq .login 2>$null).Trim()
    }
    if (-not $owner -and $sshProbe -match 'Hi ([A-Za-z0-9-]+)!') {
        # 从 SSH 认证回显里抠用户名："Hi mengchuya111! You've successfully authenticated..."
        $owner = $Matches[1]
    }
    if (-not $owner) {
        Stop-WithHelp '无法确定你的 GitHub 用户名。' @('先跑 gh auth login，或用 SSH 自测一次： ssh -T -p 443 git@ssh.github.com')
    }
    Write-Ok "GitHub 账号：$owner"

    $remoteUrl = if ($useSsh) { "git@github.com:$owner/$RepoName.git" } else { "https://github.com/$owner/$RepoName.git" }

    # ------------------------------------------------------------ 5. 建仓库（可选）
    $null = git ls-remote $remoteUrl HEAD 2>&1
    $repoExists = ($LASTEXITCODE -eq 0)

    if ($repoExists) {
        Write-Ok '远端仓库已存在'
    } elseif (-not $SkipCreate) {
        if ($ghAuthed) {
            Write-Step "在 GitHub 上创建 $Visibility 仓库 $RepoName"
            & gh repo create "$owner/$RepoName" --$Visibility --description $Description
            if ($LASTEXITCODE -ne 0) {
                Stop-WithHelp '创建仓库失败。' @(
                    '常见原因：仓库名被占用 → 换名字： -RepoName 别的名字',
                    '或登录过期 → gh auth login'
                )
            }
            Write-Ok '仓库已创建'
        } else {
            Stop-WithHelp "GitHub 上还没有 $RepoName 这个仓库，而 gh 没登录，脚本无法自动创建。" @(
                '两个办法，选一个：',
                '',
                '  【办法一 · 推荐】在浏览器里建一个空仓库（30 秒，不用给任何人密码）：',
                '      1. 打开 https://github.com/new',
                "      2. Repository name 填： $RepoName",
                '      3. 选 Private，不要勾 Add a README / .gitignore / license',
                '      4. 点 Create repository',
                '      5. 回来重新跑： pwsh -File tools/push-to-github.ps1 -SkipCreate',
                '',
                '  【办法二】让 gh 登录（本机 github.com 网页被拦，需要先开代理 / VPN）：',
                '      gh auth login'
            )
        }
    }

    # ------------------------------------------------------------ 6. 推送
    Write-Step '推送到 GitHub'

    & git remote get-url origin *> $null
    if ($LASTEXITCODE -eq 0) {
        & git remote set-url origin $remoteUrl
        Write-Ok "已更新 remote origin -> $remoteUrl"
    } else {
        & git remote add origin $remoteUrl
        Write-Ok "已添加 remote origin -> $remoteUrl"
    }

    $branch = (& git rev-parse --abbrev-ref HEAD).Trim()
    Write-Info "当前分支：$branch"

    & git push -u origin $branch
    if ($LASTEXITCODE -ne 0) {
        Stop-WithHelp '推送失败。' @(
            '常见原因：',
            '  · 远端已有内容且历史不一致 → git pull --rebase origin ' + $branch,
            '  · 仓库还没建 → 见上面"办法一"',
            '  · SSH 公钥没加 → https://github.com/settings/keys'
        )
    }

    Write-Ok '推送完成'
    Write-Host ''
    Write-Host "    仓库地址：https://github.com/$owner/$RepoName" -ForegroundColor Green
    Write-Host ''
}
finally {
    Pop-Location
}
