#Requires -Version 7.0
<#
.SYNOPSIS
    auditar.ps1 — Escaneo de seguridad SOLO LECTURA del equipo Windows (10/11).
.DESCRIPTION
    5 capas de verificacion + informe con remediacion sugerida por hallazgo.
    NUNCA modifica el sistema: solo lee, reporta y sugiere.
    Salidas: HTML (resumen ejecutivo, SOLO critico/alto, legible para no tecnicos),
    log .txt completo (todas las severidades + apendice CIS) y JSON machine-readable.

    Capa 1  Actualizaciones pendientes (Windows Update + winget)
    Capa 2  Red: puertos escuchando, tuneles ngrok/cloudflared, firewall, RDP
    Capa 3  Baseline CIS via HardeningKitty (lista elegida segun build de SO)
    Capa 4  Servicios criticos, autoruns, drivers sin firmar, estado Defender
    Capa 5  Permisos de ficheros sensibles (.env, claves SSH, .pem)

.PARAMETER Capas
    Que capas ejecutar. Por defecto todas. Acepta '1..5', '3,4' o '3 4'
    (formato texto para funcionar con pwsh -File).
.PARAMETER Salida
    Carpeta de informes. Por defecto 'informes\' junto al script.
.PARAMETER RutasSensibles
    Rutas a inspeccionar en la capa 5.
.PARAMETER CISDetallado
    Incluir TODOS los hallazgos CIS fallidos como hallazgos (por defecto
    solo van al apendice del log; la consola y el HTML muestran solo critico/alto).
.PARAMETER SinRed
    Saltar los chequeos que requieren red (Windows Update, winget).
.EXAMPLE
    pwsh -File auditar.ps1
    pwsh -File auditar.ps1 -Capas 2,4 -SinRed
#>
[CmdletBinding()]
param(
    [string]$Capas = '1..5',
    [string]$Salida = (Join-Path $PSScriptRoot 'informes'),
    [string[]]$RutasSensibles = @('J:\www', 'D:\www', 'D:\Importantes', "$env:USERPROFILE\.ssh"),
    [switch]$CISDetallado,
    [switch]$SinRed
)

$ErrorActionPreference = 'SilentlyContinue'

# -Capas llega como TEXTO con pwsh -File: aceptar '1..5', '3,4' o '3 4'
if ($Capas -match '^\s*\d+\s*\.\.\s*\d+\s*$') { $a, $b = ($Capas -replace '\s', '') -split '\.\.'; $capasSel = $a..$b }
else { $capasSel = @($Capas -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { [int]$_ }) }

# ---------------------------------------------------------------- utilidades --
$script:Hallazgos = [System.Collections.Generic.List[object]]::new()
$script:Log       = [System.Collections.Generic.List[string]]::new()

function Nuevo-Hallazgo {
    param([string]$Capa, [string]$Sev, [string]$ID, [string]$Titulo, [string]$Evidencia, [string]$Solucion, [string]$Ref = '')
    $script:Hallazgos.Add([pscustomobject]@{ Capa = $Capa; Severidad = $Sev; ID = $ID; Titulo = $Titulo; Evidencia = $Evidencia; Solucion = $Solucion; Referencia = $Ref })
}

function Emit {
    param([string]$Icono, [string]$Color = 'Gray', [string]$Texto)
    Write-Host ('{0} {1}' -f $Icono, $Texto) -ForegroundColor $Color
    $script:Log.Add(('{0} {1}' -f $Icono, $Texto))
}

function Buscar-CarpetaHardeningKitty {
    $candidatas = @((Join-Path $PSScriptRoot 'tools\windows_hardening'), 'J:\www\tools\windows_hardening')
    $candidatas | Where-Object { Test-Path (Join-Path $_ 'HardeningKitty.psd1') } | Select-Object -First 1
}

# ------------------------------------------------------------------- capa 1 --
function Invoke-CapaActualizaciones {
    Emit '[i]' 'Cyan' 'CAPA 1 — Actualizaciones pendientes'
    if ($SinRed) { Emit '[i]' 'Gray' '  Saltada (-SinRed)'; return }

    # Actualizaciones de Windows Update (busqueda COM, solo lectura)
    try {
        $svc  = New-Object -ComObject Microsoft.Update.Session
        $srch = $svc.CreateUpdateSearcher()
        $res  = $srch.Search('IsInstalled=0 and IsHidden=0')
        $n    = $res.Updates.Count
        if ($n -gt 0) {
            $imp = @($res.Updates | Where-Object { $_.MsrcSeverity -in 'Critical','Important' }).Count
            $sev = if ($imp -gt 0) { 'Alto' } else { 'Medio' }
            Nuevo-Hallazgo '1' $sev 'UPD-001' "$n actualizaciones de Windows pendientes ($imp criticas/importantes)" 'Windows Update' 'Instalar desde Configuracion > Windows Update; o módulo PSWindowsUpdate (Get-WindowsUpdate)' 'Microsoft KB mensual'
            Emit '[$]' 'Yellow' "  $n pendientes ($imp importantes)"
        } else { Emit '[OK]' 'Green' '  Windows Update al día' }
    } catch { Emit '[!]' 'Yellow' '  No se pudo consultar Windows Update (COM bloqueado o sin red)' }

    # winget: paquetes con actualizacion disponible (ruta directa si no esta en PATH)
    $wg = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $wg -and (Test-Path "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe")) { $wg = "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe" }
    if ($wg) {
        $upg = & $wg upgrade --disable-interactivity 2>$null | Where-Object { $_ -match '^\S+\s+\S+\s+\S+' -and $_ -notmatch '^(-|Nombre|Id)' }
        $n = @($upg).Count
        if ($n -gt 0) {
            $muestra = (@($upg) | Select-Object -First 5) -join ' | '
            Nuevo-Hallazgo '1' 'Medio' 'UPD-002' "$n aplicaciones con actualización disponible (winget)" $muestra 'winget upgrade --all --disable-interactivity' 'winget'
            Emit '[$]' 'Yellow' "  winget: $n actualizaciones disponibles"
        } else { Emit '[OK]' 'Green' '  winget: sin actualizaciones pendientes' }
    } else { Emit '[i]' 'Gray' '  winget no disponible' }
}

# ------------------------------------------------------------------- capa 2 --
function Invoke-CapaRed {
    Emit '[i]' 'Cyan' 'CAPA 2 — Red: puertos, tuneles, firewall, RDP'

    # Tuneles salientes (exposicion de red local a internet)
    $tuneles = Get-Process ngrok, cloudflared, frp, bore -ErrorAction SilentlyContinue
    if ($tuneles) {
        $nombres = ($tuneles.ProcessName | Sort-Object -Unique) -join ', '
        Nuevo-Hallazgo '2' 'Alto' 'RED-001' "Túnel de exposición activo: $nombres" "Procesos: $nombres" 'Cerrar el túnel si no es imprescindible; si lo es, restringir autenticación y puertos remotos' 'Superficie de exposición'
        Emit '[X]' 'Red' "  Túnel activo: $nombres"
    } else { Emit '[OK]' 'Green' '  Sin túneles ngrok/cloudflared activos' }

    # Puertos escuchando
    $listen = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalAddress -in '0.0.0.0','::','127.0.0.1','::1' }
    $resumen = $listen | ForEach-Object { $p = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue; '{0} ({1})' -f $_.LocalPort, $(if ($p) { $p.ProcessName } else { '?' }) } | Sort-Object -Unique
    Emit '[i]' 'Gray' ("  Escuchando: " + ($resumen -join ', '))
    if ($listen | Where-Object LocalPort -eq 4040) {
        Nuevo-Hallazgo '2' 'Medio' 'RED-002' 'API de ngrok (puerto 4040) accesible' 'ngrok en 4040 permite ver/modificar túneles' 'Restringir a 127.0.0.1 o cerrar ngrok' 'ngrok docs'
    }

    # Perfiles de firewall
    $fwOff = Get-NetFirewallProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Enabled }
    if ($fwOff) {
        $nombres = ($fwOff.Name -join ', ')
        Nuevo-Hallazgo '2' 'Alto' 'RED-003' "Perfiles de firewall DESACTIVADOS: $nombres" "Perfiles: $nombres" 'Set-NetFirewallProfile -Profile <perfil> -Enabled True' 'Microsoft Learn: Set-NetFirewallProfile'
        Emit '[X]' 'Red' "  Firewall desactivado en: $nombres"
    } else { Emit '[OK]' 'Green' '  Firewall activo en todos los perfiles' }

    # Escritorio remoto
    $ts = Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -ErrorAction SilentlyContinue
    if ($ts -and $ts.fDenyTSConnections -eq 0) {
        $nla = Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -ErrorAction SilentlyContinue
        $sev = if ($nla.UserAuthentication -ne 1) { 'Alto' } else { 'Medio' }
        $ev  = "fDenyTSConnections=0; NLA=$(if ($nla.UserAuthentication -eq 1) {'ON'} else {'OFF'})"
        Nuevo-Hallazgo '2' $sev 'RED-004' 'Escritorio remoto (RDP) habilitado' $ev 'Deshabilitar si no se usa (fDenyTSConnections=1); si se usa, exigir NLA y red privada' 'CIS 18.10.57'
        Emit '[$]' 'Yellow' '  RDP habilitado'
    } else { Emit '[OK]' 'Green' '  RDP deshabilitado' }
}

# ------------------------------------------------------------------- capa 3 --
function Invoke-CapaCIS {
    Emit '[i]' 'Cyan' 'CAPA 3 — Baseline CIS (HardeningKitty)'
    $hk = Buscar-CarpetaHardeningKitty
    if (-not $hk) { Emit '[!]' 'Yellow' '  HardeningKitty no encontrado (tools\windows_hardening) — saltado'; return }

    # Seleccion de lista segun build del SO (Win10/Win11)
    $build = [System.Environment]::OSVersion.Version.Build
    $archivo = switch ($true) {
        ($build -ge 26100) { 'finding_list_cis_microsoft_windows_11_enterprise_24h2_machine.csv'; break }
        ($build -ge 22631) { 'finding_list_cis_microsoft_windows_11_enterprise_23h2_machine.csv'; break }
        ($build -ge 22000) { 'finding_list_cis_microsoft_windows_11_enterprise_22h2_machine.csv'; break }
        default            { 'finding_list_cis_microsoft_windows_10_enterprise_22h2_3.0.0_machine.csv'; break }
    }
    $lista = Join-Path $hk "lists\$archivo"
    if (-not (Test-Path $lista)) { Emit '[!]' 'Yellow' "  Lista CIS no encontrada: $archivo"; return }
    Emit '[i]' 'Gray' "  Build $build -> lista $archivo"

    Import-Module (Join-Path $hk 'HardeningKitty.psd1') -Force
    $logHK = Join-Path $env:TEMP ('hk_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date))
    Invoke-HardeningKitty -FileFindingList $lista -Mode Audit -Log -LogFile $logHK 6>$null | Out-Null

    $lineas  = Get-Content $logHK
    $score   = ($lineas | Select-String 'score is: (\d+(?:\.\d+)?)').Matches.Groups[1].Value
    $fallidos = $lineas | Where-Object { $_ -match '^ID [\d.]+' } | ForEach-Object {
        if ($_ -match '^ID (?<id>[\d.]+), (?<nom>.*?), Result=(?<res>.*?), Recommended=(?<rec>.*?), Severity=(?<sev>\w+)') {
            [pscustomobject]@{ ID = $Matches['id']; Nom = $Matches['nom']; Res = $Matches['res']; Rec = $Matches['rec']; Sev = $Matches['sev'] }
        }
    } | Where-Object Sev -ne 'Passed'

    $errores = if ($lineas | Select-String 'Total errors: (\d+)') { $Matches[1] } else { '0' }
    Nuevo-Hallazgo '3' 'Info' 'CIS-000' "Baseline CIS: score $score — $($fallidos.Count) controles no conformes ($errores errores por falta de admin)" "Lista: $archivo" 'Ver apendice del log; priorizar los de severidad High' 'CIS Windows Benchmark'
    Emit '[i]' 'Gray' "  Score $score — $($fallidos.Count) no conformes (apendice en el log)"

    # Hallazgos individuales solo para severidad High (el resto al apendice)
    foreach ($f in ($fallidos | Where-Object Sev -eq 'High')) {
        $ev  = "Resultado: $($f.Res) — Recomendado: $($f.Rec)"
        $sol = "Aplicar el valor recomendado del control CIS $($f.ID) (documentacion en windows_hardening.md)"
        Nuevo-Hallazgo '3' 'Alto' "CIS-$($f.ID)" $f.Nom $ev $sol "CIS $($f.ID)"
    }
    if ($CISDetallado) {
        foreach ($f in ($fallidos | Where-Object Sev -ne 'High')) {
            $sev = if ($f.Sev -eq 'Medium') { 'Medio' } else { 'Bajo' }
            $ev  = "Resultado: $($f.Res) — Recomendado: $($f.Rec)"
            Nuevo-Hallazgo '3' $sev "CIS-$($f.ID)" $f.Nom $ev 'Aplicar el valor recomendado del control' "CIS $($f.ID)"
        }
    }
    # Apendice siempre al log
    $script:Log.Add('  --- APENDICE CIS: controles no conformes ---')
    foreach ($f in $fallidos) { $script:Log.Add(('  [{0}] {1} — {2} (res={3} rec={4})' -f $f.Sev, $f.ID, $f.Nom, $f.Res, $f.Rec)) }
}

# ------------------------------------------------------------------- capa 4 --
function Invoke-CapaServicios {
    Emit '[i]' 'Cyan' 'CAPA 4 — Servicios, autoruns, drivers, Defender'

    # Servicios de seguridad deshabilitados
    foreach ($svc in 'WinDefend','mpssvc','wuauserv','SecurityHealthService') {
        $s = Get-Service $svc -ErrorAction SilentlyContinue
        if ($s -and $s.StartType -eq 'Disabled') {
            $ev = "StartType=Disabled, Status=$($s.Status)"
            Nuevo-Hallazgo '4' 'Critico' "SVC-$svc" "Servicio de seguridad deshabilitado: $svc" $ev "Set-Service $svc -StartupType Automatic; reiniciar" 'CIS 2.x'
            Emit '[X]' 'Red' "  Servicio crítico deshabilitado: $svc"
        }
    }

    # Estado de Microsoft Defender (sin admin, Get-Mp* devuelve "N/A": evitar falsos positivos)
    try {
        $st = Get-MpComputerStatus -ErrorAction Stop
        if ($st.RealTimeProtectionEnabled -is [bool] -and -not $st.RealTimeProtectionEnabled) {
            Nuevo-Hallazgo '4' 'Critico' 'DEF-001' 'Protección en tiempo real de Defender DESACTIVADA' 'RealTimeProtectionEnabled=False' 'Activar en Seguridad de Windows > Protección antivirus' 'Microsoft Defender'
            Emit '[X]' 'Red' '  Defender: protección en tiempo real OFF'
        } elseif ($st.RealTimeProtectionEnabled -is [bool]) { Emit '[OK]' 'Green' '  Defender: protección en tiempo real activa' }
        else { Emit '[i]' 'Gray' '  Defender: estado de protección no legible sin admin' }
        $edad = -1
        if ([int]::TryParse("$($st.SignatureAge)", [ref]$edad)) {
            if ($edad -gt 7) {
                Nuevo-Hallazgo '4' 'Alto' 'DEF-002' "Defender con definiciones obsoletas ($edad días)" "SignatureAge=$edad" 'Update-MpSignature; comprobar el servicio de actualización' 'Microsoft Defender'
                Emit '[$]' 'Yellow' "  Defender: firmas con $edad días"
            } else { Emit '[OK]' 'Green' "  Defender: firmas al día ($edad días)" }
        } else { Emit '[i]' 'Gray' '  Defender: antigüedad de firmas no legible sin admin' }
        if ($st.AntivirusEnabled -is [bool] -and -not $st.AntivirusEnabled) {
            Nuevo-Hallazgo '4' 'Critico' 'DEF-003' 'Antivirus de Defender deshabilitado' 'AntivirusEnabled=False' 'Activar en Seguridad de Windows' 'Microsoft Defender'
            Emit '[X]' 'Red' '  Defender: antivirus OFF'
        }
        $pref = Get-MpPreference -ErrorAction SilentlyContinue
        $excl = @($pref.ExclusionPath) | Where-Object { $_ -and $_ -notmatch '^N/A' }
        if ($excl.Count -gt 0) {
            $ev = ($excl -join '; ')
            Nuevo-Hallazgo '4' 'Alto' 'DEF-004' "Exclusiones de Defender configuradas ($($excl.Count))" $ev 'Revisar cada exclusión: si no es imprescindible, eliminarla (Remove-MpPreference -ExclusionPath)' 'Defender exclusiones'
            Emit '[$]' 'Yellow' "  Defender: $($excl.Count) exclusiones"
        } elseif (-not $esAdmin) { Emit '[i]' 'Gray' '  Defender: exclusiones no listables sin admin' }
    } catch { Emit '[!]' 'Yellow' '  Módulo Defender no accesible' }

    # Autoruns (HKLM/HKCU Run + carpeta Startup)
    $runs = @()
    foreach ($k in 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run','HKCU:\Software\Microsoft\Windows\CurrentVersion\Run') {
        $runs += (Get-ItemProperty $k -ErrorAction SilentlyContinue).PSObject.Properties |
            Where-Object { $_.Name -notin 'PSPath','PSParentPath','PSChildName','PSDrive','PSProvider' } |
            ForEach-Object { '{0} = {1}' -f $_.Name, $_.Value }
    }
    $startup = Get-ChildItem "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup" -File -ErrorAction SilentlyContinue
    Emit '[i]' 'Gray' "  Autoruns: $($runs.Count) entradas de registro + $($startup.Count) de Startup"
    foreach ($s in ($runs | Where-Object { $_ -match 'temp|downloads|\\[a-z0-9]{8}\.exe' })) {
        $corto = $s.Substring(0, [Math]::Min(120, $s.Length))
        Nuevo-Hallazgo '4' 'Alto' 'ARL-001' 'Autorun con ruta sospechosa (temp/downloads)' $s 'Verificar el origen; si no es legítimo, eliminar la entrada del registro' 'Persistence techniques'
        Emit '[X]' 'Red' "  Autorun sospechoso: $corto"
    }

    # Drivers sin firmar en ejecucion
    $drivers = Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue | Where-Object State -eq 'Running'
    $sinFirma = foreach ($d in $drivers) {
        $ruta = $d.PathName -replace '^\\SystemRoot\\', "$env:SystemRoot\"
        if (Test-Path $ruta) {
            $sig = Get-AuthenticodeSignature $ruta
            if ($sig.Status -ne 'Valid') { "$($d.Name) ($($sig.Status))" }
        }
    }
    if ($sinFirma) {
        $ev = (@($sinFirma) -join '; ')
        Nuevo-Hallazgo '4' 'Alto' 'DRV-001' "Drivers en ejecución con firma inválida ($(@($sinFirma).Count))" $ev 'Investigar cada driver; desinstalar el componente que lo instala' 'Driver signing'
        Emit '[X]' 'Red' "  Drivers con firma inválida: $(@($sinFirma).Count)"
    } else { Emit '[OK]' 'Green' "  $($drivers.Count) drivers en ejecución: todos firmados" }
}

# ------------------------------------------------------------------- capa 5 --
function Invoke-CapaPermisos {
    Emit '[i]' 'Cyan' 'CAPA 5 — Permisos de ficheros sensibles'
    $abiertos = 'BUILTIN\Users','Everyone','Authenticated Users','Todos'
    $total = 0
    $solIcacls = 'icacls "<fichero>" /inheritance:r /grant "%USERNAME%:R"'

    foreach ($raiz in $RutasSensibles) {
        if (-not (Test-Path $raiz)) { continue }
        # Ficheros .env (excluye dependencias)
        $envs = Get-ChildItem $raiz -Filter '.env' -Recurse -Depth 6 -Force -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch 'node_modules|vendor|\.git' }
        foreach ($f in $envs) {
            $total++
            $acl = Get-Acl $f.FullName -ErrorAction SilentlyContinue
            if (-not $acl) { continue }
            $abiertosAcceso = $acl.Access | Where-Object { $_.IdentityReference.ToString() -in $abiertos -and $_.FileSystemRights.ToString() -match 'Read|Full|Modify' -and $_.AccessControlType -eq 'Allow' }
            if ($abiertosAcceso) {
                $refs = ($abiertosAcceso.IdentityReference | Select-Object -Unique) -join ', '
                Nuevo-Hallazgo '5' 'Alto' 'PERM-001' '.env legible por usuarios no privilegiados' "$($f.FullName) — acceso: $refs" $solIcacls 'Principio mínimo privilegio'
                Emit '[X]' 'Red' "  .env expuesto: $($f.FullName)"
            }
        }
        # Claves SSH privadas
        if ($raiz -eq "$env:USERPROFILE\.ssh") {
            $claves = Get-ChildItem $raiz -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(id_|.*_rsa|.*_ed25519|.*\.pem)' -and $_.Extension -ne '.pub' }
            foreach ($c in $claves) {
                $total++
                $acl = Get-Acl $c.FullName -ErrorAction SilentlyContinue
                $abiertosAcceso = $acl.Access | Where-Object { $_.IdentityReference.ToString() -in $abiertos -and $_.FileSystemRights.ToString() -match 'Read|Full|Modify' -and $_.AccessControlType -eq 'Allow' }
                if ($abiertosAcceso) {
                    $refs = ($abiertosAcceso.IdentityReference | Select-Object -Unique) -join ', '
                    Nuevo-Hallazgo '5' 'Alto' 'PERM-002' "Clave SSH privada legible por otros usuarios: $($c.Name)" "$($c.FullName) — acceso: $refs" $solIcacls 'OpenSSH permissions'
                    Emit '[X]' 'Red' "  Clave SSH expuesta: $($c.Name)"
                }
            }
        }
    }
    if ($total -eq 0) { Emit '[OK]' 'Green' '  Sin ficheros sensibles expuestos en las rutas inspeccionadas' }
    else { Emit '[i]' 'Gray' "  Inspeccionados $total ficheros sensibles" }
}

# -------------------------------------------------------------------- main --
$inicio = Get-Date
Clear-Host
Emit ('=' * 100) 'DarkGray'
Emit ('AUDITORIA DE SEGURIDAD — {0} — {1:yyyy-MM-dd HH:mm}' -f $env:COMPUTERNAME, $inicio) 'White'
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Emit ('SO: Windows build {0} | PowerShell {1} | Admin: {2}' -f [System.Environment]::OSVersion.Version.Build, $PSVersionTable.PSVersion.Major, $esAdmin) 'Gray'
Emit 'SOLO LECTURA — este script NO modifica el sistema.' 'DarkGray'
Emit ('=' * 100) 'DarkGray'

if (1 -in $capasSel) { Invoke-CapaActualizaciones }
if (2 -in $capasSel) { Invoke-CapaRed }
if (3 -in $capasSel) { Invoke-CapaCIS }
if (4 -in $capasSel) { Invoke-CapaServicios }
if (5 -in $capasSel) { Invoke-CapaPermisos }

# Resumen por severidad (consola + log)
Emit '' ; Emit ('=' * 100) 'DarkGray'
Emit 'RESUMEN' 'White'
$orden = @{ Critico = 0; Alto = 1; Medio = 2; Bajo = 3; Info = 4 }
$resumen = $script:Hallazgos | Group-Object Severidad | Sort-Object { $orden[$_.Name] }
foreach ($g in $resumen) { Emit ('  {0,-9} {1}' -f $g.Name, $g.Count) 'Gray' }
Emit ('Total: {0} hallazgos' -f $script:Hallazgos.Count) 'Gray'

function Write-Hallazgo {
    param($h)
    $color = switch ($h.Severidad) { 'Critico' { 'Red' } 'Alto' { 'Red' } 'Medio' { 'Yellow' } default { 'Gray' } }
    Emit '' ; Emit ('[{0}] {1} — {2}' -f $h.Severidad.ToUpper(), $h.ID, $h.Titulo) $color
    Emit ('      Evidencia : {0}' -f $h.Evidencia) 'Gray'
    Emit ('      Solucion  : {0}' -f $h.Solucion) 'Gray'
    if ($h.Referencia) { Emit ('      Referencia: {0}' -f $h.Referencia) 'DarkGray' }
}

# CONSOLA: solo lo critico (legibilidad); el resto al log y al JSON
$criticos = $script:Hallazgos | Where-Object { $_.Severidad -in 'Critico','Alto' } | Sort-Object { $orden[$_.Severidad] }, Capa, ID
Emit '' ; Emit ('=' * 100) 'DarkGray'
Emit ('LO CRITICO — {0} hallazgos que requieren accion' -f $criticos.Count) 'White'
foreach ($h in $criticos) { Write-Hallazgo $h }

# LOG: detalle COMPLETO de todos los hallazgos (todas las severidades)
$script:Log.Add('')
$script:Log.Add('=' * 100)
$script:Log.Add('DETALLE COMPLETO (todas las severidades)')
foreach ($h in ($script:Hallazgos | Sort-Object { $orden[$_.Severidad] }, Capa, ID)) {
    $script:Log.Add('')
    $script:Log.Add((' [{0}] {1} — {2}' -f $h.Severidad.ToUpper(), $h.ID, $h.Titulo))
    $script:Log.Add(('        Evidencia : {0}' -f $h.Evidencia))
    $script:Log.Add(('        Solucion  : {0}' -f $h.Solucion))
    if ($h.Referencia) { $script:Log.Add(('        Referencia: {0}' -f $h.Referencia)) }
}

# RESUMEN EJECUTIVO HTML: lo que se comparte y se lee (solo Critico y Alto)
$marca = '{0:yyyy-MM-dd_HHmmss}' -f $inicio
function Enc([string]$s) { if ($null -eq $s) { return '' }; [System.Net.WebUtility]::HtmlEncode($s) }
$clase = @{ Critico = 'critico'; Alto = 'alto'; Medio = 'medio'; Bajo = 'bajo'; Info = 'info' }
$tarjetas = foreach ($h in $criticos) {
    $refHtml = if ($h.Referencia) { "<p class=`"ref`">Ref: $(Enc $h.Referencia)</p>" } else { '' }
    @"
  <div class="card $($clase[$h.Severidad])">
    <span class="badge $($clase[$h.Severidad])">$($h.Severidad.ToUpper())</span>
    <h3>$(Enc "$($h.ID) — $($h.Titulo)")</h3>
    <p><b>Evidencia:</b> $(Enc $h.Evidencia)</p>
    <p class="sol"><b>Solución:</b> $(Enc $h.Solucion)</p>
    $refHtml
  </div>
"@
}
if (-not $criticos) { $tarjetas = '  <div class="ok">Sin hallazgos críticos ni altos. El equipo está en buena postura.</div>' }
$tarjetasBloque = $tarjetas -join "`n"
$totas = ($resumen | ForEach-Object { '<div class="stat {0}"><span class="num">{1}</span>{0}</div>' -f $clase[$_.Name], $_.Count }) -join "`n"

$html = @"
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Resumen de auditoría — $(Enc $env:COMPUTERNAME)</title>
<style>
  :root { --rojo:#c0392b; --naranja:#e67e22; --gris:#7f8c8d; --azul:#2980b9; }
  body { font-family:'Segoe UI',system-ui,sans-serif; margin:0; background:#f4f6f7; color:#2c3e50; }
  header { background:#2c3e50; color:#fff; padding:24px 32px; }
  header h1 { margin:0; font-size:22px; }
  header p { margin:6px 0 0; color:#bdc3c7; font-size:13px; }
  .stats { display:flex; gap:12px; padding:20px 32px 0; flex-wrap:wrap; }
  .stat { background:#fff; border-radius:8px; padding:12px 20px; min-width:110px; text-align:center;
          box-shadow:0 1px 3px rgba(0,0,0,.08); font-size:13px; text-transform:capitalize; }
  .stat .num { display:block; font-size:28px; font-weight:700; }
  .stat.critico .num { color:var(--rojo); } .stat.alto .num { color:var(--naranja); }
  .stat.medio .num { color:#b7950b; } .stat.bajo .num { color:var(--gris); } .stat.info .num { color:var(--azul); }
  main { padding:16px 32px 32px; }
  h2 { border-bottom:2px solid #ecf0f1; padding-bottom:8px; font-size:18px; }
  .card { background:#fff; border-left:5px solid var(--gris); border-radius:6px; padding:14px 18px;
          margin:12px 0; box-shadow:0 1px 3px rgba(0,0,0,.06); }
  .card.critico { border-left-color:var(--rojo); } .card.alto { border-left-color:var(--naranja); }
  .badge { display:inline-block; padding:2px 10px; border-radius:12px; color:#fff; font-size:11px; font-weight:700; }
  .badge.critico { background:var(--rojo); } .badge.alto { background:var(--naranja); }
  .card h3 { margin:4px 0 8px; font-size:16px; } .card p { margin:4px 0; font-size:14px; }
  .sol { background:#f8f9f9; padding:8px 10px; border-radius:4px; font-family:Consolas,monospace; font-size:13px; }
  .ref { color:#7f8c8d; font-size:12px; }
  .ok { background:#eafaf1; border:1px solid #27ae60; color:#1e8449; padding:16px; border-radius:8px; font-size:16px; }
  footer { color:#95a5a6; font-size:12px; padding:0 32px 24px; }
</style>
</head>
<body>
<header>
  <h1>Resumen de auditoría de seguridad</h1>
  <p>Equipo: $(Enc $env:COMPUTERNAME) — $(Get-Date -Format 'dddd, dd MMMM yyyy HH:mm') — Windows build $([System.Environment]::OSVersion.Version.Build) — PowerShell $($PSVersionTable.PSVersion)</p>
</header>
<div class="stats">
$totas
</div>
<main>
<h2>Lo que requiere acción ($($criticos.Count))</h2>
$tarjetasBloque
</main>
<footer>Generado por auditar.ps1 (solo lectura — no modifica el sistema). Detalle técnico completo en el .txt y el JSON de la misma fecha.</footer>
</body>
</html>
"@

# Salidas: HTML (resumen ejecutivo) + log completo + JSON
New-Item -ItemType Directory -Path $Salida -Force | Out-Null
$logFile  = Join-Path $Salida "auditoria_$marca.txt"
$jsonFile = Join-Path $Salida "auditoria_$marca.json"
$htmlFile = Join-Path $Salida "auditoria_${marca}_RESUMEN.html"
[System.IO.File]::WriteAllLines($logFile, $script:Log, [System.Text.UTF8Encoding]::new($true))
$script:Hallazgos | ConvertTo-Json -Depth 3 | Set-Content $jsonFile -Encoding utf8
[System.IO.File]::WriteAllText($htmlFile, $html, [System.Text.UTF8Encoding]::new($false))
Emit ''; Emit ('RESUMEN  : {0}' -f $htmlFile) 'Cyan'
Emit ('Log      : {0}' -f $logFile) 'DarkGray'
Emit ('JSON     : {0}' -f $jsonFile) 'DarkGray'
Start-Process $htmlFile   # abre el resumen en el navegador automaticamente
