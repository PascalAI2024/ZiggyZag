@echo off
REM Double-clickable wrapper around scripts/doctor-desktop.ps1.
REM Diagnoses (and optionally repairs) a ZiggyZag Windows install.
REM Run `doctor.bat` for a dry pass; run `doctor.bat -Launch` to start the
REM desktop afterward. See scripts/doctor-desktop.ps1 for the full options
REM and docs/reviews/2026-05-17-windows-debug.md for the bugs it diagnoses.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\doctor-desktop.ps1" %*
pause
