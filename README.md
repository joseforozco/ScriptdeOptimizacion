# Kit de Herramientas - José Orozco

Herramientas en PowerShell para la puesta a punto, limpieza y mantenimiento de
equipos **Windows 10 y 11**, orientadas a trabajo de soporte IT.

## Uso rápido (una sola línea)

```powershell
irm https://raw.githubusercontent.com/joseforozco/ScriptdeOptimizacion/main/start.ps1 | iex
```

El menú se abre en la consola actual y cada herramienta se lanza en su propia
ventana; al cerrarla se vuelve al menú. En este modo remoto los scripts se
descargan solos a una carpeta temporal.

## Uso local

Opción A — clonar el repositorio:

```powershell
git clone https://github.com/joseforozco/ScriptdeOptimizacion.git
cd ScriptdeOptimizacion
.\menu.ps1
```

Opción B — descargar el ZIP desde GitHub, extraerlo y ejecutar `menu.ps1`.

## Herramientas

| Script | Qué hace | Motor |
|---|---|---|
| `start.ps1` | Entrada remota para el one-liner (`irm … \| iex`); descarga los scripts y lanza el menú | 5.1 y 7 |
| `menu.ps1` | Menú principal del Kit | Windows PowerShell 5.1 y PowerShell 7 |
| `HerramientasIT.ps1` | Suite de 11 utilidades de soporte: bloqueo de software (Autodesk, WPS), borrado por años, duplicados, reporte NAS, organización de fuentes, reubicación de instaladores, reparación de perfil y más | PowerShell 7 (se valida e instala solo si falta) |
| `optimizador.ps1` | Debloat y optimización en 15 secciones, con modo simulación para revisar antes de aplicar | PowerShell 7 (se valida e instala solo si falta) |
| `AsignaH.ps1` | Fija la letra H: del SSD externo (vía CIM + diskpart) | 5.1 y 7 |
| `AsignaH.bat` | Lanzador clásico de `AsignaH.ps1` | cmd |

Cada herramienta funciona de forma independiente: también pueden lanzarse
directamente, sin pasar por el menú.

### Carpetas

- `Reg\` — ajustes de registro que el Optimizador lleva embebidos en su
  sección 14, y `rarreg.key` (licencia de WinRAR: copiar a la carpeta de
  instalación de WinRAR).
- `Roblox\` — utilidades para Roblox (activar / desactivar).
- `Seguridad\` — auditoría de equipos (`auditar.ps1`, con HardeningKitty
  incluido en `tools\`).

## Requisitos

- Windows 10 u 11.
- Ejecutar como administrador (los scripts que lo exigen lo comprueban y avisan).
- PowerShell 7 se valida e instala automáticamente cuando hace falta, vía
  winget o MSI.

## Notas técnicas

- Los scripts se ejecutan igual en Windows PowerShell 5.1 y en PowerShell 7
  siempre que es posible; los módulos de Windows (Appx, Dism,
  LocalAccounts) se cargan por compatibilidad (`-UseWindowsPowerShell`)
  cuando el motor es 7.
- Codificación de los fuentes: UTF-8 con BOM y finales de línea CRLF
  (forzados en el clone vía `.gitattributes`).
