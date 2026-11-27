# Fixes for the PixelExperience-Reborn mondrian kernel

Patches for the mondrian (POCO F5 Pro / Redmi K60) kernel of LF5's PixelExperience-Reborn Android 17 project

The base code is LF5's and these patches are for him to review and apply

## Status (27-nov-2026)

- Modules packaging: already in LF5's branch (`855b449` and `f575a30`), the patch here is kept only for reference
- Module blocklists: already in LF5's branch (`519319d`)
- Loading `vendor_dlkm`: LF5 uses the stock `vendor_modprobe.sh` with `init.qti.kernel.rc` (`cc10c35`), so the `device-sm8450-common` patch is no longer needed
- Kernel touch patches: moved to the new kernel branch `641c9a89` (zero stack init, A510 erratum 2051678, CRNG trust, UFS HPB); the only conflict was one line of `mondrian_GKI.config`. Both modules build without warnings, `goodix_core` depends on `xiaomi_touch` and `tools/verify_mondrian_goodix.py` passes
- Device trees patches: still apply on `547c333c`, the current head

## Patches

| Patches | Repository | Base |
|---|---|---|
| `patches/modules/0001-*.patch` | `android_kernel_xiaomi_sm8450-modules` | `f0100b23` (branch `bringup/a17-mondrian-kernel-release-20261126`) |
| `patches/kernel/0001-*.patch` to `0004-*.patch` | `android_kernel_xiaomi_sm8450` | `641c9a89` (branch `bringup/a17-mondrian-kernel-hardening-20261126`) |
| `patches/devicetrees/0001-*.patch` and `0002-*.patch` | `android_kernel_xiaomi_sm8450-devicetrees` | `547c333c` (branch `bringup/a17-mondrian-stock-dt-reconcile-20261125`) |
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

**0001** removes `xiaomi-touch` from `dt-driver-coverage-allowlist.json` and adds it to the compatibles that must always have a driver, so the coverage check now requires the `xiaomi_touch` driver of the kernel patches. With them, `verify_dt_driver_coverage.py` resolves the node to `drivers/input/touchscreen/xiaomi/xiaomi_touch.c` and `CONFIG_TOUCHSCREEN_XIAOMI_TOUCHFEATURE=m`. Apply it together with the kernel patches, otherwise the coverage check fails for this node

All tests of the repository pass except 3 camera and Wi-Fi tests that need the `upstream/` submodules, which fail the same way without this patch

**0002** makes the MMRM check of `tools/build_mondrian_multimedia.py` accept both ways dtc prints a string list. dtc up to 1.7.0 (Ubuntu 24.04, the CI) decompiles `mm-rail-corners` as `"lowsvs\0svs..."` and newer releases (seen with 1.8.1) as `"lowsvs", "svs", ...`, so on a newer host the build stopped with "MMRM node differs from the stock CAPE values" although the DTB is correct. It does not depend on the kernel patches

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

`docs/Rom-module-loading.md` has the background, the checks against the AOSP 17 sources of the manifest and how to check it on the phone

## Status

- Nothing here has been tested on the phone yet
- Game mode and the other touch tuning modes are stored but not sent to the chip

## Tools

`tools/Build_touch_modules.sh` builds only `xiaomi_touch` and the Goodix driver, to check that they compile

```bash
W=<folder with kernel/ and modules/> CLANG_BIN=<clang/bin> bash tools/Build_touch_modules.sh
```

`tools/Compilar_ci_local.sh` replays the CI up to step 32 ("Package the mondrian kernel release") with these patches applied. The stages are `prep config kernel mmrm wlan display camera media data dt package` and each one leaves a mark, so a finished stage is skipped on the next run

```bash
W=<folder with kernel/ modules/ devicetrees/ google-clang/> VERIFIER_REPO=<clone of android_device_xiaomi_mondrian-kernel> THIN=1 bash tools/Compilar_ci_local.sh
```

- `THIN=1` switches Full LTO to ThinLTO, needed with 15 GB of RAM
- `prep` moves the kernel and devicetrees pins to the local commits, without committing
- The comments of the script are in Spanish
- To repeat `mmrm`, `wlan` and `camera` first restore the original sources with `git checkout -- .` in `upstream/xiaomi-wlan` and `xiaomi-camera-source`

`docs/Local-build-result.txt` has the result of the last full run: both `[PASS]` of `package_mondrian_kernel_release.py` and `verify_prebuilt.py`, with `xiaomi_touch.ko` and `goodix_core.ko` in `vendor_dlkm`

## Credits

- LF5 (Anatoly), author of the PixelExperience-Reborn kernel, modules and device trees for mondrian
- Xiaomi, `xiaomi_touch` and the reference GT9916 integration (GPL)
- Nanairo8890, these patches
