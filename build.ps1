# ============================================================
#  Summon Night (PS1) 汉化  一键构建脚本
#
#  用法：
#    双击 build.bat
#    或在 PowerShell 里执行：.\build.ps1
#
#  可选参数：
#    -SkipImages   跳过“翻译图片”目录检查（只构建文本）
#    -CheckOnly    只做检查，不编译、不执行
#
#  脚本会自动：
#    1. 检查是否安装 .NET 8 SDK
#    2. 检查 config.json 及其中配置的路径是否存在
#    3. 判断是否已经 RIP；没有则先执行 RIP
#       （按设定：RIP 完成后即停止，不会继续封包）
#    4. 检查构建（写回）所需的文件是否齐全
#    5. 编译并运行 romhack_csharp（封包）
# ============================================================

[CmdletBinding()]
param(
    [switch]$SkipImages,
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$ScriptDir  = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$RepoRoot   = $ScriptDir
$RomhackDir = Join-Path $RepoRoot 'romhack'
$ProjectDir = Join-Path $RepoRoot 'romhack_csharp\romhack_csharp'
$ConfigPath = Join-Path $RomhackDir 'config.json'

function Write-Step([string]$m) { Write-Host ''; Write-Host "== $m ==" -ForegroundColor Cyan }
function Write-Ok([string]$m)   { Write-Host "[OK]   $m" -ForegroundColor Green }
function Write-Note([string]$m) { Write-Host "[注意] $m" -ForegroundColor Yellow }
function Write-Err([string]$m, [string]$fix) {
    Write-Host "[错误] $m" -ForegroundColor Red
    if ($fix) { Write-Host "       解决办法：$fix" -ForegroundColor Yellow }
}
function Stop-WithError([string]$msg, [string]$fix) {
    Write-Err $msg $fix
    Write-Host ''
    Write-Host '脚本已停止。' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host '============================================' -ForegroundColor Magenta
Write-Host '  Summon Night 汉化  一键构建脚本' -ForegroundColor Magenta
Write-Host '============================================' -ForegroundColor Magenta
Write-Host "仓库目录：$RepoRoot"
Write-Host "工作目录：$RomhackDir"

# ------------------------------------------------------------
# 1. 检查 .NET SDK
# ------------------------------------------------------------
Write-Step '检查 .NET SDK'
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Stop-WithError '没有检测到 dotnet 命令，可能还没安装 .NET SDK。' `
        '请安装 .NET 8 SDK：https://dotnet.microsoft.com/download/dotnet/8.0 ，安装后重新运行本脚本。'
}
$sdkList = & dotnet --list-sdks 2>$null
if (-not ($sdkList -and ($sdkList | Where-Object { $_ -match '^8\.' }))) {
    $have = if ($sdkList) { ($sdkList -join ' / ') } else { '（无）' }
    Stop-WithError "没有找到 .NET 8 SDK（本项目需要 net8.0-windows）。当前已安装：$have" `
        '请安装 .NET 8 SDK：https://dotnet.microsoft.com/download/dotnet/8.0'
}
Write-Ok 'dotnet 可用，且已安装 .NET 8 SDK'

# ------------------------------------------------------------
# 2. 检查目录
# ------------------------------------------------------------
Write-Step '检查项目目录'
if (-not (Test-Path -LiteralPath $RomhackDir)) {
    Stop-WithError "找不到工作目录：$RomhackDir" `
        '请把本脚本放在仓库根目录（与 romhack\、romhack_csharp\ 同级）。'
}
if (-not (Test-Path -LiteralPath (Join-Path $ProjectDir 'romhack_csharp.csproj'))) {
    Stop-WithError "找不到 C# 项目：$ProjectDir\romhack_csharp.csproj" `
        '请确认 romhack_csharp\romhack_csharp\romhack_csharp.csproj 存在。'
}
Write-Ok '目录结构正常'

# ------------------------------------------------------------
# 3. 检查 config.json 及其中路径
# ------------------------------------------------------------
Write-Step '检查 config.json'
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Stop-WithError "找不到配置文件：$ConfigPath" `
        '把 romhack_csharp\config.json.sample 复制成 romhack\config.json，填入 SDKPath 和 GamePath 后重试。'
}
$config = $null
try {
    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Stop-WithError "config.json 不是合法的 JSON：$($_.Exception.Message)" `
        '对照 romhack_csharp\config.json.sample 检查逗号、引号、反斜杠（路径里的 \ 要写成 \\）。'
}
Write-Ok 'config.json 读取成功'

Write-Step '检查 config.json 中的路径'
if ([string]::IsNullOrWhiteSpace($config.SDKPath)) {
    Stop-WithError 'config.json 缺少 SDKPath。' '填入 PSn00bSDK 根目录，例如：D:\\PSn00bSDK-0.24-win32\\'
}
if (-not (Test-Path -LiteralPath $config.SDKPath)) {
    Stop-WithError "SDKPath 指向的目录不存在：$($config.SDKPath)" `
        '确认 PSn00bSDK 已解压到该路径，或修改 config.json 的 SDKPath。'
}
foreach ($tool in 'bin\dumpsxiso.exe', 'bin\mkpsxiso.exe', 'bin\mipsel-none-elf-gcc.exe', 'bin\mipsel-none-elf-objcopy.exe') {
    if (-not (Test-Path -LiteralPath (Join-Path $config.SDKPath $tool))) {
        Stop-WithError "SDKPath 里缺少 $tool" `
            '确认 SDKPath 是 PSn00bSDK 0.24 的根目录（其 bin\ 下应有编译与打包工具）。'
    }
}
if ([string]::IsNullOrWhiteSpace($config.GamePath)) {
    Stop-WithError 'config.json 缺少 GamePath。' '填入原版《Summon Night》日版 ISO（.bin / .iso）的完整路径。'
}
if (-not (Test-Path -LiteralPath $config.GamePath)) {
    Stop-WithError "GamePath 指向的文件不存在：$($config.GamePath)" `
        '确认原版 ISO 路径正确（RIP 需要它）。若只想重新构建，也请保留一个正确的路径。'
}
Write-Ok 'SDKPath / GamePath 均存在'

# ------------------------------------------------------------
# 辅助：编译 / 运行
# ------------------------------------------------------------
function Invoke-BuildProject {
    Write-Step '编译 romhack_csharp'
    & dotnet build $ProjectDir --nologo
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError "编译失败（dotnet build 退出码 $LASTEXITCODE）。" `
            '按上面的编译错误修正代码；也可用 Rider / Visual Studio 打开 romhack_csharp\romhack_csharp.sln 检查。'
    }
    Write-Ok '编译完成'
}

function Invoke-Pipeline {
    param([string[]]$ExtraArgs)
    Push-Location -LiteralPath $RomhackDir
    $nativeExit = 1
    try {
        # 用 Out-Host 显示子进程输出，避免它混进本函数的返回值
        # （否则调用方拿到的 $code 会变成「一堆输出行 + 退出码」的数组）。
        if ($ExtraArgs -and $ExtraArgs.Count -gt 0) {
            & dotnet run --project $ProjectDir --no-build -- @ExtraArgs | Out-Host
        } else {
            & dotnet run --project $ProjectDir --no-build | Out-Host
        }
        if ($null -ne $LASTEXITCODE) { $nativeExit = $LASTEXITCODE }
    } finally {
        Pop-Location
    }
    return [int]$nativeExit
}

# 返回构建（写回）阶段缺少的文件列表
function Test-BuildInputs {
    $required = New-Object System.Collections.ArrayList
    [void]$required.Add([pscustomobject]@{ Rel = 'shared_text.txt';       Desc = '两种字库共享字符表';       Fix = '在 romhack\ 新建 shared_text.txt，逐行（或连续）列出必须共用编码的字符。' })
    [void]$required.Add([pscustomobject]@{ Rel = 'rom_text_zh_CN.json';   Desc = '小字库 / 内嵌文本翻译';      Fix = '先 RIP 得到 rom_text.json，把译文填进 translation 后另存为 romhack\rom_text_zh_CN.json。' })
    [void]$required.Add([pscustomobject]@{ Rel = 'zh_CN_translated.json'; Desc = '对话框文本翻译';             Fix = '先 RIP 得到 zh_CN.json，把译文填进 translation 后另存为 romhack\zh_CN_translated.json。' })
    [void]$required.Add([pscustomobject]@{ Rel = 'rom2.xml';              Desc = 'ISO 打包清单';              Fix = '确认 romhack\rom2.xml 存在（仓库自带，勿删）。' })
    [void]$required.Add([pscustomobject]@{ Rel = 'pic_output';            Desc = 'RIP 提取的原始图片目录';     Fix = '运行本脚本自动 RIP 生成。' })
    if (-not $SkipImages) {
        [void]$required.Add([pscustomobject]@{ Rel = 'pic_output_translated'; Desc = '翻译后的图片目录'; Fix = '把想汉化的 GIF 按相同相对路径放进 pic_output_translated（保持文件名 / 尺寸 / 8bpp 索引色），.act 可选一起复制；或加 -SkipImages 只构建文本。' })
    }
    @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RomhackDir $_.Rel)) })
}

# ------------------------------------------------------------
# 4. 判断是否已经 RIP
# ------------------------------------------------------------
Write-Step '检查是否已经 RIP'
# RIP 的产物：rom\ 下的游戏文件 + pic_output\ 提取图片
$ripMarkers = @(
    'rom\SLPS_025.42',
    'rom\CM1100.DAT',
    'rom\CM1200.DAT',
    'pic_output'
)
$missingRip = @($ripMarkers | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RomhackDir $_)) })

function Test-RipComplete {
    @($ripMarkers | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RomhackDir $_)) })
}

if ($missingRip.Count -eq 0) {
    Write-Ok '已检测到 RIP 产物，跳过 RIP'
} else {
    Write-Note ("尚未 RIP（缺少：" + ($missingRip -join '、') + '）')
}

if ($CheckOnly) {
    # 只检查模式：报告 RIP 状态和缺少的构建文件，不做任何修改
    Write-Step '检查构建（写回）所需文件'
    $missingNow = @(Test-BuildInputs)
    if ($missingNow.Count -gt 0) {
        Write-Host '缺少以下文件：' -ForegroundColor Red
        foreach ($r in $missingNow) { Write-Err "$($r.Desc)：romhack\$($r.Rel)" $r.Fix }
        Write-Host ''
        Write-Host '检查未通过（-CheckOnly，未执行构建）。' -ForegroundColor Red
        exit 1
    }
    Write-Ok '构建所需文件齐全'
    Write-Host ''
    Write-Host '检查通过（-CheckOnly，未编译、未执行）。' -ForegroundColor Green
    exit 0
}

# ------------------------------------------------------------
# 5. 需要则先执行 RIP
# ------------------------------------------------------------
if ($missingRip.Count -gt 0) {
    Invoke-BuildProject
    Write-Step '执行 RIP（解包 ISO、提取文本与图片）'
    Write-Host '正在调用 dumpsxiso 解包，可能耗时较久，请耐心等待……' -ForegroundColor Yellow
    $code = Invoke-Pipeline -ExtraArgs @('--rip')
    if ($code -ne 0) {
        Stop-WithError "RIP 失败（返回码 $code）。" `
            '检查 config.json 的 GamePath / SDKPath；查看上面的错误输出。'
    }
    $stillMissing = @(Test-RipComplete)
    if ($stillMissing.Count -gt 0) {
        Stop-WithError ("RIP 结束后仍缺少：" + ($stillMissing -join '、')) `
            '查看上面的 RIP 日志，确认原版 ISO 完整、dumpsxiso 可正常运行。'
    }
    Write-Ok 'RIP 完成：rom\ 已生成，文本与图片已提取'
    Write-Host ''
    Write-Host '按设定，RIP 完成后不再继续封包。' -ForegroundColor Yellow
    Write-Host '接下来请先翻译：' -ForegroundColor Yellow
    Write-Host '  - zh_CN.json / processed\ -> zh_CN_translated.json（填 processed\ 后运行 apply_text.bat）'
    Write-Host '  - rom_text.json   -> rom_text_zh_CN.json'
    Write-Host '  - pic_output\     -> pic_output_translated\（把想汉化的图按相同路径放进去）'
    Write-Host '翻译完成后重新运行本脚本，即可编译并封包生成 ISO。' -ForegroundColor Yellow
    exit 0
}

# ------------------------------------------------------------
# 6. 检查构建（写回）所需文件
# ------------------------------------------------------------
Write-Step '检查构建（写回）所需文件'
$missing = @(Test-BuildInputs)
if ($missing.Count -gt 0) {
    Write-Host '缺少以下文件，无法开始构建：' -ForegroundColor Red
    foreach ($r in $missing) { Write-Err "$($r.Desc)：romhack\$($r.Rel)" $r.Fix }
    Write-Host ''
    Write-Host '脚本已停止，请补齐上述文件后重新运行。' -ForegroundColor Red
    exit 1
}
Write-Ok '构建所需文件齐全'

# ------------------------------------------------------------
# 7. 编译并执行构建
# ------------------------------------------------------------
Invoke-BuildProject

Write-Step '执行构建（写回文本 / 字库 / 图片并打包 ISO）'
$code = Invoke-Pipeline
if ($code -ne 0) {
    Stop-WithError "构建失败（返回码 $code）。" `
        '查看上面的错误信息，常见原因见 README.md 的“常见问题”。'
}

# ------------------------------------------------------------
# 8. 完成
# ------------------------------------------------------------
Write-Step '完成'
$cue = Join-Path $RomhackDir 'output\Summon_Night_Chinese.cue'
$bin = Join-Path $RomhackDir 'output\Summon_Night_Chinese.bin'
if (Test-Path -LiteralPath $cue) {
    Write-Ok "已生成：$cue"
} else {
    Write-Note "未找到 $cue，请检查上面的输出。"
}
if (Test-Path -LiteralPath $bin) {
    Write-Ok "已生成：$bin"
}
Write-Host ''
Write-Host '用模拟器加载上面的 .cue 即可测试中文版。' -ForegroundColor Green
exit 0
