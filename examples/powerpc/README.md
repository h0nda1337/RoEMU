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
