@echo off
REM OPC V7 fallback launcher. Same app as OPC-V7.exe.
REM The script asks for administrator rights by itself.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0OPC-V7.ps1"
