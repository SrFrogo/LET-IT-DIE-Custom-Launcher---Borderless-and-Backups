@echo off
rem SPDX-License-Identifier: GPL-3.0-only
rem Copyright (C) 2026 SrFrogo
chcp 65001 >nul
title LET IT DIE Custom Launcher v2.3
set "SCRIPT=%~dp0_Launcher Files\launcher.ps1"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "EXITCODE=%ERRORLEVEL%"
echo.
if not "%EXITCODE%"=="0" pause
exit /b %EXITCODE%
