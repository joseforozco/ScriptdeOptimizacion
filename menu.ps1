# ============================================================================
# menu.ps1 - "Kit de Herramientas - José Orozco" (entrada unica)
# ============================================================================
# Dos formas de arrancarlo:
#   1) Local  :  .\menu.ps1  o .\start.ps1  (carpeta clonada o descargada)
#   2) Remoto :  irm https://raw.githubusercontent.com/joseforozco/ScriptdeOptimizacion/main/start.ps1 | iex
#      (start.ps1, ASCII sin BOM, es la entrada del one-liner: baja los
#      scripts y lanza este menu. Este menu tambien sabe bajarlos por si
#      alguien lo sirve a el directamente.)
#
# - El menu vive en ESTA consola: cada herramienta se abre en su propia
#   ventana y, al cerrarla, se vuelve aqui automaticamente.
# - Corre igual en Windows PowerShell 5.1 y en PowerShell 7. Lanza siempre
#   powershell.exe (existe en todo Win10/11): las herramientas que exigen
#   PS7 (Optimizador, HerramientasIT) se lo traen solas con su arranque.
# - Entrada protegida: sin consola interactiva se sale en limpio.
# - Geometria: fija la consola en 80x30 para que el centrado quede comodo
#   en cualquier tamano de ventana.
# ============================================================================

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# --- Geometria fija de la consola ---------------------------------------------
# El menu es "la aplicacion": fija 80x30 para verse comodo tanto en una
# ventana maximizada (donde centrar a lo ancho deja margenes enormes) como
# en una consola pequena (donde las cajas no cabrian). Si el host no deja
# redimensionar (editores, redirecciones), se ignora y el centrado dinamico
# se adapta al ancho que haya.
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

# --- Configuracion -----------------------------------------------------------
$script:Titulo       = 'Kit de Herramientas - José Orozco'
$script:Subtitulo    = 'Puesta a punto y soporte para Windows 10 y 11'
$script:UrlBase      = 'https://raw.githubusercontent.com/joseforozco/ScriptdeOptimizacion/main/'
$script:Herramientas = @('HerramientasIT.ps1', 'optimizador.ps1', 'AsignaH.ps1')

# --- Ayudas de dibujo (centrado dinamico) ------------------------------------
function Get-AnchoConsola {
    # Ancho real de la ventana; 80 si el host no lo permite consultar.
    try {
        $w = $Host.UI.RawUI.WindowSize.Width
        if ($w -gt 0) { return [int]$w }
    } catch { }
    return 80
}

function Write-Centrado {
    # Escribe una linea centrada. $AnchoBloque permite centrar varias lineas
    # de distinta longitud como si fueran una sola columna (bloque parejo).
    param([string]$Texto = '', [string]$Color = 'White', [int]$AnchoBloque = 0)
    $longitud = [math]::Max($Texto.Length, $AnchoBloque)
    $margen = [int][math]::Floor((Get-AnchoConsola - $longitud) / 2)
    if ($margen -lt 0) { $margen = 0 }
    Write-Host ((' ' * $margen) + $Texto) -ForegroundColor $Color
}

function Show-Titulo {
    # Caja Unicode del tamano exacto del titulo: ╔═╗ ║ ╚═╝
    param([string]$Texto)
    $anchoCaja = $Texto.Length + 10
    $relleno   = $anchoCaja - 2 - $Texto.Length
    $izq       = [int][math]::Floor($relleno / 2)
    $der       = $relleno - $izq
    Write-Centrado ('╔' + ('═' * ($anchoCaja - 2)) + '╗') 'Cyan'
    Write-Centrado ('║' + (' ' * $izq) + $Texto + (' ' * $der) + '║') 'Yellow'
    Write-Centrado ('╚' + ('═' * ($anchoCaja - 2)) + '╝') 'Cyan'
}

function Read-HostCentrado {
    # Pregunta centrada como el resto del menu. Sin consola interactiva
    # devuelve "" (el llamador decide que hacer con ello).
    param([string]$Texto)
    $margen = [int][math]::Floor((Get-AnchoConsola - $Texto.Length - 1) / 2)
    try { return [string](Read-Host ((' ' * $margen) + $Texto)) } catch { return '' }
}

# --- Localizacion de los scripts (local o descarga remota) -------------------
function Get-RaizHerramientas {
    # Modo local: menu.ps1 esta en disco (carpeta clonada o copiada a mano).
    if ($PSScriptRoot) { return $PSScriptRoot }

    # Modo remoto (irm | iex): no hay carpeta local; se bajan los 3 scripts
    # desde GitHub a un temporal. Si la descarga falla y estan en el
    # directorio actual, se usa ese como plan B.
    $destino = Join-Path ([System.IO.Path]::GetTempPath()) 'KitHerramientas'
    New-Item -ItemType Directory -Path $destino -Force | Out-Null
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
    Write-Host ''
    Write-Centrado 'Primera ejecucion remota: descargando herramientas...' 'Cyan'
    $prev = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
    $todoOk = $true
    foreach ($h in $script:Herramientas) {
        try {
            Invoke-WebRequest -Uri ($script:UrlBase + $h) -OutFile (Join-Path $destino $h) -UseBasicParsing -ErrorAction Stop
            Write-Centrado "[OK]    $h" 'Green'
        } catch {
            Write-Centrado "[FALLO] $h" 'Red'
            $todoOk = $false
        }
    }
    $ProgressPreference = $prev
    if ($todoOk) {
        Write-Centrado "Herramientas listas en: $destino" 'DarkGray'
        return $destino
    }
    $aqui = (Get-Location).Path
    $todasAqui = $true
    foreach ($h in $script:Herramientas) {
        if (-not (Test-Path -LiteralPath (Join-Path $aqui $h))) { $todasAqui = $false }
    }
    if ($todasAqui) {
        Write-Centrado 'Descarga incompleta: se usan los scripts del directorio actual.' 'Yellow'
        return $aqui
    }
    throw 'No se pudieron descargar las herramientas y no estan en el directorio actual. Descargue el repositorio completo (ZIP o git clone) y ejecute menu.ps1 desde esa carpeta.'
}

# --- Lanzamiento de herramientas ---------------------------------------------
function Start-Herramienta {
    # Abre la herramienta en su propia ventana y espera a que se cierre.
    param([string]$Fichero, [string]$Titulo)
    $ruta = Join-Path $script:Raiz $Fichero
    if (-not (Test-Path -LiteralPath $ruta)) {
        Write-Host ''
        Write-Centrado "ERROR: no se encuentra $Fichero en la carpeta del menu." 'Red'
        return
    }
    Write-Host ''
    Write-Centrado "Abriendo '$Titulo' en su propia ventana..." 'Cyan'
    Write-Centrado '(cierrela para volver al menu)' 'DarkGray'
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $proc = Start-Process -FilePath $exe -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ruta`""
    ) -PassThru
    $proc.WaitForExit()
}

# --- Menu principal ------------------------------------------------------------
function Show-MenuPrincipal {
    $entradas = @(
        @{ Tecla = '1'; Nombre = 'Herramientas IT';     Desc = 'Suite de 11 utilidades de soporte' }
        @{ Tecla = '2'; Nombre = 'Optimizador Windows'; Desc = 'Debloat y optimizacion (15 secciones)' }
        @{ Tecla = '3'; Nombre = 'Asignar letra H:';    Desc = 'Fija el SSD externo en la unidad H:' }
        @{ Tecla = '0'; Nombre = 'Salir';              Desc = 'Vuelve a la consola' }
    )
    $anchoNombre = ($entradas.Nombre | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
    $anchoLinea  = ($entradas | ForEach-Object { 5 + $anchoNombre + 2 + $_.Desc.Length } | Measure-Object -Maximum).Maximum
    $separador   = '─' * $anchoLinea
    $motor       = "PowerShell $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)"
    $modo        = if ($PSScriptRoot) { 'carpeta local' } else { 'remoto (descarga temporal)' }

    $opcion = ''
    do {
        try { Clear-Host } catch { }
        Write-Host ''
        Show-Titulo -Texto $script:Titulo
        Write-Host ''
        Write-Centrado $script:Subtitulo 'DarkGray'
        Write-Host ''
        Write-Centrado $separador 'DarkCyan'
        Write-Host ''
        foreach ($e in $entradas) {
            $tecla = " $($e.Tecla))"
            $nom   = '  ' + $e.Nombre.PadRight($anchoNombre)
            $des   = '  ' + $e.Desc
            $margen = [int][math]::Floor((Get-AnchoConsola - ($tecla.Length + $nom.Length + $des.Length)) / 2)
            if ($margen -lt 0) { $margen = 0 }
            Write-Host ((' ' * $margen) + $tecla) -ForegroundColor Yellow -NoNewline
            Write-Host $nom -ForegroundColor White -NoNewline
            Write-Host $des -ForegroundColor DarkGray
        }
        Write-Host ''
        Write-Centrado 'Cada herramienta se abre en su propia ventana; cierrala para volver aqui.' 'DarkGray'
        Write-Host ''
        Write-Centrado $separador 'DarkCyan'
        Write-Host ''
        Write-Centrado "Motor: $motor   |   Modo: $modo" 'Gray'
        $raizCorta = if ($script:Raiz.Length -gt $anchoLinea) {
            '...' + $script:Raiz.Substring($script:Raiz.Length - ($anchoLinea - 3))
        } else { $script:Raiz }
        Write-Centrado $raizCorta 'DarkGray'
        Write-Host ''

        $opcion = Read-HostCentrado 'Seleccione una opcion [0-3]'
        if ([string]::IsNullOrWhiteSpace($opcion)) { $opcion = '0' }
        switch ($opcion) {
            '1' { Start-Herramienta -Fichero 'HerramientasIT.ps1' -Titulo 'Herramientas IT' }
            '2' { Start-Herramienta -Fichero 'optimizador.ps1'    -Titulo 'Optimizador de Windows' }
            '3' { Start-Herramienta -Fichero 'AsignaH.ps1'        -Titulo 'Asignar letra H:' }
            '0' { }
            default {
                Write-Host ''
                Write-Centrado "Opcion no valida: '$opcion'" 'Red'
                Start-Sleep -Milliseconds 900
            }
        }
        if ($opcion -in '1', '2', '3') {
            Read-HostCentrado 'Pulsa Enter para volver al menu' | Out-Null
        }
    } while ($opcion -ne '0')
}

# --- Arranque ------------------------------------------------------------------
$script:Raiz = Get-RaizHerramientas
Show-MenuPrincipal
