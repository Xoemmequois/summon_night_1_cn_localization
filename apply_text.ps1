# ============================================================
#  汉化文字（对话框）辅助脚本
#
#  作用：检查是否安装 Python，然后执行 romhack\apply_translations.py，
#        把 ruby_tools\opencode_generated\processed\ 里的译文
#        合并进 romhack\zh_CN_translated.json。
#
#  用法：双击 apply_text.bat，或在 PowerShell 里执行 .\apply_text.ps1
# ============================================================

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$ApplyScript = Join-Path $ScriptDir 'romhack\apply_translations.py'
$TranslatedJson = Join-Path $ScriptDir 'romhack\zh_CN_translated.json'

function Write-Info([string]$m) { Write-Host "[信息] $m" -ForegroundColor Cyan }
function Write-Ok([string]$m)   { Write-Host "[OK]   $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "[注意] $m" -ForegroundColor Yellow }
function Stop-WithError([string]$msg, [string]$fix) {
    Write-Host "[错误] $msg" -ForegroundColor Red
    if ($fix) { Write-Host "       解决办法：$fix" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host '脚本已停止。' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host '============================================' -ForegroundColor Magenta
Write-Host '  汉化文字（对话框）  apply_translations' -ForegroundColor Magenta
Write-Host '============================================' -ForegroundColor Magenta

# ------------------------------------------------------------
# 1. 检查 Python
# ------------------------------------------------------------
Write-Info '检查 Python'
$python = $null
$pythonVer = ''
foreach ($cand in @('python', 'py')) {
    if (-not (Get-Command $cand -ErrorAction SilentlyContinue)) { continue }
    $ver = (& $cand --version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and $ver -match 'Python\s*3') {
        $python = $cand
        $pythonVer = $ver
        break
    }
}
if (-not $python) {
    Stop-WithError '没有检测到可用的 Python 3。' `
        '请安装 Python 3：https://www.python.org/downloads/ （安装时勾选 “Add Python to PATH”），安装后重新运行本脚本。'
}
Write-Ok "$python 可用（$pythonVer）"

# ------------------------------------------------------------
# 2. 检查 apply_translations.py
# ------------------------------------------------------------
if (-not (Test-Path -LiteralPath $ApplyScript)) {
    Stop-WithError "找不到脚本：$ApplyScript" `
        '请确认仓库里有 romhack\apply_translations.py，并且本脚本放在仓库根目录。'
}

# ------------------------------------------------------------
# 3. 执行 apply_translations.py
# ------------------------------------------------------------
Write-Info '执行 romhack\apply_translations.py'
Write-Host '读取 ruby_tools\opencode_generated\processed\ 下的译文并写入 zh_CN_translated.json……' -ForegroundColor Yellow

Push-Location -LiteralPath $ScriptDir
try {
    & $python $ApplyScript | Out-Host
    $code = $LASTEXITCODE
} finally {
    Pop-Location
}

if ($code -ne 0) {
    Stop-WithError "apply_translations.py 执行失败（返回码 $code）。" `
        '查看上面的错误信息；常见原因：processed 文件里有冲突译文、或 JSON 格式不对。'
}

# ------------------------------------------------------------
# 4. 完成
# ------------------------------------------------------------
Write-Host ''
if (Test-Path -LiteralPath $TranslatedJson) {
    Write-Ok "已生成：$TranslatedJson"
    Write-Host '接下来双击 build.bat 即可编译并封包。' -ForegroundColor Green
} else {
    Write-Warn "未找到 $TranslatedJson，请检查上面的输出。"
}
exit 0
