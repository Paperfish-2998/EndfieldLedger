@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0EndfieldLedger.ps1" %*
if "%~1"=="" pause