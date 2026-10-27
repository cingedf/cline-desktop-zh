@echo off
chcp 65001 >nul
title Cline 官方更新后 - 重新汉化
echo.
echo  ============================================================
echo    本脚本【不会升级 Cline】，请先在 Cline 里完成官方更新
echo  ============================================================
echo.
echo  正确用法：
echo    1) 在 Cline 界面里更新到新版本
echo    2) 再运行本脚本 —— 它会识别后端类型、按需打补丁、
echo       补齐 WebView2 调试端口、恢复汉化并重启验证
echo.
echo  前提：Cline 设置里的【自动更新】需保持关闭。
echo.
echo  将自动完成：
echo    1) 前置检查（自动更新守卫 / 代理 / connector 快照）
echo    2) 识别后端：0.0.49 起为 cline-cli.exe，实证能否直接运行
echo    3) 仅在需要补丁时才检出源码并编译 code-sidecar
echo    4) 确保 WebView2 调试端口（汉化注入的前提）
echo    5) 备份、用中文版启动器重启并验证后端存活
echo    6) 验证汉化生效 + Telegram connector 恢复
echo    7) 清理临时文件与陈旧备份
echo.
echo  注意：需要打补丁时 Cline 会被关闭并重新启动，请先保存工作。
echo.
pause
powershell -ExecutionPolicy Bypass -File "%~dp0upgrade-cline-zh.ps1" %*
echo.
echo 按任意键关闭...
pause >nul
