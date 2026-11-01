# Payloads locales

El código del emulador y los binarios del sistema invitado son componentes
distintos. Este repositorio solo incluye el primero y su estructura de Roblox.

`sources.json` marca con `external_payload: true` los módulos que contenían
firmware, kernels, contenedores de disco o metadatos privados del disco Windows.
Sus rutas permanecen en `src/`, pero su contenido público es un marcador. Los
valores StringValue de la plantilla están vacíos, incluidos los fragmentos de
disco y las ROMs PC. El árbol completo aparece en `project.tree.json`.

Para seguir trabajando con una copia privada completa, usa esa copia como
`--template` y añade `--preserve-payloads`. El constructor omite los marcadores
externos al aplicar las fuentes, conserva los valores locales y escribe otro
archivo. No modifica el archivo de entrada.

```sh
python tools/build_place.py --template /ruta/local/RoEMU.rbxl \
  --preserve-payloads --output /ruta/local/RoEMU-local.rbxl
```

La plantilla local debe tener la misma jerarquía y los módulos de esta versión.
No se ofrecen descargas automáticas de sistemas operativos ni de sus licencias.
Los hashes y tamaños históricos en manifiestos no significan que sus bytes se
incluyan en el repositorio.

La política de `.gitignore` evita añadir por accidente los formatos comunes de
disco/firmware y los lugares de trabajo privados. La única excepción `.rbxl`
versionada es `templates/RoEMU-layout.rbxl`: se verificó sin fuentes ni payloads.
No utilices `git add -f` para incorporar binarios locales.
