# ============================================================================
# start.ps1 - Entrada remota del Kit (para un 'irm <url> | iex' limpio)
# ============================================================================
# POR QUE EXISTE ESTE FICHERO: menu.ps1 lleva marca BOM (UTF-8), necesaria
# para que Windows PowerShell 5.1 lea bien los acentos y las cajas Unicode al
# ejecutarlo como archivo local. Ese BOM hace que 'iex' escupa un aviso si se
# sirve menu.ps1 directamente. Este fichero es ASCII puro y SIN BOM: es el
# unico que se sirve para el one-liner.
#
#   irm https://raw.githubusercontent.com/joseforozco/ScriptdeOptimizacion/main/start.ps1 | iex
#
# Que hace:
#   - Local (junto a menu.ps1): lo lanza en esta misma consola.
#   - Remoto (irm | iex): descarga los 4 scripts a una carpeta temporal
#     (%TEMP%\KitHerramientas) y lanza el menu desde alli.
#
# NOTA: la lista de ficheros esta duplicada en menu.ps1 ($script:Herramientas);
# si se anade una herramienta, actualizar AMBOS sitios.
# ============================================================================

$UrlBase   = 'https://raw.githubusercontent.com/joseforozco/ScriptdeOptimizacion/main/'
$Ficheros  = @('menu.ps1', 'HerramientasIT.ps1', 'optimizador.ps1', 'AsignaH.ps1')

$dir = $null
if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'menu.ps1'))) {
    # Modo local: carpeta completa clonada o descargada.
    $dir = $PSScriptRoot
} else {
    # Modo remoto: bajar los 4 scripts a un temporal.
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) 'KitHerramientas'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
    Write-Host 'Descargando herramientas desde GitHub...' -ForegroundColor Cyan
    $prev = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    foreach ($f in $Ficheros) {
        try {
            Invoke-WebRequest -Uri ($UrlBase + $f) -OutFile (Join-Path $dir $f) -UseBasicParsing -ErrorAction Stop
            Write-Host "  [OK]    $f" -ForegroundColor Green
        } catch {
            Write-Host "  [FALLO] $f" -ForegroundColor Red
            Write-Host 'Descarga incompleta: clone o descargue el repositorio y ejecute menu.ps1.' -ForegroundColor Red
            return
        }
    }
    $ProgressPreference = $prev
}

$menu = Join-Path $dir 'menu.ps1'
$exe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
& $exe -NoProfile -ExecutionPolicy Bypass -File $menu
