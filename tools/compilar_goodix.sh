#!/usr/bin/env bash
# Compila solo el driver Goodix para comprobar que compila
# Uso: W=<carpeta con kernel/ y modules/> CLANG_BIN=<clang/bin> bash compilar_goodix.sh
set -euo pipefail
W=${W:-$(pwd)}
K=$W/kernel; O=$W/out-kernel
export PATH=${CLANG_BIN:?pon en CLANG_BIN la carpeta bin de clang}:$PATH
export LLVM=1 LLVM_IAS=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
# OpenSSL 4 del sistema ya no trae ENGINE: solo afecta a herramientas del host
M=(make -C "$K" O="$O" "HOSTCFLAGS=-DOPENSSL_IS_BORINGSSL -DOPENSSL_NO_ENGINE")
if [ ! -s $O/.config ]; then
  mkdir -p $O
  "${M[@]}" gki_defconfig >/dev/null; "${M[@]}" gki_defconfig >/dev/null
  bash $K/scripts/kconfig/merge_config.sh -m -r -O $O $O/.config \
    $K/arch/arm64/configs/vendor/mondrian_GKI.config $W/modules/tools/config/mondrian_gki_hardening.config >/dev/null
  "${M[@]}" olddefconfig >/dev/null
fi
grep -E '^CONFIG_(TOUCHSCREEN_GOODIX_BRL|QCOM_PANEL_EVENT_NOTIFIER|LTO_CLANG_FULL|CFI_CLANG|PINCTRL)=' $O/.config
"${M[@]}" -j12 modules_prepare >/dev/null
"${M[@]}" -j12 KBUILD_MODPOST_WARN=1 M=drivers/input/touchscreen/goodix_berlin_driver modules 2>&1 | grep -v -E '^\s*(CC|LD|AR|MODPOST|  )' || true
ls -la $O/drivers/input/touchscreen/goodix_berlin_driver/*.ko
