$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$toolDir = Join-Path $root '.tooling'
$version = '4.7.2-stable'
$archive = Join-Path $env:TEMP "Godot_v${version}_win64.zip"
$downloadUrl = "https://github.com/godotengine/godot/releases/download/${version}/Godot_v${version}_win64.exe.zip"

New-Item -ItemType Directory -Force -Path $toolDir | Out-Null
$exe = Join-Path $toolDir "Godot_v${version}_win64.exe"
$consoleExe = Join-Path $toolDir "Godot_v${version}_win64_console.exe"
if ((Test-Path $exe) -and (Test-Path $consoleExe)) {
    Write-Host "Godot $version already exists in $toolDir"
    exit 0
}

Write-Host "Downloading Godot $version from $downloadUrl"
Invoke-WebRequest -Uri $downloadUrl -OutFile $archive
Write-Host 'Extracting archive...'
Expand-Archive -LiteralPath $archive -DestinationPath $toolDir -Force
Remove-Item -LiteralPath $archive -Force
if (-not (Test-Path $exe)) { throw "Expected executable missing: $exe" }
if (-not (Test-Path $consoleExe)) { throw "Expected console executable missing: $consoleExe" }
Write-Host "Installed Godot $version"
& $consoleExe --version
