# Programa C propio para PowerPC64

`bringup.c` calcula una suma con valores de 64 bits, incluidos valores mayores
de 2⁵³. El resultado esperado es `0103456689ABCDFB` y la función devuelve 42.
No contiene código, firmware ni bibliotecas de Sony.

Compilación de referencia: Clang/LLD 19.1.7 sobre Linux, sin libc:

```sh
mkdir -p build/powerpc
clang --target=powerpc64-unknown-linux-gnu -mcpu=970 -mabi=elfv1 -O1 \
  -ffreestanding -fno-builtin -fno-stack-protector -fno-pic \
  -mno-altivec -mno-vsx -msoft-float \
  -c examples/powerpc/bringup.c -o build/powerpc/bringup.o
ld.lld -m elf64ppc -T examples/powerpc/bringup.ld \
  build/powerpc/bringup.o -o build/powerpc/bringup-linked.elf
python examples/powerpc/pack_elf.py build/powerpc/bringup-linked.elf build/powerpc
```

El empaquetador conserva las direcciones de las secciones asignadas, construye
cargas estáticas y declara explícitamente la ABI ELFv1. Produce también una
variante con el descriptor PPU PS3 de dos palabras de 32 bits. No convierte
un programa Linux en una aplicación PS3 general: este ejemplo es una función
autónoma sin llamadas al sistema, biblioteca, TLS ni inicialización de proceso.
El modelo 970 se usa para validar instrucciones escalares comunes; no equivale
a implementar el procesador Cell.

La prueba `tests/powerpc_owned_probe.luau` contiene únicamente esta variante
propia compacta de 528 bytes, generada con esa versión del compilador.
Con el CLI oficial de Luau:

```sh
luau --codegen -O2 tests/powerpc_elf.luau
```

Comprueba la ejecución real, el checksum, ELFv1/PPU/direct dispatch, BSS, pila,
presupuestos y rechazo atómico de entradas inválidas. El caso de entrada
directa aporta el TOC de este ejemplo explícitamente; no prueba un binario C
ELFv2 compilado de forma independiente. No comprueba un arranque de GameOS.

## Proceso PPU con TLS y llamadas al sistema

`process.c` es otra prueba propia. Recibe `argv`/`envp` y metadatos TLS, comprueba
una variable TLS inicializada y otra inicialmente a cero, modifica valores
mayores de 2⁵³, escribe `ROEMU_PPU_TLS_ARGS_OK` mediante la llamada 403 y termina
con estado 42 mediante la llamada 22.

Se compila con las mismas opciones anteriores, añadiendo
`-ftls-model=local-exec`, y se enlaza con `process.ld`:

```sh
clang --target=powerpc64-unknown-linux-gnu -mcpu=970 -mabi=elfv1 -O1 \
  -ffreestanding -fno-builtin -fno-stack-protector -fno-pic \
  -mno-altivec -mno-vsx -msoft-float -ftls-model=local-exec \
  -c examples/powerpc/process.c -o build/powerpc/process.o
ld.lld -m elf64ppc -T examples/powerpc/process.ld \
  build/powerpc/process.o -o build/powerpc/process-linked.elf
python examples/powerpc/pack_process.py build/powerpc/process-linked.elf build/powerpc
luau --codegen -O2 tests/powerpc_process.luau
```

La muestra compacta incluida en las pruebas tiene 808 bytes. La referencia
RPCS3 utiliza PPU Interpreter (static), vídeo/audio Null y las bibliotecas
`liblv2.sprx:hle` y `libsysmodule.sprx:hle`, para entrar directamente al ELF y
comparar la inicialización HLE. Eso no prueba el arranque mediante bibliotecas
LLE ni GameOS. El ELF con la disposición original y el compacto conservan las
mismas instrucciones y el segmento TLS; solo cambia el empaquetado de archivo.

## Varios hilos y sincronización

`threads.c` crea tres hijos, señala una condición, despierta dos esperadores
mediante difusión, recupera mutex recursivos después de una señal y un
vencimiento, y une los hilos con resultados de 64 bits. También verifica mutex
ligeros, CAS de 64 bits y el contador de tiempo. La entrada adicional `I`
selecciona el protocolo de herencia de prioridad y un hijo de prioridad superior.
Ambas variantes imprimen `ROEMU_PPU_THREADS_COND_OK` y salen con estado 42 en
RoEMU y en la referencia HLE de RPCS3.

Para esta muestra con llamadas entre funciones se necesita un enlazador que
soporte ELFv1, como GNU Binutils para PowerPC64. LLD retiró ese soporte;
[la revisión de LLVM](https://reviews.llvm.org/D46316) documenta la diferencia.
Las dos muestras iniciales verificadas con LLD son funciones autónomas, y no
prueban llamadas ELFv1 generales.

```sh
clang --target=powerpc64-unknown-linux-gnu -mcpu=970 -mabi=elfv1 -O1 \
  -ffreestanding -fno-builtin -fno-stack-protector -fno-pic \
  -mno-altivec -mno-vsx -msoft-float -ftls-model=local-exec \
  -c examples/powerpc/threads.c -o build/powerpc/threads.o
powerpc64-linux-gnu-ld -m elf64ppc -T examples/powerpc/process.ld \
  build/powerpc/threads.o -o build/powerpc/threads-linked.elf
python examples/powerpc/pack_process.py build/powerpc/threads-linked.elf build/powerpc
luau --codegen -O2 tests/powerpc_threads.luau
luau --codegen -O2 tests/powerpc_wait.luau
luau --codegen -O2 tests/powerpc_atomic.luau
```

Referencia de construcción: Clang 19.1.7 y GNU ld 2.44. La muestra compacta
tiene 4 808 bytes. `pack_process.py` adapta los descriptores `.opd` usados por
estas muestras para entregarlos a LV2. Es una adaptación de programas propios
sin SDK ni libc; no convierte de forma general llamadas indirectas ELFv1 en
llamadas indirectas con ABI PS3. El archivo compilado y los fixtures proceden
exclusivamente de este código propio.
