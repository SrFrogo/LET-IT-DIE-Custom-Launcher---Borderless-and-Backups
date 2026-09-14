@echo off
rem SPDX-License-Identifier: GPL-3.0-only
rem Copyright (C) 2026 SrFrogo
chcp 65001 >nul
title Google Drive - LET IT DIE Custom Launcher
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0_Launcher Files\configurar-drive.ps1"
set "EXITCODE=%ERRORLEVEL%"
echo.
pause
exit /b %EXITCODE%
