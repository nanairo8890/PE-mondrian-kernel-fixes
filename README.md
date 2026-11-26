# Fixes for the PixelExperience-Reborn mondrian kernel

Patches for the mondrian (POCO F5 Pro / Redmi K60) kernel of LF5's PixelExperience-Reborn Android 17 project

Private repository: the base code is LF5's and these patches are for him

## Patches

| Patches | Repository | Base |
|---|---|---|
| `patches/modules/0001-*.patch` | `android_kernel_xiaomi_sm8450-modules` | `f0100b23` (branch `bringup/a17-mondrian-kernel-release-20261126`) |
| `patches/kernel/0001-*.patch` to `0004-*.patch` | `android_kernel_xiaomi_sm8450` | `2efda4cf` (branch `bringup/a17-mondrian-oem-display-coherent-20261115`) |
| `patches/devicetrees/0001-*.patch` | `android_kernel_xiaomi_sm8450-devicetrees` | `547c333c` (branch `bringup/a17-mondrian-stock-dt-reconcile-20261125`) |
| `patches/device-sm8450-common/0001-*.patch` | `android_device_xiaomi_sm8450-common` | `427b0f68` (branch `bringup/a17-mondrian-oem-vendor-os3-20261125`) |
| `patches/device-mondrian/0001-*.patch` | `android_device_xiaomi_mondrian` | `aef7688d` (branch `bringup/a17-mondrian-oem-vendor-os3-20261125`) |

Apply them in order with `git am`:

```bash
git am patches/kernel/*.patch
```

### Kernel release packaging (modules)

Fixes the CI step "Package the mondrian kernel release"

- The stock load lists repeat some lines and `verify_prebuilt.py` rejects duplicates: every module is now written once, in stock order
- Stock keeps 243 modules both in the `vendor_boot` ramdisk and in `vendor_dlkm`, and the packager put each module in one place only: `msm_drm`, `goodix_core`, `spi-msm-geni`, `panel_event_notifier` and others were left out of the normal boot load list
- `vendor_dlkm` now gets what stock has there, what is not in the ramdisk, and the dependencies the first stage does not load
- 3 new tests, all 161 tests of the repository pass

Checked with the stock modules of a mondrian dump: `verify_prebuilt.py` passes, 306 of the 307 `vendor_dlkm` modules end up there and every second stage dependency can be loaded

### Device trees

Removes `xiaomi-touch` from `dt-driver-coverage-allowlist.json` and adds it to the compatibles that must always have a driver, so the coverage check now requires the `xiaomi_touch` driver of the kernel patches. With them, `verify_dt_driver_coverage.py` resolves the node to `drivers/input/touchscreen/xiaomi/xiaomi_touch.c` and `CONFIG_TOUCHSCREEN_XIAOMI_TOUCHFEATURE=m`. Apply it together with the kernel patches, otherwise the coverage check fails for this node

All tests of the repository pass except 3 camera and Wi-Fi tests that need the `upstream/` submodules, which fail the same way without this patch

### Kernel

**0001 Goodix touch fixes**

- A wake gesture (double tap, FOD) could read SPI before the controller resumed, and the event was lost: the IRQ thread now waits for the system resume for up to 700 ms
- A FOD-DOWN in gesture mode left slot 0 pressed if FOD-UP was lost in the reset at unblank: contacts are released when leaving gesture mode
- The DT defines `pmx_ts_active` and `pmx_ts_suspend` but the driver never selected them: it does now, and both stay optional
- With `goodix,require-panel-notifier`, a missing panel now leaves its reason in `devices_deferred`

**0002 to 0004 Fingerprint and touch modes (`xiaomi_touch`)**

The stock `goodix_core` depends on `xiaomi_touch`, which provides `/dev/xiaomi-touch` (touch modes such as `Touch_Fod_Enable` and `Touch_Doubletap_Mode`) and `/sys/class/touch/touch_dev/` (`fod_press_status`, `gesture_single_tap_state`, `suspend_state`). The ROM ships the stock `mfp-daemon` and `vendor.xiaomi.hw.touchfeature@1.0`, which use that interface. Xiaomi did not publish it in `mondrian-s-oss`

- 0002 imports it unchanged from the official `MiCode/Xiaomi_Kernel_OpenSource` branch `mayfly-s-oss` (Xiaomi 12S, SM8475, Linux 5.10, commit `fa4513e6`) and builds it as a module. The mondrian DT already has its `xiaomi-touch` node
- 0003 fixes it for Clang (`-Wstrict-prototypes`), a NULL dereference when the touch driver registers before the node probes, a NULL device in the single tap notification, and stops printing kernel addresses
- 0004 connects the Goodix driver to it, as Xiaomi's own GT9916 driver (`marble-s-oss` `goodix_9916`) does, in a new file `goodix_ts_xiaomi.c`:
  - double tap, FOD and AOD/FOD icon modes set the gesture mask
  - a mode change while the touch is asleep is applied at once (wake and suspend again under the PM lock)
  - `fod_press_status` follows FOD-DOWN/FOD-UP with the screen off and the fingerprint flag of the touch events with the screen on
  - single tap notifies `gesture_single_tap_state` and the suspend state follows the touch
  - without `xiaomi_touch` the glue is compiled out

Both modules build without warnings (Clang r584948, mondrian GKI config with Full LTO and CFI), `goodix_core` depends on `xiaomi_touch` as the stock module, and `tools/verify_mondrian_goodix.py` passes

The stock OS3 module also has THP, knock and touch sensor nodes that are in no published Xiaomi source; the Goodix touch does not use them

### ROM: load the vendor_dlkm modules

Nothing in the ROM loaded the modules of `vendor_dlkm`, so display, touch, Wi-Fi, audio, video, camera and data drivers never loaded in a normal boot

- **sm8450-common:** new `rootdir/etc/init.vendor_dlkm.rc`, an own `vendor.modprobe` service that runs the platform `/vendor/bin/modprobe -b -s --all=/vendor_dlkm/lib/modules/modules.load` in AOSP's `vendor_modprobe` domain at early-init, as stock starts its loader, and sets `vendor.all.modules.ready`. No new SELinux policy is needed and the stock Qualcomm script (marked confidential and proprietary) is not used. It lifts the `vendor.modprobe` gate of `init-service-qualification.json` and adds a test for the service, its domain, its install and the first stage mount of `vendor_dlkm`. All 38 tests pass
- **mondrian:** `BoardConfig.mk` installs the stock `modules.blocklist` of the release in the `vendor_boot` ramdisk and in `vendor_dlkm`. All 13 tests pass

`docs/rom-module-loading.md` has the background, the checks against the AOSP 17 sources of the manifest and how to check it on the phone

## Status

- Nothing here has been tested on the phone yet
- Game mode and the other touch tuning modes are stored but not sent to the chip

## Tools

`tools/build_touch_modules.sh` builds only `xiaomi_touch` and the Goodix driver, to check that they compile

```bash
W=<folder with kernel/ and modules/> CLANG_BIN=<clang/bin> bash tools/build_touch_modules.sh
```

## Credits

- LF5 (Anatoly), author of the PixelExperience-Reborn kernel, modules and device trees for mondrian
- Xiaomi, `xiaomi_touch` and the reference GT9916 integration (GPL)
- Nanairo8890, these patches
