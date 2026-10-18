@echo off
rem yuri for cmd.exe. PowerShell runs yuri.ps1 directly instead.
powershell.exe -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%~dp0yuri.ps1" %*
exit /b %ERRORLEVEL%
