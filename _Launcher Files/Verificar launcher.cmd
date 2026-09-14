@echo off
chcp 65001 >nul
title Verificar LET IT DIE Custom Launcher v2.3

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher.ps1" -SelfTest
set "LID_EXIT=%ERRORLEVEL%"

echo.
pause
exit /b %LID_EXIT%
