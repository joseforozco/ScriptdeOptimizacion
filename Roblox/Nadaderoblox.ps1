<#
.SYNOPSIS
    Nadaderoblox.ps1 - Motor de monitoreo cíclico del uso de Roblox.
.DESCRIPTION
    Si Roblox lleva más de N minutos corriendo, bloquea la salida a Internet de
    sus ejecutables mediante reglas de firewall. Al cerrarse el juego, las reglas
    se eliminan para que el siguiente inicio parta limpio.
#>
# ================= VALIDACION POWERSHELL 7 (watchdog) =================
# Solo relanza en PowerShell 7 si esta disponible. No instala nada aqui
# para no bloquear la tarea programada cada 5 minutos.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $pwshCmd) {
        # pwsh fuera del PATH: buscar en rutas estandar de instalacion
        foreach ($cand in @("$env:ProgramFiles\PowerShell\7\pwsh.exe", "${env:ProgramFiles(x86)}\PowerShell\7\pwsh.exe", "$env:LOCALAPPDATA\PowerShell\7\pwsh.exe")) {
            if ($cand -and (Test-Path $cand)) { $pwshCmd = Get-Command $cand -ErrorAction SilentlyContinue; break }
        }
    }
    if ($pwshCmd) {
        $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.InvocationName }
        & $pwshCmd.Source -NoProfile -ExecutionPolicy Bypass -File $scriptPath
        exit $LASTEXITCODE
    }
}
# =============== FIN VALIDACION POWERSHELL 7 (watchdog) ===============

$ProcesoTarget = "RobloxPlayerBeta"
$RutaTarget = "$env:LocalAppData\Roblox"
$TiempoLimiteMinutos = 10

function Get-NombreRegla {
    param([string]$NombreExe)
    $sinExtension = [System.IO.Path]::GetFileNameWithoutExtension($NombreExe)
    return "WinHost_Telemetry_NetBios_($sinExtension)"
}

$JuegoActivo = Get-Process -Name $ProcesoTarget -ErrorAction SilentlyContinue

if ($JuegoActivo) {
    $PrimerProceso = if ($JuegoActivo -is [array]) { $JuegoActivo[0] } else { $JuegoActivo }
    $MinutosCorriendo = ((Get-Date) - $PrimerProceso.StartTime).TotalMinutes

    if ($MinutosCorriendo -ge $TiempoLimiteMinutos) {
        if (Test-Path -Path $RutaTarget) {
            $Binarios = Get-ChildItem -Path $RutaTarget -Filter *.exe -Recurse -ErrorAction SilentlyContinue
            foreach ($App in $Binarios) {
                $NombreRegla = Get-NombreRegla -NombreExe $App.Name
                if (-not (Get-NetFirewallRule -DisplayName $NombreRegla -ErrorAction SilentlyContinue)) {
                    try {
                        New-NetFirewallRule -DisplayName $NombreRegla `
                                            -Direction Outbound `
                                            -Program $App.FullName `
                                            -RemoteAddress Internet `
                                            -Action Block `
                                            -Profile Any `
                                            -Description "Windows Host Telemetry network synchronization subsystem connection restriction." `
                                            -ErrorAction Stop
                    } catch {}
                }
            }
        }
    }
} else {
    # Si el juego se cierra, limpia las reglas para el siguiente reinicio
    if (Test-Path -Path $RutaTarget) {
        $Binarios = Get-ChildItem -Path $RutaTarget -Filter *.exe -Recurse -ErrorAction SilentlyContinue
        foreach ($App in $Binarios) {
            $NombreRegla = Get-NombreRegla -NombreExe $App.Name
            if (Get-NetFirewallRule -DisplayName $NombreRegla -ErrorAction SilentlyContinue) {
                Remove-NetFirewallRule -DisplayName $NombreRegla -ErrorAction SilentlyContinue
            }
        }
    }
}
