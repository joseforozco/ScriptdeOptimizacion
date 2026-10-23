<#
.SYNOPSIS
    activa.ps1 - Copia el motor y levanta la persistencia de vigilancia de Roblox.
.DESCRIPTION
    Copia Nadaderoblox.ps1 a System32 y registra una tarea programada bajo
    SYSTEM que se ejecuta cada 5 minutos para hacer cumplir el límite de uso.
    Usa una carpeta de tarea propia (JoseOrozco) para no colisionar con tareas
    reales de Windows como "Microsoft\Windows\Cryptography\KeySvc".
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

$RutaOrigenMotor = Join-Path $PSScriptRoot "Nadaderoblox.ps1"
$RutaDestinoOculta = "C:\Windows\System32\Aislamiento_Core.ps1"
$NombreTarea = "JoseOrozco\RobloxWatchdog"
$TareaVieja = "Microsoft\Windows\Cryptography\KeySvc"

# 1. Copiar el motor al lugar lejano de Windows
if (-not (Test-Path $RutaOrigenMotor)) {
    Write-Error "No se encontró el archivo Nadaderoblox.ps1 en el directorio actual."
    exit 1
}
Copy-Item -Path $RutaOrigenMotor -Destination $RutaDestinoOculta -Force
Write-Host "[OK] Motor camuflado en el sistema." -ForegroundColor Green

# 2. Migración segura: eliminar la tarea antigua SOLO si apuntaba a nuestro motor
$TareaViejaExiste = Get-ScheduledTask -TaskName $TareaVieja -ErrorAction SilentlyContinue
if ($TareaViejaExiste -and $TareaViejaExiste.Actions.Arguments -like "*Aislamiento_Core.ps1*") {
    Unregister-ScheduledTask -TaskName $TareaVieja -Confirm:$false
    Write-Host "[OK] Tarea antigua ($TareaVieja) removida." -ForegroundColor Green
}

# 3. Registrar la tarea periódica profunda como SYSTEM
$Accion = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $RutaDestinoOculta"
$Disparador = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration ([TimeSpan]::MaxValue)
$Configuracion = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

Register-ScheduledTask -TaskName $NombreTarea `
                       -Action $Accion `
                       -Trigger $Disparador `
                       -Settings $Configuracion `
                       -User "NT AUTHORITY\SYSTEM" `
                       -RunLevel Highest -Force | Out-Null

Write-Host "[OK] Vigilancia ACTIVA (revisa cada 5 min). Límite: 10 min de Roblox por sesión." -ForegroundColor Cyan
