<#
.SYNOPSIS
    desactiva.ps1 - Remueve la persistencia y limpia el entorno para jugar libremente.
.DESCRIPTION
    Elimina la tarea programada de vigilancia (nueva y antigua, si apuntan al
    motor), las reglas de firewall y el archivo camuflado de System32.
#>
# ===================== AUTO-ARRANQUE POWERSHELL 7 =====================
# Valida PowerShell 7 y, si falta, lo instala (winget o MSI oficial firmado
# por Microsoft) y relanza este script conservando TODOS los parametros.
# Correcciones sobre la version anterior:
#   - Comprueba Administrador ANTES de intentar instalar (antes el error era
#     "no se pudo instalar" y nunca se veia "Requiere Administrador").
#   - Refresca el PATH tras instalar (antes pwsh quedaba instalado y no se veia).
#   - Verifica la firma digital del MSI antes de ejecutarlo.
#   - Relanza con -EncodedCommand (base64): con -File los arrays llegaban
#     como un unico literal y con -Command se perdian las comillas dobles.
#   - Version de respaldo sin red actualizada a 7.6.6 (antes 7.4.6).
if ($PSVersionTable.PSVersion.Major -lt 7) {

    function Buscar-Pwsh {
        $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd }
        foreach ($cand in @("$env:ProgramFiles\PowerShell\7\pwsh.exe", "${env:ProgramFiles(x86)}\PowerShell\7\pwsh.exe", "$env:LOCALAPPDATA\PowerShell\7\pwsh.exe")) {
            if ($cand -and (Test-Path $cand)) {
                $cmd = Get-Command $cand -ErrorAction SilentlyContinue
                if ($cmd) { return $cmd }
            }
        }
        return $null
    }

    function Actualizar-Path {
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    }

    $pwshCmd = Buscar-Pwsh

    if (-not $pwshCmd) {
        # ---------------- INSTALACION (requiere Administrador) ----------------
        $esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $esAdmin) {
            Write-Host "  PowerShell 7 no esta instalado y se necesita Administrador para instalarlo." -ForegroundColor Yellow
            Write-Host "  Abre la terminal como Administrador y vuelve a ejecutar este script, o" -ForegroundColor Yellow
            Write-Host "  instalalo manualmente:  winget install --id Microsoft.PowerShell" -ForegroundColor Yellow
            exit 1
        }

        Write-Host "  PowerShell 7 no detectado. Instalando..." -ForegroundColor Yellow
        $instalado = $false

        # 1) winget (via rapida)
        $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
        if (-not $wingetCmd) {
            $waAlias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
            if (Test-Path $waAlias) { $wingetCmd = $waAlias }
        }
        if ($wingetCmd) {
            try {
                & $wingetCmd install --id Microsoft.PowerShell --source winget --accept-source-agreements --accept-package-agreements --silent | Out-Null
            } catch {}
            Actualizar-Path
            $pwshCmd = Buscar-Pwsh
            if ($pwshCmd) { $instalado = $true }
        }

        # 2) MSI oficial desde GitHub: ultima version publicada + respaldo fijo
        if (-not $instalado) {
            $versiones = @()
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                $rel = Invoke-RestMethod 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -Headers @{ 'User-Agent' = 'ps7-bootstrap' } -TimeoutSec 20
                $tag = "$($rel.tag_name)" -replace '^v', ''
                if ($tag) { $versiones += @{ Tag = $tag; Url = "https://github.com/PowerShell/PowerShell/releases/download/v$tag/PowerShell-$tag-win-x64.msi" } }
            } catch {}
            $versiones += @{ Tag = '7.6.6'; Url = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/PowerShell-7.6.6-win-x64.msi' }

            foreach ($v in $versiones) {
                $msi = Join-Path $env:TEMP "PowerShell-$($v.Tag)-win-x64.msi"
                try {
                    if (-not (Test-Path $msi)) {
                        Invoke-WebRequest $v.Url -OutFile $msi -UseBasicParsing -TimeoutSec 180
                    }
                    $firma = Get-AuthenticodeSignature -FilePath $msi
                    if ($firma.Status -ne 'Valid' -or $firma.SignerCertificate.Subject -notmatch 'Microsoft') {
                        Write-Host "  MSI $($v.Tag) rechazado: firma no valida ($($firma.Status))." -ForegroundColor Red
                        Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
                        continue
                    }
                    Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /quiet /norestart" -Wait
                    Actualizar-Path
                    $pwshCmd = Buscar-Pwsh
                    if ($pwshCmd) { $instalado = $true; break }
                } catch {}
            }
        }

        if (-not $instalado -or -not $pwshCmd) {
            Write-Host "  No se pudo instalar PowerShell 7." -ForegroundColor Red
            Write-Host "  Instalalo manualmente:  winget install --id Microsoft.PowerShell" -ForegroundColor Yellow
            exit 1
        }
    }

    # ---------------- RELANZADO CONSERVANDO PARAMETROS ----------------
    # -EncodedCommand (base64): las comillas, espacios, $ y acentos viajan
    # codificados, asi que no hay forma de que la linea de comandos los rompa.
    $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.InvocationName }
    $parametros = foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) {
            if ($v) { "-$k" }
        } elseif ($v -is [array]) {
            # Array vacio: no se emite nada (el hijo usa su valor por defecto)
            $elementos = @($v | ForEach-Object { ("$_" -replace "'", "''") })
            if ($elementos.Count -gt 0) { "-$k '" + ($elementos -join "','") + "'" }
        } else {
            "-$k '" + ("$v" -replace "'", "''") + "'"
        }
    }
    $comando = "& '$("$scriptPath" -replace "'", "''")' $($parametros -join ' ')"
    $codificado = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($comando))
    & $pwshCmd.Source -NoProfile -ExecutionPolicy Bypass -EncodedCommand $codificado
    exit $LASTEXITCODE
}
# =================== FIN AUTO-ARRANQUE POWERSHELL 7 ===================

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "CRÍTICO: Ejecuta este script como ADMINISTRADOR."
    exit 1
}

# 1. Tumbar las tareas programadas (nueva y antigua, si apuntan a nuestro motor)
$NombresTarea = @("JoseOrozco\RobloxWatchdog", "Microsoft\Windows\Cryptography\KeySvc")
foreach ($nombre in $NombresTarea) {
    $Tarea = Get-ScheduledTask -TaskName $nombre -ErrorAction SilentlyContinue
    if ($Tarea -and $Tarea.Actions.Arguments -like "*Aislamiento_Core.ps1*") {
        Unregister-ScheduledTask -TaskName $nombre -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "[OK] Tarea eliminada: $nombre" -ForegroundColor Green
    }
}

# 2. Limpiar bloqueos del Firewall en caliente
Get-NetFirewallRule -DisplayName "WinHost_Telemetry_NetBios_*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue

# 3. Eliminar el archivo camuflado de System32
if (Test-Path "C:\Windows\System32\Aislamiento_Core.ps1") {
    Remove-Item "C:\Windows\System32\Aislamiento_Core.ps1" -Force -ErrorAction SilentlyContinue
}

Write-Host "[OK] Sistema desarmado. Roblox está libre de restricciones." -ForegroundColor Green
