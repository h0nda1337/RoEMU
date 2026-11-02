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
- Reservas `lwarx`/`ldarx`, escrituras condicionales y barreras en el modelo de
  memoria ordenada, además de lectura exacta del contador de tiempo.
- Transferencias de los 32 FPR como bits exactos: cargas/almacenamientos
  simples y dobles, indexados y con actualización; `fmr`, `fneg`, `fabs`,
  `fnabs` y sus formas con CR1. Los movimientos dobles conservan los bits de NaN.
- Precargas `dcbt`/`dcbtst` sin acceso arquitectónico a la dirección sugerida.
- Presupuestos de ejecución y resultados explícitos para instrucciones o
  direcciones que todavía no soporta.

La memoria es una ventana de RAM plana, no un espacio virtual completo de
64 bits. Los accesos exigen alineación natural. Los fallos se devuelven al
anfitrión; todavía no se entregan como excepciones arquitectónicas al invitado.
No se implementan privilegios, MMU, aritmética FPU, AltiVec ni el juego completo
de instrucciones. Los movimientos FPR no implican soporte de operaciones numéricas.
La actualización de CR1 en `fmr.` sigue los bits de estado documentados por
[IBM](https://www.ibm.com/docs/en/aix/7.2.0?topic=set-fmr-floating-move-register-instruction).

`RoEmu_PowerPC_Platform.SelfTest()` ejecuta instrucciones reales de prueba y
comprueba suma, memoria, bucle y precisión de 64 bits. En la validación local,
5 875 casos del subconjunto se contrastaron con un procesador 970 de QEMU,
además de 120 secuencias de reserva/escritura condicional y barreras.
Otros 729 casos contrastan transferencias FPR y precargas, incluidos ceros con
signo, subnormales, infinitos y NaN señalizadores. Las conversiones de formato
en memoria son operaciones de bits de la ISA; no ejecutan aritmética del host.
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
-- cpu:setFloatingRegister(numero, bitsAltos, bitsBajos)
-- cpu:getFloatingRegister(numero) -> bitsAltos, bitsBajos
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
- Parámetros SFO (30): devuelve el bloque de 64 bytes con el identificador
  real del título o `CELL_ENOENT` si falta, sin modificar entonces el búfer.
- Mutex privados: crear/destruir/bloquear/intentar/desbloquear (100–104),
  propietario, recursión, colas FIFO/prioridad, herencia de prioridad y errores.
- Condiciones privadas (105–110): asociación al mutex, espera con liberación
  atómica, señal individual/dirigida, difusión y recuperación del mutex antes
  de devolver el control. La espera conserva la profundidad recursiva.
- Hilos PPU (41, 43–45, 47–49, 52/53): creación detenida, inicio, cesión,
  salida, unión y separación, prioridad y consulta de pila.
- Mutex ligeros del núcleo (95–99/117): objetos y señales, colas de espera,
  intento sin bloqueo, tiempos límite y señal de reintento. El protocolo
  `SYS_SYNC_RETRY` y las condiciones ligeras todavía se detienen explícitamente.
- Esperas de temporizador (141/142) y frecuencia del contador (147).
- Memoria (348/349): reservas reales de 64 KiB/1 MiB dentro de la RAM disponible,
  sin superponer imágenes/pila/TLS, inicialización a cero y liberación.

Los errores CELL se extienden con signo a los 64 bits del registro de retorno.
Los punteros usados por estos servicios se validan contra los segmentos, pila,
TLS y reservas activas. La CPU sigue usando memoria plana: esto no implementa
una MMU ni todas las protecciones de acceso del hardware PS3.

`LoadProcess` admite `paramSFO` como búfer o cadena de bytes de un `PARAM.SFO`
aportado por quien llama. `RoEmu_PS3_SFO.Read` valida PSF 1.01, índices y límites
antes de cargar el proceso; admite texto, enteros little endian y datos binarios.
El límite es 1 MiB y 4 096 entradas. Los formatos desconocidos se rechazan
explícitamente. Los valores se copian al estado del proceso y nunca se inventa
un `TITLE_ID` predeterminado. No se accede a archivos del host desde Luau.

La prueba C propia `metadata.c` verifica el resultado y todos los bytes del
búfer, con metadatos presentes y ausentes, tanto en RoEMU como en RPCS3. Las
pruebas incluyen archivos truncados, punteros inválidos y rechazo de una carga
sin alterar un proceso existente. El planificador guarda los 32 FPR y FPSCR
por hilo; otro ensayo verifica su aislamiento durante 311 cambios de contexto
en un programa compilado de cuatro hilos. `floatingArithmetic` sigue en `false`.

La prueba C de proceso imprime `ROEMU_PPU_TLS_ARGS_OK` y termina con estado 42
tanto en RoEMU como en la entrada directa HLE de RPCS3. Hay 104 comprobaciones
de proceso adicionales, incluidas fallos atómicos de TLS/argumentos, punteros
interiores de reservas, liberación/reutilización, mutex y llamadas pendientes.
No se implementan aún carga PRX/importaciones, IPC ni el entorno completo de
LV2. El selector sigue indicando que PS3 no arranca.

## Planificador y operaciones atómicas

`RoEmu_PS3_Scheduler` ejecuta contextos enteros de hasta 256 hilos sobre una
única CPU virtual. Conserva GPR, PC, LR, CTR, CR y XER; cada hijo recibe una
pila separada y el TLS indicado por el llamador. Al salir libera su pila;
`join` conserva el resultado exacto de 64 bits y consume el recurso del hilo.
La opción `quantum` de `LoadProcess` fija el presupuesto entre intercalaciones
(256 instrucciones por defecto). Se prioriza el número menor y se rota entre
iguales; los mutex de protocolo 3 propagan prioridad a través de sus esperadores.
Este modelo no implementa SMT, ejecución simultánea de PPEs ni ciclos Cell.

Una espera aceptada avanza una vez y aparca el contexto. Si nadie puede
ejecutarse y no hay un tiempo límite, `RunProcess` devuelve `process-waiting`
sin seguir ejecutando instrucciones. Cuando hay un tiempo límite, el reloj
virtual puede avanzar hasta el siguiente vencimiento sin ejecutar un bucle
del invitado. El reloj usa un microsegundo virtual por instrucción retirada;
no representa la velocidad real del host. `mftb`/`mftbu` y la llamada 147 usan
un contador coherente de 80 MHz. Los plazos que exceden la precisión admitida
se detienen explícitamente con `unsupported_timeout`.

Las escrituras condicionales consumen una reserva de 128 bytes; comprueban
dirección, ancho y valor observado, y actualizan CR0. Las escrituras del
invitado en ese bloque, las llamadas al sistema y los cambios de contexto
invalidan la reserva. `sync`, `lwsync`, `eieio` e `isync` respetan el modelo ya
serializado de memoria e instrucciones. No se implementa un subsistema de
cachés físicas ni coherencia entre varios PPEs.

La prueba C propia `threads.c` crea tres hijos y verifica señalización,
difusión a dos esperadores, espera recursiva con vencimiento, resultados de
unión, errores, mutex ligeros, operaciones atómicas y contador de tiempo.
Termina con el mismo mensaje y estado 42 en RoEMU y RPCS3. Se comprueba con
seis tamaños de quantum y dos perfiles de prioridad (577 comprobaciones),
además de 19 comprobaciones de espera y 32 de reservas/contador/barreras.
El programa busca el argumento de perfil entre todos los argumentos y emite
un mensaje distinto para herencia de prioridad. Así se comprueba el perfil
realmente ejecutado incluso con el argumento vacío que inserta RPCS3.

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
invitado y sin inventar metadatos de título, VSH ejecuta 34 336 instrucciones,
crea mutex y condiciones, usa operaciones atómicas, reservas de memoria y
transferencias FPR. Se detiene en `fcfid`, conversión numérica aún pendiente,
en PC `0x0034DE0C`. No llega a la
interfaz ni al arranque completo de GameOS. El
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
