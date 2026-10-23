# ============================================================================
# AsignaH.ps1 - Asigna la letra H: a la unidad externa desde la que se ejecuta
# Migrado de AsignaH.bat (wmic + diskpart) a PowerShell + CIM.
#   - wmic esta eliminado en Windows 11 24H2+; aqui se usa Get-CimInstance.
#   - El cambio de letra se hace con Set-CimInstance (Win32_Volume) y, si
#     falla, con diskpart como respaldo (metodo original).
# Uso:  .\AsignaH.ps1 [-Letra D] [-Forzar] [-Simulacion]
# ============================================================================
param(
    [string]$Letra = "",
    [switch]$Forzar,
    [switch]$Simulacion
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host ""
Write-Host "====================================" -ForegroundColor Cyan
Write-Host " ASIGNANDO LETRA H: A SSD EXTERNO" -ForegroundColor Cyan
Write-Host " (migrado a PowerShell + CIM)" -ForegroundColor DarkGray
Write-Host "====================================" -ForegroundColor Cyan

# --- 1. Unidad de origen (la de este script) ---
if (-not $Letra) {
    $origen = if ($PSCommandPath) { Split-Path -Qualifier $PSCommandPath } else { (Get-Location).Drive.Name }
    $Letra = $origen
}
$Letra = $Letra.TrimEnd(':', '\').ToUpper()

Write-Host ""
Write-Host "  Ejecutando desde la unidad: ${Letra}:"

if ($Letra -eq 'H') {
    Write-Host "  La unidad ya tiene la letra H: asignada. No es necesario cambiar nada." -ForegroundColor Green
    exit 0
}

# --- 2. DETECCION CON CIM (reemplaza wmic logicaldisk) ---
$unidad = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='${Letra}:'" -ErrorAction SilentlyContinue
if (-not $unidad) {
    Write-Host "  ERROR: No se encontro la unidad ${Letra}:." -ForegroundColor Red
    exit 1
}

$tipos = @{ 2 = "Removible/USB"; 3 = "Fijo (interno)"; 4 = "Red"; 5 = "CD/DVD"; 6 = "Disco RAM" }
$tipoTxt = if ($tipos.ContainsKey([int]$unidad.DriveType)) { $tipos[[int]$unidad.DriveType] } else { "Desconocido" }
Write-Host ""
Write-Host "  Metodo 1 - Tipo de unidad (Win32_LogicalDisk.DriveType): $tipoTxt" -ForegroundColor White
Write-Host "     Descripcion : $($unidad.Description)" -ForegroundColor DarkGray
Write-Host "     Sistema     : $($unidad.FileSystem)" -ForegroundColor DarkGray
Write-Host "     Tamanio     : $([math]::Round($unidad.Size/1GB,1)) GB" -ForegroundColor DarkGray

$esExterno = ([int]$unidad.DriveType -eq 2)

# --- 3. METODO 2: Bus del disco USB via asociaciones CIM (reemplaza diskpart) ---
if (-not $esExterno) {
    Write-Host "  Metodo 2 - Bus del disco (asociaciones CIM)..." -ForegroundColor White
    try {
        $particiones = Get-CimInstance -Query "ASSOCIATORS OF {Win32_LogicalDisk.DeviceID='${Letra}:'} WHERE AssocClass = Win32_LogicalDiskToPartition" -ErrorAction Stop
        foreach ($p in @($particiones)) {
            $discos = Get-CimInstance -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID='$($p.DeviceID)'} WHERE AssocClass = Win32_DiskDriveToDiskPartition" -ErrorAction Stop
            foreach ($d in @($discos)) {
                $esUsb = ($d.InterfaceType -eq 'USB') -or ($d.PNPDeviceID -like 'USBSTOR*') -or ($d.PNPDeviceID -like 'USB\*')
                Write-Host "     Disco: $($d.Model) | Interfaz: $($d.InterfaceType)" -ForegroundColor DarkGray
                if ($esUsb) { $esExterno = $true }
            }
        }
    } catch {
        Write-Host "     (no se pudo determinar el bus: $($_.Exception.Message))" -ForegroundColor DarkGray
    }
}

# --- 4. Confirmacion si no se confirmo como externa ---
if (-not $esExterno -and -not $Forzar) {
    Write-Host ""
    Write-Host "  ADVERTENCIA: No se pudo confirmar automaticamente que ${Letra}: es externa/SSD." -ForegroundColor Yellow
    $force = Read-Host "  Deseas forzar el cambio a H:? (S/N)"
    if ($force -notmatch '^[sS]') {
        Write-Host "  Operacion cancelada." -ForegroundColor Yellow
        exit 0
    }
}

# --- 5. Disponibilidad de H: (reemplaza wmic de la lista final) ---
Write-Host ""
Write-Host "  Verificando disponibilidad de H:..." -ForegroundColor White
$enUso = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='H:'" -ErrorAction SilentlyContinue
if ($enUso) {
    Write-Host "  ERROR: La letra H: ya esta en uso." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Unidades que usan H::" -ForegroundColor Yellow
    Get-CimInstance -ClassName Win32_LogicalDisk | Format-Table DeviceID, VolumeName, Description -AutoSize | Out-String | Write-Host
    Write-Host "  Libera la letra H: primero." -ForegroundColor Yellow
    exit 1
}

# --- 6. Cambio de letra ---
Write-Host ""
if ($Simulacion) {
    Write-Host "  SIMULACION: se cambiaria ${Letra}: a H: (no se modifico nada)." -ForegroundColor Yellow
    exit 0
}

$identidad = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identidad)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "  Requiere ADMINISTRADOR para cambiar la letra." -ForegroundColor Red
    Write-Host "  Ejecuta este script como Administrador y vuelve a intentarlo." -ForegroundColor Yellow
    exit 1
}

Write-Host "  Cambiando ${Letra}: a H:..." -ForegroundColor Cyan
$cambiado = $false

# 6a. Metodo principal: CIM sobre Win32_Volume
try {
    $volumen = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='${Letra}:'" -ErrorAction Stop
    if ($volumen) {
        Set-CimInstance -InputObject $volumen -Property @{ DriveLetter = 'H:' } -ErrorAction Stop
        $cambiado = $true
        Write-Host "  Cambio aplicado via CIM (Win32_Volume.DriveLetter)." -ForegroundColor DarkGray
    }
} catch {
    Write-Host "  CIM fallo: $($_.Exception.Message)" -ForegroundColor DarkGray
}

# 6b. Respaldo: diskpart (metodo original del .bat)
if (-not $cambiado) {
    Write-Host "  Respaldo: ejecutando Diskpart..." -ForegroundColor DarkGray
    $tmp = Join-Path $env:TEMP "asignah_$PID.txt"
    @("select volume ${Letra}", "assign letter=H", "exit") | Set-Content -LiteralPath $tmp -Encoding ASCII
    $out = diskpart /s $tmp 2>&1
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ERROR: No se pudo cambiar la letra." -ForegroundColor Red
        Write-Host ($out | Out-String) -ForegroundColor DarkGray
        exit 1
    }
    $cambiado = $true
    Write-Host "  Cambio aplicado via Diskpart." -ForegroundColor DarkGray
}

# --- 7. Verificacion final ---
$verificado = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='H:'" -ErrorAction SilentlyContinue
if ($verificado) {
    Write-Host ""
    Write-Host "  EXITO: La unidad ahora es H: ($($verificado.VolumeName), $([math]::Round($verificado.Size/1GB,1)) GB)" -ForegroundColor Green
    exit 0
}
Write-Host ""
Write-Host "  No se pudo verificar el cambio. Revisa el Administrador de discos." -ForegroundColor Yellow
exit 1
