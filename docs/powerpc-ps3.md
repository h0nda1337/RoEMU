# PowerPC64 y perfil PS3

El selector incluye **PowerPC / CellOS–GameOS** con la etiqueta «En desarrollo».
Su acción consulta el estado de compatibilidad. No inicia firmware PS3 ni
consume la selección de arquitectura: después se puede elegir RV32 o i386.

## Qué funciona

`ServerStorage/RoEmu_PowerPC_CPU` es una base de intérprete PowerPC64 con:

- 32 registros de 64 bits representados mediante pares de palabras de 32 bits,
  para conservar exactamente valores mayores de 2⁵³ en Luau.
- Memoria plana big endian; cargas/almacenamientos enteros de 8/16/32/64 bits
  del subconjunto implementado y formas de actualización de registros base.
- Suma, operaciones lógicas, comparaciones, CR, LR, CTR, imagen de XER y saltos
  directos/condicionales, incluidos bucles mediante CTR y retorno por LR.
- Presupuestos de ejecución y resultados explícitos para instrucciones o
  direcciones que todavía no soporta.

La memoria es una ventana de RAM plana, no un espacio virtual completo de
64 bits. Los accesos exigen alineación natural. Los fallos se devuelven al
anfitrión; todavía no se entregan como excepciones arquitectónicas al invitado.
No se implementan privilegios, MMU, FPU, AltiVec ni el juego completo de instrucciones.

`RoEmu_PowerPC_Platform.SelfTest()` ejecuta instrucciones reales de prueba y
comprueba suma, memoria, bucle y precisión de 64 bits. En la validación local,
1 243 casos del subconjunto se contrastaron con un procesador 970 de QEMU.
Ese contraste no certifica una implementación de Cell ni de toda PowerPC.

## API sin dependencia de la GUI

```lua
local Platform = require(game.ServerStorage.RoEmu_PowerPC_Platform)
local status = Platform.Status() -- bootSupported = false
local passed, report = Platform.SelfTest()

local cpu = Platform.new({ ramBytes = 1024 * 1024, entry = 0 })
-- cpu:load(bufferConProgramaPropio, direccionAlineada)
-- cpu:setRegister(numero, palabraAlta, palabraBaja)
-- cpu:getRegister(numero) -> palabraAlta, palabraBaja
-- cpu:step() / cpu:run(presupuesto)
```

`RoEmu_BootController.Choose("powerpc")`, también accesible como `"ppc64"`,
devuelve `false` y el código `powerpc-platform-incomplete`. No marca la máquina
como iniciada. `Status().powerpc` expone el estado sin asignar una CPU nueva.

## Por qué esto todavía no ejecuta GameOS

La PS3 combina un PPE de PowerPC de 64 bits con SPEs. Las SPU de los SPEs usan
su propio juego de instrucciones, memoria local y transferencias mediante MFC;
añadir una CPU PowerPC genérica no implementa esas piezas. La documentación de
[arquitectura Cell de Sony](https://www.kernel.org/pub/linux/kernel/people/geoff/cell/ps3-linux-docs/CellProgrammingTutorial/BasicsOfCellArchitecture.html)
describe esta separación.

Además hacen falta gráficos RSX, interrupciones, almacenamiento y servicios de
plataforma/hipervisor PS3. Incluso Linux para PS3 depende de dispositivos y
recursos virtualizados por el hipervisor, como explica la
[documentación de plataforma de Sony](https://cdn.kernel.org/pub/linux/kernel/people/geoff/cell/ps3-linux-docs/LinuxKernelOverview.html).
No se implementan LV1/LV2, cadena de arranque PS3 ni cargadores SELF/PUP.
CellOS/GameOS sigue marcado como **no compatible y no arrancable**.

## Orden de desarrollo propuesto

1. Ampliar y validar ISA PowerPC64, excepciones, privilegios, MMU y ELF64.
2. Construir una plataforma sencilla con consola, interrupciones y disco para
   probar primero software propio y después un sistema PowerPC apropiado.
3. Implementar y validar PPE/SMT y SPE/SPU/MFC de Cell.
4. Desarrollar plataforma PS3, RSX y los servicios de arranque necesarios.
5. Evaluar entonces un arranque real de GameOS y medir su viabilidad en Luau.

No se promete un plazo de arranque PS3 ni rendimiento interactivo. No se
incluyen ni descargan firmware Sony, imágenes de consola, juegos o claves.
