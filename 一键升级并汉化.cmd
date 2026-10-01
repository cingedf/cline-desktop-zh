@echo off
chcp 65001 >nul
title Cline 升级后一键汉化
echo.
echo  ============================================================
echo    Cline 官方升级后，运行本脚本即可重新汉化 + 重打补丁
echo  ============================================================
echo.
echo  将自动完成：
echo    1) 检测本机 CPU 是否需要 AVX2 补丁
echo    2) 考证官方该版本是否已修复（决定是否还要编译）
echo    3) 检出对应版本源码并编译 sidecar
echo    4) 备份并替换 + 同步固定副本
echo    5) 用中文版启动器重启并验证
echo    6) 清理临时文件与陈旧备份
echo.
echo  注意：过程中 Cline 会被关闭并重新启动，请先保存工作。
echo.
pause
powershell -ExecutionPolicy Bypass -File "%~dp0upgrade-cline-zh.ps1" %*
echo.
echo 按任意键关闭...
pause >nul
