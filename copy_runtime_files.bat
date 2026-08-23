@echo off
setlocal
rem Copy runtime data files needed by SummonNightTool from this repo's
rem romhack\ directory into ..\summon_night_bizhawk\BizHawk\ExternalTools\.
rem Uses relative paths. The DLL itself is NOT touched.

cd /d "%~dp0"

set "SRC=romhack"
set "DEST=..\summon_night_bizhawk\BizHawk\ExternalTools"

if not exist "%SRC%\output\fid_first64.json" goto :missing
if not exist "%SRC%\output\chinese_font_map.json" goto :missing
if not exist "%SRC%\rom\chinese.fnt" goto :missing
if not exist "%SRC%\rom\S.F" goto :missing
if not exist "%SRC%\zh_CN_translated.json" goto :missing

if not exist "%DEST%" mkdir "%DEST%"

copy /Y "%SRC%\output\fid_first64.json"        "%DEST%\" >nul
copy /Y "%SRC%\output\chinese_font_map.json"   "%DEST%\" >nul
copy /Y "%SRC%\rom\chinese.fnt"                "%DEST%\" >nul
copy /Y "%SRC%\rom\S.F"                        "%DEST%\" >nul
copy /Y "%SRC%\zh_CN_translated.json"          "%DEST%\" >nul

echo Runtime files copied to %DEST%:
echo   fid_first64.json
echo   chinese_font_map.json
echo   chinese.fnt
echo   S.F
echo   zh_CN_translated.json
exit /b 0

:missing
echo ERROR: source data file not found under %SRC%\. Aborting.
exit /b 1
