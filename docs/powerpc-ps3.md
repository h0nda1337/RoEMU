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
- Rotaciones con máscara e inserción de 32/64 bits, desplazamientos lógicos y
  aritméticos, y actualización del acarreo de XER para estos últimos.
- Cargas/almacenamientos indexados, aritmética con acarreo y desbordamiento,
  multiplicación/división enteras exactas, extensión de signo y manipulación CR.
- Presupuestos de ejecución y resultados explícitos para instrucciones o
  direcciones que todavía no soporta.

La memoria es una ventana de RAM plana, no un espacio virtual completo de
64 bits. Los accesos exigen alineación natural. Los fallos se devuelven al
anfitrión; todavía no se entregan como excepciones arquitectónicas al invitado.
No se implementan privilegios, MMU, FPU, AltiVec ni el juego completo de instrucciones.

`RoEmu_PowerPC_Platform.SelfTest()` ejecuta instrucciones reales de prueba y
comprueba suma, memoria, bucle y precisión de 64 bits. En la validación local,
5 795 casos del subconjunto se contrastaron con un procesador 970 de QEMU.
Ese contraste no certifica una implementación de Cell ni de toda PowerPC.

`RoEmu_PowerPC_ELF64` carga ELF64 big endian estáticos (`ET_EXEC`, `EM_PPC64`)
en RAM plana. Reconoce ELFv1, entrada directa declarada como ABI 2 y el
descriptor PPU de PS3. Valida todos los segmentos antes de modificar el estado,
copia los datos, limpia BSS y prepara una pila autónoma. Rechaza SELF, enlaces
dinámicos, segmentos superpuestos y direcciones fuera de la ventana RAM.
TLS requiere una inicialización de proceso explícita: puede copiarse a un
bloque privado con r13 o entregarse al programa para que lo inicialice.

La prueba C propia de [examples/powerpc](../examples/powerpc/README.md) produjo
el checksum exacto `0103456689ABCDFB` y retornó 42 en Luau y Roblox Studio.
Las pruebas incluyen 1 097 rechazos atómicos; una carga rechazada conserva los
registros, la RAM y la imagen previa. Esto valida una llamada autónoma, sin
simular la inicialización de un proceso o sistema operativo PS3.

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

local loaded, image = Platform.LoadELF(cpu, bufferConELFPropio)
if loaded then
    local result = Platform.RunStandalone(cpu, 1000)
    -- result.kind: returned, budget, unsupported_instruction o memory_fault
end
```

`LoadELF` admite `entryMode`, `stackTop`, `stackBytes` y `returnAddress`.
Por defecto deduce la ABI del encabezado, reserva 64 KiB al final de la RAM y
usa la dirección 0 como retorno al anfitrión. El ELF no puede ocupar esa
dirección ni la pila reservada. `RunStandalone` admite continuación por
presupuestos de hasta un millón de instrucciones. Las llamadas al sistema
requieren el anfitrión de proceso descrito a continuación.

## Proceso PPU experimental

`RoEmu_PS3_Process` prepara un único proceso PPU: argumentos y entorno con
punteros big endian de 64 bits, pila alineada, TOC, identificadores y los ocho
registros de argumentos de entrada. El segmento TLS se valida contra un LOAD
y sus límites antes de modificar la máquina. El modo `static` copia `.tdata`,
limpia `.tbss` y el área de sistema, conserva la alineación y establece r13 con
el desplazamiento TLS de `0x7000`. `guest` deja r13 a cero y entrega la imagen,
su tamaño y su reserva en los registros de entrada para programas que se
inicializan por sí mismos, como VSH.

```lua
local ok, process = Platform.LoadProcess(cpu, bufferConELFPropio, {
    argv = {"/app_home/process.elf", "argumento"},
    envp = {"ALPHA=42"},
    tlsMode = "static", -- "guest" para inicialización por el propio programa
})
if ok then
    local stop = Platform.RunProcess(cpu, 10000)
    print(stop.kind, stop.exitStatus)
    print(Platform.ProcessConsole(cpu))
end
```

La instrucción `sc 0` genera un evento preciso. Solo el anfitrión confirma una
llamada implementada y avanza PC/contador. Una llamada desconocida devuelve
`unimplemented_syscall`, conservando el punto de parada. Se implementan:

- Identificador de proceso (1), salida (22) y escritura TTY (403).
- Mutex privados: crear/destruir/bloquear/intentar/desbloquear (100–104),
  propietario, recursión y errores. IPC y espera con otros hilos se detienen
  expresamente; todavía no existe un planificador multihilo.
- Memoria (348/349): reservas reales de 64 KiB/1 MiB dentro de la RAM disponible,
  sin superponer imágenes/pila/TLS, inicialización a cero y liberación.

Los errores CELL se extienden con signo a los 64 bits del registro de retorno.
Los punteros usados por estos servicios se validan contra los segmentos, pila,
TLS y reservas activas. La CPU sigue usando memoria plana: esto no implementa
una MMU ni todas las protecciones de acceso del hardware PS3.

La prueba C de proceso imprime `ROEMU_PPU_TLS_ARGS_OK` y termina con estado 42
tanto en RoEMU como en la entrada directa HLE de RPCS3. Hay 104 comprobaciones
de proceso adicionales, incluidas fallos atómicos de TLS/argumentos, punteros
interiores de reservas, liberación/reutilización, mutex y llamadas pendientes.
No se implementan aún carga PRX/importaciones, condiciones, otros hilos ni el
entorno completo de LV2. El selector sigue indicando que PS3 no arranca.

## Referencia RPCS3

Se descargaron el código fuente oficial y el ejecutable de Windows de
[RPCS3](https://github.com/RPCS3/rpcs3), fijados en el commit
`ad468a13f6374f364467a9e4988e95938c37bb42` (0.0.43-20551). Los datos de versión
y SHA-256 están en [rpcs3-reference.json](rpcs3-reference.json).
No se ha incorporado su C++ ni una traducción de su implementación al motor.

La referencia nativa ejecutó el mismo cálculo propio y verificó el checksum
antes de terminar mediante la llamada LV2 de salida de proceso, con estado 42.
Se utilizó un perfil portátil local, sin interfaz, con el firmware oficial
4.93 de [Sony](https://www.playstation.com/es-es/support/hardware/ps3/system-software/).
Ni RPCS3 completo ni ese firmware se incluyen en este repositorio o en el
selector de RoEMU.

La estructura PPU `ppu_func_opd_t` de RPCS3 contiene dos direcciones big endian
de 32 bits. Se implementa por separado del descriptor genérico ELFv1, que usa
tres campos de 64 bits. Confundirlos impide llegar a la entrada correcta.
RPCS3 aporta una referencia de ejecución y servicios HLE; su descarga no
implementa automáticamente el arranque de firmware, LV1/LV2 o GameOS en Luau.

La inspección local de `vsh.self` 4.93 mediante RPCS3 permitió obtener su ELF
y probarlo contra el motor real de RoEMU. Con inicialización TLS a cargo del
invitado, VSH ejecuta 2 163 instrucciones, crea mutex privados y obtiene una
reserva de 64 KiB. Se detiene en la llamada 105 (`sys_cond_create`), todavía no
implementada. No llega a la interfaz ni al arranque completo de GameOS. El
firmware no se incluye en los ejemplos, la plantilla ni el lugar distribuible.

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

No se promete un plazo de arranque PS3 ni rendimiento interactivo. El firmware
oficial usado como referencia y todos los sistemas completos permanecen
exclusivamente en el espacio local; no se distribuyen con el código fuente.
