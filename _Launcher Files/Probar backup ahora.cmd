@echo off
rem SPDX-License-Identifier: GPL-3.0-only
rem Copyright (C) 2026 SrFrogo
chcp 65001 >nul
title Prueba de backup - LET IT DIE

echo Esta prueba no abre el juego. LET IT DIE debe estar cerrado.
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher.ps1" -BackupOnly
set "LID_EXIT=%ERRORLEVEL%"

echo.
pause
exit /b %LID_EXIT%
