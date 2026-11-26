# Arreglos para el kernel de PixelExperience-Reborn en mondrian

Parches para el kernel de mondrian (POCO F5 Pro / Redmi K60) del proyecto PixelExperience-Reborn de LF5, Android 17

Repositorio privado: el código base es de LF5 y estos parches son para él

## Parches

| Parche | Repositorio | Se aplica sobre |
|---|---|---|
| `patches/modules/0001-kernel-release-ship-stock-dual-placed-modules-in-ven.patch` | `android_kernel_xiaomi_sm8450-modules` | `f0100b23` (rama `bringup/a17-mondrian-kernel-release-20261126`) |
| `patches/kernel/0001-input-goodix-wait-for-system-resume-in-the-IRQ-relea.patch` | `android_kernel_xiaomi_sm8450` | `2efda4cf` (rama `bringup/a17-mondrian-oem-display-coherent-20261115`) |

Se aplican con `git am`:

```bash
git am patches/modules/0001-kernel-release-ship-stock-dual-placed-modules-in-ven.patch
```

### Empaquetado del kernel (modules)

Arregla el paso "Package the mondrian kernel release" del CI

- Las listas de carga stock traen líneas repetidas y `verify_prebuilt.py` las rechaza: ahora se escribe cada módulo una vez, en el orden de stock
- Stock tiene 243 módulos en el ramdisk de `vendor_boot` y también en `vendor_dlkm`, y el empaquetador los ponía en un solo lugar: `msm_drm`, `goodix_core`, `spi-msm-geni`, `panel_event_notifier` y otros quedaban fuera de la carga normal
- `vendor_dlkm` recibe ahora lo que stock tiene ahí, lo que no está en el ramdisk y las dependencias que la primera etapa no carga
- 3 pruebas nuevas, pasan las 161 del repositorio

Comprobado con los módulos stock de un volcado de mondrian: `verify_prebuilt.py` pasa, 306 de los 307 módulos de `vendor_dlkm` quedan ahí y todas las dependencias de la segunda etapa se pueden cargar

### Táctil Goodix (kernel)

- Al despertar con doble toque o huella, el IRQ podía leer el SPI antes de que el controlador volviera y se perdía el gesto: ahora espera hasta 700 ms al resume del sistema
- Un FOD-DOWN en modo gestos dejaba el slot 0 presionado si se perdía el FOD-UP en el reset al encender la pantalla: ahora se sueltan los toques al salir del modo gestos
- El DT define `pmx_ts_active` y `pmx_ts_suspend` pero el driver nunca los aplicaba: ahora sí, y siguen siendo opcionales
- Con `goodix,require-panel-notifier`, si el panel no aparece queda el motivo en `devices_deferred`

Compila como módulo sin avisos (Clang r584948, configuración GKI de mondrian con Full LTO y CFI)

## Estado

- Nada de esto se probó en el teléfono
- Falta en el kernel la interfaz `xiaomi_touch`: en stock `goodix_core` depende de ella y es lo que usan la huella y el doble toque en los HAL de Xiaomi

## Herramientas

`tools/compilar_goodix.sh` compila solo el driver del táctil para comprobar que compila

```bash
W=<carpeta con kernel/ y modules/> CLANG_BIN=<clang/bin> bash tools/compilar_goodix.sh
```

## Créditos

- LF5 (Anatoly), autor del kernel, los módulos y los devicetrees de PixelExperience-Reborn para mondrian
- Nanairo8890, estos parches
