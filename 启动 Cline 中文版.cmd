@echo off
chcp 65001 >nul
title Cline 中文版启动器

rem 路径探测 / 调试端口 / 注入器 / 本地代理统一由 launch-silent.vbs 维护，
rem 这里不再重复实现（旧版本写死 ..\cline-app.exe 与 9333 端口，已失效）。
if not exist "%~dp0launch-silent.vbs" (
  echo [cline-zh] 找不到 launch-silent.vbs，无法启动。
  pause
  exit /b 1
)

wscript.exe //B //Nologo "%~dp0launch-silent.vbs"

rem 等约 5 秒后用 ping 代替 timeout（timeout 不支持重定向输入）
ping -n 6 127.0.0.1 >nul
tasklist /FI "IMAGENAME eq cline-app.exe" /NH 2>nul | find /I "cline-app.exe" >nul
if errorlevel 1 (
  echo [cline-zh] 启动失败：未检测到 cline-app.exe。
  echo           请确认 Cline 已正确安装，或手动运行 launch-silent.vbs 排查。
  pause
  exit /b 1
)

echo [cline-zh] 已启动 Cline 中文版。
exit /b 0
