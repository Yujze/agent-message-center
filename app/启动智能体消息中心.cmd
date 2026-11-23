@echo off
start "" pwsh.exe -NoLogo -NoProfile -STA -WindowStyle Hidden -File "%~dp0Start-Reminder.ps1" -CodexLocal
