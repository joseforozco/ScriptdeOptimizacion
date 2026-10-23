<#
.SYNOPSIS
    Suite de herramientas IT para administracion de equipos.
.DESCRIPTION
    Script unificado con funciones generales reutilizables.
.PARAMETER Tool
    Herramienta a ejecutar. Sin parametro = menu interactivo.
.EXAMPLE
    .\HerramientasIT.ps1
    .\HerramientasIT.ps1 -Tool Borrado
#>
[CmdletBinding()]
param(
    [ValidateSet("BloquearTodo","BloquearWPS","Borrado","BorrarDuplicados","MoverArchivos",
                 "OrganizaFuentes","QuitarG","QuitarZip","RepararPerfil",
                 "ReporteNAS","ReubicarInstaladores","Menu")]
    [string]$Tool = "Menu",

    # Con '-SinElevar' no se pide UAC: el script sigue como esta y cada
    # herramienta avisa si necesita Administrador. Es lo que hace falta cuando
    # lo lanza una tarea, o cuando el usuario prefiere abrir la terminal
    # elevada por su cuenta.
    [switch]$SinElevar
)


# ===================== AUTO-ARRANQUE POWERSHELL 7 =====================
# Valida PowerShell 7 y, si falta, lo instala (winget o MSI oficial firmado
# por Microsoft) y relanza este script conservando TODOS los parametros.
# En este mismo bloque viven la comprobacion de Administrador ('Test-EsAdmin')
# y la elevacion ('Invoke-Elevacion'), para que no haya dos reglas distintas.
#
# Correcciones sobre la version anterior:
#   - 'Get-Pwsh7' mira la VERSION del binario, no solo que exista: con un
#     'pwsh' 6.x instalado el relanzado era un bucle infinito, porque cada
#     arranque volvia a encontrar el mismo y volvia a relanzar.
#   - Marca de entorno '_PS7_RELANZADO' como red de seguridad de ese bucle.
#   - '$ProgressPreference' a 'SilentlyContinue' mientras se descarga: en 5.1
#     la barra de progreso de 'Invoke-WebRequest' cuesta ~10x con un MSI de
#     ~110 MB. Se restaura antes de relanzar para no ocultar el
#     'Write-Progress' propio de las herramientas.
#   - App Installer se descarga por la via oficial ('aka.ms/getwinget'), con
#     la API de GitHub como respaldo.
#   - 'winget install -e': sin '-e' el ID se busca por coincidencia difusa.
#   - MSI: arquitectura real del equipo (x64/arm64), 10 minutos de descarga en
#     vez de 3, y se comprueba el codigo de salida de 'msiexec'.
#   - Se avisa si 'pwsh' no llega a arrancar (antes se salia con codigo 0).
#   - Version de respaldo sin red actualizada a 7.6.7 (antes 7.6.6).

# Parametros con los que se llamo a este script. Los necesitan el relanzado y
# la elevacion: dentro de una funcion, 'PSBoundParameters' es el de la funcion.
$script:ParametrosLlamada = $PSBoundParameters

# Ruta absoluta de este script: es lo que se relanza y lo que se eleva.
$script:RutaPropia = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }

function Get-CadenaInvocacion {
    # Reconstruye "& 'script.ps1' -Param1 'valor' -Switch" a partir de los
    # parametros recibidos.
    param([string]$RutaScript, [System.Collections.IDictionary]$Parametros)
    $partes = foreach ($k in @($Parametros.Keys)) {
        $v = $Parametros[$k]
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
    return ("& '" + ("$RutaScript" -replace "'", "''") + "' " + ($partes -join ' ')).TrimEnd()
}

function Get-ComandoCodificado {
    # -EncodedCommand en base64 UTF-16LE: comillas, espacios, $ y acentos
    # viajan codificados, asi que la linea de comandos no puede romperlos
    # (con -File los arrays llegaban como un unico literal y con -Command se
    # perdian las comillas dobles).
    param([string]$Comando)
    return [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Comando))
}

function Test-EsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Elevacion {
    # Relanza este script elevado (UAC) con los mismos parametros y la misma
    # carpeta de trabajo. Devuelve $true si el llamante debe parar el proceso
    # actual porque ya se relanzo, y $false si no se ha elevado.
    if (Test-EsAdmin) { return $false }

    if (-not $script:RutaPropia) {
        Write-Host "  Se necesita Administrador, pero no se sabe la ruta de este script" -ForegroundColor Red
        Write-Host "  (se ha invocado sin fichero en disco). Abre una terminal como" -ForegroundColor Yellow
        Write-Host "  Administrador y ejecutalo desde su ruta." -ForegroundColor Yellow
        return $false
    }

    # Red de seguridad: si ya se intento elevar en este arbol de procesos y
    # seguimos sin ser Administrador, no se repite el UAC.
    if ([Environment]::GetEnvironmentVariable('_PS7_ELEVADO')) {
        Write-Host "  Ya se intento la elevacion y no se es Administrador. Se para." -ForegroundColor Red
        return $false
    }

    Write-Host ""
    Write-Host "  Este script necesita Administrador." -ForegroundColor Yellow
    Write-Host "  Pidiendo elevacion (UAC): el script continuara en una ventana nueva." -ForegroundColor Yellow

    # Se relanza el MISMO interprete que esta corriendo, no 'pwsh' a secas: si
    # esto aun corre en Windows PowerShell 5.1, la ventana elevada sera 5.1, y
    # sera ella la que instale PowerShell 7 con permisos.
    $nuevoPwsh = (Get-Process -Id $PID).Path
    if (-not $nuevoPwsh -or -not (Test-Path -LiteralPath $nuevoPwsh)) { $nuevoPwsh = Join-Path $PSHOME 'pwsh.exe' }

    $destino = (Get-Location).ProviderPath
    $comando = "Set-Location -LiteralPath '" + ($destino -replace "'", "''") + "'; " +
               (Get-CadenaInvocacion -RutaScript $script:RutaPropia -Parametros $script:ParametrosLlamada)

    $env:_PS7_ELEVADO = '1'
    try {
        Start-Process -FilePath $nuevoPwsh -Verb RunAs -ErrorAction Stop -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', (Get-ComandoCodificado $comando)
        ) | Out-Null
    } catch {
        Write-Host "  No se pudo elevar: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Abre la terminal como Administrador y vuelve a ejecutar este script." -ForegroundColor Yellow
        return $false
    }
    return $true
}

# ---------------- ADMINISTRADOR (antes que el motor) ----------------
# Va ANTES del arranque de PowerShell 7 a proposito: instalar PowerShell 7
# necesita Administrador, asi que no tiene sentido enterarse despues. El orden
# es: primero permisos, luego el motor.
if (-not (Test-EsAdmin)) {
    if ($SinElevar) {
        # Una sola vez: este bloque se ejecuta en 5.1 y otra vez en el pwsh 7
        # relanzado, y sin la marca el aviso salia por duplicado.
        if (-not [Environment]::GetEnvironmentVariable('_SIN_ELEVAR_AVISADO')) {
            $env:_SIN_ELEVAR_AVISADO = '1'
            Write-Host "  Sin Administrador (-SinElevar): se continua, pero las tareas que" -ForegroundColor Yellow
            Write-Host "  necesiten permisos avisaran y no haran nada." -ForegroundColor Yellow
        }
    } else {
        if (Invoke-Elevacion) { exit 0 }
        exit 1
    }
}

if ($PSVersionTable.PSVersion.Major -lt 7) {

    function Test-EsPwsh7 {
        # $true solo si la ruta apunta a un 'pwsh' que es de verdad la 7 o
        # superior. Comprobar la version es lo que evita el bucle con un
        # 'pwsh' 6.x y con los alias rotos de 'WindowsApps'.
        param([string]$Ruta)
        if (-not $Ruta -or -not (Test-Path -LiteralPath $Ruta)) { return $false }
        # 1) Barato: el numero grabado en el propio ejecutable.
        try {
            $fvi = [Diagnostics.FileVersionInfo]::GetVersionInfo($Ruta)
            if ($fvi.ProductMajorPart -ge 7) { return $true }
        } catch {}
        # 2) Exacto: se lo preguntamos al binario. Cubre los shims y los
        #    ejecutables que no llevan el numero en la cabecera.
        try {
            $v = & $Ruta -NoProfile -NonInteractive -Command '[int]$PSVersionTable.PSVersion.Major' 2>$null
            return (([int]($v | Select-Object -First 1)) -ge 7)
        } catch { return $false }
    }

    function Get-Pwsh7 {
        # Ruta de un 'pwsh.exe' de la version 7 o superior, o $null.
        $candidatos = @()
        $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) { $candidatos += $cmd.Source }
        $candidatos += @(
            "$env:ProgramFiles\PowerShell\7\pwsh.exe",
            "${env:ProgramFiles(x86)}\PowerShell\7\pwsh.exe",
            "$env:LOCALAPPDATA\PowerShell\7\pwsh.exe"
        )
        foreach ($c in ($candidatos | Where-Object { $_ } | Select-Object -Unique)) {
            if (Test-EsPwsh7 $c) { return $c }
        }
        return $null
    }

    function Actualizar-Path {
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    }

    # winget no puede instalarse a si mismo, asi que si falta se instala el
    # paquete App Installer (Microsoft.DesktopAppInstaller) con Add-AppxPackage,
    # usando el .msixbundle oficial y sus tres dependencias (VCLibs y .NET
    # Native 2.2) publicadas en aka.ms.
    function Buscar-Winget {
        $cmd = Get-Command winget -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd }
        # El alias de ejecucion no siempre esta en el PATH de la sesion actual
        $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
        if (Test-Path $alias) { return (Get-Command $alias -ErrorAction SilentlyContinue) }
        return $null
    }

    function Instalar-Winget {
        # App Installer requiere Windows 10 1809 (build 17763) o superior
        $build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuild -EA SilentlyContinue).CurrentBuild
        if ($build -lt 17763) {
            Write-Host "  Windows build $build (< 17763): App Installer no es compatible." -ForegroundColor Yellow
            return $null
        }

        Write-Host "  winget no esta disponible. Instalando App Installer..." -ForegroundColor Yellow
        $dir = Join-Path $env:TEMP 'winget-bootstrap'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        # 1) Dependencias (sin ellas Add-AppxPackage falla por codigo 0x80073CF3)
        $deps = @(
            @{ N = 'Microsoft.VCLibs.x64.14.00.Desktop.appx'; U = 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx' },
            @{ N = 'Microsoft.NET.Native.Framework.2.2.appx'; U = 'https://aka.ms/Microsoft.NET.Native.Framework.2.2.appx' },
            @{ N = 'Microsoft.NET.Native.Runtime.2.2.appx';   U = 'https://aka.ms/Microsoft.NET.Native.Runtime.2.2.appx' }
        )
        $rutasDeps = @()
        foreach ($d in $deps) {
            $dest = Join-Path $dir $d.N
            try {
                if (-not (Test-Path $dest)) { Invoke-WebRequest $d.U -OutFile $dest -UseBasicParsing -TimeoutSec 300 }
                $rutasDeps += $dest
            } catch {
                Write-Host "  No se pudo descargar $($d.N): $($_.Exception.Message)" -ForegroundColor Red
                return $null
            }
        }

        # 2) Bundle oficial. Primero la via de Microsoft ('aka.ms/getwinget'
        #    redirige al .msixbundle del ultimo release) y, si falla, la API
        #    de GitHub, que era el unico camino de la version anterior.
        $bundle = $null
        try {
            $bundle = Join-Path $dir 'Microsoft.DesktopAppInstaller.msixbundle'
            if (-not (Test-Path $bundle)) {
                Invoke-WebRequest 'https://aka.ms/getwinget' -OutFile $bundle -UseBasicParsing -TimeoutSec 900
            }
        } catch {
            Write-Host "  aka.ms/getwinget no respondio; se prueba la API de GitHub..." -ForegroundColor Yellow
            $bundle = $null
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                $rel   = Invoke-RestMethod 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' -Headers @{ 'User-Agent' = 'winget-bootstrap' } -TimeoutSec 20
                $asset = $rel.assets | Where-Object { $_.name -like '*.msixbundle' } | Select-Object -First 1
                if (-not $asset) { throw 'El release no publica ningun .msixbundle' }
                $bundle = Join-Path $dir $asset.name
                if (-not (Test-Path $bundle)) { Invoke-WebRequest $asset.browser_download_url -OutFile $bundle -UseBasicParsing -TimeoutSec 900 }
            } catch {
                Write-Host "  No se pudo obtener el bundle de winget: $($_.Exception.Message)" -ForegroundColor Red
                return $null
            }
        }

        # 3) Instalacion. Nota: Add-AppxPackage instala para el perfil del usuario
        #    ACTUAL, asi que hay que ejecutarlo como el usuario que usara winget.
        try {
            Add-AppxPackage -Path $bundle -DependencyPath $rutasDeps -ForceApplicationShutdown -ErrorAction Stop
        } catch {
            try {
                Add-AppxPackage -Path $bundle -DependencyPath $rutasDeps -ForceApplicationShutdown -ForceUpdateFromAnyVersion -ErrorAction Stop
            } catch {
                Write-Host "  Add-AppxPackage fallo: $($_.Exception.Message)" -ForegroundColor Red
                return $null
            }
        }

        Actualizar-Path
        return (Buscar-Winget)
    }

    # Descargas: con la barra de progreso activa, un MSI de ~110 MB tarda ~10
    # veces mas en Windows PowerShell 5.1.
    $progresoPrevio = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'

    $pwshCmd = Get-Pwsh7

    if (-not $pwshCmd) {
        # ---------------- INSTALACION (requiere Administrador) ----------------
        if (-not (Test-EsAdmin)) {
            Write-Host "  PowerShell 7 no esta instalado y se necesita Administrador para instalarlo." -ForegroundColor Yellow
            Write-Host "  Y ahora mismo no se es Administrador (por ejemplo, con '-SinElevar')." -ForegroundColor Yellow
            Write-Host "  Abre la terminal como Administrador y vuelve a ejecutar este script, o" -ForegroundColor Yellow
            Write-Host "  instalalo manualmente:  winget install -e --id Microsoft.PowerShell" -ForegroundColor Yellow
            exit 1
        }

        Write-Host "  PowerShell 7 no detectado. Instalando..." -ForegroundColor Yellow
        $instalado = $false

        # 1) winget (via rapida). Si no esta, se instala primero App Installer.
        #    El '-e' es obligatorio para que el ID sea coincidencia EXACTA.
        $wingetCmd = Buscar-Winget
        if (-not $wingetCmd) { $wingetCmd = Instalar-Winget }
        if ($wingetCmd) {
            Write-Host "  Via winget: instalando Microsoft.PowerShell..." -ForegroundColor Yellow
            try {
                & $wingetCmd.Source install -e --id Microsoft.PowerShell --source winget --accept-source-agreements --accept-package-agreements --silent | Out-Null
            } catch {}
            Actualizar-Path
            $pwshCmd = Get-Pwsh7
            if ($pwshCmd) { $instalado = $true }
        }

        # 2) MSI oficial desde GitHub: ultima version publicada + respaldo fijo
        if (-not $instalado) {
            $arquitectura = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
            $versiones = @()
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                $rel = Invoke-RestMethod 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -Headers @{ 'User-Agent' = 'ps7-bootstrap' } -TimeoutSec 20
                $tag = "$($rel.tag_name)" -replace '^v', ''
                if ($tag) { $versiones += @{ Tag = $tag } }
            } catch {}
            $versiones += @{ Tag = '7.6.7' }

            foreach ($v in $versiones) {
                $url = "https://github.com/PowerShell/PowerShell/releases/download/v$($v.Tag)/PowerShell-$($v.Tag)-win-$arquitectura.msi"
                $msi = Join-Path $env:TEMP "PowerShell-$($v.Tag)-win-$arquitectura.msi"
                try {
                    if (-not (Test-Path $msi)) {
                        Invoke-WebRequest $url -OutFile $msi -UseBasicParsing -TimeoutSec 600
                    }
                    $firma = Get-AuthenticodeSignature -FilePath $msi
                    if ($firma.Status -ne 'Valid' -or $firma.SignerCertificate.Subject -notmatch 'Microsoft') {
                        Write-Host "  MSI $($v.Tag) rechazado: firma no valida ($($firma.Status))." -ForegroundColor Red
                        Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
                        continue
                    }
                    $msiProc = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /quiet /norestart" -Wait -PassThru
                    if ($msiProc.ExitCode -notin @(0, 3010)) {
                        Write-Host "  msiexec devolvio $($msiProc.ExitCode) al instalar $($v.Tag); se prueba la otra via." -ForegroundColor Yellow
                        continue
                    }
                    Actualizar-Path
                    $pwshCmd = Get-Pwsh7
                    if ($pwshCmd) { $instalado = $true; break }
                } catch {}
            }
        }

        if (-not $instalado -or -not $pwshCmd) {
            Write-Host "  No se pudo instalar PowerShell 7." -ForegroundColor Red
            Write-Host "  Instalalo manualmente:  winget install -e --id Microsoft.PowerShell" -ForegroundColor Yellow
            exit 1
        }
    }

    # ---------------- RELANZADO CONSERVANDO PARAMETROS ----------------
    if ([Environment]::GetEnvironmentVariable('_PS7_RELANZADO')) {
        Write-Host "  Tras el relanzado seguimos sin PowerShell 7: se para para no entrar en bucle." -ForegroundColor Red
        exit 1
    }
    $env:_PS7_RELANZADO = '1'
    $ProgressPreference = $progresoPrevio

    $comando = Get-CadenaInvocacion -RutaScript $script:RutaPropia -Parametros $script:ParametrosLlamada
    try {
        & $pwshCmd -NoProfile -ExecutionPolicy Bypass -EncodedCommand (Get-ComandoCodificado $comando)
    } catch {
        Write-Host "  No se pudo arrancar '$pwshCmd': $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    exit $LASTEXITCODE
}
# =================== FIN AUTO-ARRANQUE POWERSHELL 7 ===================
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8


# ================================================================
# FUNCIONES GENERALES REUTILIZABLES
# ================================================================

function Draw-Line    { Write-Host ("  " + "=" * 62) -ForegroundColor DarkGray }
function Show-Success { param([string]$M) Write-Host "  OK $M" -ForegroundColor Green }
function Show-Error   { param([string]$M) Write-Host "  ERROR $M" -ForegroundColor Red }
function Show-Info    { param([string]$M) Write-Host "  INFO $M" -ForegroundColor Cyan }
function Show-Warning { param([string]$M) Write-Host "  AVISO $M" -ForegroundColor Yellow }

function Read-HostStyled {
    param([string]$Prompt, [string]$Icon = "?", [string]$DefaultValue = "")
    Write-Host "  $Icon  $Prompt" -NoNewline -ForegroundColor Cyan
    if ($DefaultValue) { Write-Host " [default: $DefaultValue]" -NoNewline -ForegroundColor DarkGray }
    Write-Host ": " -NoNewline -ForegroundColor White
    # Protegido igual que Read-Respuesta del optimizador: sin entrada (stdin
    # cerrado) 5.1 lanza excepcion y PS7 devuelve "nada"; en ambos casos se
    # cae al DefaultValue, que siempre es la opcion segura (simulacion).
    try { $in = Read-Host } catch { $in = "" }
    if ([string]::IsNullOrWhiteSpace([string]$in) -and $DefaultValue) { return $DefaultValue }
    return $in
}

function Preguntar-SiNo {
    param([string]$Mensaje = "Continuar?")
    # Sin respuesta o error de entrada = $false: nunca se ejecuta la accion.
    try { $r = Read-Host "  CONFIRMAR: $Mensaje (S/N)" } catch { return $false }
    return ($r -in 'S', 's', 'SI', 'si', 'Si')
}

function Invoke-ConProgreso {
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [ValidateSet("barra", "spinner")][string]$Estilo = "barra"
    )
    $job = Start-ThreadJob -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    $chars = @([char]0x250B,[char]0x2519,[char]0x2539,[char]0x253B,[char]0x253C,[char]0x2534,[char]0x2526,[char]0x2527,[char]0x2523,[char]0x250F)
    $ancho = 22; $i = 0; $dir = 1
    if ($Estilo -eq "spinner") {
        Write-Host "  $Message " -NoNewline -ForegroundColor Cyan
        while ($job.State -eq 'Running') {
            Write-Host "`b$($chars[$i])" -NoNewline -ForegroundColor Green
            $i = ($i + 1) % $chars.Length; Start-Sleep -Milliseconds 80
        }
        Write-Host "`b OK" -ForegroundColor Green
    } else {
        while ($job.State -eq 'Running') {
            $barra = ' ' * $i + '#' * 4 + ' ' * ($ancho - $i - 4)
            Write-Host ("`r  $Message  [$barra]") -NoNewline -ForegroundColor Cyan
            $i += $dir
            if ($i -ge ($ancho - 4) -or $i -le 0) { $dir = -$dir }
            Start-Sleep -Milliseconds 50
        }
        Write-Host ("`r  OK $Message" + (' ' * ($ancho + 8))) -ForegroundColor Green
    }
    Wait-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
    $result = Receive-Job -Job $job -ErrorAction SilentlyContinue
    Remove-Job -Job $job -Force
    return $result
}

function Formatear-Tamanio {
    param([long]$Bytes)
    if ($Bytes -ge 1TB) { return "{0:N2} TB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Agregar-Log {
    param([string]$Accion, [string]$Archivo, [string]$Detalle)
    if ($script:LogFile) {
        Add-Content $script:LogFile "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $Accion | $Archivo | $Detalle" -EA SilentlyContinue
    }
}

# ================================================================
# FUNCIONES GENERALES DE PATRONES
# ================================================================

function Invoke-EscanearArchivos {
    param(
        [Parameter(Mandatory)][string]$Ruta,
        [string]$Filtro = "*.*",
        [string]$PatronNombre = "",
        [datetime]$FechaDesde,
        [datetime]$FechaHasta,
        [string[]]$Extensiones = @(),
        [string]$ExcluirRutas = "",
        [string]$Mensaje = "Escaneando archivos",
        [string]$Estilo = "barra"
    )
    return @(Invoke-ConProgreso -Message $Mensaje -Estilo $Estilo -ScriptBlock {
        param($r, $f, $pat, $fd, $fh, $exts, $excl)
        $params = @{ Path = $r; File = $true; Recurse = $true; ErrorAction = 'SilentlyContinue' }
        if ($f -and $f -ne "*.*") { $params['Filter'] = $f }
        $res = Get-ChildItem @params
        if ($pat)       { $res = $res | Where-Object { $_.Name -match $pat } }
        if ($fd)        { $res = $res | Where-Object { $_.LastWriteTime -ge $fd } }
        if ($fh)        { $res = $res | Where-Object { $_.LastWriteTime -le $fh } }
        if ($exts.Count -gt 0) { $res = $res | Where-Object { $exts -contains $_.Extension.ToLower() } }
        if ($excl)      { $res = $res | Where-Object { $_.FullName -notmatch $excl } }
        return @($res)
    } -ArgumentList $Ruta, $Filtro, $PatronNombre, $FechaDesde, $FechaHasta, $Extensiones, $ExcluirRutas)
}

function Invoke-EscanearUnidades {
    param(
        [Parameter(Mandatory)][string[]]$Unidades,
        [string]$Filtro = "*.*",
        [string]$PatronNombre = "",
        [string[]]$Extensiones = @(),
        [string]$ExcluirRutas = "",
        [string]$Mensaje = "Escaneando unidades",
        [int]$ThrottleLimit = 4
    )
    return @(Invoke-ConProgreso -Message $Mensaje -Estilo barra -ScriptBlock {
        param($uni, $f, $pat, $exts, $excl)
        $resultado = [System.Collections.Generic.List[object]]::new()
        foreach ($u in $uni) {
            $raiz = if ($u.EndsWith('\')) { $u } else { "$u\" }
            $params = @{ Path = $raiz; File = $true; Recurse = $true; ErrorAction = 'SilentlyContinue' }
            if ($f -and $f -ne "*.*") { $params['Filter'] = $f }
            $res = Get-ChildItem @params
            if ($pat)  { $res = $res | Where-Object { $_.Name -match $pat } }
            if ($exts -and $exts.Count -gt 0) { $res = $res | Where-Object { $exts -contains $_.Extension.ToLower() } }
            if ($excl) { $res = $res | Where-Object { $_.FullName -notmatch $excl } }
            foreach ($r in $res) { $resultado.Add($r) }
        }
        return @($resultado)
    } -ArgumentList $Unidades, $Filtro, $PatronNombre, $Extensiones, $ExcluirRutas)
}

function Mostrar-ResumenArchivos {
    param([object[]]$Archivos, [string]$Titulo = "Resultados")
    if (-not $Archivos -or $Archivos.Count -eq 0) { Show-Warning "Sin archivos."; return $false }
    Show-Success "Encontrados: $($Archivos.Count)"
    $totalMB = [math]::Round(($Archivos | Measure-Object Length -Sum).Sum / 1MB, 2)
    Show-Info "Total: $totalMB MB"
    return $true
}

function Invoke-ProcesarArchivos {
    param(
        [Parameter(Mandatory)][object[]]$Archivos,
        [Parameter(Mandatory)][scriptblock]$Accion,
        [string]$TituloAccion = "procesar",
        [switch]$RequiereConfirmacion,
        [switch]$MostrarProgreso
    )
    if ($RequiereConfirmacion) {
        Show-Warning "Se $TituloAccion $($Archivos.Count) archivos."
        if (-not (Preguntar-SiNo "Confirmar?")) { return @{ Eliminados = 0; Fallos = 0; Cancelado = $true } }
    }
    $elim = 0; $fallos = 0
    if ($MostrarProgreso -and $Archivos.Count -gt 20) {
        $total = $Archivos.Count; $i = 0
        foreach ($a in $Archivos) {
            $i++
            Write-Progress -Activity "Procesando..." -Status "$i/$total" -PercentComplete ([math]::Round(($i / $total) * 100))
            try { & $Accion $a; $elim++ } catch { $fallos++ }
        }
        Write-Progress -Activity "Procesando..." -Completed
    } else {
        foreach ($a in $Archivos) { try { & $Accion $a; $elim++ } catch { $fallos++ } }
    }
    return @{ Eliminados = $elim; Fallos = $fallos; Cancelado = $false }
}

function Mostrar-ResultadoFinal {
    param([hashtable]$Resultado, [string]$Accion = "procesados")
    Draw-Line
    Write-Host "  RESULTADO: $($Resultado.Eliminados) $Accion" -ForegroundColor Green
    if ($Resultado.Fallos -gt 0) { Write-Host "  Errores: $($Resultado.Fallos)" -ForegroundColor Red }
    Draw-Line
}

function Obtener-UnidadesDisponibles {
    param([string[]]$Preferidas = @("C:","D:","E:","F:","G:","H:","I:","J:","K:"))
    $disponibles = @()
    foreach ($u in $Preferidas) {
        $raiz = if ($u.EndsWith('\')) { $u } else { "${u}\" }
        if (Test-Path $raiz) { $disponibles += $raiz }
    }
    return $disponibles
}


# ================================================================
# HERRAMIENTAS (usan funciones generales)
# ================================================================

function Invoke-BloquearTodo {
    $PerfilesSoftware = @{
        "Corel"    = @("C:\Program Files\Corel\", "C:\Program Files (x86)\Corel\")
        "Adobe"    = @("C:\Program Files\Adobe\", "C:\Program Files (x86)\Adobe\",
                       "C:\Program Files\Common Files\Adobe\", "C:\Program Files (x86)\Common Files\Adobe\")
        "Autodesk" = @("C:\Program Files\Autodesk\", "C:\Program Files (x86)\Autodesk\",
                       "C:\Program Files\Common Files\Autodesk Shared\", "C:\Program Files (x86)\Common Files\Autodesk Shared\",
                       "C:\Autodesk\")
    }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Show-Error "Requiere ADMINISTRADOR"; return
    }
    # $Suite y $RutaManual hoy no son parametros del script (modo por CLI
    # pendiente); sin ellos la herramienta es interactiva: menu de suites.
    $SuiteLocal = if ($RutaManual) { "Manual" } elseif ($Suite) { $Suite } else { "Menu" }
    $detectadas = @()
    if ($SuiteLocal -ne "Manual") {
        foreach ($k in $PerfilesSoftware.Keys) {
            foreach ($r in $PerfilesSoftware[$k]) { if (Test-Path $r) { $detectadas += $k; break } }
        }
    }
    if ($SuiteLocal -eq "Menu") {
        if (-not $detectadas) { Show-Warning "Sin suites detectadas."; return }
        $idx = 1; $mapa = @{}
        foreach ($s in $detectadas) { Write-Host "  $idx. $s" -ForegroundColor White; $mapa[$idx.ToString()] = $s; $idx++ }
        if ($detectadas.Count -gt 1) { Write-Host "  $idx. Todos" -ForegroundColor Yellow; $mapa[$idx.ToString()] = "Todos"; $idx++ }
        Write-Host "  0. Salir" -ForegroundColor Red
        $op = Read-Host "  Selecciona"
        if ($op -eq "0" -or -not $mapa.ContainsKey($op)) { return }
        $SuiteLocal = $mapa[$op]
        # El modo desbloquear antes solo se alcanzaba con '-Desbloquear' en el
        # script externo; en modo interactivo se pregunta aqui.
        $Desbloquear = -not (Preguntar-SiNo "BLOQUEAR la salida a Internet de '$SuiteLocal'? (N = desbloquear)")
    }
    $rutas = switch ($SuiteLocal) {
        "Manual" { @($RutaManual) }
        "Todos"  { foreach ($k in $detectadas) { $PerfilesSoftware[$k] } }
        default  { $PerfilesSoftware[$SuiteLocal] }
    }
    $cambios = 0
    foreach ($ruta in $rutas) {
        if (-not (Test-Path $ruta)) { continue }
        foreach ($app in (Get-ChildItem $ruta -Filter *.exe -Recurse -EA SilentlyContinue)) {
            $regla = "Aislamiento_LAN_Ok - $($app.Name)"
            $existe = Get-NetFirewallRule -DisplayName $regla -EA SilentlyContinue
            if ($Desbloquear) {
                if ($existe) { try { Remove-NetFirewallRule $regla -EA Stop; $cambios++ } catch {} }
            } else {
                if (-not $existe) {
                    try { New-NetFirewallRule $regla -Direction Outbound -Program $app.FullName -RemoteAddress Internet -Action Block -EA Stop | Out-Null; $cambios++ } catch {}
                }
            }
        }
    }
    Show-Success "Cambios: $cambios"
}

function Invoke-Borrado {
    if (-not $Ruta)  { $Ruta = Read-HostStyled "Ruta a escanear" "📁" }
    if (-not $Desde) {
        $entrada = Read-HostStyled "Desde año" "📅" "2020"
        if ($entrada -notmatch '^\d{4}$') { Show-Error "Año invalido: '$entrada'"; return }
        $Desde = [int]$entrada
    }
    if (-not $Hasta) {
        $entrada = Read-HostStyled "Hasta año" "📅" "2025"
        if ($entrada -notmatch '^\d{4}$') { Show-Error "Año invalido: '$entrada'"; return }
        $Hasta = [int]$entrada
    }
    if ($Desde -gt $Hasta) { Show-Error "Rango invalido: Desde ($Desde) es mayor que Hasta ($Hasta)"; return }
    if (-not (Test-Path $Ruta)) { Show-Error "Ruta no existe: $Ruta"; return }
    $fd = Get-Date -Year $Desde -Month 1 -Day 1
    $fh = Get-Date -Year $Hasta -Month 12 -Day 31 -Hour 23 -Minute 59 -Second 59
    $ext = if ($Extension) { "*.$($Extension.TrimStart('.'))" } else { "*.*" }
    $archivos = Invoke-EscanearArchivos -Ruta $Ruta -Filtro $ext -FechaDesde $fd -FechaHasta $fh -Mensaje "Buscando archivos"
    if (-not (Mostrar-ResumenArchivos $archivos)) { return }
    $op = Read-HostStyled "Ejecutar borrado? [1] Si [2] No (simulacion)" "?" "2"
    if ($op -ne "1") { Show-Warning "SIMULACION. No se borro nada."; return }
    $r = Invoke-ProcesarArchivos $archivos -Accion { param($a) Remove-Item $a.FullName -Force -EA Stop } -TituloAccion "borrar" -RequiereConfirmacion -MostrarProgreso
    Mostrar-ResultadoFinal $r "eliminados"
}

function Invoke-BorrarDuplicados {
    if (-not $Ruta) { $Ruta = Read-HostStyled "Carpeta" "📁" "Z:\" }
    if (-not (Test-Path $Ruta)) { Show-Error "Ruta no existe: $Ruta"; return }

    if (-not $Duplicados -and -not $Copias) {
        Write-Host ""
        Write-Host "  ¿Qué buscar?" -ForegroundColor Magenta
        Write-Host "    1) Duplicados de Windows  (Movil(1).dbf)" -ForegroundColor Cyan
        Write-Host "    2) Copias de CorelDraw    (Copia_de_seguridad.cdr)" -ForegroundColor Cyan
        Write-Host "    3) Ambos" -ForegroundColor Cyan
        $op = Read-HostStyled "Selecciona" "🔍" "1"
        switch ($op) {
            "2" { $Copias = $true }
            "3" { $Duplicados = $true; $Copias = $true }
            default { $Duplicados = $true }
        }
    }

    $pats = @()
    $etiquetas = @()
    if ($Duplicados) { $pats += '\(\d+\)\.[^\.]+$'; $etiquetas += "Duplicados (n).ext" }
    if ($Copias)     { $pats += '(?i)^copia[_ ]de[_ ].*\.cdr$'; $etiquetas += "Copia_de_*.cdr" }
    $patron = '(' + ($pats -join '|') + ')'
    Show-Info "Buscando: $($etiquetas -join ' + ')"

    $corte = (Get-Date).Date
    $archivos = @(Invoke-EscanearArchivos -Ruta $Ruta -PatronNombre $patron -Mensaje "Buscando archivos" | Where-Object { $_.LastWriteTime.Date -lt $corte })
    if (-not (Mostrar-ResumenArchivos $archivos)) { return }
    $op = Read-HostStyled "¿Ejecutar borrado? [1] Sí [2] No (simulación)" "⚠️" "2"
    if ($op -ne "1") { Show-Warning "SIMULACIÓN. No se borró nada."; return }
    $r = Invoke-ProcesarArchivos $archivos -Accion { param($a) Remove-Item -LiteralPath $a.FullName -Force -EA Stop } -TituloAccion "borrar" -RequiereConfirmacion
    Mostrar-ResultadoFinal $r "eliminados"
}

function Invoke-MoverArchivos {
    if (-not $Ruta)    { $Ruta = Read-HostStyled "Origen" "📁" "Y:\" }
    if (-not $Destino) { $Destino = Read-HostStyled "Destino" "📂" "E:\copia nas" }
    if (-not $Hasta)   { $Hasta = [int](Read-HostStyled "Año límite" "📅" "2025") }
    $Ruta = $Ruta.Trim().Trim('"').Trim("'").TrimEnd('\') + '\'
    $Destino = $Destino.Trim().Trim('"').Trim("'").TrimEnd('\')
    if (-not (Test-Path $Ruta)) { Show-Error "Origen no existe: $Ruta"; return }
    $exts = @("*.cdr","*.ai","*.psd","*.indd","*.eps","*.pdf","*.ps")
    $rutaLog = Join-Path $Destino "robocopy_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    if (-not (Test-Path $Destino)) { New-Item $Destino -ItemType Directory -Force | Out-Null }
    $op = Read-HostStyled "Ejecutar movimiento? [1] Si [2] No (simulacion)" "?" "2"
    $esReal = $op -eq "1"
    $modo = if ($esReal) { "/MOV" } else { "/L" }
    # $rcArgs y no $args: $args es la variable automatica de argumentos no
    # vinculados y sombrearla dentro de una funcion es pedir problemas.
    $rcArgs = @($Ruta, $Destino) + $exts + @($modo,"/S","/MINAGE:$($Hasta+1)0101","/MT:16","/FFT","/R:1","/W:2","/TEE","/LOG:$rutaLog","/XD",$Destino)
    & robocopy.exe $rcArgs
    Show-Success "Robocopy finalizado. Log: $rutaLog"
}

function Invoke-QuitarG {
    $excluir = @("Windows","System Volume Information",'$Recycle.Bin') | ForEach-Object { [regex]::Escape($_) }
    $patron = $excluir -join '|'

    # Si no se especificaron unidades, preguntar interactivamente
    if ($Unidades.Count -eq 0) {
        $unidadActual = [System.IO.Path]::GetPathRoot((Get-Location).Path).TrimEnd('\')
        Write-Host ""
        Write-Host "  Unidades detectadas: $unidadActual" -ForegroundColor Cyan
        $inputUnidades = Read-HostStyled "Unidades a escanear (separadas por coma, vacio = actual)" "💾" $unidadActual
        $unis = @($inputUnidades -split ',' | ForEach-Object { $_.Trim().TrimEnd('\') } | Where-Object { $_ })
    } else {
        $unis = $Unidades
    }

    # Modo
    if (-not $Real) {
        $op = Read-HostStyled "Modo: [1] Simulacion [2] Ejecucion real" "⚙️" "1"
        $Real = ($op -eq "2")
    }

    $modoTxt = if ($Real) { "REAL" } else { "SIMULACIÓN" }
    Write-Host ""
    Write-Host "  Unidades: $($unis -join ', ')" -ForegroundColor White
    Write-Host "  Modo: $modoTxt" -ForegroundColor $(if ($Real) {'Red'} else {'Yellow'})

    # El -Filter y el -PatronNombre son case-insensitive: sin este corte
    # tambien entrarian 'G*.exe' (mayuscula), a los que '-creplace "^g"' no
    # puede quitar el prefijo y acabarian en "Conflicto". El externo las
    # excluyia con -cmatch; se reproduce aqui.
    $candidatos = @(Invoke-EscanearUnidades $unis -Filtro "g*.exe" -PatronNombre "^g" -ExcluirRutas $patron -Mensaje "Escaneando unidades" |
        Where-Object { $_.Name -cmatch '^g' })
    if ($candidatos.Count -eq 0) { Show-Warning "Sin archivos g*.exe."; return }
    Show-Success "Encontrados: $($candidatos.Count)"

    if (-not $Real) { Show-Warning "SIMULACIÓN: nada se renombra."; return }

    $r = Invoke-ProcesarArchivos $candidatos -Accion {
        param($a)
        $nuevo = $a.Name -creplace "^g", ""
        if (Test-Path (Join-Path $a.DirectoryName $nuevo)) { throw "Conflicto" }
        Rename-Item $a.FullName -NewName $nuevo -EA Stop
    } -TituloAccion "renombrar" -RequiereConfirmacion
    Mostrar-ResultadoFinal $r "renombrados"
}

function Invoke-QuitarZip {
    $paths = @($env:USERPROFILE, "$env:USERPROFILE\Downloads", "$env:USERPROFILE\Documents") | Where-Object { Test-Path $_ }
    $procesados = 0
    foreach ($base in $paths) {
        $carpetas = Invoke-ConProgreso -Message "Escaneando $base" -Estilo spinner -ScriptBlock {
            param($b) @(Get-ChildItem $b -Directory -Recurse -EA SilentlyContinue | Select-Object -ExpandProperty FullName)
        } -ArgumentList $base
        foreach ($sub in @($base) + $carpetas) {
            foreach ($a in (Get-ChildItem $sub -Filter "*.cdr.zip" -EA SilentlyContinue)) {
                $nueva = $a.FullName -replace '\.zip$', ''
                if (-not (Test-Path -LiteralPath $nueva)) {
                    try { Rename-Item -LiteralPath $a.FullName -NewName (Split-Path $nueva -Leaf) -EA Stop; $procesados++ } catch {}
                }
            }
        }
    }
    Show-Success "Renombrados: $procesados"
}


function Invoke-RepararPerfil {
    $ErrorActionPreference = "Stop"
    $u = $env:USERNAME; $d = $env:SystemDrive
    $perfil = "$d\Users\$u"

    if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Show-Error "Requiere Administrador"; return
    }
    Draw-Line; Write-Host "  🔧 REPARACIÓN DE PERFIL - $u" -ForegroundColor Magenta; Draw-Line
    if (-not (Preguntar-SiNo "Reparar perfil de $u?")) { return }

    Write-Host "`n[1/3] Estructura..." -ForegroundColor Cyan
    $carpetas = @("Desktop","Documents","Downloads","Music","Pictures","Videos","Favorites","Links",
        "AppData\Local","AppData\Roaming","AppData\Local\Temp",
        "AppData\Roaming\Microsoft\Windows\Start Menu","AppData\Roaming\Microsoft\Windows\Recent")
    if (-not (Test-Path $perfil)) { New-Item $perfil -ItemType Directory -Force | Out-Null }
    foreach ($c in $carpetas) {
        $r = Join-Path $perfil $c
        if (-not (Test-Path $r)) { try { New-Item $r -ItemType Directory -Force | Out-Null } catch {} }
    }
    Show-Success "Estructura creada"

    Write-Host "`n[2/3] Registro..." -ForegroundColor Cyan
    $sid = (Get-CimInstance Win32_UserAccount -Filter "Name='$u' AND Domain='$env:USERDOMAIN'" -EA SilentlyContinue).SID
    if (-not $sid) { $sid = ([Security.Principal.NTAccount]$u).Translate([Security.Principal.SecurityIdentifier]).Value }
    if ($sid) {
        $rc = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
        if (Test-Path $rc) { try { Set-ItemProperty $rc -Name "ProfileImagePath" -Value $perfil -Force } catch {} }
    }
    Show-Success "Registro listo"

    Write-Host "`n[3/3] Variables..." -ForegroundColor Cyan
    try {
        [Environment]::SetEnvironmentVariable("USERPROFILE", $perfil, "User")
        [Environment]::SetEnvironmentVariable("TEMP", "$perfil\AppData\Local\Temp", "User")
    } catch {}
    Show-Success "Variables listas"
    Draw-Line; Show-Success "REPARACIÓN COMPLETADA"; Draw-Line
}

function Invoke-ReporteNAS {
    $extD = @(".cdr",".psd",".ai")
    $extM = @(".jpg",".jpeg",".png",".gif",".bmp",".tif",".tiff",".mp4",".mov",".avi",".mp3",".wav",".flac")

    if (-not $TipoArchivos) {
        $op = Read-HostStyled "Tipo: [1] Diseños [2] Multimedia" "📊" "1"
        $TipoArchivos = if ($op -eq "2") { "multimedia" } else { "disenos" }
    }

    # Preguntar formato de exportación
    if (-not $Exportar) {
        $op = Read-HostStyled "Exportar: [1] Consola [2] HTML [3] CSV" "📄" "1"
        $Exportar = switch ($op) { "2" {"html"} "3" {"csv"} default {"console"} }
    }

    # Preguntar qué unidades escanear
    $disponibles = Obtener-UnidadesDisponibles
    if (-not $disponibles) { Show-Error "Sin unidades disponibles"; return }

    if ($Unidades.Count -eq 0) {
        Write-Host ""
        Write-Host "  Unidades disponibles: $($disponibles -join ', ')" -ForegroundColor Cyan
        $inputUnidades = Read-HostStyled "Unidades a escanear (separadas por coma, vacio = todas)" "💾" ($disponibles -join ',')
        if ([string]::IsNullOrWhiteSpace($inputUnidades)) {
            $rutas = $disponibles
        } else {
            $rutas = @($inputUnidades -split ',' | ForEach-Object { $_.Trim().TrimEnd('\') } | Where-Object { Test-Path "$_\" })
        }
    } else {
        $rutas = $Unidades
    }

    if (-not $rutas) { Show-Error "Ninguna unidad válida seleccionada"; return }

    $exts = if ($TipoArchivos -eq "disenos") { $extD } else { $extM }

    # Escanear
    $todosArchivos = @(Invoke-EscanearUnidades $rutas -Mensaje "Escaneando NAS")
    $archivos = @($todosArchivos | Where-Object { $exts -contains $_.Extension.ToLower() })

    if ($archivos.Count -eq 0) { Show-Warning "Sin archivos de tipo $($TipoArchivos)."; return }

    $totalBytes = [double]($archivos | Measure-Object Length -Sum).Sum
    Show-Success "Encontrados: $($archivos.Count) archivos ($(Formatear-Tamanio $totalBytes))"

    # === CONSOLA ===
    if ($Exportar -eq "console") {
        Write-Host "`n  TOP 10 TIPOS" -ForegroundColor Cyan
        $archivos | Group-Object { $_.Extension.ToLower() } |
            Sort-Object { ($_.Group | Measure-Object Length -Sum).Sum } -Descending |
            Select-Object -First 10 | ForEach-Object {
                $b = ($_.Group | Measure-Object Length -Sum).Sum
                Write-Host ("    {0,-10} {1,6}  {2,10}" -f $_.Name, $_.Count, (Formatear-Tamanio $b)) -ForegroundColor Yellow
            }

        Write-Host "`n  POR AÑO" -ForegroundColor Cyan
        $archivos | Group-Object { $_.LastWriteTime.Year } | Sort-Object { [int]$_.Name } | ForEach-Object {
            $b = ($_.Group | Measure-Object Length -Sum).Sum
            Write-Host ("    {0}: {1,6} archivos  {2,10}" -f $_.Name, $_.Count, (Formatear-Tamanio $b)) -ForegroundColor Yellow
        }
        return
    }

    # === EXPORTAR A ARCHIVO ===
    $fecha = Get-Date -Format 'yyyyMMdd_HHmmss'
    $dir = Join-Path $env:USERPROFILE "Documents\Reportes"
    if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }

    if ($Exportar -eq "html") {
        $path = Join-Path $dir "nas_$($TipoArchivos)_$fecha.html"

        $porTipo = $archivos | Group-Object { if ($_.Extension) { $_.Extension.ToLower() } else { "(sin ext)" } } |
            Sort-Object { ($_.Group | Measure-Object Length -Sum).Sum } -Descending | Select-Object -First 20
        $tablaTipos = ""
        foreach ($g in $porTipo) {
            $b = ($g.Group | Measure-Object Length -Sum).Sum
            $pct = if ($totalBytes -gt 0) { [math]::Round(($b / $totalBytes) * 100, 1) } else { 0 }
            $tablaTipos += "<tr><td>$($g.Name)</td><td>$($g.Count.ToString('N0'))</td><td>$(Formatear-Tamanio $b)</td><td>$pct%</td></tr>`n"
        }

        $porAnio = $archivos | Group-Object { $_.LastWriteTime.Year } | Sort-Object { [int]$_.Name }
        $tablaAnios = ""
        foreach ($g in $porAnio) {
            $b = ($g.Group | Measure-Object Length -Sum).Sum
            $tablaAnios += "<tr><td>$($g.Name)</td><td>$($g.Count.ToString('N0'))</td><td>$(Formatear-Tamanio $b)</td></tr>`n"
        }

        $rangos = @(
            @{L="2006-2010";MN=2006;MX=2010}, @{L="2011-2015";MN=2011;MX=2015},
            @{L="2016-2020";MN=2016;MX=2020}, @{L="2021-2025";MN=2021;MX=2025},
            @{L="2026-2030";MN=2026;MX=2030}
        )
        $tablaRangos = ""
        foreach ($r in $rangos) {
            $grupo = @($archivos | Where-Object { $a = $_.LastWriteTime.Year; $a -ge $r.MN -and $a -le $r.MX })
            $b = ($grupo | Measure-Object Length -Sum).Sum
            $tablaRangos += "<tr><td>$($r.L)</td><td>$($grupo.Count.ToString('N0'))</td><td>$(Formatear-Tamanio $b)</td></tr>`n"
        }

        $html = @"
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<title>Reporte NAS - $($TipoArchivos.ToUpper())</title>
<style>
    body { font-family: Consolas, monospace; background: #1a1a2e; color: #e0e0e0; margin: 20px; }
    h1 { color: #00d4ff; border-bottom: 2px solid #00d4ff; padding-bottom: 10px; }
    h2 { color: #ff6b35; margin-top: 30px; }
    table { border-collapse: collapse; width: 100%; margin: 10px 0; }
    th { background: #16213e; color: #00d4ff; padding: 8px; text-align: left; border: 1px solid #333; }
    td { padding: 6px 12px; border: 1px solid #333; }
    tr:nth-child(even) { background: #1f2940; }
    tr:nth-child(odd) { background: #16213e; }
    .total { font-weight: bold; color: #00ff88; font-size: 1.2em; }
</style>
</head>
<body>
<h1>Reporte NAS - $($TipoArchivos.ToUpper())</h1>
<p>Generado: $(Get-Date -Format 'dd/MM/yyyy HH:mm') | Unidades: $($rutas -join ', ')</p>
<p class='total'>Total: $($archivos.Count.ToString('N0')) archivos - $(Formatear-Tamanio $totalBytes)</p>

<h2>Top 20 Tipos de Archivo</h2>
<table>
<tr><th>Tipo</th><th>Cantidad</th><th>Espacio</th><th>%</th></tr>
$tablaTipos
</table>

<h2>Por Año</h2>
<table>
<tr><th>Año</th><th>Archivos</th><th>Espacio</th></tr>
$tablaAnios
</table>

<h2>Rangos de Años</h2>
<table>
<tr><th>Rango</th><th>Archivos</th><th>Espacio</th></tr>
$tablaRangos
</table>

</body></html>
"@
        $html | Out-File $path -Encoding utf8Bom
        Show-Success "HTML exportado: $path"
        Start-Process $path

    } elseif ($Exportar -eq "csv") {
        $path = Join-Path $dir "nas_$($TipoArchivos)_$fecha.csv"
        $archivos | Select-Object Name, Extension, Length, LastWriteTime, DirectoryName |
            Export-Csv $path -NoTypeInformation -Encoding utf8Bom
        Show-Success "CSV exportado: $path"
    }
}

# ================================================================
# BLOQUEO WPS OFFICE
# ================================================================
# Impide instalar, ejecutar, actualizar y descargar WPS Office en el equipo.
# Cuatro capas, cada una reversible por separado:
#   1) IFEO + Debugger = "cmd.exe /c exit": el proceso nunca arranca (ni el
#      instalador ni el programa ni el actualizador). Bloquea por NOMBRE de
#      ejecutable, asi que sirve aunque el archivo venga de un correo, de un
#      espejo o de una IP directa.
#   2) Cebo: un ARCHIVO llamado "WPS Office" con ACL Deny, colocado tanto en
#      AppData\Local\Kingsoft como en Kingsoft de cada unidad fija. El
#      instalador no puede crear su carpeta de destino. Necesario porque el
#      instalador elige el destino: en un equipo probado instalo en
#      E:\Kingsoft y no en AppData.
#   3) hosts: los dominios de WPS se resuelven a 0.0.0.0. Sin esto el
#      instalador web (wps_office_inst.exe) sigue pudiendo bajar el paquete
#      completo aunque IFEO lo bloquee.
#   4) Tarea programada KillWPS_Silent que mata procesos *wps* al iniciar sesion.
# Ademas puede desinstalar una instalacion existente con uninst.exe /S.
function Invoke-BloquearWPS {
    param(
        # Menu interactivo por defecto. Las otras opciones permiten uso no
        # interactivo: ".\Bloquear-WPS.ps1 -Accion Activar", tareas y scripts.
        [ValidateSet('Menu','Activar','Desactivar','Desinstalar','Estado')]
        [string]$Accion = 'Menu'
    )

    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Show-Error "Requiere ADMINISTRADOR"; return
    }

    $ifeoBase = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options"
    # Nombres de ejecutable reales, verificados en un WPS Office 12.1.0.29162
    # instalado. Se agrupan por rol para que sea facil mantenerlos:
    #   Programa      Writer(et/wpp) y el lanzador principal.
    #   Lanzadores    accesos de escritorio, panel lateral y conversion.
    #   Nube/util     sincronizacion y utilidades internas.
    #   Actualizador  el que busca e instala nuevas versiones.
    #   Instaladores  el online (launcher) y el offline. Son los que el
    #                 usuario lanza desde el correo o desde Descargas.
    # OJO: "uninst.exe" NO va aqui. Es el desinstalador y el script lo
    # necesita para desinstalar; bloquearlo anularia esa funcion.
    $executables = @(
        # --- programa ---
        "wps.exe", "et.exe", "wpp.exe", "wpscenter.exe", "wpsoffice.exe",
        # --- lanzadores ---
        "ksolaunch.exe", "wpscli.exe", "photolaunch.exe", "pintaskbar.exe",
        # --- nube y utilidades ---
        "wpscloudsvr.exe", "ksomisc.exe", "kwpsconvert.exe", "kwinappinstaller.exe",
        # --- actualizador ---
        "wpsupdate.exe",
        # --- instaladores ---
        "WPSOffice.exe", "wps_office_inst.exe", "wps_setup.exe"
    )
    # Dominios de WPS. IMPORTANTE: el archivo hosts solo bloquea nombres
    # EXACTOS, no subdominios: "0.0.0.0 wpscdn.com" NO corta
    # "wdl1.pcfg.cache.wpscdn.com". Por eso aqui van los FQDN reales tal como
    # aparecen en el historial de descargas, no los dominios raiz.
    # Los cuatro primeros estan verificados en el historial del navegador:
    #   www.wps.com                        pagina de aterrizaje (busqueda Google)
    #   wdl1.pcfg.cache.wpscdn.com         host que entrega los instaladores
    #   global.wps.com                     telemetria post-instalacion
    #   ap.wps.com / params.wps.com        configuracion del cliente
    $hostsWps = @(
        "www.wps.com", "wps.com",
        "wdl1.pcfg.cache.wpscdn.com", "wpscdn.com", "wpscdn.cn",
        "global.wps.com", "ap.wps.com", "params.wps.com",
        "dl.wps.cn", "wdl.wps.cn", "wps.cn", "wpsstatic.cn",
        "api-wps-param-us-test.4wps.net", "4wps.net",
        "kingsoft.com", "ksosoft.com", "wpscloud.cn"
    )
    # Raices de registro que usa la limpieza de rastros y el desinstalador.
    # Se declaran aqui, igual que $ifeoBase, para no repetir literales y para
    # poder redirigirlas todas de una vez.
    $regKingsoft  = @(
        "HKCU:\SOFTWARE\Kingsoft",
        "HKLM:\SOFTWARE\Kingsoft",
        "HKLM:\SOFTWARE\WOW6432Node\Kingsoft"
    )
    $regUninstall = @(
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    $regClasses   = @(
        "HKCU:\Software\Classes",
        "HKLM:\SOFTWARE\Classes",
        "HKLM:\SOFTWARE\WOW6432Node\Classes"
    )
    $regRun       = @(
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce"
    )
    # Carpetas fuera de las rutas de cebo donde puede quedar WPS. Se agrupan
    # en variable por el mismo motivo que las raices de registro.
    $rastrosCarpetas = @(
        "$env:ProgramData\Kingsoft",
        "$env:ProgramFiles\Kingsoft",
        "${env:ProgramFiles(x86)}\Kingsoft"
    )
    $taskName = "KillWPS_Silent"
    # SID "Everyone"/"Todos" (S-1-1-0). Se usa el SID y no el nombre porque el
    # nombre esta localizado: en es-ES/es-CO es "Todos", en en-US es "Everyone",
    # y con el nombre literal AddAccessRule falla por no poder traducirlo.
    $everyoneSid = [System.Security.Principal.SecurityIdentifier]::new("S-1-1-0")

    function Obtener-Perfiles {
        Get-ChildItem -Path "$env:SystemDrive\Users" -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '^(Public|All Users|Default|Default User|desktop)$' }
    }

    # Bloquea o libera los dominios de WPS en el archivo hosts.
    # Todo lo que toca va entre marcadores, para que al desactivar se retiren
    # EXCLUSIVAMENTE nuestras lineas y no se toque el resto del archivo (que
    # aqui ya contiene un bloqueador de anuncios con miles de entradas).
    $marcaIni = "# >>> BLOQUEO-WPS-INICIO (no editar a mano)"
    $marcaFin = "# >>> BLOQUEO-WPS-FIN"
    $hostsPath = Join-Path -Path $env:SystemRoot -ChildPath "System32\drivers\etc\hosts"

    function Editar-Hosts([bool]$bloquear) {
        if (-not (Test-Path -LiteralPath $hostsPath)) { New-Item -ItemType File -Path $hostsPath -Force | Out-Null }
        $lineas = @(Get-Content -LiteralPath $hostsPath -ErrorAction SilentlyContinue)

        # Quitar primero cualquier bloque anterior (idempotente: repetir no duplica).
        $lineas = @($lineas | Where-Object { $_ -ne $marcaIni -and $_ -ne $marcaFin -and $_ -notmatch '^\s*0\.0\.0\.0\s+\S*wps\S*\s*$' -and $_ -notmatch '^\s*0\.0\.0\.0\s+\S*kingsoft\S*\s*$' -and $_ -notmatch '^\s*0\.0\.0\.0\s+\S*4wps\S*\s*$' -and $_ -notmatch '^\s*0\.0\.0\.0\s+\S*ksosoft\S*\s*$' })

        # Construir el bloque nuevo (se anade tras filtrar el anterior, de
        # modo que repetir la operacion no duplica lineas).
        if ($bloquear) {
            $lineas += $marcaIni
            foreach ($d in $hostsWps) { $lineas += "0.0.0.0   $d" }
            $lineas += $marcaFin
        }

        # "Si esta se deja, si no esta se aplica": si el contenido resultante
        # es identico al que ya hay en disco, NO se reescribe. Reescribir el
        # hosts en cada activacion era lo que provocaba el fallo "file is
        # being used by another process" y dejaba la capa de descarga a
        # medias sin que el aviso lo contara.
        $actual = @(Get-Content -LiteralPath $hostsPath -ErrorAction SilentlyContinue)
        $iguales = ($actual.Count -eq $lineas.Count) -and
                   (@(Compare-Object -ReferenceObject $actual -DifferenceObject $lineas).Count -eq 0)
        if ($iguales) {
            if ($bloquear) { Write-Host "    [i] hosts: ya correcto ($($hostsWps.Count) dominios), sin reescribir" -ForegroundColor DarkGray }
            else           { Write-Host "    [i] hosts: ya sin bloqueo WPS, sin reescribir" -ForegroundColor DarkGray }
            return
        }

        # El aviso se imprime DESPUES de escribir, nunca antes: si se pone
        # delante, el script reporta exito aunque Set-Content falle (p. ej.
        # cuando otro proceso tiene el hosts abierto) y el bloqueo queda a
        # medias sin que nadie se entere. Se detecta igualmente en la capa
        # siguiente con Get-CapasFaltantes, que vuelve a intentarlo.
        try {
            Set-Content -LiteralPath $hostsPath -Value $lineas -Encoding Ascii -Force -ErrorAction Stop
        } catch {
            Show-Warning "hosts NO escrito, capa de descarga sin aplicar: $($_.Exception.Message)"
            return
        }

        if ($bloquear) {
            Write-Host "    [+] hosts: $($hostsWps.Count) dominios WPS bloqueados" -ForegroundColor Green
        } else {
            Write-Host "    [-] hosts: dominios WPS liberados" -ForegroundColor Gray
        }
    }

    function Get-EstadoWPS {
        $n = @($executables | Where-Object {
            (Get-ItemProperty -Path "$ifeoBase\$_" -Name Debugger -ErrorAction SilentlyContinue).Debugger -eq "cmd.exe /c exit"
        }).Count
        return ($n -eq $executables.Count)
    }

    # Estado de las 4 capas, con detalle de cada una.
    #
    # Devuelve objetos [Capa, Ok, Detalle] para que Activar pueda MOSTRAR
    # la validacion paso a paso (el usuario quiere ver que se comprueba
    # cada capa sin tener que desactivar antes para probar), y de aqui se
    # deriva Get-CapasFaltantes para decidir si hay que actuar.
    #
    # Motivo de existir: con solo mirar IFEO, un fallo a medias dejaba el
    # bloqueo sin reparar NUNCA. Si IFEO salia bien pero hosts o la tarea
    # fallaban, la guarda de "ya esta activo" impedia volver a ejecutar
    # Enable-WPSBlock, asi que el hueco se perpetuaba. Como Enable-WPSBlock
    # es idempotente, repetirlo no molesta: mejor comprobar las 4 capas y
    # reponer solo las que falten.
    #
    # NOTA: la tarea programada solo es visible desde un proceso elevado;
    # sin administrador Get-ScheduledTask no la devuelve y esta funcion
    # reportaria que falta. El preflight del script exige administrador,
    # asi que en el uso normal no influye.
    # Rutas donde puede haber (o quererse colocar) un cebo Kingsoft: el perfil
    # de cada usuario y la raiz de cada unidad fija.
    #
    # Se comparte entre la COMPROBACION (Get-EstadoCapas), la APLICACION
    # (Enable/Disable-WPSBlock) y la deteccion de instalacion (Test-WPSInstalado)
    # porque si cada una listara por su cuenta podrian divergir: la comprobacion
    # miraria una ruta que la aplicacion no cubre y se informaria de "falta" algo
    # que nunca se puede reponer, o al reves "4 capas completas" con un hueco.
    function Get-RutasKingsoft {
        $rutas = @()
        foreach ($profile in (Obtener-Perfiles)) {
            $rutas += Join-Path -Path $profile.FullName -ChildPath "AppData\Local\Kingsoft"
        }
        foreach ($unidad in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
                Where-Object { $_.Used -ne $null -and $_.Root -match '^[A-Z]:\\$' })) {
            $rutas += Join-Path -Path $unidad.Root -ChildPath "Kingsoft"
        }
        return $rutas
    }

    function Get-EstadoCapas {
        $lista = @()

        # --- capa 1: IFEO (ejecucion) ---
        $n = @($executables | Where-Object {
            (Get-ItemProperty -Path "$ifeoBase\$_" -Name Debugger -ErrorAction SilentlyContinue).Debugger -eq "cmd.exe /c exit"
        }).Count
        $lista += [pscustomobject]@{
            Capa    = "IFEO (ejecucion)"
            Ok      = ($n -eq $executables.Count)
            Detalle = "$n de $($executables.Count) ejecutables"
        }

        # --- capa 3: hosts (descarga) ---
        $hostsOk = $false
        $marcadores = 0
        if (Test-Path -LiteralPath $hostsPath) {
            $h = @(Get-Content -LiteralPath $hostsPath -ErrorAction SilentlyContinue)
            $marcadores = @($h | Where-Object { $_ -eq $marcaIni -or $_ -eq $marcaFin }).Count
            $hostsOk = ($marcadores -eq 2)
        }
        $lista += [pscustomobject]@{
            Capa    = "hosts (descarga)"
            Ok      = $hostsOk
            Detalle = $(if ($hostsOk) { "$($hostsWps.Count) dominios" } else { "marcadores $marcadores de 2" })
        }

        # --- capa 4: tarea programada (persistencia) ---
        $tareaOk = $false
        try { $tareaOk = [bool](Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) } catch { $tareaOk = $false }
        $lista += [pscustomobject]@{
            Capa    = "tarea programada (persistencia)"
            Ok      = $tareaOk
            Detalle = $(if ($tareaOk) { $taskName } else { "$taskName no existe" })
        }

        # --- capa 2: cebo (instalacion) ---
        # En cada perfil y cada unidad fija tiene que haber O un cebo
        # (archivo, denegado) O una instalacion real (directorio, que
        # Colocar-Cebo respeta). Si no hay nada en esa ruta, hay hueco.
        # Es la misma condicion que usa Colocar-Cebo: no se inventa otro
        # criterio distinto.
        $rutasCebo = @(Get-RutasKingsoft)
        $faltante = ""
        foreach ($ruta in $rutasCebo) {
            $dummy = Join-Path -Path $ruta -ChildPath "WPS Office"
            if (-not (Test-Path -LiteralPath $dummy)) { $faltante = $dummy; break }
            # Un cebo es ARCHIVO y tiene que llevar el ACL Deny: sin el, el
            # instalador puede borrarlo y crear el directorio encima, con lo
            # que la capa quedaria en nada. Si es DIRECTORIO es una
            # instalacion real y no lleva Deny (Colocar-Cebo la respeta),
            # asi que ahi no se comprueba nada.
            if (-not (Get-Item -LiteralPath $dummy -Force).PSIsContainer) {
                $denegados = 0
                try { $denegados = @((Get-Acl -LiteralPath $dummy).Access |
                        Where-Object AccessControlType -eq 'Deny').Count } catch { $denegados = 0 }
                if ($denegados -eq 0) { $faltante = "$dummy (existe pero SIN ACL Deny)"; break }
            }
        }
        $lista += [pscustomobject]@{
            Capa    = "cebo (instalacion)"
            Ok      = ($faltante -eq "")
            Detalle = $(if ($faltante -eq "") { "$($rutasCebo.Count) rutas protegidas" } else { "falta $faltante" })
        }

        return $lista
    }

    # Devuelve solo las capas que faltan, con su detalle, para que Activar
    # pueda informar de que va a reponer y en que se ha quedado corto.
    function Get-CapasFaltantes {
        return @(Get-EstadoCapas | Where-Object { -not $_.Ok } |
                 ForEach-Object { "$($_.Capa): $($_.Detalle)" })
    }

    # -------------------- ACTIVAR --------------------
    function Enable-WPSBlock {
        Show-Info "Aplicando bloqueo silencioso..."

        foreach ($exe in $executables) {
            $exeKey = "$ifeoBase\$exe"
            if (-not (Test-Path $exeKey)) { New-Item -Path $exeKey -Force | Out-Null }
            New-ItemProperty -Path $exeKey -Name "Debugger" -Value "cmd.exe /c exit" -PropertyType String -Force | Out-Null
            Write-Host "    [+] IFEO activado: $exe" -ForegroundColor Green
        }

        # El instalador de WPS elige el destino; en un equipo probado fue a
        # E:\Kingsoft y NO a AppData\Local\Kingsoft. Por eso el cebo se coloca
        # en todas las rutas que el instalador usa, y no solo en la por defecto.
        # $ruta = carpeta "Kingsoft" que se quiere dejar bloqueada.
        function Colocar-Cebo([string]$ruta) {
            $dummyFile = Join-Path -Path $ruta -ChildPath "WPS Office"

            # Si ya es un DIRECTORIO hay una instalacion real de WPS: no se
            # coloca el cebo (romperia el programa) y no se toca su ACL.
            if ((Test-Path -LiteralPath $dummyFile) -and (Get-Item -LiteralPath $dummyFile -Force).PSIsContainer) {
                Write-Host "    [i] Instalacion real en '$dummyFile': se omite el cebo" -ForegroundColor Yellow
                return
            }

            if (-not (Test-Path -LiteralPath $ruta)) { New-Item -ItemType Directory -Path $ruta -Force | Out-Null }
            if (-not (Test-Path -LiteralPath $dummyFile)) { New-Item -ItemType File -Path $dummyFile -Force | Out-Null }

            try {
                $acl = Get-Acl -LiteralPath $dummyFile
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $everyoneSid, "Write, Modify, Delete", [System.Security.AccessControl.AccessControlType]::Deny)
                $acl.AddAccessRule($rule) | Out-Null
                Set-Acl -LiteralPath $dummyFile -AclObject $acl
                Write-Host "    [+] Cebo protegido: $dummyFile" -ForegroundColor Green
            } catch {
                Show-Warning "ACL sobre $dummyFile : $($_.Exception.Message)"
            }
        }

        foreach ($ruta in @(Get-RutasKingsoft)) { Colocar-Cebo $ruta }

        $argumento = '-NoProfile -WindowStyle Hidden -Command "Get-Process -Name *wps* -ErrorAction SilentlyContinue | Stop-Process -Force"'
        $action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $argumento
        $trigger   = New-ScheduledTaskTrigger -AtLogOn

        # El principal se define por SID S-1-5-18 (LOCAL SYSTEM), no por nombre:
        # "NT AUTHORITY\SYSTEM" esta localizado en Windows en espanol (en es-CO
        # es "AUTORIDAD NT\SISTEMA") y el nombre literal puede no resolverse.
        # Es el mismo motivo por el que el ACL usa S-1-1-0 y no "Todos".
        $principal = New-ScheduledTaskPrincipal -UserId "S-1-5-18" -LogonType ServiceAccount -RunLevel Highest

        # Se verifica con Get-ScheduledTask en vez de dar por buena la llamada:
        # si el registro falla en silencio el bloqueo quedaria a medio hacer y
        # nadie se enteraria.
        $creada = $false
        foreach ($intento in @('principal', 'usuario')) {
            try {
                if ($intento -eq 'principal') {
                    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
                        -Principal $principal -Force -ErrorAction Stop | Out-Null
                } else {
                    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
                        -User "SYSTEM" -RunLevel Highest -Force -ErrorAction Stop | Out-Null
                }
            } catch {
                $motivo = $_.Exception.Message
                continue
            }
            if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { $creada = $true; break }
            $motivo = "el cmdlet no devolvio error pero la tarea no existe"
        }

        if ($creada) {
            Write-Host "    [+] Tarea programada '$taskName' creada y verificada" -ForegroundColor Green
        } else {
            Show-Warning "Tarea programada '$taskName' NO creada: $motivo"
        }

        # Capa de descarga: sin esto el instalador web (wps_office_inst.exe)
        # sigue pudiendo bajar el paquete completo aunque IFEO lo bloquee.
        Editar-Hosts -bloquear $true
    }

    # -------------------- DESACTIVAR --------------------
    function Disable-WPSBlock {
        Show-Info "Removiendo bloqueo silencioso..."

        foreach ($exe in $executables) {
            $exeKey = "$ifeoBase\$exe"
            if (Test-Path -LiteralPath $exeKey) {
                Remove-Item -LiteralPath $exeKey -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "    [-] IFEO removido: $exe" -ForegroundColor Gray
            }
        }

        # Quita el cebo de una carpeta "Kingsoft" si lo hay (es un ARCHIVO, no
        # un directorio). Si es directorio es una instalacion real y no se toca.
        function Quitar-Cebo([string]$ruta) {
            $dummyFile = Join-Path -Path $ruta -ChildPath "WPS Office"

            if (-not (Test-Path -LiteralPath $dummyFile)) { return }
            if ((Get-Item -LiteralPath $dummyFile -Force).PSIsContainer) {
                Write-Host "    [i] $dummyFile es una instalacion real: no se toca" -ForegroundColor Yellow
                return
            }

            # Quitar el ACE Deny ANTES de borrar: mientras el Deny siga ahi, nadie
            # (ni siquiera Administradores) puede borrar el archivo.
            try {
                $acl = Get-Acl -LiteralPath $dummyFile
                foreach ($rule in @($acl.Access | Where-Object { $_.AccessControlType -eq 'Deny' })) {
                    $acl.RemoveAccessRule($rule) | Out-Null
                }
                Set-Acl -LiteralPath $dummyFile -AclObject $acl
            } catch {
                Show-Warning "ACL sobre $dummyFile : $($_.Exception.Message)"
            }

            Remove-Item -LiteralPath $dummyFile -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $dummyFile) { Show-Warning "No se pudo remover: $dummyFile" }
            else { Write-Host "    [-] Cebo removido: $dummyFile" -ForegroundColor Gray }
        }

        foreach ($ruta in @(Get-RutasKingsoft)) { Quitar-Cebo $ruta }

        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "    [-] Tarea programada '$taskName' eliminada" -ForegroundColor Gray

        Editar-Hosts -bloquear $false
    }

    # -------------------- DESINSTALAR --------------------
    # Devuelve las instalaciones de WPS registradas en el registro. WPS instala
    # POR USUARIO, asi que hay que mirar en HKCU y en HKLM, y en las dos vistas
    # 64 y 32 bits.
    function Get-WPSInstallaciones {
        $hives = @($regUninstall)
        $encontradas = @()
        foreach ($hive in $hives) {
            if (-not (Test-Path -LiteralPath $hive)) { continue }
            foreach ($k in (Get-ChildItem -LiteralPath $hive -ErrorAction SilentlyContinue)) {
                $d = Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue
                if ($d.DisplayName -match '(?i)wps|kingsoft') {
                    $encontradas += [pscustomobject]@{
                        Nombre    = $d.DisplayName
                        Ruta      = $d.InstallLocation
                        Desinst   = $d.UninstallString
                        Silencioso= $d.QuietUninstallString
                    }
                }
            }
        }
        return $encontradas
    }

    # ¿Hay WPS instalado en este equipo? Solo cuenta evidencia de FICHEROS:
    #   - un directorio Kingsoft\WPS Office real (el cebo es ARCHIVO y no cuenta)
    #   - una clave de desinstalacion cuya InstallLocation EXISTE
    # Con solo el registro se escapa una instalacion cuya clave se borro a
    # medias; y lo contrario tambien: una clave HUERFANA (WPS ya borrado,
    # entrada sobrante) no es evidencia de nada, y darla por instalada haria
    # que el veredicto dijera "SIGUE INSTALADO" para siempre y que cada
    # Activar intentara limpiar restos alborotando los cebos.
    # Es la condicion que decide si Activar pasa por el paso de desinstalacion.
    function Test-WPSInstalado {
        # Ademas de las rutas de cebo (perfil y unidades fijas) se mira
        # Program Files: ahi NO se coloca cebo, pero si puede haber instalado.
        $rutas = @(Get-RutasKingsoft) + @(
            "$env:ProgramFiles\Kingsoft",
            "${env:ProgramFiles(x86)}\Kingsoft"
        )
        foreach ($ruta in $rutas) {
            $d = Join-Path -Path $ruta -ChildPath "WPS Office"
            if ((Test-Path -LiteralPath $d) -and (Get-Item -LiteralPath $d -Force).PSIsContainer) { return $true }
        }
        foreach ($inst in @(Get-WPSInstallaciones)) {
            if ($inst.Ruta -and (Test-Path -LiteralPath $inst.Ruta)) { return $true }
        }
        return $false
    }

    # Desinstala WPS si ya esta instalado.
    function Remove-WPSInstall {
        Show-Info "Buscando instalaciones de WPS Office..."

        $encontradas = @(Get-WPSInstallaciones)

        if ($encontradas.Count -eq 0) {
            Show-Info "No hay instalaciones de WPS Office registradas."
        }

        foreach ($inst in $encontradas) {
            Write-Host "    [i] $($inst.Nombre)" -ForegroundColor Cyan

            # Matar procesos ANTES: con WPS en ejecucion el desinstalador se
            # queda a medias y deja archivos bloqueados.
            Get-Process -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '(?i)^(wps|et|wpp|ksolaunch|wpscloudsvr|kcrashdumper)' } |
                ForEach-Object {
                    Write-Host "    [-] Deteniendo $($_.Name)" -ForegroundColor Yellow
                    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
                }
            Start-Sleep -Seconds 2

            # Ejecutable del desinstalador, sacado del UninstallString.
            $exe = $null
            if ($inst.Silencioso) { $exe = ($inst.Silencioso -replace '(?i)\s*/[A-Za-z].*$', '').Trim().Trim('"') }
            if (-not $exe -and $inst.Desinst) { $exe = ($inst.Desinst -replace '(?i)\s+/[A-Za-z].*$', '').Trim().Trim('"') }
            if (-not $exe -or -not (Test-Path -LiteralPath $exe)) {
                # Buscar un uninst.exe si el registro no daba una ruta valida.
                $raices = @()
                if ($inst.Ruta) { $raices += $inst.Ruta }
                $raices += @("$env:LOCALAPPDATA\Kingsoft", "$env:PROGRAMFILES\Kingsoft", "${env:ProgramFiles(x86)}\Kingsoft")
                foreach ($r in ($raices | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique)) {
                    $c = Get-ChildItem -LiteralPath $r -Filter "uninst*.exe" -Recurse -File -Force -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($c) { $exe = $c.FullName; break }
                }
            }

            if (-not $exe -or -not (Test-Path -LiteralPath $exe)) {
                Show-Warning "No se encontro el desinstalador de '$($inst.Nombre)'."
                continue
            }

            # Verificar firma antes de lanzarlo: no se ejecuta un desinstalador
            # que no este firmado por Kingsoft/WPS.
            $sig = Get-AuthenticodeSignature -LiteralPath $exe -ErrorAction SilentlyContinue
            if ($sig.Status -notin 'Valid', 'NotSigned') {
                Show-Warning "Firma del desinstalador no valida ($($sig.Status)): no se ejecuta."
                continue
            }

            Write-Host "    [i] Ejecutando desinstalacion silenciosa..." -ForegroundColor Cyan
            try {
                $p = Start-Process -FilePath $exe -ArgumentList "/S" -PassThru -Wait -ErrorAction Stop
                Write-Host "    [i] Codigo de salida: $($p.ExitCode)" -ForegroundColor Gray
            } catch {
                Show-Warning "El desinstalador fallo: $($_.Exception.Message)"
                continue
            }
        }

        # Limpieza de restos: el desinstalador de WPS deja carpetas y claves.
        Start-Sleep -Seconds 2
        $restos = @()
        foreach ($profile in (Obtener-Perfiles)) {
            $restos += Join-Path -Path $profile.FullName -ChildPath "AppData\Local\Kingsoft"
            $restos += Join-Path -Path $profile.FullName -ChildPath "AppData\Roaming\Kingsoft"
        }
        foreach ($unidad in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
                Where-Object { $_.Used -ne $null -and $_.Root -match '^[A-Z]:\\$' })) {
            $restos += Join-Path -Path $unidad.Root -ChildPath "Kingsoft"
        }

        foreach ($ruta in ($restos | Select-Object -Unique)) {
            if (-not (Test-Path -LiteralPath $ruta)) { continue }

            Remove-Item -LiteralPath $ruta -Recurse -Force -ErrorAction SilentlyContinue

            # El instalador deja archivos de la nube/actualizador con permisos
            # que deniegan incluso a Administradores (p. ej. los archivos
            # "xxx.dll_d_dNNNNN" de WPS Cloud). En ese caso se toma propiedad,
            # se resetea el ACL y se reintenta; sin esto la carpeta permanece
            # y el cebo no puede colocarse en su sitio.
            if (Test-Path -LiteralPath $ruta) {
                Write-Host "    [i] Permisos reacios en '$ruta': tomando propiedad..." -ForegroundColor Yellow
                $oculto = [System.Diagnostics.ProcessWindowStyle]::Hidden
                Start-Process -FilePath "takeown.exe" -ArgumentList "/F `"$ruta`" /R /D Y" `
                    -WindowStyle $oculto -Wait -ErrorAction SilentlyContinue
                Start-Process -FilePath "icacls.exe" -ArgumentList "`"$ruta`" /reset /T /C /Q" `
                    -WindowStyle $oculto -Wait -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $ruta -Recurse -Force -ErrorAction SilentlyContinue
            }

            if (Test-Path -LiteralPath $ruta) {
                Show-Warning "Restos NO borrados (sigue bloqueado): $ruta"
            } else {
                Write-Host "    [-] Restos eliminados: $ruta" -ForegroundColor Gray
            }
        }

        foreach ($k in @($regKingsoft)) {
            if (Test-Path -LiteralPath $k) {
                Remove-Item -LiteralPath $k -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "    [-] Clave eliminada: $k" -ForegroundColor Gray
            }
        }
    }

    # -------------------- RASTROS --------------------
    # ¿Hay en $ruta un CEBO puesto por el propio script? El cebo es un archivo
    # "WPS Office" con ACL Deny: eso NO es un rastro de WPS, es NUESTRA
    # proteccion, y borrarlo como si fuera rastro reabriria el hueco de
    # instalacion que se acaba de cerrar.
    function Test-CeboEn([string]$ruta) {
        $d = Join-Path -Path $ruta -ChildPath "WPS Office"
        if (-not (Test-Path -LiteralPath $d)) { return $false }
        if ((Get-Item -LiteralPath $d -Force).PSIsContainer) { return $false }
        $den = 0
        try { $den = @((Get-Acl -LiteralPath $d).Access | Where-Object AccessControlType -eq 'Deny').Count } catch { $den = 0 }
        return ($den -gt 0)
    }

    # DLLs de WPS todavia cargadas en memoria en el explorador. Windows no
    # deja borrar un fichero que otro proceso tenga cargado, y mientras WPS
    # estuvo instalado sus extensiones de shell entraron en explorer.exe.
    function Get-WPSCargadasEnExplorer {
        $lista = @()
        foreach ($proc in @(Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
            # Los modulos de un proceso ajeno no siempre son legibles; si no lo
            # son, se ignora en vez de tumbar la limpieza entera.
            $mods = @()
            try { $mods = @($proc.Modules) } catch { $mods = @() }
            foreach ($m in $mods) {
                if ("$($m.FileName)" -match '(?i)kingsoft|wps') { $lista += "$($m.ModuleName) (en PID $($proc.Id))" }
            }
        }
        return $lista
    }

    # Borra lo que WPS deja detras de su propio desinstalador. El
    # desinstalador se lleva el programa; esto se lleva el resto:
    #   carpetas        ProgramData, Program Files y Temp de cada perfil
    #   registro        Kingsoft en las 3 vistas y las entradas de desinstalacion
    #   asociaciones    .wps / .et / .wpp, ProgIDs y aplicaciones registradas
    #   shell           CLSIDs cuyo DLL viva bajo Kingsoft (qingshellext64.dll)
    #   arranques       Run / RunOnce
    #
    # Devuelve lo que NO se pudo borrar, y ese es el motivo de devolver algo:
    # el veredicto tiene que decir lo que hay de verdad en el equipo, no
    # "sin rastros" por intencion. Cada categoria se vuelve a comprobar
    # despues de intentar borrarla, por ese mismo motivo.
    #
    # Regla de seguridad: solo se borra algo atribuible con certeza a
    # Kingsoft/WPS (ruta bajo una carpeta Kingsoft, clave llamada Kingsoft,
    # DisplayName que casa con wps|kingsoft, o CLSID cuyo DLL este bajo
    # Kingsoft). Nada ajeno: por eso una clave de otro fabricante no se toca
    # aunque este en el mismo arbol.
    function Remove-WPSTraces {
        $siguen = @()
        $oculto = [System.Diagnostics.ProcessWindowStyle]::Hidden

        # --- carpetas que el desinstalador no se lleva ---
        $carpetas = @($rastrosCarpetas)
        foreach ($profile in (Obtener-Perfiles)) {
            $carpetas += Join-Path -Path $profile.FullName -ChildPath "AppData\Local\Temp\Kingsoft"
            $carpetas += Join-Path -Path $profile.FullName -ChildPath "AppData\Roaming\Kingsoft"
        }

        # --- explorador: hay que liberar los manejos antes de borrar ---
        # Si WPS estuvo instalado, sus extensiones de shell ya estan dentro de
        # explorer.exe, y Windows no deja borrar los ficheros mientras las
        # tenga cargadas. El takeown/icacls de abajo no sirve para eso: arregla
        # PERMISOS, no bloqueos de manejo. Lo comprobo un equipo real: quedaban
        # 26 MB de WPS sin poder borrar.
        #
        # Solo se reinicia si ademas hay carpetas que borrar: si no, se
        # cerrarian las ventanas del usuario sin motivo.
        $cargadas = @(Get-WPSCargadasEnExplorer)
        $hayCarpetas = $false
        foreach ($ruta in @($carpetas | Select-Object -Unique)) {
            if ((Test-Path -LiteralPath $ruta) -and -not (Test-CeboEn $ruta)) { $hayCarpetas = $true; break }
        }
        if ($cargadas.Count -and $hayCarpetas) {
            Write-Host "    [i] WPS sigue cargado en el explorador ($($cargadas.Count) DLLs): reiniciandolo para liberar los ficheros..." -ForegroundColor Yellow
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
                Start-Process -FilePath "explorer.exe" -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 3
            }
            $cargadas = @(Get-WPSCargadasEnExplorer)
            if ($cargadas.Count) { Show-Warning "Siguen cargadas tras reiniciar el explorador: $($cargadas -join ', ')" }
            else { Write-Host "    [+] Explorador reiniciado: extensiones de WPS descargadas" -ForegroundColor Green }
        } elseif ($cargadas.Count) {
            Show-Warning "Extensiones de WPS en el explorador (no hay carpetas que borrar, asi que no se reinicia): $($cargadas -join ', ')"
        }

        foreach ($ruta in ($carpetas | Select-Object -Unique)) {
            if (-not (Test-Path -LiteralPath $ruta)) { continue }
            if (Test-CeboEn $ruta) { continue }

            Remove-Item -LiteralPath $ruta -Recurse -Force -ErrorAction SilentlyContinue

            # El instalador deja ficheros con permisos que deniegan incluso a
            # Administradores (los "xxx.dll_d_dNNNNN" de WPS Cloud). Ahi se toma
            # propiedad, se resetea el ACL y se reintenta.
            if (Test-Path -LiteralPath $ruta) {
                Start-Process -FilePath "takeown.exe" -ArgumentList "/F `"$ruta`" /R /D Y" -WindowStyle $oculto -Wait -ErrorAction SilentlyContinue
                Start-Process -FilePath "icacls.exe" -ArgumentList "`"$ruta`" /reset /T /C /Q" -WindowStyle $oculto -Wait -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $ruta -Recurse -Force -ErrorAction SilentlyContinue
            }

            if (Test-Path -LiteralPath $ruta) { $siguen += "carpeta $ruta" }
            else { Write-Host "    [-] Carpeta de rastro eliminada: $ruta" -ForegroundColor Gray }
        }

        # --- claves de Kingsoft (vista de 32 bits incluida) ---
        foreach ($k in @($regKingsoft)) {
            if (-not (Test-Path -LiteralPath $k)) { continue }
            Remove-Item -LiteralPath $k -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $k) { $siguen += "clave $k" }
            else { Write-Host "    [-] Clave de registro eliminada: $k" -ForegroundColor Gray }
        }

        # --- entradas de desinstalacion sobrantes ---
        foreach ($base in @($regUninstall)) {
            if (-not (Test-Path -LiteralPath $base)) { continue }
            foreach ($sub in @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)) {
                $d = Get-ItemProperty -Path $sub.PSPath -ErrorAction SilentlyContinue
                if ("$($d.DisplayName)" -notmatch '(?i)wps|kingsoft') { continue }
                Remove-Item -LiteralPath $sub.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $sub.PSPath) { $siguen += "entrada '$($d.DisplayName)'" }
                else { Write-Host "    [-] Entrada de desinstalacion eliminada: $($d.DisplayName)" -ForegroundColor Gray }
            }
        }

        # --- asociaciones de fichero y extensiones de shell ---
        foreach ($base in @($regClasses)) {
            if (-not (Test-Path -LiteralPath $base)) { continue }

            # Formatos del propio WPS: Writer, Spreadsheets y Presentations.
            foreach ($ext in @(".wps", ".et", ".wpp")) {
                $p = Join-Path -Path $base -ChildPath $ext
                if (-not (Test-Path -LiteralPath $p)) { continue }
                Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $p) { $siguen += "asociacion $ext" }
                else { Write-Host "    [-] Asociacion eliminada: $ext" -ForegroundColor Gray }
            }

            # Aplicaciones registradas en el selector de programa.
            foreach ($nom in @("Applications\wps.exe", "Applications\et.exe", "Applications\wpp.exe")) {
                $p = Join-Path -Path $base -ChildPath $nom
                if (-not (Test-Path -LiteralPath $p)) { continue }
                Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $p) { $siguen += "aplicacion $nom" }
                else { Write-Host "    [-] Aplicacion registrada eliminada: $nom" -ForegroundColor Gray }
            }

            # CLSIDs cuyo DLL esta bajo una carpeta Kingsoft: ahi viven las
            # extensiones de shell (qingshellext64.dll y demas). Son las que se
            # cuelan en explorer.exe aunque IFEO bloquee la ejecucion de los
            # .exe, asi que sin esto la limpieza quedaria a medias.
            $clsid = Join-Path -Path $base -ChildPath "CLSID"
            if (-not (Test-Path -LiteralPath $clsid)) { continue }
            foreach ($c in @(Get-ChildItem -LiteralPath $clsid -ErrorAction SilentlyContinue)) {
                $dll = (Get-ItemProperty -Path "$($c.PSPath)\InprocServer32" -Name '(default)' -ErrorAction SilentlyContinue).'(default)'
                if ("$dll" -notmatch '(?i)kingsoft') { continue }
                Remove-Item -LiteralPath $c.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $c.PSPath) { $siguen += "extension $($c.PSChildName)" }
                else { Write-Host "    [-] Extension de shell eliminada: $($c.PSChildName)" -ForegroundColor Gray }
            }
        }

        # --- arranques automaticos ---
        foreach ($p in @($regRun)) {
            if (-not (Test-Path -LiteralPath $p)) { continue }
            $props = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue
            foreach ($prop in @($props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' })) {
                if ("$($prop.Value)" -notmatch '(?i)kingsoft|wps') { continue }
                Remove-ItemProperty -Path $p -Name $prop.Name -Force -ErrorAction SilentlyContinue
                if (Get-ItemProperty -Path $p -Name $prop.Name -ErrorAction SilentlyContinue) { $siguen += "arranque $($prop.Name)" }
                else { Write-Host "    [-] Arranque eliminado: $($prop.Name)" -ForegroundColor Gray }
            }
        }

        # --- servicios ---
        # Se exige que el ejecutable del servicio este bajo Kingsoft: con solo
        # el nombre borrar un servicio seria adivinar, y un servicio ajeno
        # perdido es mucho peor que un rastro que se queda.
        foreach ($svc in @(Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue)) {
            if ("$($svc.PathName)" -notmatch '(?i)kingsoft') { continue }
            & sc.exe delete $svc.Name | Out-Null
            $sigue = $null
            try { $sigue = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($svc.Name)'" -ErrorAction SilentlyContinue } catch { $sigue = $null }
            if ($sigue) { $siguen += "servicio $($svc.Name)" }
            else { Write-Host "    [-] Servicio eliminado: $($svc.Name)" -ForegroundColor Gray }
        }

        # --- tareas programadas propias de WPS ---
        # La nuestra ($taskName) queda fuera: es el limpiador silencioso, no un
        # rastro de WPS. Se comprueba el nombre de la tarea y su ubicacion.
        foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue |
                Where-Object { $_.TaskName -ne $taskName -and ("$($_.TaskName) $($_.TaskPath)" -match '(?i)kingsoft|wps') })) {
            Unregister-ScheduledTask -TaskName $t.TaskName -Confirm:$false -ErrorAction SilentlyContinue
            if (Get-ScheduledTask -TaskName $t.TaskName -ErrorAction SilentlyContinue) { $siguen += "tarea $($t.TaskName)" }
            else { Write-Host "    [-] Tarea eliminada: $($t.TaskName)" -ForegroundColor Gray }
        }

        # --- accesos directos del menu de inicio ---
        # Se mira el nombre del .lnk y la carpeta que lo contiene; no hace
        # falta resolver el destino con COM para saber que es de WPS.
        foreach ($profile in (Obtener-Perfiles)) {
            $menu = Join-Path -Path $profile.FullName -ChildPath "AppData\Roaming\Microsoft\Windows\Start Menu\Programs"
            if (-not (Test-Path -LiteralPath $menu)) { continue }
            foreach ($lnk in @(Get-ChildItem -LiteralPath $menu -Filter "*.lnk" -Recurse -File -Force -ErrorAction SilentlyContinue)) {
                if ($lnk.Name -notmatch '(?i)wps|kingsoft' -and $lnk.FullName -notmatch '(?i)kingsoft') { continue }
                Remove-Item -LiteralPath $lnk.FullName -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $lnk.FullName) { $siguen += "acceso directo $($lnk.Name)" }
                else { Write-Host "    [-] Acceso directo eliminado: $($lnk.Name)" -ForegroundColor Gray }
            }
        }

        return $siguen
    }

    # -------------------- ACTIVAR: FLUJO COMPLETO (2 PASOS) --------------------
    # Es lo que ejecuta la opcion 1 del menu y -Accion Activar. Dos pasos, en
    # este orden:
    #
    #   1) DESINSTALAR si WPS esta instalado
    #   2) validar y reponer las 4 capas
    #
    # El orden NO es estetico: mientras exista el DIRECTORIO real de la
    # instalacion, Colocar-Cebo lo respeta y no puede ocupar su ruta, asi que
    # el cebo quedaria fuera de sitio hasta el proximo Activar. Y IFEO solo
    # corta la ejecucion de los .exe: las extensiones de shell de WPS
    # (qingshellext64.dll y demas) siguen cargadas en explorer.exe mientras el
    # programa este instalado, y solo la desinstalacion las saca.
    #
    # Si la desinstalacion falla NO se aborta: se siguen aplicando las capas
    # (mejor bloqueado que instalado y sin bloquear) y el veredicto final
    # refleja que sigue instalado, en vez de darlo por hecho.
    #
    # En el caso real de uso: nos llaman y WPS YA esta instalado. Una sola
    # ejecucion de la opcion 1 deja el equipo limpio y bloqueado.
    function Invoke-ActivarWPS {

        # ---- PASO 1: desinstalar ----
        Show-Info "Paso 1/2: desinstalando WPS Office si esta instalado..."
        if (-not (Test-WPSInstalado)) {
            Write-Host "    [i] WPS Office no esta instalado; nada que desinstalar" -ForegroundColor DarkGray
        } else {
            Remove-WPSInstall
            # Se VUELVE a comprobar en vez de dar por buena la llamada al
            # desinstalador: un /S que devuelve "falta reinicio" o que ni
            # llego a arrancar deja los archivos donde estaban.
            if (Test-WPSInstalado) {
                Show-Warning "WPS Office SIGUE INSTALADO tras la desinstalacion (¿falta reinicio?)."
            } else {
                Write-Host "    [+] WPS Office desinstalado" -ForegroundColor Green
            }
        }

        # Rastros: se comprueban SIEMPRE, tambien cuando no hay instalacion.
        # Puede quedar registro, carpetas o asociaciones de una instalacion
        # anterior, o de un desinstalado a medias hecho a mano por el usuario.
        # Si algo no se pudo borrar se avisa aqui, y el veredicto final lo
        # repite: no se puede decir "equipo limpio" sobre lo que no se ha
        # comprobado.
        $rastros = @(Remove-WPSTraces)
        if ($rastros.Count) { Show-Warning "Rastros que NO se pudieron borrar: $($rastros -join ' | ')" }

        # ---- PASO 2: las 4 capas ----
        # Se muestra la validacion paso a paso: el usuario quiere comprobar el
        # bloqueo sin tener que desactivarlo antes para probar. Lo que esta
        # bien se deja tal cual; lo que falta, se aplica.
        Show-Info "Paso 2/2: validando las 4 capas del bloqueo..."
        foreach ($c in (Get-EstadoCapas)) {
            if ($c.Ok) { Write-Host "    [+] $($c.Capa)  $($c.Detalle)  -> ya estaba, se deja" -ForegroundColor Green }
            else       { Write-Host "    [-] $($c.Capa)  $($c.Detalle)  -> SE APLICA" -ForegroundColor Yellow }
        }

        $faltan = Get-CapasFaltantes
        if ($faltan) {
            Show-Info "Reponiendo: $($faltan -join ' | ')"
            Enable-WPSBlock
        }

        # ---- VEREDICTO ----
        # Se vuelve a medir TODO al final: el resultado sale de lo que hay en
        # el equipo, no de la intencion de lo que se acaba de intentar.
        $faltanTras    = @(Get-CapasFaltantes)
        $sigueInstalado = Test-WPSInstalado

        Draw-Line
        if ($faltanTras.Count -eq 0 -and -not $sigueInstalado -and $rastros.Count -eq 0) {
            Show-Success "Bloqueo WPS ACTIVADO - equipo limpio (sin WPS ni rastros, 4 capas completas)"
        } elseif ($faltanTras.Count -eq 0 -and -not $sigueInstalado) {
            Show-Warning "4 capas activas y sin instalacion, pero quedan rastros: $($rastros -join ' | ')"
        } elseif ($faltanTras.Count -eq 0) {
            Show-Warning "Las 4 capas estan activas, pero WPS Office SIGUE INSTALADO (¿falta reinicio?)."
        } else {
            Show-Warning "Bloqueo ACTIVADO pero incompleto: $($faltanTras -join ' | ')"
        }
    }

    # -------------------- MODO NO INTERACTIVO --------------------
    # Permite usar la funcion sin el menu: -Accion Activar / Desactivar / Estado.
    if ($Accion -ne 'Menu') {
        $estado = Get-EstadoWPS
        switch ($Accion) {
            'Estado' {
                if ($estado) { Write-Host "  Estado: [ BLOQUEADO ]" -ForegroundColor Red }
                else         { Write-Host "  Estado: [ PERMISIVO ]" -ForegroundColor Green }
                # Informe por capa: el rotulo de arriba refleja IFEO (capa de
                # ejecucion), pero el bloqueo puede estar incompleto en las
                # otras. Se listan las 4 para poder diagnosticar a distancia
                # sin tener que preguntar al usuario que ve en pantalla.
                foreach ($c in (Get-EstadoCapas)) {
                    if ($c.Ok) { Write-Host "    [+] $($c.Capa)  $($c.Detalle)" -ForegroundColor Green }
                    else       { Write-Host "    [-] $($c.Capa)  $($c.Detalle)" -ForegroundColor Yellow }
                }
                return
            }
            'Activar' {
                # El mismo flujo de 2 pasos de la opcion 1 del menu: primero
                # desinstala si hace falta, luego valida y reponer las capas.
                Invoke-ActivarWPS
                return
            }
            'Desactivar' {
                # A proposito usa Get-EstadoWPS (solo IFEO) y NO
                # Get-CapasFaltantes: si IFEO esta puesto y hosts fallo, hay
                # que poder desactivar aunque el bloqueo este incompleto.
                if (-not $estado) { Show-Warning "El bloqueo no estaba activo."; return }
                Disable-WPSBlock
                Draw-Line; Show-Success "Bloqueo WPS DESACTIVADO"
                return
            }
            'Desinstalar' {
                # Independiente del estado del bloqueo: se puede desinstalar
                # con el bloque puesto o quitado. Ademas de desinstalar se
                # borran los rastros, que es lo que deja el desinstalador.
                Remove-WPSInstall
                $rastros = @(Remove-WPSTraces)
                if ($rastros.Count) { Show-Warning "Rastros que NO se pudieron borrar: $($rastros -join ' | ')" }
                Draw-Line; Show-Success "Desinstalacion de WPS finalizada"
                return
            }
        }
    }

    # -------------------- MENU --------------------
    while ($true) {
        $estado = Get-EstadoWPS
        Write-Host ""
        Draw-Line
        Write-Host "  BLOQUEO WPS OFFICE" -ForegroundColor Cyan
        Write-Host "  Estado: " -NoNewline
        if ($estado) { Write-Host "[ BLOQUEADO ]" -ForegroundColor Red }
        else         { Write-Host "[ PERMISIVO ]" -ForegroundColor Green }
        # El rotulo refleja IFEO (ejecucion). Si otra capa fallo, se avisa:
        # sin esto el usuario ve "BLOQUEADO" y no se entera de que la
        # descarga o la persistencia siguen abiertas.
        $faltan = Get-CapasFaltantes
        if ($faltan) { Write-Host "  Capas incompletas: $($faltan -join ', ')" -ForegroundColor Yellow }
        Draw-Line
        Write-Host "  1. Activar bloqueo (desinstala WPS Office si esta + aplica los 4 bloqueos)" -ForegroundColor White
        Write-Host "  2. Desactivar bloqueo (no re-instala nada)" -ForegroundColor White
        Write-Host "  0. Volver" -ForegroundColor Red
        # Entrada protegida, AUTOCONTENIDA a proposito (sin helpers externos):
        # el mismo cuerpo vive en HerramientasIT.ps1, optimizador.ps1 y
        # Bloquear-WPS.ps1, y si llamara a una funcion auxiliar dejaria de
        # funcionar en el fichero que no la tenga. Sin consola con entrada,
        # Read-Host devuelve "nada" (AutomationNull) o cadena vacia -un switch
        # sobre eso no llega ni al 'default' y el while giraria para siempre-
        # o lanza excepcion en PowerShell 5.1 no interactivo. Vacia = salir del
        # menu, igual que "0. Volver": asi la opcion 13 nunca queda colgada.
        $op = ""
        try { $op = Read-Host "  Selecciona" } catch { $op = "" }
        if ([string]::IsNullOrWhiteSpace([string]$op)) {
            Show-Info "Sin respuesta en el menu WPS: volviendo"
            return
        }
        switch ($op) {
            "1" { Invoke-ActivarWPS }
            "2" { if (-not $estado) { Show-Warning "El bloqueo no estaba activo." } else { Disable-WPSBlock; Draw-Line; Show-Success "Bloqueo WPS DESACTIVADO" } }
            "0" { return }
            default { Show-Warning "Opcion no valida." }
        }
    }
}

function Invoke-OrganizaFuentes {
# ==============================================================================
# ORGANIZAR FUENTES: Centraliza fuentes del NAS y elimina duplicados
#
# Uso:
#   .\organizaFuentes.ps1 -Ruta "Z:\" -Destino "Z:\Red Diseño\Fuentes" [-Real] [-SinExclusiones]
#
# Parametros:
#   -Ruta             Carpeta a escanear (por defecto: la carpeta actual)
#   -Destino          Carpeta central donde mover/extraer (por defecto: Z:\FUENTES)
#   -Real             Aplica movimientos, extracciones y borrados (por defecto es SIMULACIÓN)
#   -SinExclusiones   Escanea también AppData y carpetas protegidas. PELIGROSO.
#   -Log              Guarda registro de la operación en un archivo .txt
#   -Respaldo         Mueve comprimidos eliminados a carpeta de respaldo
#   -AniosMinimos     Solo mover fuentes de hace X años (ej: -AniosMinimos 3)
#   -ExcluirSistema   Excluir fuentes del sistema (Windows\fonts, etc.)
#
# Extensiones de fuente: .ttf .otf .ttc .otc .fnt .fon .woff .woff2
# Comprimidos inspeccionados: .zip .rar .7z
#
# REGLA CLAVE:
#   Si un comprimido contiene un EJECUTABLE (.exe, .msi, setup.exe, ...) NO es un
#   archivo de fuentes: es un instalador. Se IGNORA y se deja para
#   reubicarInstaladores.ps1.
# ==============================================================================

    # --------------------------------------------------------------------------
    # PARAMETROS: el bloque param() del script standalone se elimino; cada
    # parametro se resuelve aqui con prompts del estilo de la suite.
    # --------------------------------------------------------------------------
    $Ruta = Read-HostStyled -Prompt "Carpeta a escanear (Enter = carpeta actual)" -Icon "?" -DefaultValue ""
    $Destino = Read-HostStyled -Prompt "Carpeta destino donde centralizar las fuentes (obligatorio, ej. Z:\FUENTES)" -Icon "?" -DefaultValue ""
    $op = Read-HostStyled -Prompt "Ejecutar real? [1] Si [2] No (simulacion)" -Icon "?" -DefaultValue "2"
    $Real = ($op -eq "1")
    $SinExclusiones = Preguntar-SiNo -Mensaje "Sin exclusiones (escanear tambien AppData y carpetas protegidas)? PELIGROSO"
    $Log = Preguntar-SiNo -Mensaje "Guardar registro de la operacion en un archivo .txt?"
    $Respaldo = Preguntar-SiNo -Mensaje "Mover comprimidos eliminados a carpeta de respaldo (_respaldo_fuentes)?"
    $AniosMinimos = 0
    $aniosMinimosInput = Read-HostStyled -Prompt "Anios minimos de antiguedad para mover fuentes (0 = todas)" -Icon "?" -DefaultValue "0"
    if ($aniosMinimosInput -match '^\d+$') { $AniosMinimos = [int]$aniosMinimosInput }
    $ExcluirSistema = Preguntar-SiNo -Mensaje "Excluir ademas las fuentes del sistema (Windows\Fonts, etc.)?"
    $SinMenu = -not (Preguntar-SiNo -Mensaje "Mostrar tambien el menu interactivo original? (los parametros ya se han pedido arriba)")

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
            Show-Error "PowerShell 7 no esta instalado y se necesita Administrador para instalarlo."; return
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
            Show-Error "No se pudo instalar PowerShell 7."; return
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
    return
}
# =================== FIN AUTO-ARRANQUE POWERSHELL 7 ===================


# Configurar encoding (compatible PS5.1 y PS7)
$esPS7 = $PSVersionTable.PSVersion.Major -ge 7
if ($esPS7) {
    $OutputEncoding = [System.Text.Encoding]::UTF8
} else {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
}

# ==============================================================================
# FUNCIONES AUXILIARES
# ==============================================================================

function Formatear-Tamanio([long]$bytes) {
    if ($bytes -ge 1GB) { "{0:N2} GB" -f ($bytes / 1GB) }
    elseif ($bytes -ge 1MB) { "{0:N2} MB" -f ($bytes / 1MB) }
    elseif ($bytes -ge 1KB) { "{0:N2} KB" -f ($bytes / 1KB) }
    else { "$bytes bytes" }
}

function Escribir-Log {
    param([string]$Mensaje, [string]$Tipo = "INFO")
    $marca = "[$(Get-Date -Format 'HH:mm:ss')] [$Tipo]"
    $linea = "$marca $Mensaje"
    if ($script:logStream) {
        $script:logStream.WriteLine($linea)
        $script:logStream.Flush()
    }
}

function Agregar-Log {
    param([string]$Accion, [string]$Archivo, [string]$Detalle = "")
    $script:registrosLog += [PSCustomObject]@{
        Hora    = Get-Date -Format 'HH:mm:ss'
        Accion  = $Accion
        Archivo = $Archivo
        Detalle = $Detalle
    }
}

# ==============================================================================
# MENU INTERACTIVO
# ==============================================================================

if (-not $SinMenu -and [string]::IsNullOrWhiteSpace($Destino)) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  ORGANIZAR FUENTES" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""

    # Carpeta a escanear
    Write-Host "  Carpeta a escanear (Enter = carpeta actual):" -ForegroundColor White
    $rutaInput = Read-Host "  Ruta"
    if (-not [string]::IsNullOrWhiteSpace($rutaInput)) { $Ruta = $rutaInput }

    # Destino
    Write-Host ""
    Write-Host "  Carpeta destino (obligatorio):" -ForegroundColor White
    do {
        $destinoInput = Read-Host "  Destino"
    } while ([string]::IsNullOrWhiteSpace($destinoInput))
    $Destino = $destinoInput

    # Modo
    Write-Host ""
    Write-Host "  Modo de ejecucion:" -ForegroundColor White
    Write-Host "    1) Simulacion (revisar antes de aplicar)" -ForegroundColor Yellow
    Write-Host "    2) Movimiento real (aplicar cambios)" -ForegroundColor Yellow
    Write-Host ""
    do {
        $opcionModo = Read-Host "  Seleccione (1-2)"
    } while ($opcionModo -notmatch '^[1-2]$')
    if ($opcionModo -eq "2") { $Real = $true }

    # Filtro por antigüedad
    Write-Host ""
    Write-Host "  Filtrar por antigüedad (Enter = todas):" -ForegroundColor White
    Write-Host "    Ejemplo: 3 = solo fuentes con 3 o mas años" -ForegroundColor DarkGray
    $aniosInput = Read-Host "  Anios minimos"
    if ($aniosInput -match '^\d+$') { $AniosMinimos = [int]$aniosInput }

    # Log
    Write-Host ""
    Write-Host "  Guardar log de la operacion? (s/n):" -ForegroundColor White
    $logInput = Read-Host "  Log"
    if ($logInput -match '^[sS]') { $Log = $true }

    # Respaldo
    Write-Host ""
    Write-Host "  Respaldo de comprimidos eliminados? (s/n):" -ForegroundColor White
    Write-Host "    (Guarda los .zip/.rar/.7z en _respaldo_fuentes/)" -ForegroundColor DarkGray
    $respaldoInput = Read-Host "  Respaldo"
    if ($respaldoInput -match '^[sS]') { $Respaldo = $true }

    Write-Host ""
}

# ==============================================================================
# CONFIGURACION INICIAL
# ==============================================================================

# 1. VERIFICAR ADMIN
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "AVISO: No se ejecuta como Administrador." -ForegroundColor Yellow
    Write-Host "Si el destino o las carpetas protegidas requieren permisos elevados, el proceso puede fallar." -ForegroundColor Yellow
}

# 2. DETERMINAR CARPETA A ESCANEAR
if ([string]::IsNullOrWhiteSpace($Ruta)) {
    $rutaEscaneo = (Get-Location).Path
} else {
    $resuelta = Resolve-Path -Path $Ruta -ErrorAction SilentlyContinue
    if (-not $resuelta) {
        Write-Host "ERROR: La ruta no existe: $Ruta" -ForegroundColor Red
        Show-Error "La ruta no existe: $Ruta"; return
    }
    $rutaEscaneo = $resuelta.Path
}
$rutaEscaneo = $rutaEscaneo.TrimEnd('\', '/')

# 3. NORMALIZAR DESTINO
if ([string]::IsNullOrWhiteSpace($Destino)) {
    Write-Host "ERROR: Debes especificar un destino." -ForegroundColor Red
    Show-Error "Debes especificar un destino."; return
}
if (-not [System.IO.Path]::IsPathRooted($Destino)) {
    $Destino = Join-Path (Get-Location).Path $Destino
}
$Destino = $Destino.TrimEnd('\', '/')
if ([string]::Equals($Destino, $rutaEscaneo, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Host "ERROR: El destino no puede ser la misma carpeta que se escanea." -ForegroundColor Red
    Show-Error "El destino no puede ser la misma carpeta que se escanea."; return
}

# 4. EXTENSIONES
$extensionesFuente = @("*.ttf", "*.otf", "*.ttc", "*.otc", "*.fnt", "*.fon", "*.woff", "*.woff2")
$extensionesFuenteExt = @(".ttf", ".otf", ".ttc", ".otc", ".fnt", ".fon", ".woff", ".woff2")
$extensionesComprimidas = @("*.zip", "*.rar", "*.7z")

# 5. EXCLUSIONES
$excluir = @(
    "AppData",
    "Windows",
    "Windows.old",
    "Program Files",
    "Program Files (x86)",
    "ProgramData",
    "System Volume Information",
    '\$Recycle.Bin',
    "WindowsApps"
)

if ($ExcluirSistema) {
    $excluir += @(
        "Fonts",
        "Fuentes",
        "C:\Windows\Fonts",
        "$env:SystemRoot\Fonts"
    )
}

# Construir patrón regex de exclusiones
$patronSegmentos = $excluir | ForEach-Object { [regex]::Escape($_) }
$patronExcluir = ($patronSegmentos | ForEach-Object { "(?:^|[\\/])$_(?:[\\/]|$)" }) -join '|'

# Excluir la carpeta destino del escaneo
$nombreDestino = Split-Path $Destino -Leaf
if ($excluir -notcontains $nombreDestino) {
    $excluir += $nombreDestino
    $patronSegmentos = $excluir | ForEach-Object { [regex]::Escape($_) }
    $patronExcluir = ($patronSegmentos | ForEach-Object { "(?:^|[\\/])$_(?:[\\/]|$)" }) -join '|'
}

# 6. CARPETAS PROTEGIDAS
$carpetasProtegidas = @(
    "Desktop", "Escritorio", "Documents", "Documentos", "Downloads", "Descargas",
    "Music", "Música", "Pictures", "Imágenes", "Videos", "Vídeos",
    "AppData", "Public", "Público", "OneDrive", "Favorites", "Favoritos",
    "Contacts", "Contactos", "Links", "Saved Games", "Juegos guardados",
    "Searches", "3D Objects", "Objetos 3D"
)

# 7. CONFIGURAR LOG (con StreamWriter para mejor rendimiento)
$script:rutaLog = $null
$script:logStream = $null
$script:registrosLog = @()
if ($Log) {
    $fecha = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:rutaLog = Join-Path $rutaEscaneo "log_fuentes_$fecha.txt"
    $script:logStream = [System.IO.StreamWriter]::new($script:rutaLog, $true, [System.Text.Encoding]::UTF8)
    Escribir-Log "Inicio de operacion"
    Escribir-Log "Origen: $rutaEscaneo"
    Escribir-Log "Destino: $Destino"
    Escribir-Log "Modo: $(if ($Real) { 'REAL' } else { 'SIMULACION' })"
    if ($AniosMinimos -gt 0) { Escribir-Log "Filtro: solo fuentes con $AniosMinimos o mas años" }
}

# 8. CARPETA DE RESPALDO
$carpetaRespaldo = $null
if ($Respaldo) {
    $carpetaRespaldo = Join-Path $rutaEscaneo "_respaldo_fuentes"
    if ($Real -and -not (Test-Path $carpetaRespaldo)) {
        New-Item -ItemType Directory -Path $carpetaRespaldo -Force | Out-Null
    }
}

# ==============================================================================
# MOSTRAR CONFIGURACION
# ==============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  ORGANIZAR FUENTES (.ttf .otf .ttc .otc .fnt .fon .woff .woff2)" -ForegroundColor Cyan
Write-Host "  PowerShell: $($PSVersionTable.PSVersion) | Modo: $(if ($esPS7) { 'Paralelo' } else { 'Secuencial' })" -ForegroundColor DarkGray
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "Carpeta : $rutaEscaneo"
Write-Host "Destino : $Destino"
Write-Host "Modo    : $(if ($Real) { 'MOVIMIENTO REAL' } else { 'SIMULACION' })" -ForegroundColor Yellow
if ($AniosMinimos -gt 0) { Write-Host "Filtro  : Solo fuentes con $AniosMinimos o mas años" -ForegroundColor Yellow }
if ($Log) { Write-Host "Log     : $($script:rutaLog)" -ForegroundColor DarkGray }
if ($Respaldo) { Write-Host "Respaldo: $carpetaRespaldo" -ForegroundColor DarkGray }
if ($SinExclusiones) {
    Write-Host "Exclusiones: DESACTIVADAS (incluye AppData, PELIGROSO)" -ForegroundColor Red
} else {
    Write-Host "Exclusiones: $($excluir -join ', ')" -ForegroundColor DarkGray
}
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ==============================================================================
# FUNCIONES DE HERRAMIENTA DE COMPRESION
# ==============================================================================

function Buscar-Herramienta {
    $portable64 = Join-Path $PSScriptRoot '7-Zip64\7z.exe'
    if (Test-Path $portable64) { return @{ Tipo = '7z'; Ruta = $portable64 } }

    $completo = Join-Path $PSScriptRoot '7zip\7z.exe'
    if (Test-Path $completo) { return @{ Tipo = '7z'; Ruta = $completo } }

    $reducido = Join-Path $PSScriptRoot '7zr.exe'
    if (Test-Path $reducido) { return @{ Tipo = '7zr'; Ruta = $reducido } }

    $sys7z = @(
        (Join-Path $env:ProgramFiles '7-Zip\7z.exe'),
        (Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe')
    )
    foreach ($p in $sys7z) { if (Test-Path $p) { return @{ Tipo = '7z'; Ruta = $p } } }

    $sysrar = @(
        (Join-Path $env:ProgramFiles 'WinRAR\Rar.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'WinRAR\Rar.exe'),
        (Join-Path $env:ProgramFiles 'WinRAR\WinRAR.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'WinRAR\WinRAR.exe')
    )
    foreach ($p in $sysrar) { if (Test-Path $p) { return @{ Tipo = 'rar'; Ruta = $p } } }

    $syswz = @(
        (Join-Path $env:ProgramFiles 'WinZip\WZZIP.EXE'),
        (Join-Path ${env:ProgramFiles(x86)} 'WinZip\WZZIP.EXE')
    )
    foreach ($p in $syswz) { if (Test-Path $p) { return @{ Tipo = 'zip'; Ruta = $p } } }

    return $null
}

function Obtener-7zCompleto {
    param([string]$Ruta7zr)

    $carpetaDestino = Join-Path $PSScriptRoot '7zip'
    $completo = Join-Path $carpetaDestino '7z.exe'
    if (Test-Path $completo) { return $completo }

    $version = '26.02'
    $url = "https://github.com/ip7z/7zip/releases/download/$version/7z$($version.Replace('.', ''))-x64.exe"
    $tmpDir = if ($env:TEMP) { $env:TEMP } elseif ($env:TMP) { $env:TMP } else { (Get-Location).Path }
    $sfx = Join-Path $tmpDir '7zsetup.exe'

    Write-Host "  Descargando 7-Zip portable ($url)..." -ForegroundColor Cyan
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $sfx -UseBasicParsing
        if (-not (Test-Path $carpetaDestino)) {
            New-Item -ItemType Directory -Path $carpetaDestino -Force | Out-Null
        }
        & $Ruta7zr x -y "-o$carpetaDestino" $sfx | Out-Null
        Remove-Item $sfx -Force -ErrorAction SilentlyContinue
        Write-Host "  OK: 7-Zip portable extraído en $carpetaDestino" -ForegroundColor Green
    } catch {
        Write-Host "  [ERROR] No se pudo obtener el 7-Zip completo: $($_.Exception.Message)" -ForegroundColor Red
    }

    if (Test-Path $completo) { return $completo }
    return $null
}

function Listar-Comprimido {
    param([string]$RutaArchivo, $Herramienta)

    $ext = [System.IO.Path]::GetExtension($RutaArchivo).ToLowerInvariant()
    $nombres = @()

    try {
        if ($ext -eq '.zip') {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            $zip = [System.IO.Compression.ZipFile]::OpenRead($RutaArchivo)
            $nombres = @($zip.Entries | ForEach-Object { $_.FullName })
            $zip.Dispose()
            return $nombres
        }

        if (-not $Herramienta) { return @() }

        if ($Herramienta.Tipo -eq '7z' -or $Herramienta.Tipo -eq '7zr') {
            $salida = & $Herramienta.Ruta l -slt $RutaArchivo 2>&1
            $nombreArchivo = [regex]::Escape([System.IO.Path]::GetFileName($RutaArchivo))
            $nombres = @($salida | Where-Object { $_ -match '^Path = ' } |
                ForEach-Object { ($_ -split '= ', 2)[1] } |
                Where-Object { $_ -and $_ -notmatch "(^|[\\/])$nombreArchivo$" })
        } elseif ($Herramienta.Tipo -eq 'rar') {
            $salida = & $Herramienta.Ruta l $RutaArchivo 2>&1
            $nombres = @($salida | Where-Object {
                    $_ -match '\S' -and
                    $_ -notmatch '(?i)^(RAR|Archive|--------|$\s*$)' -and
                    $_ -notmatch '(?i)^\s*(Name|Path)\s' } |
                ForEach-Object {
                    $parts = $_ -split '\s{2,}'
                    if ($parts.Count -gt 0) { $parts[0].Trim() }
                } |
                Where-Object { $_ -and $_ -notmatch '[\\/]:\\' -and $_ -ne 'Name' })
        } elseif ($Herramienta.Tipo -eq 'zip') {
            $salida = & $Herramienta.Ruta -v $RutaArchivo 2>&1
            $nombres = @($salida | Where-Object { $_ -match '^\s*\d+\s+[\d\-/]+\s+[\d:]+\s+(.+)$' } |
                ForEach-Object { ($_ -split '\s{2,}', 2)[-1].Trim() })
        }
    } catch {
        return @()
    }

    return $nombres
}

function Clasificar-ComprimidoFuentes {
    param([string[]]$Nombres)

    if (-not $Nombres) { return 'desconocido' }

    $extEjecutable = @('.exe', '.msi', '.msix', '.msp', '.iso', '.cab', '.inf', '.bat', '.cmd', '.setup')
    $patronSetup = '(?i)(^|[^a-z0-9])(setup|install|autorun|uninstall|update)([^a-z0-9]|$)'

    $hayEjecutable = $false
    $hayFuente = $false
    foreach ($n in $Nombres) {
        $ext = [System.IO.Path]::GetExtension($n).ToLowerInvariant()
        $base = [System.IO.Path]::GetFileName($n)
        if ($extEjecutable -contains $ext -or $base -match $patronSetup) {
            $hayEjecutable = $true
        } elseif ($extensionesFuenteExt -contains $ext) {
            $hayFuente = $true
        }
    }

    if ($hayEjecutable) { return 'instalador' }
    if ($hayFuente) { return 'fuentes' }
    return 'sin-fuentes'
}

function Extraer-Fuentes {
    param([string]$RutaArchivo, $Herramienta, [string]$CarpetaTemporal)

    if (-not $Herramienta) { return $null }

    $ext = [System.IO.Path]::GetExtension($RutaArchivo).ToLowerInvariant()

    try {
        if ($ext -eq '.zip') {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            $zip = [System.IO.Compression.ZipFile]::OpenRead($RutaArchivo)
            try {
                foreach ($entrada in $zip.Entries) {
                    $e = [System.IO.Path]::GetExtension($entrada.FullName).ToLowerInvariant()
                    if ($extensionesFuenteExt -contains $e -and -not $entrada.FullName.Contains('..')) {
                        $rutaRel = $entrada.FullName -replace '/', '\'
                        $rutaDest = Join-Path $CarpetaTemporal $rutaRel
                        $dirDest = Split-Path $rutaDest -Parent
                        if (-not (Test-Path $dirDest)) {
                            New-Item -ItemType Directory -Path $dirDest -Force | Out-Null
                        }
                        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entrada, $rutaDest, $true)
                    }
                }
            } finally {
                $zip.Dispose()
            }
        } else {
            if ($Herramienta.Tipo -eq 'rar') {
                & $Herramienta.Ruta x -o+ $RutaArchivo "$CarpetaTemporal\" | Out-Null
            } else {
                $filtros = $extensionesFuenteExt | ForEach-Object { "-ir!*$_" }
                & $Herramienta.Ruta x -y "-o$CarpetaTemporal" $filtros $RutaArchivo | Out-Null
            }
        }
    } catch {
        return $null
    }

    return @(Get-ChildItem -Path $CarpetaTemporal -Recurse -File -ErrorAction SilentlyContinue)
}

# ==============================================================================
# FUNCIONES DE MOVIMIENTO
# ==============================================================================

function Mover-ArchivoDedup {
    param([System.IO.FileInfo]$Archivo, [string]$CarpetaDestino)

    # Verificar filtro por antigüedad
    if ($AniosMinimos -gt 0) {
        $limite = (Get-Date).AddYears(-$AniosMinimos)
        if ($Archivo.LastWriteTime -gt $limite) {
            Write-Host "    [>] Omitido (menos de $AniosMinimos años): $($Archivo.Name)" -ForegroundColor DarkGray
            Agregar-Log -Accion "OMITIDO" -Archivo $Archivo.FullName -Detalle "Menos de $AniosMinimos años"
            return
        }
    }

    $destinoArchivo = Join-Path $CarpetaDestino $Archivo.Name
    $info = Get-Item $destinoArchivo -ErrorAction SilentlyContinue

    if ($info -and -not $info.PSIsContainer) {
        if ($Archivo.LastWriteTime -ge $info.LastWriteTime) {
            if ($Real) {
                Remove-Item -Path $destinoArchivo -Force -ErrorAction SilentlyContinue
                Move-Item -Path $Archivo.FullName -Destination $destinoArchivo -ErrorAction SilentlyContinue
                # Verificar que el archivo se movió correctamente
                if (Test-Path $destinoArchivo) {
                    Remove-Item -Path $Archivo.FullName -Force -ErrorAction SilentlyContinue
                    $script:reemplazados++
                    Write-Host "    [~] Reemplazado: $($Archivo.Name)" -ForegroundColor Yellow
                    Agregar-Log -Accion "REEMPLAZADO" -Archivo $Archivo.Name -Detalle "Origen más reciente"
                } else {
                    Write-Host "    [ERROR] Fallo al mover: $($Archivo.Name)" -ForegroundColor Red
                    Agregar-Log -Accion "ERROR" -Archivo $Archivo.FullName -Detalle "No se pudo verificar destino"
                }
            } else {
                Write-Host "    [~] Se reemplazará: $($Archivo.Name)" -ForegroundColor Yellow
            }
        } else {
            if ($Real) {
                Remove-Item -Path $Archivo.FullName -Force -ErrorAction SilentlyContinue
                $script:borradosSuelto++
                Write-Host "    [X] Eliminado (destino más reciente): $($Archivo.Name)" -ForegroundColor Red
                Agregar-Log -Accion "ELIMINADO" -Archivo $Archivo.FullName -Detalle "Destino más reciente"
            } else {
                Write-Host "    [X] Se eliminará (destino más reciente): $($Archivo.Name)" -ForegroundColor Red
            }
        }
        return
    }

    # No existe -> mover
    if ($Real) {
        if (-not (Test-Path $CarpetaDestino)) {
            New-Item -ItemType Directory -Path $CarpetaDestino -Force | Out-Null
        }
        try {
            Move-Item -Path $Archivo.FullName -Destination $destinoArchivo -ErrorAction Stop
            # Verificar que el archivo se movió correctamente
            if (Test-Path $destinoArchivo) {
                Remove-Item -Path $Archivo.FullName -Force -ErrorAction SilentlyContinue
                Agregar-Log -Accion "MOVIDO" -Archivo $Archivo.Name -Detalle "A $CarpetaDestino"
            } else {
                Write-Host "    [ERROR] Fallo al mover: $($Archivo.Name)" -ForegroundColor Red
                Agregar-Log -Accion "ERROR" -Archivo $Archivo.FullName -Detalle "No se pudo verificar destino"
            }
        } catch {
            Write-Host "    [ERROR] No se pudo mover: $($Archivo.FullName) - $($_.Exception.Message)" -ForegroundColor Red
            Agregar-Log -Accion "ERROR" -Archivo $Archivo.FullName -Detalle $_.Exception.Message
        }
    } else {
        Write-Host "    [>] Se moverá: $destinoArchivo" -ForegroundColor DarkGray
    }
}

function Limpiar-Vacios {
    param([string]$ruta)
    $dirs = Get-ChildItem -Path $ruta -Recurse -Directory -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending
    foreach ($d in $dirs) {
        if (-not (Get-ChildItem -Path $d.FullName -Force -ErrorAction SilentlyContinue)) {
            Remove-Item -Path $d.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not (Get-ChildItem -Path $ruta -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -Path $ruta -Force -ErrorAction SilentlyContinue
    }
}

# ==============================================================================
# FLUJO PRINCIPAL
# ==============================================================================

# 9. DETECTAR HERRAMIENTA DE COMPRESION
$herramienta = Buscar-Herramienta
if ($herramienta) {
    Write-Host "Herramienta de compresión: $($herramienta.Tipo) -> $($herramienta.Ruta)" -ForegroundColor DarkGray
    if ($herramienta.Tipo -eq '7zr') {
        Write-Host "  (7zr solo lee .7z; se usará como bootstrap para el 7-Zip completo si hay .rar)" -ForegroundColor DarkGray
    }
} else {
    Write-Host "AVISO: No se encontró 7-Zip ni WinRAR/WinZip." -ForegroundColor Yellow
    Write-Host "  Los .zip se inspeccionan nativamente; los .rar/.7z se reportarán como 'desconocido'." -ForegroundColor Yellow
}

# 10. ESCANEAR CON UNA SOLA PASADA RECURSIVA (OPTIMIZADO + PARALELO PS7)
Write-Host ""
Write-Host "Escaneando (una sola pasada recursiva)..." -ForegroundColor Magenta

function Invoke-ConProgreso {
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [ValidateSet("barra", "spinner")][string]$Estilo = "barra"
    )
    $job = Start-ThreadJob -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    $chars = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
    $ancho = 22
    $i = 0
    $dir = 1
    if ($Estilo -eq "spinner") {
        Write-Host "  $Message " -NoNewline -ForegroundColor Cyan
        while ($job.State -eq 'Running') {
            Write-Host "`b$($chars[$i])" -NoNewline -ForegroundColor Green
            $i = ($i + 1) % $chars.Length
            Start-Sleep -Milliseconds 80
        }
        Write-Host "`b ✅" -ForegroundColor Green
    } else {
        while ($job.State -eq 'Running') {
            $barra = ' ' * $i + '█' * 4 + ' ' * ($ancho - $i - 4)
            Write-Host ("`r  $Message  [$barra]") -NoNewline -ForegroundColor Cyan
            $i += $dir
            if ($i -ge ($ancho - 4) -or $i -le 0) { $dir = -$dir }
            Start-Sleep -Milliseconds 50
        }
        Write-Host ("`r  ✅ $Message" + (' ' * ($ancho + 8))) -ForegroundColor Green
    }
    Wait-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
    $result = Receive-Job -Job $job -ErrorAction SilentlyContinue
    Remove-Job -Job $job -Force
    return $result
}

# Usar List[T] en lugar de arrays para evitar reasignaciones O(n²)
$archivosFuente = [System.Collections.Generic.List[object]]::new()
$archivosComprimidos = [System.Collections.Generic.List[object]]::new()

# Escaneo recursivo completo - una sola llamada I/O al OS
$todosArchivos = @(Invoke-ConProgreso -Message "Escaneando fuentes" -Estilo barra -ScriptBlock {
    param($ruta, $patron)
    Get-ChildItem -Path $ruta -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch $patron }
} -ArgumentList $rutaEscaneo, $patronExcluir)

# Clasificar archivos en una sola pasada
$extensionesFuenteSet = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
$extensionesComprimidasSet = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

foreach ($ext in $extensionesFuenteExt) { [void]$extensionesFuenteSet.Add($ext) }
foreach ($ext in @('.zip', '.rar', '.7z')) { [void]$extensionesComprimidasSet.Add($ext) }

foreach ($archivo in $todosArchivos) {
    $ext = $archivo.Extension
    if ($extensionesFuenteSet.Contains($ext)) {
        $archivosFuente.Add($archivo)
    } elseif ($extensionesComprimidasSet.Contains($ext)) {
        $archivosComprimidos.Add($archivo)
    }
}

Write-Host "Fuentes encontradas: $($archivosFuente.Count)  Comprimidos: $($archivosComprimidos.Count)" -ForegroundColor Green
Escribir-Log "Fuentes encontradas: $($archivosFuente.Count)"
Escribir-Log "Comprimidos encontrados: $($archivosComprimidos.Count)"

# 11. MOSTRAR ESTRUCTURA DEL ORIGEN
Write-Host ""
Write-Host "=== ESTRUCTURA DEL ORIGEN ===" -ForegroundColor Cyan

$porCarpeta = $archivosFuente | Group-Object {
    $padre = $_.DirectoryName
    if ([string]::Equals($padre, $rutaEscaneo, [System.StringComparison]::OrdinalIgnoreCase)) {
        "(raíz)"
    } else {
        $padre.Substring($rutaEscaneo.Length).TrimStart('\')
    }
}

$carpetasConFuentes = @($porCarpeta | Sort-Object { $_.Name })
foreach ($grupo in $carpetasConFuentes) {
    $carpetaRel = $grupo.Name
    if ($carpetaRel -eq "(raíz)") {
        Write-Host "  [raíz] $($grupo.Count) fuentes sueltas" -ForegroundColor Yellow
    } else {
        Write-Host "  $carpetaRel ($($grupo.Count) fuentes)" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Presiona Enter para continuar o Ctrl+C para cancelar..." -ForegroundColor White
Read-Host

# 12. MEDIR ESPACIO ANTES
$letraDisco = Split-Path $rutaEscaneo -Qualifier
$discoAntes = Get-PSDrive -Name $letraDisco.TrimEnd(':') -ErrorAction SilentlyContinue
$libreAntes = if ($discoAntes) { $discoAntes.Free } else { 0 }

Write-Host ""
Write-Host "=== ESPACIO LIBRE EN $letraDisco ANTES ===" -ForegroundColor Cyan
Write-Host "  Libre: $(Formatear-Tamanio $libreAntes)" -ForegroundColor Yellow

# 13. CLASIFICAR FUENTES: sueltos vs carpetas contenedoras
$extComprimidas = @('.zip', '.rar', '.7z')
$suelto = New-Object System.Collections.Generic.List[object]
$contenedoras = New-Object System.Collections.Generic.List[string]

$script:ruta7zLista = $null
if ($herramienta -and $herramienta.Tipo -eq '7z') { $script:ruta7zLista = $herramienta.Ruta }

foreach ($archivo in $archivosFuente) {
    $padre = $archivo.DirectoryName.TrimEnd('\', '/')
    $nombrePadre = Split-Path $padre -Leaf
    $esRaiz = [string]::Equals($padre, $rutaEscaneo, [System.StringComparison]::OrdinalIgnoreCase)
    $esProtegida = $carpetasProtegidas -contains $nombrePadre
    if ($esRaiz -or $esProtegida) {
        $suelto.Add($archivo)
    } else {
        if (-not $contenedoras.Contains($padre)) {
            $contenedoras.Add($padre)
        }
    }
}

# 14. CLASIFICAR COMPRIMIDOS
$aExtraer = New-Object System.Collections.Generic.List[object]
$omitidos = New-Object System.Collections.Generic.List[object]

foreach ($archivo in $archivosComprimidos) {
    $ext = $archivo.Extension.ToLowerInvariant()

    if ($script:ruta7zLista) {
        $herramientaInspeccion = @{ Tipo = '7z'; Ruta = $script:ruta7zLista }
    } elseif ($ext -eq '.7z' -and $herramienta -and $herramienta.Tipo -eq '7zr') {
        $herramientaInspeccion = $herramienta
    } else {
        if ($ext -eq '.rar' -and $herramienta -and $herramienta.Tipo -eq '7zr') {
            $script:ruta7zLista = Obtener-7zCompleto -Ruta7zr $herramienta.Ruta
        }
        $herramientaInspeccion = if ($script:ruta7zLista) {
            @{ Tipo = '7z'; Ruta = $script:ruta7zLista }
        } elseif ($herramienta -and $herramienta.Tipo -in '7z', 'rar', 'zip') {
            $herramienta
        } else {
            $null
        }
    }

    $contenido = Listar-Comprimido -RutaArchivo $archivo.FullName -Herramienta $herramientaInspeccion
    $clase = Clasificar-ComprimidoFuentes -Nombres $contenido

    if ($clase -eq 'fuentes') {
        $aExtraer.Add([pscustomobject]@{
            Archivo      = $archivo
            Contenido    = $contenido
            Herramienta  = $herramientaInspeccion
        })
    } else {
        $omitidos.Add([pscustomobject]@{
            Archivo   = $archivo
            Clase     = $clase
            Contenido = $contenido
        })
    }
}

# Quitar contenedoras anidadas (optimizado con HashSet)
$contenedorasTop = [System.Collections.Generic.List[string]]::new()
$sorted = $contenedoras | Sort-Object { $_.Length }
$kept = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

foreach ($p in $sorted) {
    $isChild = $false
    foreach ($k in $kept) {
        if ($p.StartsWith($k + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
            $p.StartsWith($k + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
            $isChild = $true
            break
        }
    }
    if (-not $isChild) {
        [void]$kept.Add($p)
        $contenedorasTop.Add($p)
    }
}

# 15. PROCESAR FUENTES SUELTAS
Write-Host "=== FUENTES SUELTAS ($($suelto.Count)) ===" -ForegroundColor Cyan
$script:borradosSuelto = 0
$script:reemplazados = 0
foreach ($archivo in $suelto) {
    Write-Host "  [+] $($archivo.FullName)" -ForegroundColor Cyan
    Mover-ArchivoDedup -Archivo $archivo -CarpetaDestino $Destino
}
Write-Host ""

# 16. PROCESAR CARPETAS CON FUENTES (usando archivos ya escaneados)
Write-Host "=== CARPETAS CON FUENTES ($($contenedorasTop.Count)) ===" -ForegroundColor Cyan
$fuentesMovidas = 0

foreach ($carpeta in $contenedorasTop) {
    # Filtrar de archivos ya escaneados en lugar de re-escanear directorio
    $fuentesEnCarpeta = @($archivosFuente | Where-Object {
        $_.DirectoryName -like "$carpeta*" -or
        $_.DirectoryName -eq $carpeta
    })

    if ($fuentesEnCarpeta.Count -eq 0) { continue }

    Write-Host "  [$carpeta] ($($fuentesEnCarpeta.Count) fuentes)" -ForegroundColor Yellow

    if ($Real) {
        foreach ($fuente in $fuentesEnCarpeta) {
            Mover-ArchivoDedup -Archivo $fuente -CarpetaDestino $Destino
            $fuentesMovidas++
        }
    } else {
        Write-Host "    [>] Se moverán $($fuentesEnCarpeta.Count) fuentes a $Destino" -ForegroundColor DarkGray
    }
}

# 17. PROCESAR COMPRIMIDOS CON FUENTES (PARALELO PS7)
Write-Host ""
Write-Host "=== COMPRIMIDOS CON FUENTES ($($aExtraer.Count)) ===" -ForegroundColor Cyan
$extraidas = 0
$comprimidosBorrados = 0
$tmpBase = if ($env:TEMP) { $env:TEMP } elseif ($env:TMP) { $env:TMP } else { (Get-Location).Path }

# Función para extraer fuentes de un comprimido (usada en paralelo)
function Extraer-FuentesComprimido {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Item,
        [Parameter(Mandatory)]
        [string]$Destino,
        [Parameter(Mandatory)]
        [string]$TmpBase,
        [Parameter(Mandatory)]
        [bool]$EsReal,
        [Parameter(Mandatory)]
        [bool]$ConRespaldo,
        [string]$CarpetaRespaldo = $null
    )
    
    $archivo = $Item.Archivo
    $fuentesEn = @($Item.Contenido | Where-Object { 
        $extensionesFuenteExt -contains [System.IO.Path]::GetExtension($_).ToLowerInvariant() 
    })
    
    $resultado = @{
        Archivo = $archivo.FullName
        FuentesEncontradas = $fuentesEn.Count
        FuentesMovidas = 0
        Extraido = $false
        Eliminado = $false
        Error = $null
    }
    
    if ($EsReal) {
        $carpetaTmp = Join-Path $TmpBase ('fuentes_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $carpetaTmp -Force | Out-Null
        
        try {
            $extraidos = Extraer-Fuentes -RutaArchivo $archivo.FullName -Herramienta $Item.Herramienta -CarpetaTemporal $carpetaTmp
            if ($extraidos -and $extraidos.Count -gt 0) {
                foreach ($f in $extraidos) {
                    Mover-ArchivoDedup -Archivo $f -CarpetaDestino $Destino
                    $resultado.FuentesMovidas++
                }
                $resultado.Extraido = $true
                
                # Respaldo antes de borrar
                if ($ConRespaldo -and $CarpetaRespaldo) {
                    $destinoRespaldo = Join-Path $CarpetaRespaldo $archivo.Name
                    if (-not (Test-Path $destinoRespaldo)) {
                        Move-Item -Path $archivo.FullName -Destination $destinoRespaldo -Force -ErrorAction SilentlyContinue
                    }
                    $resultado.Eliminado = $true
                } else {
                    Remove-Item -Path $archivo.FullName -Force -ErrorAction SilentlyContinue
                    $resultado.Eliminado = $true
                }
            }
        } catch {
            $resultado.Error = $_.Exception.Message
        } finally {
            Remove-Item -Path $carpetaTmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    
    return [pscustomobject]$resultado
}

# Procesar comprimidos (paralelo en PS7, secuencial en PS5)
if ($esPS7 -and $aExtraer.Count -gt 1) {
    Write-Host "  [PS7] Procesando $($aExtraer.Count) comprimidos en paralelo (throttle: 4)..." -ForegroundColor Cyan
    
    # Preparar datos para paralelismo
    $resultadosParalelos = $aExtraer | ForEach-Object -ThrottleLimit 4 -Parallel {
        # Importar variables necesarias
        $extensionesFuenteExt = $using:extensionesFuenteExt
        $destino = $using:Destino
        $tmpBase = $using:tmpBase
        $real = $using:Real
        $respaldo = $using:Respaldo
        $carpetaRespaldo = $using:carpetaRespaldo
        
        # Importar funciones necesarias
        function Mover-ArchivoDedup { ... }  # Esto se importará automáticamente
        function Extraer-Fuentes { ... }     # Esto se importará automáticamente
        
        $item = $_
        $archivo = $item.Archivo
        $fuentesEn = @($item.Contenido | Where-Object { 
            $extensionesFuenteExt -contains [System.IO.Path]::GetExtension($_).ToLowerInvariant() 
        })
        
        $resultado = @{
            Archivo = $archivo.FullName
            FuentesEncontradas = $fuentesEn.Count
            FuentesMovidas = 0
            Extraido = $false
            Eliminado = $false
            Error = $null
        }
        
        if ($real) {
            $carpetaTmp = Join-Path $tmpBase ('fuentes_' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $carpetaTmp -Force | Out-Null
            
            try {
                $extraidos = Extraer-Fuentes -RutaArchivo $archivo.FullName -Herramienta $item.Herramienta -CarpetaTemporal $carpetaTmp
                if ($extraidos -and $extraidos.Count -gt 0) {
                    foreach ($f in $extraidos) {
                        Mover-ArchivoDedup -Archivo $f -CarpetaDestino $destino
                        $resultado.FuentesMovidas++
                    }
                    $resultado.Extraido = $true
                    
                    if ($respaldo -and $carpetaRespaldo) {
                        $destinoRespaldo = Join-Path $carpetaRespaldo $archivo.Name
                        if (-not (Test-Path $destinoRespaldo)) {
                            Move-Item -Path $archivo.FullName -Destination $destinoRespaldo -Force -ErrorAction SilentlyContinue
                        }
                        $resultado.Eliminado = $true
                    } else {
                        Remove-Item -Path $archivo.FullName -Force -ErrorAction SilentlyContinue
                        $resultado.Eliminado = $true
                    }
                }
            } catch {
                $resultado.Error = $_.Exception.Message
            } finally {
                Remove-Item -Path $carpetaTmp -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        
        [pscustomobject]$resultado
    }
    
    # Procesar resultados
    foreach ($res in $resultadosParalelos) {
        if ($res.Extraido) {
            $extraidas += $res.FuentesMovidas
            $comprimidosBorrados++
            Write-Host "  [OK] $($res.Archivo) ($($res.FuentesEncontradas) fuentes, $($res.FuentesMovidas) movidas)" -ForegroundColor Green
        } elseif ($res.Error) {
            Write-Host "  [ERROR] $($res.Archivo): $($res.Error)" -ForegroundColor Red
        }
    }
} else {
    # Procesamiento secuencial (PS5 o pocos comprimidos)
    foreach ($item in $aExtraer) {
        $archivo = $item.Archivo
        $fuentesEn = @($item.Contenido | Where-Object { $extensionesFuenteExt -contains [System.IO.Path]::GetExtension($_).ToLowerInvariant() })

        Write-Host "  [+] $($archivo.FullName) ($($fuentesEn.Count) fuentes)" -ForegroundColor Cyan
        $fuentesEn | Select-Object -First 3 | ForEach-Object {
            Write-Host "      | $_" -ForegroundColor DarkGray
        }
        if ($fuentesEn.Count -gt 3) {
            Write-Host "      | ... ($($fuentesEn.Count) fuentes en total)" -ForegroundColor DarkGray
        }

        if ($Real) {
            $carpetaTmp = Join-Path $tmpBase ('fuentes_' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $carpetaTmp -Force | Out-Null

            $extraidos = Extraer-Fuentes -RutaArchivo $archivo.FullName -Herramienta $item.Herramienta -CarpetaTemporal $carpetaTmp
            if ($extraidos -and $extraidos.Count -gt 0) {
                foreach ($f in $extraidos) {
                    Mover-ArchivoDedup -Archivo $f -CarpetaDestino $Destino
                    $extraidas++
                }
                # Respaldo antes de borrar
                if ($Respaldo -and $carpetaRespaldo) {
                    $destinoRespaldo = Join-Path $carpetaRespaldo $archivo.Name
                    if (-not (Test-Path $destinoRespaldo)) {
                        Move-Item -Path $archivo.FullName -Destination $destinoRespaldo -Force -ErrorAction SilentlyContinue
                        Write-Host "    [R] Respaldo: $($archivo.Name)" -ForegroundColor DarkGray
                        Agregar-Log -Accion "RESPALDO" -Archivo $archivo.FullName -Detalle $carpetaRespaldo
                    }
                } else {
                    Remove-Item -Path $archivo.FullName -Force -ErrorAction SilentlyContinue
                }
                $comprimidosBorrados++
                Write-Host "    [X] Comprimido ELIMINADO: $($archivo.FullName)" -ForegroundColor Red
                Agregar-Log -Accion "COMPRIMIDO_ELIMINADO" -Archivo $archivo.FullName -Detalle "$($fuentesEn.Count) fuentes extraídas"
            } else {
                Write-Host "    [ERROR] No se pudo extraer: $($archivo.FullName)" -ForegroundColor Red
                Agregar-Log -Accion "ERROR" -Archivo $archivo.FullName -Detalle "No se pudo extraer"
            }
            Remove-Item -Path $carpetaTmp -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Write-Host "    [>] Se extraerán $($fuentesEn.Count) fuentes a $Destino y se borrará el comprimido" -ForegroundColor DarkGray
        }
    }
}

# 18. LIMPIEZA DE CARPETAS VACÍAS
if ($Real) {
    Write-Host ""
    Write-Host "=== LIMPIEZA DE CARPETAS VACÍAS ===" -ForegroundColor Cyan
    $dirsRaiz = Get-ChildItem -Path $rutaEscaneo -Recurse -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $patronExcluir } |
        Sort-Object { $_.FullName.Length } -Descending
    foreach ($d in $dirsRaiz) {
        if (-not (Get-ChildItem -Path $d.FullName -Force -ErrorAction SilentlyContinue)) {
            Write-Host "  [x] Removida: $($d.FullName)" -ForegroundColor DarkGray
            Remove-Item -Path $d.FullName -Force -ErrorAction SilentlyContinue
            Agregar-Log -Accion "CARPETA_ELIMINADA" -Archivo $d.FullName
        }
    }
}

# 19. DEDUPLICACIÓN INTERNA DEL DESTINO
Write-Host ""
Write-Host "=== DEDUPLICACIÓN INTERNA DEL DESTINO ===" -ForegroundColor Cyan
$duplicadosInternos = 0
$bytesEliminados = 0
$agrupados = Get-ChildItem -Path $Destino -Recurse -File -ErrorAction SilentlyContinue |
    Group-Object { $_.Name.ToLowerInvariant() + "|" + $_.Length }
foreach ($grupo in $agrupados) {
    if ($grupo.Count -gt 1) {
        $conservado = $grupo.Group | Sort-Object { $_.LastWriteTime } -Descending | Select-Object -First 1
        foreach ($dup in $grupo.Group | Where-Object { $_.FullName -ne $conservado.FullName }) {
            if ($Real) {
                $bytesEliminados += $dup.Length
                Remove-Item -Path $dup.FullName -Force -ErrorAction SilentlyContinue
                Write-Host "  [X] Duplicado ELIMINADO: $($dup.Name) (conservado: $($conservado.LastWriteTime.ToString('yyyy-MM-dd')))" -ForegroundColor Red
                Agregar-Log -Accion "DUPLICADO_ELIMINADO" -Archivo $dup.FullName -Detalle "Conservado: $($conservado.Name)"
            } else {
                Write-Host "  [X] Duplicado, se eliminará: $($dup.Name) (conservar: $($conservado.LastWriteTime.ToString('yyyy-MM-dd')))" -ForegroundColor Red
            }
            $duplicadosInternos++
        }
    }
}

# 20. REPORTE DE COMPRIMIDOS IGNORADOS
if ($omitidos.Count -gt 0) {
    Write-Host ""
    Write-Host "=== COMPRIMIDOS IGNORADOS ($($omitidos.Count)) ===" -ForegroundColor Yellow
    foreach ($o in $omitidos) {
        $mensaje = switch ($o.Clase) {
            'instalador'  { 'contiene ejecutables (instalador). Lo maneja reubicarInstaladores.ps1' }
            'sin-fuentes' { 'no contiene fuentes ni ejecutables' }
            default       { 'no se pudo inspeccionar' }
        }
        $color = if ($o.Clase -eq 'instalador') { 'Cyan' } elseif ($o.Clase -eq 'desconocido') { 'Red' } else { 'DarkGray' }
        Write-Host "  [$($o.Clase)] $($o.Archivo.FullName) -> $mensaje" -ForegroundColor $color
        if ($o.Contenido.Count -gt 0) {
            $o.Contenido | Select-Object -First 3 | ForEach-Object {
                Write-Host "      | $_" -ForegroundColor DarkGray
            }
            if ($o.Contenido.Count -gt 3) {
                Write-Host "      | ... ($($o.Contenido.Count) archivos en total)" -ForegroundColor DarkGray
            }
        } else {
            Write-Host "      | (no se pudo leer el contenido)" -ForegroundColor DarkGray
        }
    }
}

# 21. RESUMEN FINAL
Write-Host ""
if (-not $Real) {
    Write-Host "SIMULACION: nada se movio, extrajo ni borro. Re-ejecuta con -Real para aplicar." -ForegroundColor Yellow
} else {
    $discoDespues = Get-PSDrive -Name $letraDisco.TrimEnd(':') -ErrorAction SilentlyContinue
    $libreDespues = if ($discoDespues) { $discoDespues.Free } else { 0 }
    $liberado = $libreDespues - $libreAntes

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "RESUMEN FINAL" -ForegroundColor Green
    Write-Host "  Fuentes movidas: $($fuentesMovidas + $extraidas)" -ForegroundColor Green
    Write-Host "  Comprimidos extraidos: $comprimidosBorrados" -ForegroundColor Green
    Write-Host "  Duplicados eliminados: $($script:borradosSuelto + $duplicadosInternos)" -ForegroundColor Red
    Write-Host "  Archivos reemplazados: $($script:reemplazados)" -ForegroundColor Yellow
    Write-Host "  Comprimidos ignorados: $($omitidos.Count)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  ESPACIO LIBRE EN ${letraDisco}:" -ForegroundColor Cyan
    Write-Host "    Antes: $(Formatear-Tamanio $libreAntes)" -ForegroundColor Yellow
    Write-Host "    Despues: $(Formatear-Tamanio $libreDespues)" -ForegroundColor Yellow
    if ($liberado -gt 0) {
        Write-Host "    Liberado: $(Formatear-Tamanio $liberado)" -ForegroundColor Green
    } elseif ($liberado -lt 0) {
        Write-Host "    Ocupado: $(Formatear-Tamanio ([Math]::Abs($liberado))) (carpetas movidas ocupan espacio)" -ForegroundColor DarkGray
    } else {
        Write-Host "    Sin cambio (carpetas movidas, no comprimidas)" -ForegroundColor DarkGray
    }
    Write-Host "============================================================" -ForegroundColor Cyan

    # 22. GENERAR REPORTE HTML (con StringBuilder para mejor rendimiento)
    $fecha = Get-Date -Format 'yyyyMMdd_HHmmss'
    $carpetaReportes = "H:\Scripts\Reportes"
    if (-not (Test-Path $carpetaReportes)) { New-Item -Path $carpetaReportes -ItemType Directory -Force | Out-Null }
    $htmlPath = Join-Path $carpetaReportes "organizar_fuentes_$fecha.html"

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><title>Reporte Organizar Fuentes</title>')
    [void]$sb.AppendLine('<style>body{font-family:Consolas,monospace;background:#1a1a2e;color:#e0e0e0;margin:20px}')
    [void]$sb.AppendLine('h1{color:#00d4ff;border-bottom:2px solid #00d4ff;padding-bottom:10px}')
    [void]$sb.AppendLine('h2{color:#ff6b35;margin-top:30px}')
    [void]$sb.AppendLine('table{border-collapse:collapse;width:100%;margin:10px 0}')
    [void]$sb.AppendLine('th{background:#16213e;color:#00d4ff;padding:8px;border:1px solid #333}')
    [void]$sb.AppendLine('td{padding:6px 12px;border:1px solid #333}')
    [void]$sb.AppendLine('tr:nth-child(even){background:#1f2940}tr:nth-child(odd){background:#16213e}')
    [void]$sb.AppendLine('.total{font-weight:bold;color:#00ff88}.ok{color:#00ff88}.error{color:#ff4444}.warn{color:#ffd93d}</style></head><body>')
    [void]$sb.AppendLine('<h1>Reporte Organizar Fuentes</h1>')
    [void]$sb.AppendLine("<p>Generado: $(Get-Date -Format 'dd/MM/yyyy HH:mm')</p>")
    [void]$sb.AppendLine("<p class='total'>Origen: $rutaEscaneo → Destino: $Destino</p>")
    [void]$sb.AppendLine('<h2>Resumen</h2>')
    [void]$sb.AppendLine('<table><tr><th>Métrica</th><th>Valor</th></tr>')
    [void]$sb.AppendLine("<tr><td>Fuentes movidas</td><td class='ok'>$($fuentesMovidas + $extraidas)</td></tr>")
    [void]$sb.AppendLine("<tr><td>Comprimidos extraídos</td><td class='ok'>$comprimidosBorrados</td></tr>")
    [void]$sb.AppendLine("<tr><td>Duplicados eliminados</td><td class='error'>$($script:borradosSuelto + $duplicadosInternos)</td></tr>")
    [void]$sb.AppendLine("<tr><td>Reemplazados</td><td class='warn'>$($script:reemplazados)</td></tr>")
    [void]$sb.AppendLine("<tr><td>Espacio liberado</td><td class='ok'>$(if ($liberado -gt 0) { Formatear-Tamanio $liberado } else { 'N/A' })</td></tr></table>")
    [void]$sb.AppendLine('<h2>Registro de Operaciones</h2>')
    [void]$sb.AppendLine('<table><tr><th>Hora</th><th>Acción</th><th>Archivo</th><th>Detalle</th></tr>')

    foreach ($reg in $script:registrosLog) {
        $clase = switch ($reg.Accion) {
            "MOVIDO" { "ok" }
            "REEMPLAZADO" { "warn" }
            "ELIMINADO" { "error" }
            "DUPLICADO_ELIMINADO" { "error" }
            "COMPRIMIDO_ELIMINADO" { "error" }
            "ERROR" { "error" }
            default { "" }
        }
        [void]$sb.AppendLine("<tr><td>$($reg.Hora)</td><td class='$clase'>$($reg.Accion)</td><td>$($reg.Archivo)</td><td>$($reg.Detalle)</td></tr>")
    }

    [void]$sb.AppendLine('</table></body></html>')
    $html = $sb.ToString()

    if ($esPS7) {
        $html | Out-File -FilePath $htmlPath -Encoding utf8Bom
    } else {
        $utf8Bom = New-Object System.Text.UTF8Encoding $true
        [System.IO.File]::WriteAllText($htmlPath, $html, $utf8Bom)
    }
    Write-Host ""
    Write-Host "  Reporte HTML: $htmlPath" -ForegroundColor Green
}

# 23. GUARDAR LOG Y CERRAR STREAMWRITER
if ($Log -and $script:rutaLog) {
    Escribir-Log "Fin de operacion"
    if ($script:logStream) {
        $script:logStream.Dispose()
        $script:logStream = $null
    }
    Write-Host "  Log guardado: $($script:rutaLog)" -ForegroundColor Green
}
}

function Invoke-ReubicarInstaladores {
# ==============================================================================
# RECOPILAR INSTALADORES: Centraliza instaladores del NAS (OPTIMIZADO PS7)
#
# Uso:
#   .\reubicarInstaladores.ps1 -Ruta "Z:\" -Destino "Z:\Programas" [-Real] [-SinExclusiones] [-Log] [-ValidarWeb]
#
# Parámetros:
#   -Ruta             Carpeta a escanear (por defecto: la carpeta actual)
#   -Destino          Carpeta central donde mover (por defecto: Z:\Programas)
#   -Real             Aplica movimientos y borrados (por defecto es SIMULACIÓN)
#   -SinExclusiones   Escanea también AppData y carpetas protegidas. PELIGROSO.
#   -Log              Guarda registro de la operación en un archivo .txt
#   -ValidarWeb       Usa búsqueda web para validar carpetas dudosas
#   -SinMenu          Omite el menú interactivo
#
# Extensiones: .exe .bat .inf .iso .msi .zip .rar .7z
#
# CLASIFICACIÓN DE CARPETAS:
#   Para cada carpeta se evalúa:
#   1. Clasificación local (extensiones, patrones setup/install)
#   2. Inspección de comprimidos (7-Zip/WinRAR)
#   3. Validación web (si la confianza es baja)
#   4. Decisión: MOVER / OMITIR
#
# REGLAS DE VALIDACIÓN:
#   - Si tiene setup.exe/install.exe → INSTALADOR (confianza alta)
#   - Si tiene .exe/.msi/.iso pero no setup → Media confianza → Validar web
#   - Si es principalmente fuentes (.ttf/.otf) → OMITIR
#   - Si es principalmente documentos (.pdf/.doc) → OMITIR
#   - Si tiene <3 archivos → OMITIR (no es carpeta de instalador)
#
# REGLA CLAVE:
#   Si un comprimido contiene un EJECUTABLE (.exe, .msi, setup.exe, ...) ES un
#   archivo de instalador. Se MOVERÁ.
#   Si solo contiene fuentes o documentos → NO se mueve.
# ==============================================================================

    # --------------------------------------------------------------------------
    # PARAMETROS: el bloque param() del script standalone se elimino; cada
    # parametro se resuelve aqui con prompts del estilo de la suite.
    # --------------------------------------------------------------------------
    $Ruta = Read-HostStyled -Prompt "Carpeta a escanear (Enter = carpeta actual)" -Icon "?" -DefaultValue ""
    $Destino = Read-HostStyled -Prompt "Carpeta destino donde centralizar los instaladores (Enter = Z:\Programas)" -Icon "?" -DefaultValue "Z:\Programas"
    $op = Read-HostStyled -Prompt "Ejecutar real? [1] Si [2] No (simulacion)" -Icon "?" -DefaultValue "2"
    $Real = ($op -eq "1")
    $SinExclusiones = Preguntar-SiNo -Mensaje "Sin exclusiones (escanear tambien AppData y carpetas protegidas)? PELIGROSO"
    $Log = Preguntar-SiNo -Mensaje "Guardar registro de la operacion en un archivo .txt?"
    $ValidarWeb = Preguntar-SiNo -Mensaje "Usar busqueda web para validar carpetas dudosas?"
    $SinMenu = -not (Preguntar-SiNo -Mensaje "Mostrar tambien el menu interactivo original? (los parametros ya se han pedido arriba)")

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
            Show-Error "PowerShell 7 no esta instalado y se necesita Administrador para instalarlo."; return
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
            Show-Error "No se pudo instalar PowerShell 7."; return
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
    return
}
# =================== FIN AUTO-ARRANQUE POWERSHELL 7 ===================


# Configurar encoding (compatible PS5.1 y PS7)
$esPS7 = $PSVersionTable.PSVersion.Major -ge 7
if ($esPS7) {
    $OutputEncoding = [System.Text.Encoding]::UTF8
} else {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
}

# ==============================================================================
# FUNCIONES AUXILIARES
# ==============================================================================

function Formatear-Tamanio([long]$bytes) {
    if ($bytes -ge 1GB) { "{0:N2} GB" -f ($bytes / 1GB) }
    elseif ($bytes -ge 1MB) { "{0:N2} MB" -f ($bytes / 1MB) }
    elseif ($bytes -ge 1KB) { "{0:N2} KB" -f ($bytes / 1KB) }
    else { "$bytes bytes" }
}

function Escribir-Log {
    param([string]$Mensaje, [string]$Tipo = "INFO")
    $marca = "[$(Get-Date -Format 'HH:mm:ss')] [$Tipo]"
    $linea = "$marca $Mensaje"
    if ($script:logStream) {
        $script:logStream.WriteLine($linea)
        $script:logStream.Flush()
    }
}

function Agregar-Log {
    param([string]$Accion, [string]$Archivo, [string]$Detalle = "")
    $script:registrosLog += [PSCustomObject]@{
        Hora    = Get-Date -Format 'HH:mm:ss'
        Accion  = $Accion
        Archivo = $Archivo
        Detalle = $Detalle
    }
}

# ==============================================================================
# MENU INTERACTIVO
# ==============================================================================

if (-not $SinMenu -and -not $Real) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  RECOPILAR INSTALADORES" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""

    # Carpeta a escanear
    Write-Host "  Carpeta a escanear (Enter = carpeta actual):" -ForegroundColor White
    $rutaInput = Read-Host "  Ruta"
    if (-not [string]::IsNullOrWhiteSpace($rutaInput)) { $Ruta = $rutaInput }

    # Destino
    Write-Host ""
    Write-Host "  Carpeta destino (Enter = Z:\Programas):" -ForegroundColor White
    $destinoInput = Read-Host "  Destino"
    if (-not [string]::IsNullOrWhiteSpace($destinoInput)) { $Destino = $destinoInput }

    # Validación web
    Write-Host ""
    Write-Host "  ¿Usar búsqueda web para validar carpetas dudosas? (s/n):" -ForegroundColor White
    $webInput = Read-Host "  ValidarWeb"
    if ($webInput -match '^[sS]') { $ValidarWeb = $true }

    # Log
    Write-Host ""
    Write-Host "  ¿Guardar log de la operación? (s/n):" -ForegroundColor White
    $logInput = Read-Host "  Log"
    if ($logInput -match '^[sS]') { $Log = $true }

    Write-Host ""
}

# ==============================================================================
# CONFIGURACION INICIAL
# ==============================================================================

# 1. VERIFICAR ADMIN
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "AVISO: No se ejecuta como Administrador." -ForegroundColor Yellow
    Write-Host "Si el destino o las carpetas protegidas requieren permisos elevados, el proceso puede fallar." -ForegroundColor Yellow
}

# 2. DETERMINAR CARPETA A ESCANEAR
if ([string]::IsNullOrWhiteSpace($Ruta)) {
    $rutaEscaneo = (Get-Location).Path
} else {
    $resuelta = Resolve-Path -Path $Ruta -ErrorAction SilentlyContinue
    if (-not $resuelta) {
        Write-Host "ERROR: La ruta no existe: $Ruta" -ForegroundColor Red
        Show-Error "La ruta no existe: $Ruta"; return
    }
    $rutaEscaneo = $resuelta.Path
}
$rutaEscaneo = $rutaEscaneo.TrimEnd('\', '/')

# 3. NORMALIZAR DESTINO
if (-not [System.IO.Path]::IsPathRooted($Destino)) {
    $Destino = Join-Path (Get-Location).Path $Destino
}
$Destino = $Destino.TrimEnd('\', '/')
if ([string]::Equals($Destino, $rutaEscaneo, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Host "ERROR: El destino no puede ser la misma carpeta que se escanea." -ForegroundColor Red
    Show-Error "El destino no puede ser la misma carpeta que se escanea."; return
}

# 4. EXTENSIONES A RECOPILAR
$extensionesInstalador = @("*.exe", "*.bat", "*.inf", "*.iso", "*.msi")
$extensionesComprimidas = @("*.zip", "*.rar", "*.7z")
$extensionesTodas = $extensionesInstalador + $extensionesComprimidas
$extensionesInstaladorExt = @(".exe", ".bat", ".inf", ".iso", ".msi")
$extensionesComprimidasExt = @(".zip", ".rar", ".7z")

# 5. EXCLUSIONES
$excluir = @(
    "AppData",
    "Windows",
    "Windows.old",
    "Program Files",
    "Program Files (x86)",
    "ProgramData",
    "System Volume Information",
    '\$Recycle.Bin',
    "WindowsApps"
)

# Construir patrón regex de exclusiones
$patronSegmentos = $excluir | ForEach-Object { [regex]::Escape($_) }
$patronExcluir = ($patronSegmentos | ForEach-Object { "(?:^|[\\/])$_(?:[\\/]|$)" }) -join '|'

# Excluir la carpeta destino del escaneo
$nombreDestino = Split-Path $Destino -Leaf
if ($excluir -notcontains $nombreDestino) {
    $excluir += $nombreDestino
    $patronSegmentos = $excluir | ForEach-Object { [regex]::Escape($_) }
    $patronExcluir = ($patronSegmentos | ForEach-Object { "(?:^|[\\/])$_(?:[\\/]|$)" }) -join '|'
}

# 6. CARPETAS PROTEGIDAS (nunca se mueven como contenedora)
$carpetasProtegidas = @(
    "Desktop", "Escritorio", "Documents", "Documentos", "Downloads", "Descargas",
    "Music", "Música", "Pictures", "Imágenes", "Videos", "Vídeos",
    "AppData", "Public", "Público", "OneDrive", "Favorites", "Favoritos",
    "Contacts", "Contactos", "Links", "Saved Games", "Juegos guardados",
    "Searches", "3D Objects", "Objetos 3D"
)

# 7. CONFIGURAR LOG (con StreamWriter)
$script:rutaLog = $null
$script:logStream = $null
$script:registrosLog = @()
if ($Log) {
    $fecha = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:rutaLog = Join-Path $rutaEscaneo "log_instaladores_$fecha.txt"
    $script:logStream = [System.IO.StreamWriter]::new($script:rutaLog, $true, [System.Text.Encoding]::UTF8)
    Escribir-Log "Inicio de operacion"
    Escribir-Log "Origen: $rutaEscaneo"
    Escribir-Log "Destino: $Destino"
    Escribir-Log "Modo: $(if ($Real) { 'REAL' } else { 'SIMULACION' })"
    Escribir-Log "Validacion web: $(if ($ValidarWeb) { 'SI' } else { 'NO' })"
}

# ==============================================================================
# MOSTRAR CONFIGURACION
# ==============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  RECOPILAR INSTALADORES (.exe .bat .inf .iso .msi .zip .rar .7z)" -ForegroundColor Cyan
Write-Host "  PowerShell: $($PSVersionTable.PSVersion) | Modo: $(if ($esPS7) { 'Paralelo' } else { 'Secuencial' })" -ForegroundColor DarkGray
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "Carpeta : $rutaEscaneo"
Write-Host "Destino : $Destino"
Write-Host "Modo    : $(if ($Real) { 'MOVIMIENTO REAL' } else { 'SIMULACION' })" -ForegroundColor Yellow
if ($ValidarWeb) { Write-Host "Web     : VALIDACION ACTIVA" -ForegroundColor Yellow }
if ($Log) { Write-Host "Log     : $($script:rutaLog)" -ForegroundColor DarkGray }
if ($SinExclusiones) {
    Write-Host "Exclusiones: DESACTIVADAS (incluye AppData, PELIGROSO)" -ForegroundColor Red
} else {
    Write-Host "Exclusiones: $($excluir -join ', ')" -ForegroundColor DarkGray
}
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ==============================================================================
# FUNCIONES DE HERRAMIENTA DE COMPRESION
# ==============================================================================

function Buscar-Herramienta {
    $portable64 = Join-Path $PSScriptRoot '7-Zip64\7z.exe'
    if (Test-Path $portable64) { return @{ Tipo = '7z'; Ruta = $portable64 } }

    $completo = Join-Path $PSScriptRoot '7zip\7z.exe'
    if (Test-Path $completo) { return @{ Tipo = '7z'; Ruta = $completo } }

    $reducido = Join-Path $PSScriptRoot '7zr.exe'
    if (Test-Path $reducido) { return @{ Tipo = '7zr'; Ruta = $reducido } }

    $sys7z = @(
        (Join-Path $env:ProgramFiles '7-Zip\7z.exe'),
        (Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe')
    )
    foreach ($p in $sys7z) { if (Test-Path $p) { return @{ Tipo = '7z'; Ruta = $p } } }

    $sysrar = @(
        (Join-Path $env:ProgramFiles 'WinRAR\Rar.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'WinRAR\Rar.exe'),
        (Join-Path $env:ProgramFiles 'WinRAR\WinRAR.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'WinRAR\WinRAR.exe')
    )
    foreach ($p in $sysrar) { if (Test-Path $p) { return @{ Tipo = 'rar'; Ruta = $p } } }

    $syswz = @(
        (Join-Path $env:ProgramFiles 'WinZip\WZZIP.EXE'),
        (Join-Path ${env:ProgramFiles(x86)} 'WinZip\WZZIP.EXE')
    )
    foreach ($p in $syswz) { if (Test-Path $p) { return @{ Tipo = 'zip'; Ruta = $p } } }

    return $null
}

function Obtener-7zCompleto {
    param([string]$Ruta7zr)

    $carpetaDestino = Join-Path $PSScriptRoot '7zip'
    $completo = Join-Path $carpetaDestino '7z.exe'
    if (Test-Path $completo) { return $completo }

    $version = '26.02'
    $url = "https://github.com/ip7z/7zip/releases/download/$version/7z$($version.Replace('.', ''))-x64.exe"
    $tmpDir = if ($env:TEMP) { $env:TEMP } elseif ($env:TMP) { $env:TMP } else { (Get-Location).Path }
    $sfx = Join-Path $tmpDir '7zsetup.exe'

    Write-Host "  Descargando 7-Zip portable ($url)..." -ForegroundColor Cyan
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $sfx -UseBasicParsing
        if (-not (Test-Path $carpetaDestino)) {
            New-Item -ItemType Directory -Path $carpetaDestino -Force | Out-Null
        }
        & $Ruta7zr x -y "-o$carpetaDestino" $sfx | Out-Null
        Remove-Item $sfx -Force -ErrorAction SilentlyContinue
        Write-Host "  OK: 7-Zip portable extraido en $carpetaDestino" -ForegroundColor Green
    } catch {
        Write-Host "  [ERROR] No se pudo obtener el 7-Zip completo: $($_.Exception.Message)" -ForegroundColor Red
    }

    if (Test-Path $completo) { return $completo }
    return $null
}

function Listar-Comprimido {
    param([string]$RutaArchivo, $Herramienta)

    $ext = [System.IO.Path]::GetExtension($RutaArchivo).ToLowerInvariant()
    $nombres = @()

    try {
        if ($ext -eq '.zip') {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            $zip = [System.IO.Compression.ZipFile]::OpenRead($RutaArchivo)
            $nombres = @($zip.Entries | ForEach-Object { $_.FullName })
            $zip.Dispose()
            return $nombres
        }

        if (-not $Herramienta) { return @() }

        if ($Herramienta.Tipo -eq '7z' -or $Herramienta.Tipo -eq '7zr') {
            $salida = & $Herramienta.Ruta l -slt $RutaArchivo 2>&1
            $nombreArchivo = [regex]::Escape([System.IO.Path]::GetFileName($RutaArchivo))
            $nombres = @($salida | Where-Object { $_ -match '^Path = ' } |
                ForEach-Object { ($_ -split '= ', 2)[1] } |
                Where-Object { $_ -and $_ -notmatch "(^|[\\/])$nombreArchivo$" })
        } elseif ($Herramienta.Tipo -eq 'rar') {
            $salida = & $Herramienta.Ruta l $RutaArchivo 2>&1
            $nombres = @($salida | Where-Object {
                    $_ -match '\S' -and
                    $_ -notmatch '(?i)^(RAR|Archive|--------|$\s*$)' -and
                    $_ -notmatch '(?i)^\s*(Name|Path)\s' } |
                ForEach-Object {
                    $parts = $_ -split '\s{2,}'
                    if ($parts.Count -gt 0) { $parts[0].Trim() }
                } |
                Where-Object { $_ -and $_ -notmatch '[\\/]:\\' -and $_ -ne 'Name' })
        } elseif ($Herramienta.Tipo -eq 'zip') {
            $salida = & $Herramienta.Ruta -v $RutaArchivo 2>&1
            $nombres = @($salida | Where-Object { $_ -match '^\s*\d+\s+[\d\-/]+\s+[\d:]+\s+(.+)$' } |
                ForEach-Object { ($_ -split '\s{2,}', 2)[-1].Trim() })
        }
    } catch {
        return @()
    }

    return $nombres
}

function Clasificar-Comprimido {
    param([string[]]$Nombres)

    if (-not $Nombres) { return 'desconocido' }

    $extInstalador = @('.exe', '.msi', '.msix', '.msp', '.iso', '.cab', '.bat', '.cmd', '.setup')
    $extFuente = @('.ttf', '.otf', '.ttc', '.otc', '.fnt', '.fon', '.woff', '.woff2')
    $extDocumento = @('.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.txt', '.odt', '.ods',
        '.csv', '.rtf', '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tif', '.tiff',
        '.mp3', '.mp4', '.avi', '.mov', '.wav', '.flac')
    $patronSetup = '(?i)(^|[^a-z0-9])(setup|install|autorun|uninstall|update)([^a-z0-9]|$)'

    $hayInstalador = $false
    $hayFuente = $false
    $hayDocumento = $false
    foreach ($n in $Nombres) {
        $ext = [System.IO.Path]::GetExtension($n).ToLowerInvariant()
        $base = [System.IO.Path]::GetFileName($n)
        if ($extInstalador -contains $ext -or $base -match $patronSetup) {
            $hayInstalador = $true
        } elseif ($extFuente -contains $ext) {
            $hayFuente = $true
        } elseif ($extDocumento -contains $ext) {
            $hayDocumento = $true
        }
    }

    if ($hayInstalador) { return 'instalador' }
    if ($hayFuente) { return 'fuentes' }
    if ($hayDocumento) { return 'documentos' }
    return 'desconocido'
}

# ==============================================================================
# FUNCIONES DE VALIDACION
# ==============================================================================

# Clasificación local de una carpeta
function Es-CarpetaInstalador {
    param([string]$RutaCarpeta)

    $archivos = @(Get-ChildItem -Path $RutaCarpeta -Recurse -File -ErrorAction SilentlyContinue)
    if ($archivos.Count -eq 0) { return @{ EsInstalador = $false; Confianza = "alta"; Razon = "carpeta vacia" } }

    # REGLA 0: Si la ruta contiene "Fuentes" o "Fonts", es carpeta de fuentes
    if ($RutaCarpeta -match '(?i)(fuentes|fonts|adobe.*font|font.*foli)') {
        return @{ EsInstalador = $false; Confianza = "alta"; Razon = "carpeta de fuentes (detectada por ruta)" }
    }

    # Contar por tipo
    $ejecutables = @($archivos | Where-Object { $_.Extension -in $extensionesInstaladorExt })
    $fuentes = @($archivos | Where-Object { $_.Extension -in @('.ttf','.otf','.ttc','.otc','.fnt','.fon','.woff','.woff2') })
    $documentos = @($archivos | Where-Object { $_.Extension -in @('.pdf','.doc','.docx','.xls','.xlsx','.ppt','.pptx','.txt','.jpg','.jpeg','.png','.gif','.bmp') })

    # REGLA 1: Si tiene fuentes (.ttf/.otf/.ttc), es carpeta de fuentes (NO instalador)
    if ($fuentes.Count -gt 0) {
        $ratioFuentes = $fuentes.Count / $archivos.Count
        if ($ratioFuentes -gt 0.3) {
            return @{ EsInstalador = $false; Confianza = "alta"; Razon = "carpeta de fuentes ($($fuentes.Count) fuentes, $([math]::Round($ratioFuentes*100))%)" }
        }
    }

    # REGLA 2: Si tiene setup/install, es instalador
    $patronSetup = '(?i)(setup|install|autorun|uninstall|update)'
    $tieneSetup = @($ejecutables | Where-Object { $_.Name -match $patronSetup })
    if ($tieneSetup.Count -gt 0) {
        return @{ EsInstalador = $true; Confianza = "alta"; Razon = "contiene setup/install" }
    }

    # REGLA 3: Si tiene .exe/.msi/.iso pero no fuentes, probablemente es instalador
    if ($ejecutables.Count -gt 0 -and $fuentes.Count -eq 0) {
        if ($ejecutables.Count -gt $documentos.Count) {
            return @{ EsInstalador = $true; Confianza = "media"; Razon = "contiene $($ejecutables.Count) ejecutables (sin fuentes)" }
        }
    }

    # REGLA 4: Si es principalmente documentos
    if ($documentos.Count -gt $ejecutables.Count) {
        return @{ EsInstalador = $false; Confianza = "media"; Razon = "carpeta de documentos ($($documentos.Count) documentos)" }
    }

    # REGLA 5: Si tiene pocos archivos
    if ($archivos.Count -lt 3) {
        return @{ EsInstalador = $false; Confianza = "alta"; Razon = "menos de 3 archivos" }
    }

    return @{ EsInstalador = $null; Confianza = "baja"; Razon = "clasificacion inconclusa" }
}

# Validación por búsqueda web
function Validar-Web {
    param([string]$Nombre)

    # Construir query de búsqueda
    $query = "$Nombre installer software download"
    
    try {
        # Usar websearch si está disponible (PowerShell 7 con módulo)
        $resultados = Websearch -Query $query -NumResults 3 -ErrorAction SilentlyContinue
        
        if (-not $resultados) {
            # Fallback: no se pudo buscar
            return @{ EsInstalador = $null; Software = $null; Fuente = $null }
        }

        # Analizar resultados
        $esInstalador = $false
        $softwareIdentificado = $null
        
        foreach ($r in $resultados) {
            if ($r.Titulo -match '(?i)(installer|download|setup|software|driver|application)') {
                $esInstalador = $true
                $softwareIdentificado = $r.Titulo
                break
            }
        }

        return @{
            EsInstalador = $esInstalador
            Software = $softwareIdentificado
            Fuente = if ($resultados.Count -gt 0) { $resultados[0].URL } else { $null }
        }
    } catch {
        return @{ EsInstalador = $null; Software = $null; Fuente = $null }
    }
}

# Decisión final de movimiento
function Decidir-Movimiento {
    param([string]$RutaCarpeta, [hashtable]$ClasificacionLocal)

    # Si la confianza es alta, no buscar en web
    if ($ClasificacionLocal.Confianza -eq "alta") {
        return @{
            Movido = $ClasificacionLocal.EsInstalador
            Razon = $ClasificacionLocal.Razon
            Software = $null
        }
    }

    # Si la confianza es baja o media, validar en web (si está habilitado)
    if ($ValidarWeb) {
        $nombre = Split-Path $RutaCarpeta -Leaf
        Write-Host "    [?] Validando en web: $nombre..." -ForegroundColor DarkGray
        $validacionWeb = Validar-Web -Nombre $nombre

        if ($validacionWeb.EsInstalador -eq $true) {
            return @{
                Movido = $true
                Razon = "validado por web: $($validacionWeb.Software)"
                Software = $validacionWeb.Software
            }
        }

        if ($validacionWeb.EsInstalador -eq $false) {
            return @{
                Movido = $false
                Razon = "web indica que no es instalador"
                Software = $null
            }
        }
    }

    # Por defecto, usar la clasificación local
    return @{
        Movido = $ClasificacionLocal.EsInstalador
        Razon = $ClasificacionLocal.Razon
        Software = $null
    }
}

# ==============================================================================
# FUNCIONES DE MOVIMIENTO
# ==============================================================================

function Mover-ArchivoDedup {
    param([System.IO.FileInfo]$Archivo, [string]$CarpetaDestino)

    $destinoArchivo = Join-Path $CarpetaDestino $Archivo.Name
    $info = Get-Item $destinoArchivo -ErrorAction SilentlyContinue

    if ($info -and -not $info.PSIsContainer -and $info.Length -eq $Archivo.Length) {
        # DUPLICADO exacto -> eliminar la copia fuente
        if ($Real) {
            Remove-Item -Path $Archivo.FullName -Force -ErrorAction SilentlyContinue
            $script:borradosSuelto++
            Write-Host "    [X] Duplicado ELIMINADO: $($Archivo.Name)" -ForegroundColor Red
            Agregar-Log -Accion "DUPLICADO_ELIMINADO" -Archivo $Archivo.FullName -Detalle "Mismo nombre y tamaño en destino"
        } else {
            Write-Host "    [X] Duplicado, se eliminara: $($Archivo.Name)" -ForegroundColor Red
        }
        return
    }

    if ($info) {
        # Mismo nombre, distinto tamaño -> renombrar
        $base = [System.IO.Path]::GetFileNameWithoutExtension($Archivo.Name)
        $ext = $Archivo.Extension
        $n = 2
        $nuevoNombre = "${base}_copia$n$ext"
        while (Test-Path (Join-Path $CarpetaDestino $nuevoNombre)) {
            $n++
            $nuevoNombre = "${base}_copia$n$ext"
        }
        $destinoArchivo = Join-Path $CarpetaDestino $nuevoNombre
    }

    if ($Real) {
        if (-not (Test-Path $CarpetaDestino)) {
            New-Item -ItemType Directory -Path $CarpetaDestino -Force | Out-Null
        }
        try {
            Move-Item -Path $Archivo.FullName -Destination $destinoArchivo -ErrorAction Stop
            if ((Split-Path $destinoArchivo -Leaf) -ne $Archivo.Name) {
                Write-Host "    [~] Renombrado a: $(Split-Path $destinoArchivo -Leaf)" -ForegroundColor Yellow
                Agregar-Log -Accion "RENOMBRADO" -Archivo $Archivo.FullName -Detalle "A $destinoArchivo"
            } else {
                Agregar-Log -Accion "MOVIDO" -Archivo $Archivo.FullName -Detalle "A $CarpetaDestino"
            }
        } catch {
            Write-Host "    [ERROR] No se pudo mover: $($Archivo.FullName) - $($_.Exception.Message)" -ForegroundColor Red
            Agregar-Log -Accion "ERROR" -Archivo $Archivo.FullName -Detalle $_.Exception.Message
        }
    } else {
        Write-Host "    [>] Se movera a: $destinoArchivo" -ForegroundColor DarkGray
    }
}

function Limpiar-Vacios {
    param([string]$ruta)
    $dirs = Get-ChildItem -Path $ruta -Recurse -Directory -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending
    foreach ($d in $dirs) {
        if (-not (Get-ChildItem -Path $d.FullName -Force -ErrorAction SilentlyContinue)) {
            Remove-Item -Path $d.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not (Get-ChildItem -Path $ruta -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -Path $ruta -Force -ErrorAction SilentlyContinue
    }
}

# ==============================================================================
# FLUJO PRINCIPAL
# ==============================================================================

# 8. DETECTAR HERRAMIENTA DE COMPRESION
$herramienta = Buscar-Herramienta
if ($herramienta) {
    Write-Host "Herramienta de compresion: $($herramienta.Tipo) -> $($herramienta.Ruta)" -ForegroundColor DarkGray
    if ($herramienta.Tipo -eq '7zr') {
        Write-Host "  (7zr solo lee .7z; se usara como bootstrap para el 7-Zip completo si hay .rar)" -ForegroundColor DarkGray
    }
} else {
    Write-Host "AVISO: No se encontro 7-Zip ni WinRAR/WinZip." -ForegroundColor Yellow
    Write-Host "  Los .zip se inspeccionan nativamente; los .rar/.7z se reportaran como 'desconocido'." -ForegroundColor Yellow
}

# 9. ESCANEAR CON UNA SOLA PASADA RECURSIVA (OPTIMIZADO)
Write-Host ""
Write-Host "Escaneando (una sola pasada recursiva)..." -ForegroundColor Magenta

function Invoke-ConProgreso {
    param(
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [ValidateSet("barra", "spinner")][string]$Estilo = "barra"
    )
    $job = Start-ThreadJob -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    $chars = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
    $ancho = 22
    $i = 0
    $dir = 1
    if ($Estilo -eq "spinner") {
        Write-Host "  $Message " -NoNewline -ForegroundColor Cyan
        while ($job.State -eq 'Running') {
            Write-Host "`b$($chars[$i])" -NoNewline -ForegroundColor Green
            $i = ($i + 1) % $chars.Length
            Start-Sleep -Milliseconds 80
        }
        Write-Host "`b ✅" -ForegroundColor Green
    } else {
        while ($job.State -eq 'Running') {
            $barra = ' ' * $i + '█' * 4 + ' ' * ($ancho - $i - 4)
            Write-Host ("`r  $Message  [$barra]") -NoNewline -ForegroundColor Cyan
            $i += $dir
            if ($i -ge ($ancho - 4) -or $i -le 0) { $dir = -$dir }
            Start-Sleep -Milliseconds 50
        }
        Write-Host ("`r  ✅ $Message" + (' ' * ($ancho + 8))) -ForegroundColor Green
    }
    Wait-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
    $result = Receive-Job -Job $job -ErrorAction SilentlyContinue
    Remove-Job -Job $job -Force
    return $result
}

# Usar List[T] en lugar de arrays
$archivosInstalador = [System.Collections.Generic.List[object]]::new()

# Escaneo recursivo completo
$todosArchivos = @(Invoke-ConProgreso -Message "Escaneando instaladores" -Estilo barra -ScriptBlock {
    param($ruta, $patron)
    Get-ChildItem -Path $ruta -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch $patron }
} -ArgumentList $rutaEscaneo, $patronExcluir)

# Clasificar archivos en una sola pasada
$extensionesSet = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($ext in @('.exe', '.bat', '.inf', '.iso', '.msi', '.zip', '.rar', '.7z')) {
    [void]$extensionesSet.Add($ext)
}

foreach ($archivo in $todosArchivos) {
    if ($extensionesSet.Contains($archivo.Extension)) {
        $archivosInstalador.Add($archivo)
    }
}

Write-Host "Archivos de instalador encontrados: $($archivosInstalador.Count)" -ForegroundColor Green
Escribir-Log "Archivos encontrados: $($archivosInstalador.Count)"

# 10. CLASIFICAR: sueltos vs carpetas contenedoras (+ inspeccion de comprimidos)
$extComprimidas = @('.zip', '.rar', '.7z')
$suelto = New-Object System.Collections.Generic.List[object]
$contenedoras = New-Object System.Collections.Generic.List[string]
$omitidos = New-Object System.Collections.Generic.List[object]
$carpetasInstalador = New-Object System.Collections.Generic.List[object]

$script:ruta7zLista = $null
if ($herramienta -and $herramienta.Tipo -eq '7z') { $script:ruta7zLista = $herramienta.Ruta }

foreach ($archivo in $archivosInstalador) {
    $ext = $archivo.Extension.ToLowerInvariant()

    # Inspeccion de comprimidos
    if ($extComprimidas -contains $ext) {
        if ($script:ruta7zLista) {
            $herramientaInspeccion = @{ Tipo = '7z'; Ruta = $script:ruta7zLista }
        } elseif ($ext -eq '.7z' -and $herramienta -and $herramienta.Tipo -eq '7zr') {
            $herramientaInspeccion = $herramienta
        } else {
            if ($ext -eq '.rar' -and $herramienta -and $herramienta.Tipo -eq '7zr') {
                $script:ruta7zLista = Obtener-7zCompleto -Ruta7zr $herramienta.Ruta
            }
            $herramientaInspeccion = if ($script:ruta7zLista) {
                @{ Tipo = '7z'; Ruta = $script:ruta7zLista }
            } elseif ($herramienta -and $herramienta.Tipo -in '7z', 'rar', 'zip') {
                $herramienta
            } else {
                $null
            }
        }

        $contenido = Listar-Comprimido -RutaArchivo $archivo.FullName -Herramienta $herramientaInspeccion
        $clase = Clasificar-Comprimido -Nombres $contenido

        if ($clase -ne 'instalador') {
            $omitidos.Add([pscustomobject]@{
                Archivo   = $archivo
                Clase     = $clase
                Contenido = $contenido
            })
            continue
        }
    }

    $padre = $archivo.DirectoryName.TrimEnd('\', '/')
    $nombrePadre = Split-Path $padre -Leaf
    $esRaiz = [string]::Equals($padre, $rutaEscaneo, [System.StringComparison]::OrdinalIgnoreCase)
    $esProtegida = $carpetasProtegidas -contains $nombrePadre
    if ($esRaiz -or $esProtegida) {
        $suelto.Add($archivo)
    } else {
        if (-not $contenedoras.Contains($padre)) {
            $contenedoras.Add($padre)
        }
    }
}

# Quitar contenedoras anidadas (optimizado con HashSet)
$contenedorasTop = [System.Collections.Generic.List[string]]::new()
$sorted = $contenedoras | Sort-Object { $_.Length }
$kept = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

foreach ($p in $sorted) {
    $isChild = $false
    foreach ($k in $kept) {
        if ($p.StartsWith($k + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
            $p.StartsWith($k + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
            $isChild = $true
            break
        }
    }
    if (-not $isChild) {
        [void]$kept.Add($p)
        $contenedorasTop.Add($p)
    }
}

# 11. EVALUAR CARPETAS CONTENEDORAS (clasificacion local + web)
Write-Host ""
Write-Host "=== EVALUANDO CARPETAS ($($contenedorasTop.Count)) ===" -ForegroundColor Cyan
$script:borradosSuelto = 0
$carpetasAMover = New-Object System.Collections.Generic.List[object]
$carpetasOmitidas = New-Object System.Collections.Generic.List[object]

foreach ($carpeta in $contenedorasTop) {
    $nombre = Split-Path $carpeta -Leaf
    Write-Host "  [$nombre]" -ForegroundColor Yellow

    # Clasificación local
    $clasificacion = Es-CarpetaInstalador -RutaCarpeta $carpeta
    Write-Host "    Local: $($clasificacion.Razon) (confianza: $($clasificacion.Confianza))" -ForegroundColor DarkGray

    # Decisión final
    $decision = Decidir-Movimiento -RutaCarpeta $carpeta -ClasificacionLocal $clasificacion

    if ($decision.Movido -eq $true) {
        $softwareInfo = if ($decision.Software) { " | Software: $($decision.Software)" } else { "" }
        Write-Host "    -> INSTALADOR: $($decision.Razon)$softwareInfo" -ForegroundColor Green
        $carpetasAMover.Add([pscustomobject]@{
            Ruta     = $carpeta
            Nombre   = $nombre
            Razon    = $decision.Razon
            Software = $decision.Software
        })
    } elseif ($decision.Movido -eq $false) {
        Write-Host "    -> OMITIDO: $($decision.Razon)" -ForegroundColor Red
        $carpetasOmitidas.Add([pscustomobject]@{
            Ruta   = $carpeta
            Nombre = $nombre
            Razon  = $decision.Razon
        })
    } else {
        Write-Host "    -> INCERTIDUMBRE: $($decision.Razon)" -ForegroundColor Yellow
        $carpetasOmitidas.Add([pscustomobject]@{
            Ruta   = $carpeta
            Nombre = $nombre
            Razon  = $decision.Razon
        })
    }
}

# 12. PROCESAR ARCHIVOS SUELTOS
Write-Host ""
Write-Host "=== ARCHIVOS SUELTOS ($($suelto.Count)) ===" -ForegroundColor Cyan
foreach ($archivo in $suelto) {
    Write-Host "  [+] $($archivo.FullName)" -ForegroundColor Cyan
    Mover-ArchivoDedup -Archivo $archivo -CarpetaDestino $Destino
}

# 13. PROCESAR CARPETAS DE INSTALADORES
Write-Host ""
Write-Host "=== CARPETAS DE INSTALADORES A MOVER ($($carpetasAMover.Count)) ===" -ForegroundColor Cyan
$movidas = 0

foreach ($item in $carpetasAMover) {
    $destinoCarpeta = Join-Path $Destino $item.Nombre

    if (Test-Path $destinoCarpeta) {
        # Ya existe -> renombrar
        $base = $item.Nombre
        $n = 2
        $nuevoNombre = "${base}_copia$n"
        while (Test-Path (Join-Path $Destino $nuevoNombre)) {
            $n++
            $nuevoNombre = "${base}_copia$n"
        }
        $destinoCarpeta = Join-Path $Destino $nuevoNombre
        Write-Host "  [~] RENOMBRAR y MOVER: $($item.Ruta) -> $destinoCarpeta" -ForegroundColor Yellow
        Agregar-Log -Accion "RENOMBRAR_MOVER" -Archivo $item.Ruta -Detalle "A $destinoCarpeta"
    } else {
        Write-Host "  [+] MOVER: $($item.Ruta) -> $destinoCarpeta" -ForegroundColor Green
        Agregar-Log -Accion "MOVER_CARPETA" -Archivo $item.Ruta -Detalle "A $destinoCarpeta"
    }

    if ($Real) {
        try {
            Move-Item -Path $item.Ruta -Destination $destinoCarpeta -ErrorAction Stop
            $movidas++
        } catch {
            Write-Host "  [ERROR] No se pudo mover la carpeta: $($_.Exception.Message)" -ForegroundColor Red
            Agregar-Log -Accion "ERROR" -Archivo $item.Ruta -Detalle $_.Exception.Message
        }
    }
}

# 14. LIMPIEZA DE CARPETAS VACIAS
if ($Real) {
    Write-Host ""
    Write-Host "=== LIMPIEZA DE CARPETAS VACIAS ===" -ForegroundColor Cyan
    $dirsRaiz = Get-ChildItem -Path $rutaEscaneo -Recurse -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $patronExcluir } |
        Sort-Object { $_.FullName.Length } -Descending
    foreach ($d in $dirsRaiz) {
        if (-not (Get-ChildItem -Path $d.FullName -Force -ErrorAction SilentlyContinue)) {
            Write-Host "  [x] Removida: $($d.FullName)" -ForegroundColor DarkGray
            Remove-Item -Path $d.FullName -Force -ErrorAction SilentlyContinue
            Agregar-Log -Accion "CARPETA_ELIMINADA" -Archivo $d.FullName
        }
    }
}

# 15. DEDUPLICACION INTERNA DEL DESTINO
Write-Host ""
Write-Host "=== DEDUPLICACION INTERNA DEL DESTINO ===" -ForegroundColor Cyan
$duplicadosInternos = 0
$agrupados = Get-ChildItem -Path $Destino -Recurse -File -ErrorAction SilentlyContinue |
    Group-Object { $_.Name.ToLowerInvariant() + "|" + $_.Length }
foreach ($grupo in $agrupados) {
    if ($grupo.Count -gt 1) {
        $conservado = $grupo.Group | Sort-Object { $_.FullName.Length } | Select-Object -First 1
        foreach ($dup in $grupo.Group | Where-Object { $_.FullName -ne $conservado.FullName }) {
            if ($Real) {
                Remove-Item -Path $dup.FullName -Force -ErrorAction SilentlyContinue
                Write-Host "  [X] Duplicado ELIMINADO: $($dup.Name)" -ForegroundColor Red
                Agregar-Log -Accion "DUPLICADO_ELIMINADO" -Archivo $dup.FullName -Detalle "Conservado: $($conservado.Name)"
            } else {
                Write-Host "  [X] Duplicado, se eliminara: $($dup.Name)" -ForegroundColor Red
            }
            $duplicadosInternos++
        }
    }
}

# 16. REPORTE DE CARPETAS OMITIDAS
if ($carpetasOmitidas.Count -gt 0) {
    Write-Host ""
    Write-Host "=== CARPETAS OMITIDAS ($($carpetasOmitidas.Count)) ===" -ForegroundColor Yellow
    foreach ($o in $carpetasOmitidas) {
        Write-Host "  [omitido] $($o.Ruta)" -ForegroundColor Yellow
        Write-Host "    Razon: $($o.Razon)" -ForegroundColor DarkGray
    }
}

# 17. REPORTE DE COMPRIMIDOS NO MOVIDOS
if ($omitidos.Count -gt 0) {
    Write-Host ""
    Write-Host "=== COMPRIMIDOS NO MOVIDOS ($($omitidos.Count)) ===" -ForegroundColor Yellow
    foreach ($o in $omitidos) {
        $color = if ($o.Clase -eq 'documentos') { 'Yellow' } else { 'Red' }
        Write-Host "  [$($o.Clase)] $($o.Archivo.FullName)" -ForegroundColor $color
        if ($o.Contenido.Count -gt 0) {
            $o.Contenido | Select-Object -First 5 | ForEach-Object {
                Write-Host "      | $_" -ForegroundColor DarkGray
            }
            if ($o.Contenido.Count -gt 5) {
                Write-Host "      | ... ($($o.Contenido.Count) archivos en total)" -ForegroundColor DarkGray
            }
        }
    }
}

# 18. RESUMEN FINAL
Write-Host ""
if (-not $Real) {
    Write-Host "SIMULACION: nada se movio ni borro. Re-ejecuta con -Real para aplicar." -ForegroundColor Yellow
} else {
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "RESUMEN FINAL" -ForegroundColor Green
    Write-Host "  Carpetas movidas: $movidas" -ForegroundColor Green
    Write-Host "  Archivos sueltos movidos: $($suelto.Count)" -ForegroundColor Green
    Write-Host "  Duplicados eliminados (origen): $($script:borradosSuelto)" -ForegroundColor Red
    Write-Host "  Duplicados eliminados (interno): $duplicadosInternos" -ForegroundColor Red
    Write-Host "  Carpetas omitidas: $($carpetasOmitidas.Count)" -ForegroundColor Yellow
    Write-Host "  Comprimidos no movidos: $($omitidos.Count)" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Cyan

    # 19. GENERAR REPORTE HTML (con StringBuilder)
    $fecha = Get-Date -Format 'yyyyMMdd_HHmmss'
    $carpetaReportes = "H:\Scripts\Reportes"
    if (-not (Test-Path $carpetaReportes)) { New-Item -Path $carpetaReportes -ItemType Directory -Force | Out-Null }
    $htmlPath = Join-Path $carpetaReportes "reubicar_instaladores_$fecha.html"

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8"><title>Reporte Reubicar Instaladores</title>')
    [void]$sb.AppendLine('<style>body{font-family:Consolas,monospace;background:#1a1a2e;color:#e0e0e0;margin:20px}')
    [void]$sb.AppendLine('h1{color:#00d4ff;border-bottom:2px solid #00d4ff;padding-bottom:10px}')
    [void]$sb.AppendLine('h2{color:#ff6b35;margin-top:30px}')
    [void]$sb.AppendLine('table{border-collapse:collapse;width:100%;margin:10px 0}')
    [void]$sb.AppendLine('th{background:#16213e;color:#00d4ff;padding:8px;border:1px solid #333}')
    [void]$sb.AppendLine('td{padding:6px 12px;border:1px solid #333}')
    [void]$sb.AppendLine('tr:nth-child(even){background:#1f2940}tr:nth-child(odd){background:#16213e}')
    [void]$sb.AppendLine('.total{font-weight:bold;color:#00ff88}.ok{color:#00ff88}.error{color:#ff4444}.warn{color:#ffd93d}</style></head><body>')
    [void]$sb.AppendLine('<h1>Reporte Reubicar Instaladores</h1>')
    [void]$sb.AppendLine("<p>Generado: $(Get-Date -Format 'dd/MM/yyyy HH:mm')</p>")
    [void]$sb.AppendLine("<p class='total'>Origen: $rutaEscaneo -> Destino: $Destino</p>")
    [void]$sb.AppendLine('<h2>Resumen</h2>')
    [void]$sb.AppendLine('<table><tr><th>Metrica</th><th>Valor</th></tr>')
    [void]$sb.AppendLine("<tr><td>Carpetas movidas</td><td class='ok'>$movidas</td></tr>")
    [void]$sb.AppendLine("<tr><td>Archivos sueltos</td><td class='ok'>$($suelto.Count)</td></tr>")
    [void]$sb.AppendLine("<tr><td>Duplicados eliminados</td><td class='error'>$($script:borradosSuelto + $duplicadosInternos)</td></tr>")
    [void]$sb.AppendLine("<tr><td>Carpetas omitidas</td><td class='warn'>$($carpetasOmitidas.Count)</td></tr>")
    [void]$sb.AppendLine("<tr><td>Comprimidos no movidos</td><td class='warn'>$($omitidos.Count)</td></tr></table>")

    if ($carpetasAMover.Count -gt 0) {
        [void]$sb.AppendLine('<h2>Carpetas Movidas</h2>')
        [void]$sb.AppendLine('<table><tr><th>Nombre</th><th>Razon</th><th>Software</th></tr>')
        foreach ($item in $carpetasAMover) {
            $software = if ($item.Software) { $item.Software } else { "N/A" }
            [void]$sb.AppendLine("<tr><td>$($item.Nombre)</td><td>$($item.Razon)</td><td>$software</td></tr>")
        }
        [void]$sb.AppendLine('</table>')
    }

    if ($carpetasOmitidas.Count -gt 0) {
        [void]$sb.AppendLine('<h2>Carpetas Omitidas</h2>')
        [void]$sb.AppendLine('<table><tr><th>Nombre</th><th>Razon</th></tr>')
        foreach ($o in $carpetasOmitidas) {
            [void]$sb.AppendLine("<tr><td>$($o.Nombre)</td><td>$($o.Razon)</td></tr>")
        }
        [void]$sb.AppendLine('</table>')
    }

    [void]$sb.AppendLine('</table></body></html>')
    $html = $sb.ToString()

    if ($esPS7) {
        $html | Out-File -FilePath $htmlPath -Encoding utf8Bom
    } else {
        $utf8Bom = New-Object System.Text.UTF8Encoding $true
        [System.IO.File]::WriteAllText($htmlPath, $html, $utf8Bom)
    }
    Write-Host ""
    Write-Host "  Reporte HTML: $htmlPath" -ForegroundColor Green
}

# 20. CERRAR LOG
if ($Log -and $script:logStream) {
    Escribir-Log "Fin de operacion"
    $script:logStream.Dispose()
    $script:logStream = $null
    Write-Host "  Log guardado: $($script:rutaLog)" -ForegroundColor Green
}
}

# ================================================================
# MENU PRINCIPAL
# ================================================================
function Show-Menu {
    Clear-Host
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║       🛠️  HERRAMIENTAS IT - PS$($PSVersionTable.PSVersion.Major).x                      ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    $herramientas = [ordered]@{
        "BloquearTodo"     = "🔒 Firewall WAN"
        "BloquearWPS"      = "🛡️  Bloquear WPS Office"
        "Borrado"          = "🗑️  Borrado por año"
        "BorrarDuplicados" = "📋 Borrar duplicados"
        "MoverArchivos"    = "📦 Mover archivos"
        "QuitarG"          = "🔤 Quitar G (g*.exe)"
        "QuitarZip"        = "📁 Quitar .ZIP"
        "RepararPerfil"    = "🔧 Reparar perfil"
        "ReporteNAS"       = "📊 Reporte NAS"
        "OrganizaFuentes"  = "🗂️  Organiza fuentes (NAS)"
        "ReubicarInstaladores" = "💽 Reubica instaladores (NAS)"
    }

    $idx = 1; $mapa = @{}
    foreach ($k in $herramientas.Keys) {
        Write-Host "  $idx. $($herramientas[$k])" -ForegroundColor White
        $mapa[$idx.ToString()] = $k; $idx++
    }
    Write-Host "  0. 🚪 Salir" -ForegroundColor Red
    Write-Host ""
    # Entrada protegida: sin consola con entrada Read-Host devuelve "nada" o
    # lanza en 5.1 no interactivo, y $mapa.ContainsKey(null) lanzaria otra
    # excepcion. Vacia = salir del menu sin crashear.
    $op = ""
    try { $op = Read-Host "  Selecciona [0-$idx]" } catch { $op = "" }
    if ([string]::IsNullOrWhiteSpace([string]$op)) { return }
    if ($op -eq "0" -or -not $mapa.ContainsKey($op)) { return }

    switch ($mapa[$op]) {
        "BloquearTodo"     { Invoke-BloquearTodo }
        "BloquearWPS"      { Invoke-BloquearWPS }
        "Borrado"          { Invoke-Borrado }
        "BorrarDuplicados" { Invoke-BorrarDuplicados }
        "MoverArchivos"    { Invoke-MoverArchivos }
        "QuitarG"          { Invoke-QuitarG }
        "QuitarZip"        { Invoke-QuitarZip }
        "RepararPerfil"    { Invoke-RepararPerfil }
        "ReporteNAS"       { Invoke-ReporteNAS }
        "OrganizaFuentes"  { Invoke-OrganizaFuentes }
        "ReubicarInstaladores" { Invoke-ReubicarInstaladores }
    }
    Write-Host ""
    Read-Host "  Enter para volver al menú"
    Show-Menu
}

# ================================================================
# PUNTO DE ENTRADA
# ================================================================
if ($Tool -eq "Menu") { Show-Menu } else {
    switch ($Tool) {
        "BloquearTodo"     { Invoke-BloquearTodo }
        "BloquearWPS"      { Invoke-BloquearWPS }
        "Borrado"          { Invoke-Borrado }
        "BorrarDuplicados" { Invoke-BorrarDuplicados }
        "MoverArchivos"    { Invoke-MoverArchivos }
        "QuitarG"          { Invoke-QuitarG }
        "QuitarZip"        { Invoke-QuitarZip }
        "RepararPerfil"    { Invoke-RepararPerfil }
        "ReporteNAS"       { Invoke-ReporteNAS }
        "OrganizaFuentes"  { Invoke-OrganizaFuentes }
        "ReubicarInstaladores" { Invoke-ReubicarInstaladores }
    }
}

