@echo off
title Cline 官方更新后 - 重新汉化 + 重打 sidecar 补丁
echo.
echo  ============================================================
echo    本脚本【不会升级 Cline】，请先在 Cline 里完成官方更新
echo  ============================================================
echo.
echo  正确用法：
echo    1) 在 Cline 界面里更新到新版本
echo    2) 再运行本脚本 —— 它会检出对应版本源码、编译 sidecar、
echo       打 AVX2 补丁、恢复汉化、同步固定副本并重启验证
echo.
echo  重要：第 1 步和第 2 步之间不要直接运行 cline-app.exe。
echo        官方 sidecar 在本机（CPU 不支持 AVX2）无法运行。
echo.
echo  前提：Cline 设置里的【自动更新】需保持关闭。
echo.
echo  将自动完成：
echo    1) 前置检查（自动更新守卫 / 代理 / connector 快照）
echo    2) 检测本机 CPU 是否需要 AVX2 补丁
echo    3) 考证官方该版本是否已修复（决定是否还要编译）
echo    4) 检出对应版本源码并编译 sidecar
echo    5) 备份并替换 + 同步固定副本
echo    6) 用中文版启动器重启并验证
echo    7) 验证 Telegram connector 是否自动恢复
echo    8) 清理临时文件与陈旧备份
echo.
echo  注意：过程中 Cline 会被关闭并重新启动，请先保存工作。
echo.
pause
powershell -ExecutionPolicy Bypass -File "%~dp0upgrade-cline-zh.ps1" %*
echo.
echo 按任意键关闭...
pause >nul
