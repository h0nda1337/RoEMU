# Licencias y atribuciones

Este repositorio publica el código y la estructura del proyecto RoEMU bajo el
nombre de repositorio RoEMU. No añade una licencia global ni modifica los avisos
de autoría o licencias que aparezcan en los archivos originales.

La visibilidad pública no concede por sí sola una licencia general para
redistribuir o relicenciar el código. Cada componente conserva las condiciones
que le correspondan; los componentes sin licencia declarada requieren permiso
de su titular para usos no cubiertos por esas condiciones.

Roblox, Windows, Microsoft, RISC-V, OpenSBI, VMware y las demás marcas citadas
pertenecen a sus respectivos titulares. Sus nombres describen plataformas o
compatibilidad técnica; no implican afiliación.

No se distribuyen imágenes de sistemas operativos, boot sectors de Microsoft,
ROMs de SeaBIOS/SeaVGABIOS/OpenSBI ni kernels compilados. Los archivos de payload
deben obtenerse por separado y utilizarse conforme a sus licencias.

RPCS3 se utiliza como referencia local, fijada en
`docs/rpcs3-reference.json`. Su código conserva sus licencias originales en
esa descarga separada; no se incorpora C++ de RPCS3 ni una traducción de su
implementación al motor Luau de este repositorio. El cargador ELF y las
operaciones enteras se implementan de forma independiente. Las muestras
compiladas de las pruebas PowerPC proceden del programa C propio incluido en
`examples/powerpc`, no de firmware PS3.
