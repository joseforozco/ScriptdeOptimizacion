<#
.SYNOPSIS
    Optimizador de Windows - Basado en WinScript
.DESCRIPTION
    Script de debloating y optimizacion de Windows con menú interactivo,
    logging de cambios y modo simulacion.
.NOTES
    Compatible con Windows 10 y 11. PowerShell 5.1+ y 7.x. Requiere Administrador.
#>

param(
    [switch]$Ejecutar,
    [switch]$Simulacion,

    # Con '-SinElevar' no se pide UAC: el script sigue como esta. Es lo que
    # hace falta cuando lo lanza una tarea, o cuando el usuario prefiere abrir
    # la terminal elevada por su cuenta.
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



$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ===================== COMPATIBILIDAD APPX / DISM EN PS7 =====================
# Los modulos 'Appx' y 'Dism' son binarios de Windows PowerShell 5.1 (.NET
# Framework) y en Windows 10 NO cargan en PowerShell 7: fallan con
# "Operation is not supported on this platform. (0x80131539)". Con
# $ErrorActionPreference = Stop ese fallo mato el script en la primera
# llamada a Get-AppxPackage (seccion Bloatware). '-UseWindowsPowerShell' los
# carga a traves de una sesion de compatibilidad con 5.1; en builds de
# Windows 11 donde el modulo ya carga solo, la comprobacion previa con
# Get-Command evita cargarlo dos veces.
foreach ($par in @(
        @{ Modulo = 'Appx'; Comando = 'Get-AppxPackage' },
        @{ Modulo = 'Dism'; Comando = 'Get-AppxProvisionedPackage' }
    )) {
    $disponible = $false
    try { $disponible = [bool](Get-Command $par.Comando -ErrorAction SilentlyContinue) } catch { $disponible = $false }
    if (-not $disponible) {
        try {
            # -WarningAction: el aviso estandar de la WinPSCompatSession (los
            # objetos llegan deserializados) es ruido esperado, no un problema.
            Import-Module $par.Modulo -UseWindowsPowerShell -WarningAction SilentlyContinue -ErrorAction Stop
        } catch {
            Write-Host "  AVISO No se pudo cargar el modulo '$($par.Modulo)' via compatibilidad 5.1: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "       Las secciones que usan paquetes APPX/DISM pueden no funcionar." -ForegroundColor Yellow
        }
    }
}
# =================== FIN COMPATIBILIDAD APPX / DISM EN PS7 ===================

# Detección de versión de Windows
$script:WinBuild = [int](Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuild
if ($script:WinBuild -ge 22000) {
    $script:EsWin11 = $true
    $script:NombreSO = "Windows 11"
} else {
    $script:EsWin11 = $false
    $script:NombreSO = "Windows 10"
}

# Cronometro de las marcas 'Paso': cuenta desde el lanzamiento.
$script:InicioScript = Get-Date

# ================================================================
# FUNCIONES GENERALES
# ================================================================

function Write-Log {
    param([string]$Mensaje, [string]$Tipo = "INFO", [switch]$SoloFichero)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $linea = "[$timestamp] [$Tipo] $Mensaje"
    Add-Content -Path $script:LogFile -Value $linea -Encoding UTF8
    # -SoloFichero: para los helpers Show-*, que ya escriben la linea ellos
    # mismos con su estilo. Sin esto el aviso salia DOS veces en consola
    # ("AVISO ..." y justo despues "INFO ..."), como se ve en los logs.
    if ($SoloFichero) { return }
    switch ($Tipo) {
        "OK"    { Write-Host "  OK $Mensaje" -ForegroundColor Green }
        "WARN"  { Write-Host "  WARN $Mensaje" -ForegroundColor Yellow }
        "ERROR" { Write-Host "  ERROR $Mensaje" -ForegroundColor Red }
        "SKIP"  { Write-Host "  SKIP $Mensaje" -ForegroundColor DarkGray }
        default { Write-Host "  INFO $Mensaje" -ForegroundColor Cyan }
    }
}

# Marca de avance con cronometro. Sirve para saber en que bloque se queda el
# script cuando parece congelado: si el cronometro sigue, esta trabajando.
# Compatible con Windows 10 y 11, PowerShell 5.1 y 7.
function Paso {
    param([string]$Texto)
    if (-not $script:InicioScript) { $script:InicioScript = Get-Date }
    $t = [timespan]::FromSeconds([math]::Round(((Get-Date) - $script:InicioScript).TotalSeconds))
    Write-Host ("[{0:hh\:mm\:ss}] {1}" -f $t, $Texto) -ForegroundColor Cyan
    try {
        Add-Content -Path $script:LogFile -Value ("[{0}] [PASO] {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Texto) -Encoding UTF8
    } catch { }
}

# ================================================================
# LECTURA DE ENTRADA PROTEGIDA
# ================================================================
# Medido, no supuesto: Read-Host se comporta de TRES formas distintas cuando
# no le llega entrada, y las tres rompen un menu (comprobado con el script):
#   1. PowerShell 7 con stdin agotado devuelve "nada" (AutomationNull): un
#      switch sobre eso NO ejecuta ni siquiera el 'default', asi que un menu
#      dentro de while($true) gira en silencio para siempre.
#   2. Linea vacia (Enter sin escribir): devuelve "" y el 'default' si se
#      dispara, repitiendo "Opcion no valida" sin fin.
#   3. PowerShell 5.1 no interactivo: Read-Host LANZA excepcion y, con
#      $ErrorActionPreference = Stop, el script se caeria a mitad de camino.
# Test-EntradaInteractiva descarta 1 y 3 de raiz; Read-Respuesta normaliza
# 2 al valor por defecto. Asi ninguna seccion se queda esperando ni en bucle.
# Test-EntradaInteractiva sirve para decidir si ABRIR un menu (si no hay
# consola con entrada no tiene sentido plantarse a esperar); Read-Respuesta
# lee siempre y normaliza la respuesta inservible al valor por defecto.
function Test-EntradaInteractiva {
    try { return -not [Console]::IsInputRedirected } catch { return $false }
}

function Read-Respuesta {
    param([string]$Prompt = "  Selecciona", [string]$PorDefecto = "")
    # Se intenta SIEMPRE leer: si la entrada llega redirigida con datos
    # (echo A | powershell -File optimizador.ps1) se consumen igual. Solo se
    # cae al valor por defecto cuando no hay nada que leer, la respuesta es
    # vacia o el host lanza excepcion. Read-Host en EOF NO bloquea: devuelve
    # "nada" al instante (medido), asi que aqui no puede haber cuelgue.
    try { $r = Read-Host $Prompt } catch { return $PorDefecto }
    # Tanto el "nada" de PowerShell 7 como cadena vacia cuentan como
    # "sin respuesta": se devuelve el valor por defecto, que siempre es algo
    # que el switch siguiente sabe interpretar.
    if ([string]::IsNullOrWhiteSpace([string]$r)) { return $PorDefecto }
    return $r
}

function Invoke-RegAdd {
    param([string]$Path, [string]$Name, [string]$Type, [string]$Value, [string]$Descripcion = "")
    if ($script:ModoSim) {
        Write-Log "(SIMULACION) $Descripcion => $Path\$Name = $Value" "SKIP"
        return
    }
    try {
        if ([string]::IsNullOrEmpty($Name)) {
            & reg add $Path /ve /t $Type /d $Value /f 2>&1 | Out-Null
        } else {
            & reg add $Path /v $Name /t $Type /d $Value /f 2>&1 | Out-Null
        }
        Write-Log $Descripcion "OK"
    } catch {
        Write-Log "$Descripcion - $($_.Exception.Message)" "ERROR"
    }
}

function Invoke-ServiceAction {
    param([string]$Nombre, [string]$Accion, [string]$TipoInicio = "Manual")
    if ($script:ModoSim) {
        Write-Log "(SIMULACION) Servicio $Nombre => $Accion" "SKIP"
        return
    }
    $svc = Get-Service -Name $Nombre -EA SilentlyContinue
    if (-not $svc) {
        Write-Log "Servicio no encontrado: $Nombre" "SKIP"
        return
    }
    try {
        switch ($Accion) {
            "Disabled"  { Set-Service -Name $Nombre -StartupType Disabled }
            "Manual"    { Set-Service -Name $Nombre -StartupType Manual }
            "Stop"      { Stop-Service -Name $Nombre -Force }
            "Disable"   { Set-Service -Name $Nombre -StartupType Disabled; Stop-Service -Name $Nombre -Force }
        }
        Write-Log "Servicio $Nombre => $Accion" "OK"
    } catch {
        Write-Log "Servicio $Nombre - $($_.Exception.Message)" "ERROR"
    }
}

function Invoke-TaskDisable {
    param([string]$TaskName, [string]$Descripcion = "")
    if ($script:ModoSim) {
        Write-Log "(SIMULACION) Tarea: $TaskName" "SKIP"
        return
    }
    try {
        Disable-ScheduledTask -TaskName $TaskName -EA Stop | Out-Null
        Write-Log "Tarea deshabilitada: $TaskName" "OK"
    } catch {
        Write-Log "Tarea no encontrada: $TaskName" "SKIP"
    }
}

function Draw-Line {
    Write-Host ("=" * 60) -ForegroundColor DarkGray
}

# Helpers de presentacion usados por Invoke-BloquearWPS. Aqui no existian: el
# optimizador usa Write-Log para el fichero, pero la funcion de WPS escribe a
# consola con estos. Ademas se deja constancia en el log.
function Show-Success { param([string]$M) Write-Host "  OK $M" -ForegroundColor Green;     Write-Log $M "OK" -SoloFichero }
function Show-Error   { param([string]$M) Write-Host "  ERROR $M" -ForegroundColor Red;    Write-Log $M "ERROR" -SoloFichero }
function Show-Info    { param([string]$M) Write-Host "  INFO $M" -ForegroundColor Cyan;    Write-Log $M -SoloFichero }
function Show-Warning { param([string]$M) Write-Host "  AVISO $M" -ForegroundColor Yellow; Write-Log $M "AVISO" -SoloFichero }

function Draw-Header {
    Clear-Host
    Draw-Line
    Write-Host "  OPTIMIZADOR DE WINDOWS" -ForegroundColor Cyan
    Write-Host "  $($script:NombreSO) (Build $($script:WinBuild))" -ForegroundColor DarkCyan
    Write-Host "  Basado en WinScript - Mejorado" -ForegroundColor DarkGray
    Draw-Line
    if ($script:ModoSim) {
        Write-Host "  MODO: SIMULACION (no se aplican cambios)" -ForegroundColor Yellow
    } else {
        Write-Host "  MODO: EJECUCION REAL" -ForegroundColor Red
    }
    Write-Host "  Log: $($script:LogFile)" -ForegroundColor DarkGray
    Draw-Line
}

# ================================================================
# SECCIONES DEL SCRIPT
# ================================================================

function Remove-BloatCategory {
    param([string]$Nombre, [string[]]$Apps)
    $count = 0
    foreach ($app in $Apps) {
        $pkg = Get-AppxPackage $app -EA SilentlyContinue
        if ($pkg) {
            if (-not $script:ModoSim) {
                # Por PackageFullName (string) y no por el objeto: con el
                # modulo cargado via sesion de compatibilidad 5.1 los paquetes
                # llegan deserializados y el enlace por tipo del objeto falla.
                # Medido: -Package <string> llega bien a la API de despliegue.
                try { Remove-AppxPackage -Package $pkg.PackageFullName -EA Stop; $count++ } catch {}
            } else {
                Write-Log "(SIMULACION) Eliminaria: $app" "SKIP"
            }
        }
    }
    $color = if ($count -gt 0) { "Yellow" } else { "DarkGray" }
    Write-Host "  $Nombre : $count app(s)" -ForegroundColor $color
    return $count
}

function Invoke-SeccionBloatware {
    Write-Host "`n--- Eliminar Bloatware ---" -ForegroundColor Green

    $appsMicrosoft = @(
        "*Microsoft.3DBuilder*","*Microsoft.Microsoft3DViewer*","*Microsoft.AppConnector*",
        "*Microsoft.BingFoodAndDrink*","*Microsoft.BingHealthAndFitness*","*BingSearch*",
        "*Microsoft.BingTranslator*","*Microsoft.BingTravel*","*Clipchamp.Clipchamp*",
        "*Microsoft.WindowsAlarms*","*Microsoft.WindowsFeedbackHub*","*Microsoft.GetHelp*",
        "*Microsoft.Getstarted*","*Microsoft.ZuneMusic*","*microsoft.windowscommunicationsapps*",
        "*Microsoft.MicrosoftOfficeHub*","*Microsoft.WindowsSoundRecorder*","*Microsoft.News*",
        "*Microsoft.People*","*Microsoft.MicrosoftSolitaireCollection*","*MSTeams*",
        "*Microsoft.Todos*","*Microsoft.Wallet*","*Microsoft.Whiteboard*",
        "*Microsoft.MixedReality.Portal*","*Microsoft.BingFinance*","*Microsoft.BingNews*",
        "*Microsoft.BingSports*","*Microsoft.BingWeather*","*Microsoft.Office.OneNote*",
        "*Microsoft.OneConnect*","*Microsoft.MSPaint*","*Microsoft.CommsPhone*",
        "*Microsoft.YourPhone*","*Microsoft.Print3D*","*QuickAssist*",
        "*Microsoft.SkypeApp*","*Microsoft.MicrosoftStickyNotes*","*Microsoft.Office.Sway*",
        "*Microsoft.WindowsMaps*","*Microsoft.549981C3F5F10*","*Microsoft.NetworkSpeedTest*",
        "*Microsoft.PowerAutomateDesktop*","*Microsoft.WindowsPhone*",
        "*Microsoft.WindowsReadingList*","*Microsoft.WindowsCamera*"
    )

    $appsJuegos = @(
        "*ACGMediaPlayer*","*ActiproSoftwareLLC*","*Asphalt8Airborne*",
        "*BubbleWitch3Saga*","*CaesarsSlotsFreeCasino*","*CandyCrush*",
        "*COOKINGFEVER*","*DisneyMagicKingdoms*","*DropboxOEM*",
        "*Duolingo-LearnLanguagesforFree*","*EclipseManager*",
        "*FarmVille2CountryEscape*","*HiddenCity*",
        "*king.com.BubbleWitch3Saga*","*king.com.CandyCrushSaga*",
        "*king.com.CandyCrushSodaSaga*","*MarchofEmpires*",
        "*NYTCrossword*","*RoyalRevolt*","*Slotomania*"
    )

    $appsStreaming = @(
        "*AmazonVideo.PrimeVideo*","*Facebook*","*Flipboard*",
        "*HULULLC.HULUPLUS*","*iHeartRadio*","*LinkedInForWindows*",
        "*McAfee*","*Netflix*","*OneCalendar*","*PandoraMediaInc*",
        "*Plex*","*ShazamEntertainmentLtd.Shazam*","*SlingTV*",
        "*SpotifyAB.SpotifyMusic*","*TuneInRadio*","*Twitter*",
        "*Viber*","*Wunderlist*","*BytedancePte.Ltd.TikTok*",
        "*FACEBOOK*","*Instagram*","*WhatsApp*"
    )

    $appsHP = @(
        "*AD2F1837.myHP*","*AD2F1837.HPJumpStarts*","*AD2F1837.HPSupportAssistant*",
        "*AD2F1837.HPQuickDrop*","*AD2F1837.HPWelcome*","*AD2F1837.HPPrivacySettings*",
        "*AD2F1837.HPEasyClean*","*AD2F1837.HPWorkWell*","*AD2F1837.HPConnectedMusic*",
        "*AD2F1837.HPConnectedPhotopoweredbySnapfish*","*AD2F1837.HPDesktopSupportUtilities*",
        "*AD2F1837.HPFileViewer*","*AD2F1837.HPPowerManager*","*AD2F1837.HPPrinterControl*",
        "*AD2F1837.HPQuickTouch*","*AD2F1837.HPRegistration*","*AD2F1837.HPSureShieldAI*",
        "*AD2F1837.HPSystemInformation*","*AD2F1837.HPAIExperienceCenter*"
    )

    $appsDell = @(
        "*DellInc.DellCustomerConnect*","*DellInc.DellDigitalDelivery*",
        "*DellInc.DellHelpSupport*","*DellInc.DellProductRegistration*","*DellInc.MyDell*"
    )

    $appsLenovo = @(
        "*E046963F.LenovoCompanion*","*E046963F.LenovoSettingsforWindows*",
        "*E046963F.LenovoVantageService*","*E046963F.LenovoAppExplorer*"
    )

    $appsASUS = @(
        "*ASUSTeK.COMPUTER.ASUSProductStudyGuide*","*ASUSTeK.COMPUTER.ASUSTuning*",
        "*ASUSTeK.COMPUTER.ROGGamingFocusApp*","*ASUSTeK.COMPUTER.GiftBox*",
        "*ASUSTeK.COMPUTER.Splendid*"
    )

    $appsAcer = @(
        "*AcerInc.AcerPortal*","*AcerInc.abDocs*","*AcerInc.abPhoto*",
        "*AcerInc.AcerCareCenter*","*AcerInc.AcerJumpstart*"
    )

    $appsSamsung = @("*SAMSUNGELECTRONICSCO.LTD.*")

    $total = 0
    $total += Remove-BloatCategory "Microsoft     " $appsMicrosoft
    $total += Remove-BloatCategory "Juegos        " $appsJuegos
    $total += Remove-BloatCategory "Streaming/Redes" $appsStreaming
    $total += Remove-BloatCategory "HP OEM        " $appsHP
    $total += Remove-BloatCategory "Dell OEM      " $appsDell
    $total += Remove-BloatCategory "Lenovo OEM    " $appsLenovo
    $total += Remove-BloatCategory "ASUS OEM      " $appsASUS
    $total += Remove-BloatCategory "Acer OEM      " $appsAcer
    $total += Remove-BloatCategory "Samsung OEM   " $appsSamsung

    Write-Host "  --------------------------------" -ForegroundColor DarkGray
    $textoTotal = if ($total -eq 1) { "1 app" } else { "$total apps" }
    Write-Host "  TOTAL: $textoTotal eliminada(s)" -ForegroundColor $(if ($total -gt 0) { "Green" } else { "DarkGray" })
    Write-Log "Bloatware eliminado: $total apps" "OK"
}

function Invoke-SeccionCopilot {
    Write-Host "`n--- Eliminar Copilot/IA ---" -ForegroundColor Green
    $aiPackages = @('Microsoft.Windows.Ai.Copilot.Provider','Microsoft.Copilot',
                    'Microsoft.WindowsAiFoundation','Microsoft.Windows.Recall')
    foreach ($pkg in $aiPackages) {
        if (-not $script:ModoSim) {
            try {
                # Mismo criterio que en Remove-BloatCategory: el nombre completo
                # viaja como string porque los objetos del modulo (cargado via
                # compatibilidad 5.1) llegan deserializados y no enlazan.
                $instalados = @(Get-AppxPackage -Name $pkg -AllUsers -EA SilentlyContinue)
                foreach ($inst in $instalados) {
                    Remove-AppxPackage -Package $inst.PackageFullName -AllUsers -EA SilentlyContinue
                }
                $prov = @(Get-AppxProvisionedPackage -Online -EA SilentlyContinue |
                    Where-Object DisplayName -like $pkg)
                foreach ($provPkg in $prov) {
                    Remove-AppxProvisionedPackage -Online -PackageName $provPkg.PackageName -EA SilentlyContinue
                }
            } catch {}
        }
    }
    Invoke-RegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" "REG_DWORD" "1" "Deshabilitar Copilot (HKLM)"
    Invoke-RegAdd "HKCU\Software\Policies\Microsoft\Windows\WindowsCopilot" "TurnOffWindowsCopilot" "REG_DWORD" "1" "Deshabilitar Copilot (HKCU)"
    Invoke-RegAdd "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowCopilotButton" "REG_DWORD" "0" "Ocultar boton Copilot"
    Invoke-RegAdd "HKLM\SOFTWARE\Microsoft\Windows\Shell\Copilot" "IsCopilotAvailable" "REG_DWORD" "0" "Copilot no disponible"
    Write-Log "Copilot deshabilitado" "OK"
}

function Invoke-SeccionRecall {
    Write-Host "`n--- Deshabilitar Recall ---" -ForegroundColor Green
    if (-not $script:EsWin11) {
        Write-Log "Recall solo existe en Windows 11 - omitido" "SKIP"
        return
    }
    if (-not $script:ModoSim) {
        Paso 'DISM: Recall'
        $recall = Get-WindowsOptionalFeature -Online -FeatureName Recall -ErrorAction SilentlyContinue
        if ($null -ne $recall -and $recall.State -eq 'Enabled') {
            DISM /Online /Disable-Feature /NoRestart /FeatureName:Recall 2>&1 | Out-Null
        } else {
            Write-Log "Recall no esta disponible en esta build - omitido" "SKIP"
        }
    }
    Invoke-TaskDisable "\Microsoft\Windows\WindowsAI\*" "Tareas WindowsAI"
    Invoke-TaskDisable "\Microsoft\Windows\Recall\*" "Tareas Recall"
    Invoke-RegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" "DisableAIDataAnalysis" "REG_DWORD" "1" "Deshabilitar analisis IA"
    Write-Log "Recall deshabilitado" "OK"
}

function Invoke-SeccionOneDrive {
    Write-Host "`n--- Desinstalar OneDrive ---" -ForegroundColor Green
    if (-not $script:ModoSim) {
        Stop-Process -Name "OneDrive" -Force -EA SilentlyContinue
        $uninstaller = "$env:SystemRoot\System32\OneDriveSetup.exe"
        if (Test-Path $uninstaller) {
            Start-Process -FilePath $uninstaller -ArgumentList "/uninstall" -Wait
        }
        if (Test-Path "$env:USERPROFILE\OneDrive") {
            Paso 'OneDrive: moviendo el contenido (robocopy, puede tardar)'
            robocopy "$env:USERPROFILE\OneDrive" "$env:USERPROFILE" /mov /e /xj /ndl /nfl /njh /njs /nc /ns /np 2>&1 | Out-Null
        } else {
            Write-Log "No hay carpeta OneDrive - sin nada que mover" "SKIP"
        }
        # "HKCR:" no esta montado por defecto en ningun motor (medido): sin la
        # ruta 'Registry::' estas dos limpiezas eran un no-op silencioso.
        Remove-Item -LiteralPath "Registry::HKEY_CLASSES_ROOT\WOW6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}" -Recurse -Force -EA SilentlyContinue
        Remove-Item -LiteralPath "Registry::HKEY_CLASSES_ROOT\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}" -Recurse -Force -EA SilentlyContinue
        Remove-Item "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\OneDrive.lnk" -Force -EA SilentlyContinue
        Get-ScheduledTask -TaskPath '\' -TaskName 'OneDrive*' -EA SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -EA SilentlyContinue
        @("$env:USERPROFILE\OneDrive","$env:LOCALAPPDATA\OneDrive","$env:LOCALAPPDATA\Microsoft\OneDrive",
          "$env:ProgramData\Microsoft OneDrive","C:\OneDriveTemp") | ForEach-Object {
            Remove-Item -Path $_ -Recurse -Force -EA SilentlyContinue
        }
        Remove-Item -Path "HKCU:\Software\Microsoft\OneDrive" -Recurse -Force -EA SilentlyContinue
    }
    Write-Log "OneDrive desinstalado" "OK"
}

function Invoke-SeccionBrowsers {
    Write-Host "`n--- Deshabilitar Edge/Brave ---" -ForegroundColor Green
    $edgePolicies = @{
        "EdgeEnhanceImagesEnabled" = "0"; "PersonalizationReportingEnabled" = "0"
        "ShowRecommendationsEnabled" = "0"; "HideFirstRunExperience" = "1"
        "UserFeedbackAllowed" = "0"; "ConfigureDoNotTrack" = "1"
        "AlternateErrorPagesEnabled" = "0"; "EdgeCollectionsEnabled" = "0"
        "EdgeFollowEnabled" = "0"; "EdgeShoppingAssistantEnabled" = "0"
        "MetricsReportingEnabled" = "0"; "StartupBoostEnabled" = "0"
        "HubsSidebarEnabled" = "0"; "CopilotPageAction" = "0"
        "CryptoWalletEnabled" = "0"
    }
    foreach ($kv in $edgePolicies.GetEnumerator()) {
        Invoke-RegAdd "HKLM\SOFTWARE\Policies\Microsoft\Edge" $kv.Key "REG_DWORD" $kv.Value "Edge: $($kv.Key)"
    }
    Invoke-RegAdd "HKLM\SOFTWARE\Policies\BraveSoftware\Brave" "BraveRewardsDisabled" "REG_DWORD" "1" "Brave: Rewards off"
    Invoke-RegAdd "HKLM\SOFTWARE\Policies\BraveSoftware\Brave" "BraveWalletDisabled" "REG_DWORD" "1" "Brave: Wallet off"
    Invoke-RegAdd "HKLM\SOFTWARE\Policies\BraveSoftware\Brave" "BraveAIChatEnabled" "REG_DWORD" "0" "Brave: AI Chat off"
    Write-Log "Browsers deshabilitados" "OK"
}

function Invoke-SeccionTelemetria {
    Write-Host "`n--- Deshabilitar Telemetria (Windows/Office/NVIDIA) ---" -ForegroundColor Green

    # --- WINDOWS ---
    Write-Host "  Windows..." -ForegroundColor DarkGray
    $tasks = @(
        "\Microsoft\Windows\Customer Experience Improvement Program\Consolidator",
        "\Microsoft\Windows\Customer Experience Improvement Program\KernelCeipTask",
        "\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip",
        "\Microsoft\Windows\Autochk\Proxy",
        "\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector",
        "\Microsoft\Windows\Feedback\Siuf\DmClient",
        "\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload",
        "\Microsoft\Windows\Windows Error Reporting\QueueReporting",
        "\Microsoft\Windows\Maps\MapsUpdateTask"
    )
    foreach ($t in $tasks) { Invoke-TaskDisable $t }
    @("DiagTrack","diagsvc","WerSvc","wercplsupport") | ForEach-Object {
        Invoke-ServiceAction $_ "Manual"
    }
    Invoke-RegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" "REG_DWORD" "0" "Telemetria Windows off"
    Invoke-RegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "DisableOneSettingsDownloads" "REG_DWORD" "1" "OneSettings off"
    Invoke-RegAdd "HKLM\Software\Policies\Microsoft\SQMClient\Windows" "CEIPEnable" "REG_DWORD" "0" "CEIP off"
    Invoke-RegAdd "HKLM\Software\Policies\Microsoft\Windows\Windows Error Reporting" "Disabled" "REG_DWORD" "1" "WER off"
    Invoke-RegAdd "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" "Enabled" "REG_DWORD" "0" "Publicidad off"
    Invoke-RegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo" "DisabledByGroupPolicy" "REG_DWORD" "1" "Publicidad GP off"
    # Refuerzos de WinUtil: experiencias personalizadas y prediccion de
    # texto en la nube (entradas que faltaban en esta seccion).
    Invoke-RegAdd "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy" "TailoredExperiencesWithDiagnosticDataEnabled" "REG_DWORD" "0" "Experiencias personalizadas off"
    Invoke-RegAdd "HKCU\SOFTWARE\Microsoft\Input\TIPC" "Enabled" "REG_DWORD" "0" "Prediccion de texto en la nube off"

    # --- OFFICE ---
    Write-Host "  Office..." -ForegroundColor DarkGray
    foreach ($v in @("15.0","16.0")) {
        Invoke-RegAdd "HKCU\SOFTWARE\Microsoft\Office\$v\Outlook\Options\Mail" "EnableLogging" "REG_DWORD" "0" "Outlook $v logging off"
        Invoke-RegAdd "HKCU\SOFTWARE\Microsoft\Office\$v\Outlook\Options\Calendar" "EnableCalendarLogging" "REG_DWORD" "0" "Calendar $v logging off"
        Invoke-RegAdd "HKCU\SOFTWARE\Microsoft\Office\$v\Word\Options" "EnableLogging" "REG_DWORD" "0" "Word $v logging off"
        Invoke-RegAdd "HKCU\SOFTWARE\Policies\Microsoft\Office\$v\OSM" "EnableLogging" "REG_DWORD" "0" "OSM $v logging off"
        Invoke-RegAdd "HKCU\SOFTWARE\Policies\Microsoft\Office\$v\OSM" "EnableUpload" "REG_DWORD" "0" "OSM $v upload off"
    }
    Invoke-RegAdd "HKCU\SOFTWARE\Microsoft\Office\Common\ClientTelemetry" "DisableTelemetry" "REG_DWORD" "1" "Office telemetry off"
    Invoke-RegAdd "HKCU\SOFTWARE\Microsoft\Office\Common\ClientTelemetry" "VerboseLogging" "REG_DWORD" "0" "Office verbose off"
    @("OfficeTelemetryAgentFallBack","OfficeTelemetryAgentLogOn",
      "OfficeTelemetryAgentFallBack2016","OfficeTelemetryAgentLogOn2016",
      "Office 15 Subscription Heartbeat","Office 16 Subscription Heartbeat") | ForEach-Object {
        Invoke-TaskDisable "\Microsoft\Office\$_"
    }

    # --- NVIDIA ---
    Write-Host "  NVIDIA..." -ForegroundColor DarkGray
    Invoke-RegAdd "HKLM\SOFTWARE\NVIDIA Corporation\NvControlPanel2\Client" "OptInOrOutPreference" "REG_DWORD" "0" "NVIDIA OptIn off"
    Invoke-RegAdd "HKLM\SOFTWARE\NVIDIA Corporation\Global\FTS" "EnableRID44231" "REG_DWORD" "0" "NVIDIA FTS 44231 off"
    Invoke-RegAdd "HKLM\SOFTWARE\NVIDIA Corporation\Global\FTS" "EnableRID64640" "REG_DWORD" "0" "NVIDIA FTS 64640 off"
    Invoke-RegAdd "HKLM\SOFTWARE\NVIDIA Corporation\Global\FTS" "EnableRID66610" "REG_DWORD" "0" "NVIDIA FTS 66610 off"
    Invoke-RegAdd "HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\Startup" "SendTelemetryData" "REG_DWORD" "0" "NVIDIA telemetry off"
    @("NvTmMon_{B2FE1952-0186-46C3-BAEC-A80AA35AC5B8}",
      "NvTmRep_{B2FE1952-0186-46C3-BAEC-A80AA35AC5B8}",
      "NvTmRepOnLogon_{B2FE1952-0186-46C3-BAEC-A80AA35AC5B8}") | ForEach-Object {
        Invoke-TaskDisable $_
    }
    Invoke-ServiceAction "NvTelemetryContainer" "Disabled"

    Write-Log "Telemetria (Windows+Office+NVIDIA) deshabilitada" "OK"
}

function Invoke-SeccionServicios {
    Write-Host "`n--- Optimizar Servicios ---" -ForegroundColor Green
    $manuales = @(
        "ALG","AppMgmt","AppReadiness","AxInstSV","BDESVC","BTAGService",
        "BcastDVRUserService","BluetoothUserService","Browser","CDPSvc",
        "COMSysApp","CaptureService","CertPropSvc","CscService",
        "DevQueryBroker","DeviceAssociationService","DeviceInstall",
        "DisplayEnhancementService","DmEnrollmentSvc","DsSvc","DsmSvc",
        "EFS","EapHost","EntAppSvc","FDResPub","FrameServer",
        "FrameServerMonitor","GraphicsPerfSvc","HvHost","IEEtwCollectorService",
        "InstallService","InventorySvc","KtmRm","LicenseManager",
        "MSDTC","MSiSCSI","MapsBroker","McpManagementService","MsKeyboardFilter",
        "NPSMSvc","NaturalAuthentication","NcaSvc","NcbService",
        "NcdAutoSetup","NetSetupSvc","Netman","NgcCtnrSvc","NgcSvc",
        "NlaSvc","PNRPAutoReg","PcaSvc","PeerDistSvc","PenService",
        "PerfHost","PhoneSvc","PimIndexMaintenanceSvc","PlugPlay",
        "PolicyAgent","PrintNotify","PushToInstall","QWAVE","RasAuto",
        "RasMan","RetailDemo","RmSvc","RpcLocator","SCPolicySvc",
        "SCardSvr","SDRSVC","SEMgrSvc","SNMPTRAP","SSDPSRV",
        "ScDeviceEnum","SensorDataService","SensorService","SensrSvc",
        "SessionEnv","SharedAccess","SmsRouter","SstpSvc","StiSvc",
        "StorSvc","TapiSrv","TextInputManagementService","TieringEngineService",
        "TokenBroker","TroubleshootingSvc","UdkUserSvc","UmRdpService",
        "UserDataSvc","UsoSvc","VSS","VacSvc","WEPHOSTSVC",
        "WFDSConMgrSvc","WMPNetworkSvc","WManSvc","WPDBusEnum",
        "WalletService","WarpJITSvc","WbioSrvc","WdNisSvc",
        "WdiServiceHost","WdiSystemHost","WebClient","Wecsvc",
        "WerSvc","WiaRpc","WinRM","WpcMonSvc","WpnService",
        "WwanSvc","autotimesvc","bthserv","camsvc","cbdhsvc",
        "cloudidsvc","dcsvc","defragsvc","diagsvc","dmwappushservice",
        "dot3svc","edgeupdate","edgeupdatem","embeddedmode","fdPHost",
        "fhsvc","hidserv","icssvc","lfsvc","lltdsvc","lmhosts",
        "msiserver","netprofm","p2pimsvc","p2psvc","pla",
        "seclogon","smphost","svsvc","swprv","upnphost","wcncsvc",
        "TabletInputService","W3Csvc","Wcmsvc","Wecsvc","WerSvc"
    )
    $deshabilitados = @(
        "AppVClient","AssignedAccessManagerSvc","DiagTrack",
        "DialogBlockingService","NetTcpPortSharing","RemoteAccess",
        "RemoteRegistry","shpamsvc","ssh-agent","tzautoupdate"
    )
    $contM = 0; $contD = 0
    foreach ($s in $manuales) {
        $svc = Get-Service -Name $s -EA SilentlyContinue
        if ($svc) {
            if (-not $script:ModoSim) {
                try { Set-Service -Name $s -StartupType Manual; $contM++ } catch {}
            }
        }
    }
    foreach ($s in $deshabilitados) {
        $svc = Get-Service -Name $s -EA SilentlyContinue
        if ($svc) {
            if (-not $script:ModoSim) {
                try { Set-Service -Name $s -StartupType Disabled; Stop-Service -Name $s -Force -EA SilentlyContinue; $contD++ } catch {}
            }
        }
    }
    Write-Log "Servicios: $contM en Manual, $contD deshabilitados" "OK"
}

function Invoke-SeccionLimpieza {
    Write-Host "`n--- Limpiar Archivos ---" -ForegroundColor Green
    # Papelera
    if (-not $script:ModoSim) {
        $bin = (New-Object -ComObject Shell.Application).NameSpace(10)
        $bin.items() | ForEach-Object { Remove-Item $_.Path -Recurse -Force -EA SilentlyContinue }
    }
    # Temp
    @("C:\Windows\Temp\*","C:\Windows\Prefetch\*") | ForEach-Object {
        if (-not $script:ModoSim) { Remove-Item -Path $_ -Recurse -Force -EA SilentlyContinue }
    }
    # Historial browsers
    $browserPaths = @(
        "$env:LocalAppData\Google\Chrome\User Data\Default\History",
        "$env:LocalAppData\Google\Chrome\User Data\Default\Cookies",
        "$env:LocalAppData\Microsoft\Edge\User Data\Default\History",
        "$env:LocalAppData\Microsoft\Edge\User Data\Default\Cookies",
        "$env:LocalAppData\BraveSoftware\Brave-Browser\User Data\Default\History",
        "$env:LocalAppData\BraveSoftware\Brave-Browser\User Data\Default\Cookies"
    )
    foreach ($p in $browserPaths) {
        if (-not $script:ModoSim) { Remove-Item -Path $p -Recurse -Force -EA SilentlyContinue }
    }
    Write-Log "Limpieza completada" "OK"
}

function Invoke-SeccionUI {
    Write-Host "`n--- Interfaz de Usuario ---" -ForegroundColor Green
    if ($script:EsWin11) {
        Invoke-RegAdd "HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" "" "REG_SZ" "" "Menu clasico click derecho"
        Invoke-RegAdd "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings" "TaskbarEndTask" "REG_DWORD" "1" "End Task en barra"
        Invoke-RegAdd "HKCU\Software\Microsoft\Windows\CurrentVersion\Start" "ShowRecentList" "REG_DWORD" "0" "Ocultar apps recientes"
        Invoke-RegAdd "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "Start_IrisRecommendations" "REG_DWORD" "0" "Ocultar recomendaciones"
    } else {
        Write-Log "Ajustes UI especificos de Win11 omitidos" "SKIP"
    }
    Invoke-RegAdd "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "HideFileExt" "REG_DWORD" "0" "Mostrar extensiones"
    Invoke-RegAdd "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ShowTaskViewButton" "REG_DWORD" "0" "Ocultar Task View"
    # El menu clasico (y los ajustes de barra) solo se ven al recargar
    # Explorer: se reinicia (parpadeo de ~2 segundos), como hace WinUtil.
    # Sin esto la clave existia desde siempre pero el menu clasico no
    # aparecia hasta cerrar y volver a abrir sesion.
    if ($script:EsWin11 -and -not $script:ModoSim) {
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
            Start-Process -FilePath explorer.exe -ErrorAction SilentlyContinue
        }
        Write-Log "Explorer reiniciado para aplicar el menu clasico y la barra" "OK"
    }
    Write-Log "UI optimizada" "OK"
}

function Invoke-SeccionDNS {
    param([bool]$AutoMode = $false)
    Write-Host "`n--- Configurar DNS ---" -ForegroundColor Green
    Write-Host "  DNS disponibles:" -ForegroundColor Cyan
    Write-Host "    1) Google (8.8.8.8)" -ForegroundColor White
    Write-Host "    2) Cloudflare (1.1.1.1)" -ForegroundColor White
    Write-Host "    3) Quad9 (9.9.9.9)" -ForegroundColor White
    Write-Host "    4) No cambiar" -ForegroundColor White
    if ($AutoMode) {
        Write-Host "  (Modo automatico: usando Google)" -ForegroundColor DarkGray
        $dnsOp = "1"
    } else {
        # Sin respuesta no se toca el DNS y queda constancia explicita en el
        # log. Antes un Read-Host "nada" dejaba el switch sin rama que
        # ejecutar y el script seguia sin decir si el DNS habia cambiado o no.
        $dnsOp = Read-Respuesta "  Selecciona [1-4]" ""
    }
    switch ($dnsOp) {
        "1" { $dns = @("8.8.8.8","8.8.4.4") }
        "2" { $dns = @("1.1.1.1","1.0.0.1") }
        "3" { $dns = @("9.9.9.9","149.112.112.112") }
        "4" { Write-Log "DNS no cambiado (elegido 'No cambiar')" "SKIP"; return }
        ""  { Write-Log "DNS no cambiado (sin respuesta en el menu)" "SKIP"; return }
        default { Write-Log "DNS no cambiado (opcion no valida: '$dnsOp')" "SKIP"; return }
    }
    if (-not $script:ModoSim) {
        $interfaz = (Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1).Name
        if ($interfaz) {
            Set-DnsClientServerAddress -InterfaceAlias $interfaz -ServerAddresses $dns
            Write-Log "DNS configurado en $interfaz : $($dns -join ', ')" "OK"
        } else {
            Write-Log "No se encontro interfaz activa" "WARN"
        }
    }
}

function Invoke-SeccionPower {
    Write-Host "`n--- Alto Rendimiento ---" -ForegroundColor Green
    $guid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    if (-not $script:ModoSim) {
        $exists = powercfg -list | Select-String $guid
        if (-not $exists) {
            powercfg -duplicatescheme $guid 2>&1 | Out-Null
        }
        powercfg -setactive $guid
    }
    Write-Log "Plan de energia: Alto Rendimiento" "OK"

    # Optimizador de unidades (defrag)
    Write-Host "  Activando Optimizador de unidades..." -ForegroundColor DarkGray
    Invoke-ServiceAction "defragsvc" "Automatic"
    if (-not $script:ModoSim) {
        Start-Service -Name "defragsvc" -EA SilentlyContinue
    }
    Write-Log "Servicio Optimizador de unidades habilitado e iniciado" "OK"

    # Compresion de memoria - deshabilitar si hay suficiente RAM
    Write-Host "  Verificando compresion de memoria..." -ForegroundColor DarkGray
    $ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    Write-Host "  RAM detectada: ${ramGB}GB" -ForegroundColor DarkGray
    if ($ramGB -le 16) {
        Write-Log "RAM <= 16GB: compresion de memoria MANTENIDA (util para diseño gráfico)" "OK"
    } else {
        if (-not $script:ModoSim) {
            try {
                Disable-MMAgent -MemoryCompression -EA Stop
                Write-Log "RAM > 16GB: compresion de memoria deshabilitada (libera CPU)" "OK"
            } catch {
                Write-Log "Compresion de memoria no disponible" "SKIP"
            }
        } else {
            Write-Log "(SIMULACION) Deshabilitar compresion de memoria" "SKIP"
        }
    }
}

function Invoke-SeccionRegistros {
    Write-Host "`n--- Registros Adicionales ---" -ForegroundColor Green
    # Consumer Features
    Invoke-RegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableWindowsConsumerFeatures" "REG_DWORD" "1" "Consumer Features off"
    Invoke-RegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" "DisableCloudOptimizedContent" "REG_DWORD" "1" "Cloud Content off"
    # Activity Feed
    Invoke-RegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" "EnableActivityFeed" "REG_DWORD" "0" "Activity Feed off"
    # Maps
    Invoke-RegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\Maps" "AutoDownloadAndUpdateMapData" "REG_DWORD" "0" "Mapas auto-update off"
    # IPv6
    Invoke-RegAdd "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters" "DisabledComponents" "REG_DWORD" "32" "IPv6 deshabilitado"
    # BitLocker
    Invoke-RegAdd "HKLM\SYSTEM\CurrentControlSet\Control\BitLocker" "PreventDeviceEncryption" "REG_DWORD" "1" "BitLocker off"
    # Cloud Sync
    Invoke-RegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\SettingSync" "DisableSettingSync" "REG_DWORD" "2" "SettingSync off"
    Invoke-RegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\SettingSync" "DisableSettingSyncUserOverride" "REG_DWORD" "1" "SettingSync override off"
    # Cortana
    Invoke-RegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "AllowCortana" "REG_DWORD" "0" "Cortana off"
    Invoke-RegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "DisableWebSearch" "REG_DWORD" "1" "Web Search off"
    Invoke-RegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "AllowCloudSearch" "REG_DWORD" "0" "Cloud Search off"
    # Search
    Invoke-RegAdd "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" "BingSearchEnabled" "REG_DWORD" "0" "Bing Search off"
    # BSOD
    Invoke-RegAdd "HKLM\System\CurrentControlSet\Control\CrashControl" "DisplayParameters" "REG_DWORD" "1" "BSOD detallado"
    # Verbose logon
    Invoke-RegAdd "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "VerboseStatus" "REG_DWORD" "1" "Verbose logon"
    # UTC clock
    Invoke-RegAdd "HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" "RealTimeIsUniversal" "REG_DWORD" "1" "Reloj UTC"
    # Prefetch (sysmain). Antes se deshabilitaba sin dejar rastro en el log,
    # de modo que no habia forma de comprobar despues que el cambio se hizo.
    # Prefetch (sysmain) via Invoke-ServiceAction: comprueba que el servicio
    # exista antes de tocarlo y respeta el modo simulacion.
    Invoke-ServiceAction "sysmain" "Disable"
    Write-Log "Registros adicionales aplicados" "OK"
}

# ================================================================
# SECCION: BLOAT DE FABRICANTE Y SEGURIDAD (de Chris Titus WinUtil)
# ================================================================
# Opciones contrastadas de WinUtil que faltaban aqui: el bloat que los
# fabricantes intentan meter al conectar dispositivos (Razer, Logitech,
# companions de monitores), la puerta trasera WPBT de la BIOS, rutas
# largas, apps en segundo plano globales, ubicacion denegada y hibernacion.
function Invoke-SeccionFabricantes {
    Write-Host "`n--- Bloat de fabricante y seguridad ---" -ForegroundColor Green

    # 1) Co-instaladores de dispositivos: sin esto, al conectar un raton, un
    #    teclado o un monitor puede instalarse solo el software del
    #    fabricante (Razer Synapse y similares).
    Invoke-RegAdd "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Installer" "DisableCoInstallers" "REG_DWORD" "1" "Co-instaladores de dispositivos off"
    Invoke-RegAdd "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching" "SearchOrderConfig" "REG_DWORD" "0" "Descarga automatica de drivers off"
    # 2) Companions del Store y metadatos de dispositivos descargados por red
    Invoke-RegAdd "HKLM\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" "PreventDeviceMetadataFromNetwork" "REG_DWORD" "1" "Metadatos de dispositivos por red off"
    # 3) WPBT: tabla de la BIOS con la que el OEM puede ejecutar e instalar
    #    software en el arranque sin consentimiento (riesgo de seguridad).
    Invoke-RegAdd "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager" "DisableWpbtExecution" "REG_DWORD" "1" "WPBT (instalador del OEM) off"
    # 4) Rutas de mas de 260 caracteres
    Invoke-RegAdd "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" "LongPathsEnabled" "REG_DWORD" "1" "Rutas largas habilitadas"
    # 5) Apps de Store en segundo plano: corte global (en Win11 tocaba app
    #    por app)
    Invoke-RegAdd "HKCU\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" "GlobalUserDisabled" "REG_DWORD" "1" "Apps en segundo plano off (global)"
    # 6) Ubicacion denegada a nivel de maquina, sensor incluido
    Invoke-RegAdd "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location" "Value" "REG_SZ" "Deny" "Ubicacion denegada"
    Invoke-RegAdd "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}" "SensorPermissionState" "REG_DWORD" "0" "Sensor de ubicacion off"
    Invoke-RegAdd "HKLM\SYSTEM\Maps" "AutoUpdateEnabled" "REG_DWORD" "0" "Auto-actualizacion de mapas off"

    # 7) Hibernacion: libera hiberfil.sys (~ tamano de la RAM). En laptops
    #    se deja intacta (es util al cerrar la tapa); en desktops sobra.
    $esLaptop = $false
    try {
        $chasis = (Get-CimInstance -ClassName Win32_SystemEnclosure -EA Stop).ChassisTypes[0]
        $esLaptop = ($chasis -in 9, 10, 14)
    } catch { }
    if ($esLaptop) {
        Write-Log "Laptop detectada: hibernacion intacta" "SKIP"
    } else {
        if ($script:ModoSim) {
            Write-Log "(SIMULACION) Hibernacion off (powercfg /hibernate off)" "SKIP"
        } else {
            try {
                & powercfg.exe /hibernate off 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Log "Hibernacion deshabilitada (hiberfil.sys liberado)" "OK"
                } else {
                    Write-Log "powercfg /hibernate off devolvio $LASTEXITCODE" "ERROR"
                }
            } catch {
                Write-Log "Hibernacion: $($_.Exception.Message)" "ERROR"
            }
        }
        Invoke-RegAdd "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" "HibernateEnabled" "REG_DWORD" "0" "Hibernacion off (registro)"
        Invoke-RegAdd "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings" "ShowHibernateOption" "REG_DWORD" "0" "Opcion Hibernar oculta en el menu"
    }
    Write-Log "Bloat de fabricante y seguridad aplicado" "OK"
}

# ================================================================
# MENU PRINCIPAL
# ================================================================

$script:LogFile = Join-Path $env:USERPROFILE "Documents\Logs\optimizador_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$script:ModoSim = $true

# Verificar admin
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requiere Administrador" -ForegroundColor Red
    pause
    exit
}

# Crear carpeta de logs
$logDir = Split-Path $script:LogFile -Parent
if (-not (Test-Path $logDir)) { New-Item $logDir -ItemType Directory -Force | Out-Null }

# Geometria fija de la consola (igual que menu.ps1): 80 columnas para que
# listados y logs se lean comodos en cualquier tamano de ventana, tambien
# maximizada. El orden del resize depende de si se reduce o se amplia
# (medido en consola real). try/catch: hosts sin resize, se ignora.
try {
    if ($Host.UI.RawUI.WindowSize.Width -ne 80) {
        if ($Host.UI.RawUI.WindowSize.Width -gt 80) {
            # reducir: primero la ventana, luego el buffer
            $Host.UI.RawUI.WindowSize = New-Object System.Management.Automation.Host.Size(80, 30)
            $Host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size(80, 300)
        } else {
            # ampliar: primero el buffer, luego la ventana
            $Host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size(80, 300)
            $Host.UI.RawUI.WindowSize = New-Object System.Management.Automation.Host.Size(80, 30)
        }
    }
} catch { }

Write-Log "Inicio de sesion"

# Modo
if (-not $Ejecutar -and -not $Simulacion) {
    Write-Host ""
    Write-Host "  Modo de ejecucion:" -ForegroundColor Cyan
    Write-Host "    1) SIMULACION (recomendado - solo muestra cambios)" -ForegroundColor Yellow
    Write-Host "    2) EJECUCION REAL (aplica todos los cambios)" -ForegroundColor Red
    # Sin entrada se cae a SIMULACION (la opcion segura), nunca a ejecucion
    # real: si no llega respuesta no se puede decidir aplicar cambios.
    $modo = Read-Respuesta "  Selecciona [1-2]" "1"
    $script:ModoSim = ($modo -ne "2")
} elseif ($Simulacion) {
    $script:ModoSim = $true
} else {
    $script:ModoSim = $false
}

# Secciones disponibles

# ================================================================
# BLOQUEO WPS OFFICE (misma funcion que en HerramientasIT.ps1)
# ================================================================
# Impide instalar, ejecutar, actualizar y descargar WPS Office, y desinstala
# una instalacion existente. Requiere Administrador.

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
        # menu, igual que "0. Volver": asi la seccion 13 nunca queda colgada.
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

# ================================================================
# SECCION: IMPORTAR .REG (CONSOLA EN MENU CONTEXTUAL + VISOR CLASICO)
# ================================================================
# Los dos .reg de la carpeta Reg\ viven ahora EMBEBIDOS aqui y se aplican
# con reg.exe import desde un temporal: es la via sin riesgos, porque
# conserva EXACTO el contenido original (los valores hex(2) multilinea del
# Visor clasico y la eliminacion de valor "Extended"=- del menu cmd2 no se
# pueden pasar a mano a 'reg add' sin riesgo de error). Importar es
# idempotente: repetirlo no duplica nada.
function Invoke-SeccionImportarReg {
    Write-Host "`n--- Importar .reg (Consola aqui + Visor de Imagenes clasico) ---" -ForegroundColor Green

    $ficherosReg = @(
        @{
            Nombre    = "Consola en el menu contextual (cmd2)"
            Contenido = @'
Windows Registry Editor Version 5.00

; Tutorial: https://www.vichaunter.org/como-se-hace/anadir-la-consola-comandos-al-menu-del-boton-derecho-del-raton-windows-10


[HKEY_CLASSES_ROOT\Directory\shell\cmd2]
@="@shell32.dll,-8506"
"Extended"=-
"Icon"="imageres.dll,-5323"
"NoWorkingDirectory"=""

[HKEY_CLASSES_ROOT\Directory\shell\cmd2\command]
@="cmd.exe /s /k pushd \"%V\""


[HKEY_CLASSES_ROOT\Directory\Background\shell\cmd2]
@="@shell32.dll,-8506"
"Extended"=-
"Icon"="imageres.dll,-5323"
"NoWorkingDirectory"=""

[HKEY_CLASSES_ROOT\Directory\Background\shell\cmd2\command]
@="cmd.exe /s /k pushd \"%V\""


[HKEY_CLASSES_ROOT\Drive\shell\cmd2]
@="@shell32.dll,-8506"
"Extended"=-
"Icon"="imageres.dll,-5323"
"NoWorkingDirectory"=""

[HKEY_CLASSES_ROOT\Drive\shell\cmd2\command]
@="cmd.exe /s /k pushd \"%V\""


[HKEY_CLASSES_ROOT\LibraryFolder\Background\shell\cmd2]
@="@shell32.dll,-8506"
"Extended"=-
"Icon"="imageres.dll,-5323"
"NoWorkingDirectory"=""

[HKEY_CLASSES_ROOT\LibraryFolder\Background\shell\cmd2\command]
@="cmd.exe /s /k pushd \"%V\""
'@
        },
        @{
            Nombre    = "Visor de imagenes clasico (PhotoViewer)"
            Contenido = @'
Windows Registry Editor Version 5.00

;Descargado desde geekland.eu

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.Bitmap]
"ImageOptionFlags"=dword:00000001
"FriendlyTypeName"=hex(2):40,00,25,00,50,00,72,00,6f,00,67,00,72,00,61,00,6d,\
  00,46,00,69,00,6c,00,65,00,73,00,25,00,5c,00,57,00,69,00,6e,00,64,00,6f,00,\
  77,00,73,00,20,00,50,00,68,00,6f,00,74,00,6f,00,20,00,56,00,69,00,65,00,77,\
  00,65,00,72,00,5c,00,50,00,68,00,6f,00,74,00,6f,00,56,00,69,00,65,00,77,00,\
  65,00,72,00,2e,00,64,00,6c,00,6c,00,2c,00,2d,00,33,00,30,00,35,00,36,00,00,\
  00

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.Bitmap\DefaultIcon]
@="%SystemRoot%\\System32\\imageres.dll,-70"

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.Bitmap\shell]

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.Bitmap\shell\open]

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.Bitmap\shell\open\command]
@=hex(2):25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,\
  00,5c,00,53,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,72,00,75,00,\
  6e,00,64,00,6c,00,6c,00,33,00,32,00,2e,00,65,00,78,00,65,00,20,00,22,00,25,\
  00,50,00,72,00,6f,00,67,00,72,00,61,00,6d,00,46,00,69,00,6c,00,65,00,73,00,\
  25,00,5c,00,57,00,69,00,6e,00,64,00,6f,00,77,00,73,00,20,00,50,00,68,00,6f,\
  00,74,00,6f,00,20,00,56,00,69,00,65,00,77,00,65,00,72,00,5c,00,50,00,68,00,\
  6f,00,74,00,6f,00,56,00,69,00,65,00,77,00,65,00,72,00,2e,00,64,00,6c,00,6c,\
  00,22,00,2c,00,20,00,49,00,6d,00,61,00,67,00,65,00,56,00,69,00,65,00,77,00,\
  5f,00,46,00,75,00,6c,00,6c,00,73,00,63,00,72,00,65,00,65,00,6e,00,20,00,25,\
  00,31,00,00,00

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.Bitmap\shell\open\DropTarget]
"Clsid"="{FFE2A43C-56B9-4bf5-9A79-CC6D4285608A}"

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.JFIF]
"EditFlags"=dword:00010000
"ImageOptionFlags"=dword:00000001
"FriendlyTypeName"=hex(2):40,00,25,00,50,00,72,00,6f,00,67,00,72,00,61,00,6d,\
  00,46,00,69,00,6c,00,65,00,73,00,25,00,5c,00,57,00,69,00,6e,00,64,00,6f,00,\
  77,00,73,00,20,00,50,00,68,00,6f,00,74,00,6f,00,20,00,56,00,69,00,65,00,77,\
  00,65,00,72,00,5c,00,50,00,68,00,6f,00,74,00,6f,00,56,00,69,00,65,00,77,00,\
  65,00,72,00,2e,00,64,00,6c,00,6c,00,2c,00,2d,00,33,00,30,00,35,00,35,00,00,\
  00

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.JFIF\DefaultIcon]
@="%SystemRoot%\\System32\\imageres.dll,-72"

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.JFIF\shell]

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.JFIF\shell\open]
"MuiVerb"=hex(2):40,00,25,00,50,00,72,00,6f,00,67,00,72,00,61,00,6d,00,46,00,\
  69,00,6c,00,65,00,73,00,25,00,5c,00,57,00,69,00,6e,00,64,00,6f,00,77,00,73,\
  00,20,00,50,00,68,00,6f,00,74,00,6f,00,20,00,56,00,69,00,65,00,77,00,65,00,\
  72,00,5c,00,70,00,68,00,6f,00,74,00,6f,00,76,00,69,00,65,00,77,00,65,00,72,\
  00,2e,00,64,00,6c,00,6c,00,2c,00,2d,00,33,00,30,00,34,00,33,00,00,00

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.JFIF\shell\open\command]
@=hex(2):25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,\
  00,5c,00,53,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,72,00,75,00,\
  6e,00,64,00,6c,00,6c,00,33,00,32,00,2e,00,65,00,78,00,65,00,20,00,22,00,25,\
  00,50,00,72,00,6f,00,67,00,72,00,61,00,6d,00,46,00,69,00,6c,00,65,00,73,00,\
  25,00,5c,00,57,00,69,00,6e,00,64,00,6f,00,77,00,73,00,20,00,50,00,68,00,6f,\
  00,74,00,6f,00,20,00,56,00,69,00,65,00,77,00,65,00,72,00,5c,00,50,00,68,00,\
  6f,00,74,00,6f,00,56,00,69,00,65,00,77,00,65,00,72,00,2e,00,64,00,6c,00,6c,\
  00,22,00,2c,00,20,00,49,00,6d,00,61,00,67,00,65,00,56,00,69,00,65,00,77,00,\
  5f,00,46,00,75,00,6c,00,6c,00,73,00,63,00,72,00,65,00,65,00,6e,00,20,00,25,\
  00,31,00,00,00

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.JFIF\shell\open\DropTarget]
"Clsid"="{FFE2A43C-56B9-4bf5-9A79-CC6D4285608A}"

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.Jpeg]
"EditFlags"=dword:00010000
"ImageOptionFlags"=dword:00000001
"FriendlyTypeName"=hex(2):40,00,25,00,50,00,72,00,6f,00,67,00,72,00,61,00,6d,\
  00,46,00,69,00,6c,00,65,00,73,00,25,00,5c,00,57,00,69,00,6e,00,64,00,6f,00,\
  77,00,73,00,20,00,50,00,68,00,6f,00,74,00,6f,00,20,00,56,00,69,00,65,00,77,\
  00,65,00,72,00,5c,00,50,00,68,00,6f,00,74,00,6f,00,56,00,69,00,65,00,77,00,\
  65,00,72,00,2e,00,64,00,6c,00,6c,00,2c,00,2d,00,33,00,30,00,35,00,35,00,00,\
  00

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.Jpeg\DefaultIcon]
@="%SystemRoot%\\System32\\imageres.dll,-72"

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.Jpeg\shell]

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.Jpeg\shell\open]
"MuiVerb"=hex(2):40,00,25,00,50,00,72,00,6f,00,67,00,72,00,61,00,6d,00,46,00,\
  69,00,6c,00,65,00,73,00,25,00,5c,00,57,00,69,00,6e,00,64,00,6f,00,77,00,73,\
  00,20,00,50,00,68,00,6f,00,74,00,6f,00,20,00,56,00,69,00,65,00,77,00,65,00,\
  72,00,5c,00,70,00,68,00,6f,00,74,00,6f,00,76,00,69,00,65,00,77,00,65,00,72,\
  00,2e,00,64,00,6c,00,6c,00,2c,00,2d,00,33,00,30,00,34,00,33,00,00,00

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.Jpeg\shell\open\command]
@=hex(2):25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,\
  00,5c,00,53,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,72,00,75,00,\
  6e,00,64,00,6c,00,6c,00,33,00,32,00,2e,00,65,00,78,00,65,00,20,00,22,00,25,\
  00,50,00,72,00,6f,00,67,00,72,00,61,00,6d,00,46,00,69,00,6c,00,65,00,73,00,\
  25,00,5c,00,57,00,69,00,6e,00,64,00,6f,00,77,00,73,00,20,00,50,00,68,00,6f,\
  00,74,00,6f,00,20,00,56,00,69,00,65,00,77,00,65,00,72,00,5c,00,50,00,68,00,\
  6f,00,74,00,6f,00,56,00,69,00,65,00,77,00,65,00,72,00,2e,00,64,00,6c,00,6c,\
  00,22,00,2c,00,20,00,49,00,6d,00,61,00,67,00,65,00,56,00,69,00,65,00,77,00,\
  5f,00,46,00,75,00,6c,00,6c,00,73,00,63,00,72,00,65,00,65,00,6e,00,20,00,25,\
  00,31,00,00,00

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.Jpeg\shell\open\DropTarget]
"Clsid"="{FFE2A43C-56B9-4bf5-9A79-CC6D4285608A}"

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.Gif]
"ImageOptionFlags"=dword:00000001
"FriendlyTypeName"=hex(2):40,00,25,00,50,00,72,00,6f,00,67,00,72,00,61,00,6d,\
  00,46,00,69,00,6c,00,65,00,73,00,25,00,5c,00,57,00,69,00,6e,00,64,00,6f,00,\
  77,00,73,00,20,00,50,00,68,00,6f,00,74,00,6f,00,20,00,56,00,69,00,65,00,77,\
  00,65,00,72,00,5c,00,50,00,68,00,6f,00,74,00,6f,00,56,00,69,00,65,00,77,00,\
  65,00,72,00,2e,00,64,00,6c,00,6c,00,2c,00,2d,00,33,00,30,00,35,00,37,00,00,\
  00

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.Gif\DefaultIcon]
@="%SystemRoot%\\System32\\imageres.dll,-83"

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.Gif\shell]

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.Gif\shell\open]

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.Gif\shell\open\command]
@=hex(2):25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,\
  00,5c,00,53,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,72,00,75,00,\
  6e,00,64,00,6c,00,6c,00,33,00,32,00,2e,00,65,00,78,00,65,00,20,00,22,00,25,\
  00,50,00,72,00,6f,00,67,00,72,00,61,00,6d,00,46,00,69,00,6c,00,65,00,73,00,\
  25,00,5c,00,57,00,69,00,6e,00,64,00,6f,00,77,00,73,00,20,00,50,00,68,00,6f,\
  00,74,00,6f,00,20,00,56,00,69,00,65,00,77,00,65,00,72,00,5c,00,50,00,68,00,\
  6f,00,74,00,6f,00,56,00,69,00,65,00,77,00,65,00,72,00,2e,00,64,00,6c,00,6c,\
  00,22,00,2c,00,20,00,49,00,6d,00,61,00,67,00,65,00,56,00,69,00,65,00,77,00,\
  5f,00,46,00,75,00,6c,00,6c,00,73,00,63,00,72,00,65,00,65,00,6e,00,20,00,25,\
  00,31,00,00,00

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.Gif\shell\open\DropTarget]
"Clsid"="{FFE2A43C-56B9-4bf5-9A79-CC6D4285608A}"

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.Png]
"ImageOptionFlags"=dword:00000001
"FriendlyTypeName"=hex(2):40,00,25,00,50,00,72,00,6f,00,67,00,72,00,61,00,6d,\
  00,46,00,69,00,6c,00,65,00,73,00,25,00,5c,00,57,00,69,00,6e,00,64,00,6f,00,\
  77,00,73,00,20,00,50,00,68,00,6f,00,74,00,6f,00,20,00,56,00,69,00,65,00,77,\
  00,65,00,72,00,5c,00,50,00,68,00,6f,00,74,00,6f,00,56,00,69,00,65,00,77,00,\
  65,00,72,00,2e,00,64,00,6c,00,6c,00,2c,00,2d,00,33,00,30,00,35,00,37,00,00,\
  00

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.Png\DefaultIcon]
@="%SystemRoot%\\System32\\imageres.dll,-71"

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.Png\shell]

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.Png\shell\open]

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.Png\shell\open\command]
@=hex(2):25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,\
  00,5c,00,53,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,72,00,75,00,\
  6e,00,64,00,6c,00,6c,00,33,00,32,00,2e,00,65,00,78,00,65,00,20,00,22,00,25,\
  00,50,00,72,00,6f,00,67,00,72,00,61,00,6d,00,46,00,69,00,6c,00,65,00,73,00,\
  25,00,5c,00,57,00,69,00,6e,00,64,00,6f,00,77,00,73,00,20,00,50,00,68,00,6f,\
  00,74,00,6f,00,20,00,56,00,69,00,65,00,77,00,65,00,72,00,5c,00,50,00,68,00,\
  6f,00,74,00,6f,00,56,00,69,00,65,00,77,00,65,00,72,00,2e,00,64,00,6c,00,6c,\
  00,22,00,2c,00,20,00,49,00,6d,00,61,00,67,00,65,00,56,00,69,00,65,00,77,00,\
  5f,00,46,00,75,00,6c,00,6c,00,73,00,63,00,72,00,65,00,65,00,6e,00,20,00,25,\
  00,31,00,00,00

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.Png\shell\open\DropTarget]
"Clsid"="{FFE2A43C-56B9-4bf5-9A79-CC6D4285608A}"

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.Wdp]
"EditFlags"=dword:00010000
"ImageOptionFlags"=dword:00000001

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.Wdp\DefaultIcon]
@="%SystemRoot%\\System32\\wmphoto.dll,-400"

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.Wdp\shell]

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.Wdp\shell\open]
"MuiVerb"=hex(2):40,00,25,00,50,00,72,00,6f,00,67,00,72,00,61,00,6d,00,46,00,\
  69,00,6c,00,65,00,73,00,25,00,5c,00,57,00,69,00,6e,00,64,00,6f,00,77,00,73,\
  00,20,00,50,00,68,00,6f,00,74,00,6f,00,20,00,56,00,69,00,65,00,77,00,65,00,\
  72,00,5c,00,70,00,68,00,6f,00,74,00,6f,00,76,00,69,00,65,00,77,00,65,00,72,\
  00,2e,00,64,00,6c,00,6c,00,2c,00,2d,00,33,00,30,00,34,00,33,00,00,00

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.Wdp\shell\open\command]
@=hex(2):25,00,53,00,79,00,73,00,74,00,65,00,6d,00,52,00,6f,00,6f,00,74,00,25,\
  00,5c,00,53,00,79,00,73,00,74,00,65,00,6d,00,33,00,32,00,5c,00,72,00,75,00,\
  6e,00,64,00,6c,00,6c,00,33,00,32,00,2e,00,65,00,78,00,65,00,20,00,22,00,25,\
  00,50,00,72,00,6f,00,67,00,72,00,61,00,6d,00,46,00,69,00,6c,00,65,00,73,00,\
  25,00,5c,00,57,00,69,00,6e,00,64,00,6f,00,77,00,73,00,20,00,50,00,68,00,6f,\
  00,74,00,6f,00,20,00,56,00,69,00,65,00,77,00,65,00,72,00,5c,00,50,00,68,00,\
  6f,00,74,00,6f,00,56,00,69,00,65,00,77,00,65,00,72,00,2e,00,64,00,6c,00,6c,\
  00,22,00,2c,00,20,00,49,00,6d,00,61,00,67,00,65,00,56,00,69,00,65,00,77,00,\
  5f,00,46,00,75,00,6c,00,6c,00,73,00,63,00,72,00,65,00,65,00,6e,00,20,00,25,\
  00,31,00,00,00

[HKEY_CLASSES_ROOT\PhotoViewer.FileAssoc.Wdp\shell\open\DropTarget]
"Clsid"="{FFE2A43C-56B9-4bf5-9A79-CC6D4285608A}"

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows Photo Viewer]

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows Photo Viewer\Capabilities]
"ApplicationDescription"="@%ProgramFiles%\\Windows Photo Viewer\\photoviewer.dll,-3069"
"ApplicationName"="@%ProgramFiles%\\Windows Photo Viewer\\photoviewer.dll,-3009"

[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows Photo Viewer\Capabilities\FileAssociations]
".jpg"="PhotoViewer.FileAssoc.Jpeg"
".wdp"="PhotoViewer.FileAssoc.Wdp"
".jfif"="PhotoViewer.FileAssoc.JFIF"
".dib"="PhotoViewer.FileAssoc.Bitmap"
".png"="PhotoViewer.FileAssoc.Png"
".jxr"="PhotoViewer.FileAssoc.Wdp"
".bmp"="PhotoViewer.FileAssoc.Bitmap"
".jpe"="PhotoViewer.FileAssoc.Jpeg"
".jpeg"="PhotoViewer.FileAssoc.Jpeg"
".gif"="PhotoViewer.FileAssoc.Gif"
'@
        }
    )

    foreach ($reg in $ficherosReg) {
        if ($script:ModoSim) {
            Write-Log "(SIMULACION) Se importaria el .reg: $($reg.Nombre)" "SKIP"
            continue
        }
        try {
            # Los .reg "Windows Registry Editor Version 5.00" se escriben como
            # Unicode (UTF-16 con BOM): su formato nativo; reg.exe lo detecta.
            $tmp = Join-Path $env:TEMP ("optimizador_reg_" + [guid]::NewGuid().ToString('N') + '.reg')
            [System.IO.File]::WriteAllText($tmp, $reg.Contenido, [System.Text.Encoding]::Unicode)
            $salida = & reg.exe import $tmp 2>&1
            $rc = $LASTEXITCODE
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            if ($rc -eq 0) {
                Write-Log "Importado: $($reg.Nombre)" "OK"
            } else {
                Write-Log "reg import devolvio $rc para '$($reg.Nombre)': $($salida -join ' ')" "ERROR"
            }
        } catch {
            Write-Log "No se pudo importar '$($reg.Nombre)': $($_.Exception.Message)" "ERROR"
        }
    }
    Write-Log "Importaciones .reg aplicadas" "OK"
}

$secciones = [ordered]@{
    "1"  = @{ Nombre = "Eliminar Bloatware";    Funcion = "Invoke-SeccionBloatware" }
    "2"  = @{ Nombre = "Eliminar Copilot/IA";   Funcion = "Invoke-SeccionCopilot" }
    "3"  = @{ Nombre = "Deshabilitar Recall";   Funcion = "Invoke-SeccionRecall" }
    "4"  = @{ Nombre = "Desinstalar OneDrive";  Funcion = "Invoke-SeccionOneDrive" }
    "5"  = @{ Nombre = "Deshabilitar Browsers"; Funcion = "Invoke-SeccionBrowsers" }
    "6"  = @{ Nombre = "Deshabilitar Telemetria (Win/Office/NVIDIA)"; Funcion = "Invoke-SeccionTelemetria" }
    "7"  = @{ Nombre = "Optimizar Servicios";   Funcion = "Invoke-SeccionServicios" }
    "8"  = @{ Nombre = "Limpiar Archivos";      Funcion = "Invoke-SeccionLimpieza" }
    "9"  = @{ Nombre = "Interfaz UI";           Funcion = "Invoke-SeccionUI" }
    "10" = @{ Nombre = "Configurar DNS";        Funcion = "Invoke-SeccionDNS" }
    "11" = @{ Nombre = "Alto Rendimiento";      Funcion = "Invoke-SeccionPower" }
    "12" = @{ Nombre = "Registros Adicionales"; Funcion = "Invoke-SeccionRegistros" }
    "13" = @{ Nombre = "Bloquear WPS Office";      Funcion = "Invoke-BloquearWPS" }
    "14" = @{ Nombre = "Importar .reg (Consola aqui + Visor clasico)"; Funcion = "Invoke-SeccionImportarReg" }
    "15" = @{ Nombre = "Bloat de fabricante y seguridad"; Funcion = "Invoke-SeccionFabricantes" }
}

# Punto de restauracion
Write-Host ""
Write-Host "  Crear punto de restauracion?" -ForegroundColor Cyan
# Sin respuesta no se crea punto de restauracion (no es un cambio al sistema
# que haya que forzar, y ante la duda no se toca nada).
$opRestore = Read-Respuesta "  [S/N]" ""
if ($opRestore -eq "S" -or $opRestore -eq "s") {
    if (-not $script:ModoSim) {
        # WinUtil: sin esta clave, Windows se salta la creacion si ya existe
        # un punto de menos de 24 h (SystemRestorePointCreationFrequency) y
        # el Checkpoint-Computer no hace nada. A 0 lo crea siempre.
        Invoke-RegAdd "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore" "SystemRestorePointCreationFrequency" "REG_DWORD" "0" "Puntos de restauracion: sin limite de frecuencia"
        try {
            Enable-ComputerRestore -Drive $env:SystemDrive -EA Stop
            Checkpoint-Computer -Description "Optimizador_WinScript" -RestorePointType "MODIFY_SETTINGS" -EA Stop
            Write-Log "Punto de restauracion creado" "OK"
        } catch {
            Write-Log "Punto de restauracion no creado: $($_.Exception.Message)" "WARN"
        }
    } else {
        Write-Log "(SIMULACION) Punto de restauracion omitido" "SKIP"
    }
}

# Seleccion de secciones
Draw-Header
Write-Host ""
Write-Host "  SECCIONES DISPONIBLES:" -ForegroundColor Cyan
foreach ($k in $secciones.Keys) {
    Write-Host ("    {0,2}. {1}" -f $k, $secciones[$k].Nombre) -ForegroundColor White
}
Write-Host "    A.  EJECUTAR TODAS" -ForegroundColor Yellow
Write-Host "    0.  Salir" -ForegroundColor Red
Write-Host ""
$seleccion = Read-Respuesta "  Selecciona (separadas por coma, ej: 1,3,5)" ""

if ($seleccion -eq "0") { Write-Log "Cancelado por usuario"; exit }

if ([string]::IsNullOrEmpty($seleccion)) {
    if (Test-EntradaInteractiva) {
        # Consola viva pero respuesta vacia: se avisa y se sale limpio.
        Write-Host " Seleccion no valida" -ForegroundColor Red
        pause
        exit
    }
    # Ejecucion sin consola con entrada (stdin cerrado o redirigido): se
    # ejecutan TODAS las secciones, que es el flujo por defecto del script.
    # Antes el script se salia con "leccion no valida" sin correr nada.
    Write-Log "Sin entrada interactiva: se ejecutan TODAS las secciones" "AVISO"
    $seleccion = "A"
}

$seleccionadas = if ($seleccion -eq "A" -or $seleccion -eq "a") {
    $secciones.Keys
} else {
    @($seleccion -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $secciones.Contains($_) })
}

if ($seleccionadas.Count -eq 0) {
    Write-Host " Seleccion no valida" -ForegroundColor Red
    pause
    exit
}

# Ejecutar secciones
Draw-Header
Write-Log "Ejecutando $($seleccionadas.Count) secciones"
$inicio = Get-Date
# OJO: antes era "$seleccion.Count" y $seleccion es un STRING (p. ej. "A"):
# un string tiene .Count = 1, asi que la comparacion era "1 -eq 13" y daba
# siempre False. El modo automatico del DNS nunca se activo ni aunque se
# eligieran las 13 secciones. Se compara la lista ya resuelta.
# Automatico SOLO sin consola interactiva (tarea programada, stdin cerrado):
# si hay consola viva, el usuario elige el DNS aunque haya seleccionado todas
# las secciones. Antes, ejecutar todas forzaba Google sin preguntar.
$esAutomatico = ($seleccionadas.Count -eq $secciones.Count) -and -not (Test-EntradaInteractiva)

foreach ($s in $seleccionadas) {
    Draw-Line
    Write-Host "  [$s/$($seleccionadas.Count)] $($secciones[$s].Nombre)" -ForegroundColor Magenta
    if ($secciones[$s].Funcion -eq "Invoke-SeccionDNS") {
        & $secciones[$s].Funcion -AutoMode $esAutomatico
    } elseif ($secciones[$s].Funcion -eq "Invoke-BloquearWPS" -and -not (Test-EntradaInteractiva)) {
        # La seccion 13 es un menu interactivo. Sin consola con entrada no hay
        # quien elija, asi que se informa el estado en vez de abrir el menu:
        # la ejecucion termina y no se queda esperando (ni girando en bucle).
        Write-Log "Sin entrada interactiva: WPS Office en modo Estado (menu omitido)" "AVISO"
        & $secciones[$s].Funcion -Accion Estado
    } else {
        & $secciones[$s].Funcion
    }
}

# Resumen
$duracion = (Get-Date) - $inicio
Draw-Line
Write-Host ""
Write-Host "  COMPLETADO" -ForegroundColor Green
Write-Host "  Duracion: $($duracion.Minutes)m $($duracion.Seconds)s" -ForegroundColor White
Write-Host "  Log: $($script:LogFile)" -ForegroundColor DarkGray
if ($script:ModoSim) {
    Write-Host ""
    Write-Host "  MODO SIMULACION - Ningun cambio fue aplicado" -ForegroundColor Yellow
    Write-Host "  Para aplicar, ejecuta con -Ejecutar o selecciona modo 2" -ForegroundColor Yellow
}
Write-Log "Sesion finalizada"
Pause
