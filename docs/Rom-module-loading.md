# Load the vendor_dlkm modules in the mondrian ROM

Status: implemented in `patches/device-sm8450-common` and `patches/device-mondrian` with the approach of the "Final approach" section below. The sections in between are the first proposal, kept for the background. Nothing here is built or tested on hardware. Based on the device trees `aef7688d` (mondrian) and `427b0f68` (sm8450-common), manifest `569c63ab` and the kernel release layout of the packaging patch in this repository

## The problem

- `BoardConfig.mk` installs the release modules the stock way: first stage and recovery from the `vendor_boot` ramdisk, everything else in `vendor_dlkm` with `vendor_dlkm/lib/modules/modules.load`
- Android only loads the first stage list by itself. Nothing in the ROM loads `vendor_dlkm`: there is no `vendor_modprobe.sh`, no `vendor.modprobe` service and no policy for it. `init-service-qualification.json` already lists `vendor.modprobe` as `blocked_until_kernel_modules_abi`
- Without it, about 300 modules never load in a normal boot: display (`msm_drm`), touch (`goodix_core`, `xiaomi_touch`), Wi-Fi, audio, video, camera, IPA/RMNET and the rest

## What stock OS3 does

Stock uses Qualcomm's loader, the same one as other SM8450/SM8475 trees (for example `cupid-development/android_device_xiaomi_sm8450-common` and `LineageOS/android_device_fairphone_FP5`):

- `/vendor/bin/vendor_modprobe.sh` reads `/vendor_dlkm/lib/modules/modules.load`, drops the names in `modules.blocklist`, loads the first module, then the rest in parallel with `modprobe -b -s -d <dir>`, and sets `vendor.all.modules.ready=1`
- `init.qti.kernel.rc` starts it at `early-init`:

```
service vendor.modprobe /vendor/bin/vendor_modprobe.sh
    class main
    user root
    group root system
    disabled
    stdio_to_kmsg
    seclabel u:r:vendor_modprobe:s0
    oneshot

on early-init
    start vendor.modprobe
```

- The script uses `modules.blocklist`, so the blocklist the packager ships matters

## Proposed changes

### 1. Ship the loader (sm8450-common)

Take `vendor/bin/vendor_modprobe.sh` from OS3.0.8.0 into `proprietary-files.txt` with its sha256, like the other stock files. It is a Qualcomm BSD-3 script, so a copy in `rootdir/bin/` is also possible, as cupid does

Add a small rc of the device tree with only the service above, instead of the whole stock `init.qti.kernel.rc`, which also starts post-boot scripts and services that are not shipped yet:

```make
# common.mk
PRODUCT_COPY_FILES += \
    $(COMMON_PATH)/rootdir/etc/init.mondrian.modules.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.mondrian.modules.rc
```

### 2. Install the blocklist (mondrian BoardConfig.mk)

The release already carries `modules.blocklist` next to each load list, but `BoardConfig.mk` does not pass it, so it never reaches the images:

```make
BOARD_VENDOR_KERNEL_MODULES_BLOCKLIST_FILE := $(KERNEL_PATH)/vendor_dlkm/modules.blocklist
BOARD_VENDOR_RAMDISK_KERNEL_MODULES_BLOCKLIST_FILE := $(KERNEL_PATH)/vendor_ramdisk/modules.blocklist
```

The build then runs depmod and writes `modules.dep`, `modules.alias`, `modules.load` and `modules.blocklist` into `vendor_dlkm/lib/modules`, which is what `modprobe -d` needs

Checked in `build/make` `core/Makefile` (branch `seventeen`): both variables exist (`BOARD_$(1)_KERNEL_MODULES_BLOCKLIST_FILE`) and the build only checks that every line is `blocklist <module>`. The stock `modules.blocklist` passes that check

### 3. SELinux

The mondrian manifest does not include `device_qcom_sepolicy_vndr_sm8450` (it is only in `snippets/pixel-caf.xml`, which `aosp17_pe_mondrian_build.xml` does not include), and the device trees have no sepolicy yet. AOSP already defines the `vendor_modprobe` domain with permission to load modules from `vendor` and `vendor_dlkm`. Two options:

- **A, full Qualcomm policy:** add `device/qcom/sepolicy_vndr/sm8450` to the manifest and include it. It labels the script `vendor_modinstall-sh_exec` and has the transition in `generic/vendor/common/vendor_modprobe.te`. This is the long term path, but it brings the whole vendor policy at once
- **B, minimal policy in sm8450-common** (suggested for the first boot), taken from Qualcomm's rules. Checked against `system_sepolicy` `f12e84e0` (the revision in the manifest): `vendor/vendor_modprobe.te` already allows `module_load` on `vendor_file`, `/vendor_dlkm` is labeled `vendor_file`, and `vendor_modprobe_prop` is not defined by AOSP, so it does not clash:

```
# sepolicy/vendor/vendor_modprobe.te
type vendor_modprobe_sh_exec, exec_type, vendor_file_type, file_type;
domain_auto_trans(init, vendor_modprobe_sh_exec, vendor_modprobe)
allow vendor_modprobe vendor_shell_exec:file rx_file_perms;
allow vendor_modprobe vendor_toolbox_exec:file rx_file_perms;
allow vendor_modprobe proc_version:file r_file_perms;
set_prop(vendor_modprobe, vendor_modprobe_prop)

# sepolicy/vendor/property.te
vendor_internal_prop(vendor_modprobe_prop)

# sepolicy/vendor/property_contexts
vendor.all.modules.ready    u:object_r:vendor_modprobe_prop:s0 exact int

# sepolicy/vendor/file_contexts
/vendor/bin/vendor_modprobe\.sh    u:object_r:vendor_modprobe_sh_exec:s0
```

```make
# BoardConfigCommon.mk
BOARD_VENDOR_SEPOLICY_DIRS += $(COMMON_PATH)/sepolicy/vendor
```

With `seclabel u:r:vendor_modprobe:s0` in the rc, the `domain_auto_trans` line is not needed. It is kept so a stock rc that relies on the transition also works

## Final approach (what the patches do)

The first proposal above used the stock Qualcomm `vendor_modprobe.sh`. That script is marked "Confidential and Proprietary - Qualcomm Technologies, Inc.", so it should not be copied as source, and only does a shell loop over `modules.load`. The patches use the platform instead, checked against `system_core` `8e0f22aa` of the manifest:

- `toolbox/modprobe.cpp`: `--all=<file>` loads the list through `Modprobe::LoadListedModules(false)`, which loads every module with its dependencies, skips blocklisted ones and goes on when one fails; `-b` applies `modules.blocklist`; `-s` also logs to the kernel log
- `/vendor/bin/modprobe` is a symlink of `toolbox_vendor`
- `system_sepolicy` `vendor/vendor_modprobe.te` has `domain_trans(init, vendor_toolbox_exec, vendor_modprobe)` and allows `module_load` on `vendor_file`, which is the label of `/vendor_dlkm`, so `seclabel u:r:vendor_modprobe:s0` works with no new policy
- First stage init (`Modprobe` constructor) uses the blocklist by default
- `fstab.qcom` mounts `vendor_dlkm` in first stage, so it is there at early-init

## How to check it on the phone

```
getprop vendor.all.modules.ready                 # 1
cat /proc/modules | wc -l                        # about 400, as stock
lsmod | grep -E 'msm_drm|goodix_core|xiaomi_touch|qca_cld3'
dmesg | grep -i -E 'modprobe|avc: denied.*vendor_modprobe'
ls /dev/xiaomi-touch /sys/class/touch/touch_dev/fod_press_status
```

## Open points

- The exact text of the stock `vendor_modprobe.sh` and `init.qti.kernel.rc` of OS3.0.8.0 was not read here; the description above comes from Qualcomm's public copy used by other SM8450 trees
- `vendor.all.modules.ready` is used by other stock rc files to start services that need the modules; check them when they are added
- `msm-cvp.ko` is in the stock lists but should not be built: `msm-eva` (already built by the CI) is Qualcomm's current driver for the same `qcom,waipio-cvp` device and also matches the `qcom,msm-cvp,*` child nodes, while the old `msm-cvp` (cvp21) only knows `qcom,msm-cvp21,*` children and could take the device first if both were loaded. Nothing in stock depends on it
