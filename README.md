# RoEMU

Emulador de sistemas en **Luau para Roblox**, desarrollado a partir del proyecto
RoEMU. El repositorio conserva sus servicios, carpetas, nombres internos, scripts
y la distribución de la interfaz original.

## Qué contiene

- Motor RISC-V RV32 con MMU Sv32, interrupciones CLINT/PLIC, UART y virtio-blk.
- Motor PC i386: modos real, protegido y virtual 8086, segmentación, paginación,
  excepciones, PIC, PIT/RTC, PS/2, ATA PIO y PCI.
- Base PowerPC64 con registros exactos, rotaciones/desplazamientos y carga ELF64
  estática comprobada con un programa C propio.
  Incluye TLS, consola, hilos PPU, condiciones, metadatos SFO y transferencias
  exactas de registros de coma flotante, además de memoria/mutex básicos.
  El selector ofrece el perfil PS3 en desarrollo; **CellOS/GameOS aún no arranca**.
- VGA por planos y framebuffer VBE, hasta 1024 × 768, paleta del invitado,
  actualizaciones parciales de vídeo y ratón absoluto compatible con VMware.
- Consola, teclado, selector de arquitectura y módulos para conectar interfaces.
- Plantilla de Roblox con la jerarquía y las propiedades de la GUI conservadas.

**Este repositorio no contiene Windows 95, imágenes de disco, kernels compilados
ni ROMs de firmware.** Sus ubicaciones originales se conservan como marcadores
vacíos. Tampoco contiene las capturas, registros o archivos privados de pruebas.
Los árboles de dispositivos DTB describen el hardware virtual y sí se incluyen
como configuración de la plataforma.

## Estructura

```text
src/
  ReplicatedStorage/     # RV32, dispositivos, consola y cliente de vídeo PC
  ServerScriptService/   # Inicio, integración, entrada/salida y ejemplos originales
  ServerStorage/         # Motor i386, plataforma PC, utilidades y rutas de payloads
  StarterGui/            # Scripts de la consola y la GUI original
  StarterPlayer/         # Teclado y conexión de clientes
templates/
  RoEMU-layout.rbxl      # Jerarquía y GUI; fuentes y payloads vacíos
tools/                  # Reconstrucción verificable del lugar desde src/
sources.json            # Relación exacta entre archivos e instancias de Roblox
project.tree.json       # Inventario completo de las instancias originales
docs/                   # Arquitectura, integración y payloads locales
```

## Reconstruir el proyecto

Se necesita Python 3.11 o posterior y Roblox Studio.

```sh
python -m pip install -r requirements.txt
python tools/build_place.py --output build/RoEMU.rbxl
```

Abre `build/RoEMU.rbxl` en Studio. La construcción restaura las fuentes de `src/`
sobre la plantilla sin rediseñar la GUI ni alterar las propiedades de las demás
instancias. El arranque de un sistema operativo requiere aportar sus payloads
locales. Los marcadores públicos no contienen un sistema arrancable.

Si ya tienes una copia local completa con esta misma jerarquía, puedes actualizar
su código conservando sus payloads, siempre hacia un **archivo nuevo**:

```sh
python tools/build_place.py --template /ruta/local/RoEMU.rbxl \
  --preserve-payloads --output /ruta/local/RoEMU-local.rbxl
```

No añadas ese resultado al repositorio. Consulta [payloads locales](docs/local-payloads.md).

## Estado y límites

La ruta RV32 se ha probado localmente con OpenSBI y CaribeOS hasta Bash interactivo.
La ruta i386 ha ejecutado Windows 95 hasta el escritorio en Roblox Studio usando
firmware y disco externos a este repositorio. La emulación sigue siendo
experimental y considerablemente más lenta que ejecutar el sistema directamente.
Las escrituras del disco PC se conservan en memoria durante la sesión.

CaribeOS es un proyecto experimental de linaje XNU/Darwin para RV32. Esto **no
significa compatibilidad con macOS**, sus aplicaciones o su interfaz propietaria.
El PC no dispone de red de invitado ni de una implementación completa de toda
la arquitectura x86.

Lee [la arquitectura](docs/architecture.md) y [cómo contribuir](CONTRIBUTING.md).
El estado de PowerPC y lo que falta para PS3 se detalla en
[PowerPC64 y perfil PS3](docs/powerpc-ps3.md).
Las licencias y atribuciones existentes se mantienen; no se ha asignado una
licencia global nueva al código. Consulta [NOTICE.md](NOTICE.md).
