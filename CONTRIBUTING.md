# Contribuir

1. Conserva los nombres de instancias y las rutas de `sources.json`: los módulos
   se enlazan mediante esas rutas dentro de Roblox.
2. Haz los cambios de código en `src/` y reconstruye el lugar con
   `python tools/build_place.py --output build/EoEMU.rbxl`.
3. Describe el comportamiento anterior, el nuevo y las comprobaciones realizadas.
   Para cambios en CPU/MMU, incluye instrucciones y estados mínimos reproducibles.
4. No envíes discos, ROMs, sistemas operativos, claves de licencia, credenciales
   ni registros que contengan datos personales. Un fallo puede describirse con
   un caso pequeño y datos sintéticos.

Los resultados medidos deben indicar el entorno y distinguir una operación
aislada del tiempo de arranque completo. No atribuyas a Windows o al kernel un
fallo del emulador sin una reproducción que permita distinguirlos.
