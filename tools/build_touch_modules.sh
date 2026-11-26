#!/usr/bin/env bash
# Builds only xiaomi_touch and the Goodix driver to check that they compile
# Usage: W=<folder with kernel/ and modules/> CLANG_BIN=<clang/bin> bash build_touch_modules.sh
set -euo pipefail
W=${W:-$(pwd)}
K=$W/kernel; O=$W/out-kernel
export PATH=${CLANG_BIN:?set CLANG_BIN to the clang bin folder}:$PATH
export LLVM=1 LLVM_IAS=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
# OpenSSL 4 has no ENGINE: this only affects host tools
M=(make -C "$K" O="$O" "HOSTCFLAGS=-DOPENSSL_IS_BORINGSSL -DOPENSSL_NO_ENGINE")
if [ ! -s $O/.config ]; then
  mkdir -p $O
  "${M[@]}" gki_defconfig >/dev/null; "${M[@]}" gki_defconfig >/dev/null
  bash $K/scripts/kconfig/merge_config.sh -m -r -O $O $O/.config \
    $K/arch/arm64/configs/vendor/mondrian_GKI.config $W/modules/tools/config/mondrian_gki_hardening.config >/dev/null
  "${M[@]}" olddefconfig >/dev/null
fi
grep -E '^CONFIG_(TOUCHSCREEN_GOODIX_BRL|TOUCHSCREEN_XIAOMI_TOUCHFEATURE|QCOM_PANEL_EVENT_NOTIFIER|LTO_CLANG_FULL|CFI_CLANG|PINCTRL)=' $O/.config
"${M[@]}" -j12 modules_prepare >/dev/null
X=$O/drivers/input/touchscreen/xiaomi
"${M[@]}" -j12 KBUILD_MODPOST_WARN=1 M=drivers/input/touchscreen/xiaomi modules 2>&1 | grep -v -E '^\s*(CC|LD|AR|MODPOST|  )' || true
"${M[@]}" -j12 KBUILD_MODPOST_WARN=1 KBUILD_EXTRA_SYMBOLS=$X/Module.symvers M=drivers/input/touchscreen/goodix_berlin_driver modules 2>&1 | grep -v -E '^\s*(CC|LD|AR|MODPOST|  )' || true
ls -la $X/*.ko $O/drivers/input/touchscreen/goodix_berlin_driver/*.ko
