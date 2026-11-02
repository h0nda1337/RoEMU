# Arquitectura

Los nombres internos siguen siendo `RoEmu_*` para conservar la integración
original. Cambiar el nombre del repositorio no modifica el logotipo ni la GUI.

## RV32

`ReplicatedStorage/RiscV` contiene el núcleo de CPU, Sv32, cargador ELF,
plataforma, CLINT, PLIC y dispositivos UART/virtio-blk. Los scripts de
`ServerScriptService` conectan el arranque, OpenSBI y la consola. Los payloads
binarios se suministran localmente; sus módulos públicos solo son marcadores.

## PC i386

`ServerStorage/RoEmu_i386_CPU` implementa instrucciones, privilegios,
segmentación, paginación y excepciones. `RoEmu_PC_Machine` conecta la CPU con
RAM, VGA/VBE, PCI, ATA, PIC, PIT/RTC, PS/2 y firmware local.

`RoEmu_PC_Runtime` ejecuta intervalos de trabajo por Heartbeat y conserva margen
para Roblox. Las operaciones REP sobre RAM ordinaria pueden procesarse por
bloques; los cruces de página, solapamientos, MMIO y puntos de depuración
mantienen la ruta del intérprete cuando corresponde. Las ventanas de lectura
de instrucciones se renuevan por instrucción para respetar código modificado.

`RoEmu_PC_FrameStream` omite fotogramas sin cambios y envía las filas modificadas.
`ReplicatedStorage/RoEmu_PC_Pixels` reutiliza el búfer RGBA y una tabla de paleta.
`RoEmu_PC_VideoClient` presenta el framebuffer real del invitado.

## PowerPC64 / PS3

`RoEmu_PowerPC_CPU` y `RoEmu_PowerPC_Platform` exponen una base entera PowerPC64
con RAM plana y una prueba de instrucciones. El perfil PS3 no es arrancable y
declara por separado las capacidades que faltan. Consulta
[PowerPC64 y perfil PS3](powerpc-ps3.md).

## Conectar una interfaz

El controlador ofrece `Choose("rv32")`, `Choose("i386")` y `Status()` desde el
servidor. Se selecciona una arquitectura por sesión; la máquina PC es compartida
por los jugadores de ese servidor.
`Choose("powerpc")` consulta el perfil aún no arrancable y devuelve un estado
explícito sin impedir la selección posterior de otra arquitectura.

`ReplicatedStorage.RoEmu_PCVideo` transporta:

- Servidor → cliente: `(pixels, palette, width, height, format, rectangle?)`.
  `format` es `indexed8` o `rgba8`. `rectangle`, si existe, es `{y, rows}` y
  contiene filas completas de la imagen; `width`/`height` siguen indicando la
  resolución total. Un cambio de paleta o resolución produce un fotograma completo.
- Cliente → servidor: `"frame"` pide un fotograma completo.
- `("pointer", x, y, buttons)` usa coordenadas absolutas entre 0 y 65535.
  Los bits de botones son 1 = izquierdo, 2 = derecho, 4 = central.
- `("mouse", dx, dy, buttons)` conserva la entrada relativa PS/2.
- `("key", scan, pressed, extended)` envía teclas especiales Set 1.

La máquina también expone `queueTextByte`, `queueKey`, `queueMouse` y
`queuePointer`. `RoEmu_PC_Runtime.Pause()` y `Resume()` permiten inspección local.
Estas APIs no sustituyen las validaciones de entrada del servidor.
