@echo off
rem ============================================================
rem  AsignaH.bat - Lanzador (migrado a PowerShell + CIM)
rem  El trabajo real lo hace AsignaH.ps1:
rem    - Detecta la unidad con CIM (sin wmic, eliminado en W11 24H2+)
rem    - Cambia la letra con Set-CimInstance / diskpart de respaldo
rem  Si falta PowerShell 7, el script lo instala por winget.
rem  Original con wmic: AsignaH_legacy_wmic.bat
rem ============================================================
set "SCRIPT=%~dp0AsignaH.ps1"
if not exist "%SCRIPT%" (
    echo ERROR: No se encontro AsignaH.ps1 junto a este lanzador.
    pause
    exit /b 1
)

where pwsh >nul 2>&1
if %ERRORLEVEL%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
)
pause
