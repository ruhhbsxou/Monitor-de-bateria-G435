@echo off
setlocal
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0G435BatteryMonitor.ps1"
if errorlevel 1 (
    echo Nao foi possivel iniciar o monitor. Verifique se o Windows PowerShell esta disponivel.
    pause
)
