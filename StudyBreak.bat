@echo off
title Study Break Signal
:: If compiled fast binary exists and no flags were passed, run it directly (<30ms launch time)
if "%~1"=="" if exist "%~dp0StudyBreak.exe" (
    start "" "%~dp0StudyBreak.exe"
    exit /b
)
:: Otherwise run PowerShell launcher with arguments forwarded
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0StudyBreak.ps1" %*
