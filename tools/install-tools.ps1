<#
.SYNOPSIS
    下载并安装本项目锁定的 Godot 版本到 .tooling/ 目录。

.DESCRIPTION
    为什么需要这个脚本：Godot 本体 80 多 MB，不能进版本库（.gitignore 已排除 .tooling/），
    所以每个队友克隆完项目都要自己装一次。这个脚本保证所有人装到**同一个版本**。

    ## 下载源：三个，按顺序试

    | 顺序 | 源 | 说明 |
    |---|---|---|
    | 1 | Godot 官方 CDN | 网络正常时最快 |
    | 2 | GitHub 加速（gh-proxy.com） | **国内被墙时靠这个**，实测约 0.24 MB/s，82 MB 约 6 分钟 |
    | 3 | GitHub Releases 直连 | 国内经常连不上，放最后 |

    ## 为什么必须准备第 2 个源

    国内常见的情况是：`github.com` 和 `downloads.godotengine.org` 的 **HTTP 头能拿到**
    （HEAD 请求返回 200），但**一开始传正文就卡住直到超时**。
    所以"能 ping 通""HEAD 返回 200"都**不能**说明能下载 —— 必须真的下到字节才算数。
    实测：官方 CDN 的 HEAD 返回 200，但实际下载 15 分钟超时；走 gh-proxy 反而稳定下完了。

    ## 下载器用 curl.exe 而不是 Invoke-WebRequest

    Windows 10 以上自带 `curl.exe`，它处理大文件更稳，而且能用
    `--speed-limit/--speed-time` 做"**卡住就放弃**"的判断：
    连上了但速度掉到 10 KB/s 以下持续 30 秒，就判定这个源不通，立刻换下一个。
    没有这个保护的话，一个被墙的源会把脚本卡满整个超时时间。

.PARAMETER Force
    已经装过也强制重新下载。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\install-tools.ps1

.EXAMPLE
    # 装坏了，重新下一份
    powershell -ExecutionPolicy Bypass -File tools\install-tools.ps1 -Force

.NOTES
    装完请跑一次验收确认环境没问题：
        powershell -File tools\verify.ps1
#>

[CmdletBinding()]
param(
    [switch]$Force
)

# 用 'Continue' 而不是 'Stop'：PS 5.1 下 'Stop' 会把原生命令写到 stderr 的内容当终止性错误，
# 而 curl 的进度条就是走 stderr 的。错误一律显式判断。
$ErrorActionPreference = 'Continue'

$root = Split-Path -Parent $PSScriptRoot
$toolDir = Join-Path $root '.tooling'
$version = '4.7.2-stable'
$archive = Join-Path $env:TEMP "Godot_v${version}_win64.zip"
$exe = Join-Path $toolDir "Godot_v${version}_win64.exe"
$consoleExe = Join-Path $toolDir "Godot_v${version}_win64_console.exe"

$ghRelease = "https://github.com/godotengine/godot/releases/download/${version}/Godot_v${version}_win64.exe.zip"

$sources = @(
    @{
        Name = 'Godot 官方 CDN'
        Url  = 'https://downloads.godotengine.org/?version=4.7.2&flavor=stable&slug=win64.exe.zip&platform=windows.64'
    },
    @{
        Name = 'GitHub 加速（gh-proxy.com）'
        Url  = "https://gh-proxy.com/$ghRelease"
    },
    @{
        Name = 'GitHub Releases 直连'
        Url  = $ghRelease
    }
)

# 正常压缩包约 82 MB。小于这个数说明下到的是错误页或半截文件。
$minExpectedBytes = 40MB

New-Item -ItemType Directory -Force -Path $toolDir | Out-Null

if ((Test-Path $exe) -and (Test-Path $consoleExe) -and -not $Force) {
    Write-Host "[跳过] Godot $version 已经装好了。" -ForegroundColor Green
    Write-Host "       位置：$toolDir"
    Write-Host "       想重新下载请加 -Force"
    Write-Host ''
    & $consoleExe --version
    exit 0
}

$hasCurl = [bool](Get-Command curl.exe -ErrorAction SilentlyContinue)

Write-Host "目标版本：Godot $version"
Write-Host "安装目录：$toolDir"
if ($hasCurl) {
    Write-Host '下载器：  curl.exe'
} else {
    Write-Host '下载器：  Invoke-WebRequest（没找到 curl.exe）' -ForegroundColor Yellow
}
Write-Host ''

$downloaded = $false
foreach ($source in $sources) {
    Write-Host "尝试从 $($source.Name) 下载…" -ForegroundColor Cyan
    Write-Host "  $($source.Url)" -ForegroundColor DarkGray
    Remove-Item $archive -Force -ErrorAction SilentlyContinue

    if ($hasCurl) {
        # --speed-limit 10240 --speed-time 30：速度掉到 10 KB/s 以下持续 30 秒就放弃。
        # 这是区分"能下载"和"连上了但被卡住"的关键 —— 后者不设这个会一直挂到 --max-time。
        & curl.exe -L --fail --no-progress-meter `
            --connect-timeout 20 --max-time 1800 `
            --speed-limit 10240 --speed-time 30 `
            -o $archive $source.Url 2>$null
        $code = $LASTEXITCODE
    } else {
        try {
            Invoke-WebRequest -Uri $source.Url -OutFile $archive -TimeoutSec 1800 -UseBasicParsing -ErrorAction Stop
            $code = 0
        } catch {
            $code = 1
        }
    }

    if ($code -ne 0) {
        Write-Host "  失败（退出码 $code）：连不上或速度太慢，换下一个源。" -ForegroundColor Yellow
        continue
    }

    if (-not (Test-Path $archive)) {
        Write-Host '  没下到文件，换下一个源。' -ForegroundColor Yellow
        continue
    }

    $size = (Get-Item $archive).Length
    if ($size -lt $minExpectedBytes) {
        Write-Host ("  只下到 {0} MB，明显不对（正常约 82 MB），换下一个源。" -f [math]::Round($size / 1MB, 1)) -ForegroundColor Yellow
        continue
    }

    Write-Host ("  下载完成：{0} MB" -f [math]::Round($size / 1MB, 1)) -ForegroundColor Green
    $downloaded = $true
    break
}

if (-not $downloaded) {
    Write-Host ''
    Write-Host '三个下载源都失败了。' -ForegroundColor Red
    Write-Host ''
    Write-Host '手动下载办法（按顺序试）：' -ForegroundColor Yellow
    Write-Host '  1. 开代理 / VPN 后重跑本脚本' -ForegroundColor White
    Write-Host '  2. 用加速链接下载（浏览器里直接打开这个地址）：' -ForegroundColor White
    Write-Host "     https://gh-proxy.com/$ghRelease" -ForegroundColor Gray
    Write-Host '  3. 到 https://godotengine.org/download/windows/ 用下载工具（如 IDM）下' -ForegroundColor White
    Write-Host ''
    Write-Host "  下完之后：解压出 Godot_v${version}_win64.exe 和 Godot_v${version}_win64_console.exe，" -ForegroundColor White
    Write-Host "  两个文件都放进：$toolDir" -ForegroundColor White
    Write-Host '  （不要下载带 .NET / Mono 字样的版本，本项目用 GDScript）' -ForegroundColor White
    Write-Host ''
    exit 1
}

Write-Host '解压…'
Expand-Archive -LiteralPath $archive -DestinationPath $toolDir -Force
Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue

# 解压后必须确认两个可执行文件都在。
# 编辑器版用来手动玩，console 版用来跑测试（它会把输出回显到终端）。
if (-not (Test-Path $exe)) {
    Write-Host "解压完了但没找到：$exe" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $consoleExe)) {
    Write-Host "解压完了但没找到：$consoleExe" -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host "[完成] Godot $version 已安装到 $toolDir" -ForegroundColor Green
& $consoleExe --version
Write-Host ''
Write-Host '下一步：跑一次验收，确认环境没问题' -ForegroundColor White
Write-Host '  powershell -File tools\verify.ps1' -ForegroundColor Gray
Write-Host ''
