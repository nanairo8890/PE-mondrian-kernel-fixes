#!/usr/bin/env bash
# Repite en local el CI "oem-coherent-wlan-compile" de LF5 (scope release) hasta el paso 32,
# con el kernel, modules y devicetrees de las ramas de arreglos de pe-lf5-work
# Variables: W (carpeta de trabajo), VERIFIER_REPO (clon de android_device_xiaomi_mondrian-kernel), THIN=1 (ThinLTO si falta memoria), JOBS
# Al repetir etapas: mmrm/wlan y camera exigen el codigo original (git checkout -- . en upstream/xiaomi-wlan y xiaomi-camera-source)
# Uso: bash compilar_ci_local.sh [etapa...]   (sin etapas: todas en orden; cada una deja una marca y se salta si ya terminó)
# Etapas: prep config kernel mmrm wlan display camera media data dt package
set -euo pipefail
W=${W:-$HOME/pe-lf5-work}   # carpeta con kernel/ modules/ devicetrees/ y google-clang/
GH=$W/modules                      # GITHUB_WORKSPACE (repo de modules)
RT=$W/ci-temp                      # RUNNER_TEMP
JOBS=${JOBS:-8}
export GITHUB_WORKSPACE=$GH RUNNER_TEMP=$RT GITHUB_STEP_SUMMARY=$RT/summary.md
export GITHUB_SHA=$(git -C $GH rev-parse HEAD) GITHUB_REPOSITORY=PixelExperience-Reborn/android_kernel_xiaomi_sm8450-modules
export GITHUB_WORKFLOW="local replay" GITHUB_RUN_ID=0
export PE_KERNEL_SHA=$(git -C $W/kernel rev-parse HEAD) PE_DT_SHA=$(git -C $W/devicetrees rev-parse HEAD)
export PATH=/tmp/google-clang/clang-r614150/bin:$PATH
export LLVM=1 LLVM_IAS=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
# Idioma neutro: las herramientas de LF5 leen salidas en ingles (readelf "Machine:"); en es_MX dice "Maquina:"
export LC_ALL=C LANG=C
# OpenSSL 4 del sistema ya no trae ENGINE: solo afecta a herramientas del host
export HOSTCFLAGS="-DOPENSSL_IS_BORINGSSL -DOPENSSL_NO_ENGINE"
OUT=$RT/mondrian-out
MK=(make -C kernel O="$OUT")
mkdir -p $RT/marcas; touch $GITHUB_STEP_SUMMARY
cd $GH
log(){ echo; echo "[$(date +%H:%M:%S)] ===== $*"; }
hecho(){ test -e $RT/marcas/$1; }

etapa_prep(){
	ln -sfn $W/kernel $GH/kernel
	ln -sfn $W/devicetrees $GH/device-tree
	ln -sfn $W/google-clang /tmp/google-clang
	test "$(git -C /tmp/google-clang rev-parse HEAD)" = c9ed23e2ba198658b630d4b10e09fa980cd43119
	clang --version | head -1
	# Pins locales: los commits de las ramas de arreglos en vez de 2efda4cf / 547c333c (sin commit)
	python3 -I - "$GH" "$PE_KERNEL_SHA" "$PE_DT_SHA" <<'PY'
import json, sys, pathlib
root, k, d = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
def edit(name, fn):
    p = root / name; data = json.loads(p.read_text()); fn(data)
    p.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
def cfg(c):
    c["selected_oem_source_candidates"]["selected_kernel"]["commit_sha"] = k
    c["selected_oem_source_candidates"]["selected_devicetrees"]["commit_sha"] = d
    c["wlan_runtime_closure"]["kernel_commit"] = k
edit("modules-bsp-candidates.json", cfg)
edit("camera-bsp-candidate.json", lambda c: c["kernel"].update(commit=k))
def pol(c):
    c["selected_kernel_commit"] = k; c["xiaomi_device_tree"]["commit"] = d
edit("mondrian-camera-flash-policy.json", pol)
PY
	python3 tools/mondrian_source_pins.py check
	# Los devicetrees fijan el kernel 2efda4cf en dos locks y en build_mondrian_camera_platform.py
	sed -i "s/2efda4cf1afa2a7098d5abd4806769903e181f73/$PE_KERNEL_SHA/g" \
		$W/devicetrees/oem-source-lock.json $W/devicetrees/oem-m11a-panel-source-lock.json \
		$W/devicetrees/tools/build_mondrian_camera_platform.py
	git -C $W/devicetrees diff --stat
}

etapa_config(){
	(cd kernel && python3 tools/verify_mondrian_thermal.py && python3 tools/verify_mondrian_goodix.py \
		&& python3 tools/verify_mondrian_display_clock.py)
	mkdir -p $OUT
	"${MK[@]}" gki_defconfig
	bash kernel/scripts/kconfig/merge_config.sh -m -r -O $OUT $OUT/.config \
		kernel/arch/arm64/configs/vendor/mondrian_GKI.config tools/config/mondrian_gki_hardening.config
	"${MK[@]}" olddefconfig
	if ! python3 tools/verify_mondrian_kernel_hardening.py --generated-config $OUT/.config \
			--out $RT/mondrian-gki-hardening-evidence.json; then
		# En un out nuevo la primera pasada puede dejar KASAN genérico sin LTO/CFI/SCS: segunda pasada
		echo "[AVISO] la primera pasada de config no pasó la verificación de endurecimiento; repito"
		"${MK[@]}" gki_defconfig
		bash kernel/scripts/kconfig/merge_config.sh -m -r -O $OUT $OUT/.config \
			kernel/arch/arm64/configs/vendor/mondrian_GKI.config tools/config/mondrian_gki_hardening.config
		"${MK[@]}" olddefconfig
		python3 tools/verify_mondrian_kernel_hardening.py --generated-config $OUT/.config \
			--out $RT/mondrian-gki-hardening-evidence.json
		echo "config: hizo falta segunda pasada" >> $GITHUB_STEP_SUMMARY
	fi
	python3 kernel/tools/verify_mondrian_oem_eroFS.py --generated-config $OUT/.config
	# Solo en local: con 15 GB, el enlace Full LTO (KASAN + CFI) llena RAM y swap y systemd-oomd mata todo.
	# THIN=1 cambia a ThinLTO despues de comprobar que la config del CI es la correcta. El CI sigue con Full LTO
	if [ "${THIN:-0}" = 1 ]; then
		kernel/scripts/config --file $OUT/.config -d LTO_CLANG_FULL -e LTO_CLANG_THIN
		"${MK[@]}" olddefconfig
		grep -E '^CONFIG_(LTO_CLANG_THIN|CFI_CLANG|SHADOW_CALL_STACK|KASAN_HW_TAGS)=' $OUT/.config
		echo "config: ThinLTO local en vez de Full LTO (falta de memoria)" >> $GITHUB_STEP_SUMMARY
	fi
	grep -E '^CONFIG_(LTO_CLANG_FULL|CFI_CLANG|SHADOW_CALL_STACK|KASAN_HW_TAGS|TOUCHSCREEN_GOODIX_BRL|TOUCHSCREEN_XIAOMI_TOUCHFEATURE)=' $OUT/.config
}

etapa_kernel(){
	"${MK[@]}" -j$JOBS vmlinux Image modules
	test -s $OUT/Module.symvers
	ls -la $OUT/arch/arm64/boot/Image
}

etapa_mmrm(){
	python3 tools/apply_oem_wlan_fix.py
	python3 tools/apply_oem_wlan_fix.py --apply || true   # ya aplicado si se repite
	grep -F 'uint8_t mdie[SIR_MDIE_SIZE]);' upstream/xiaomi-wlan/qcacld-3.0/core/mac/src/include/parser_api.h
	mmrm=$GH/upstream/qualcomm/mmrm
	"${MK[@]}" -j3 M="$mmrm/driver" MMRM_ROOT="$mmrm" CONFIG_MSM_MMRM=y \
		KCFLAGS="-include $mmrm/config/waipiommrmconf.h" modules
	test -s $mmrm/driver/msm-mmrm.ko
}

etapa_wlan(){
	vendor_root=$GH/upstream/xiaomi-wlan; wlan_root=$vendor_root/qcacld-3.0
	"${MK[@]}" -j3 M="$wlan_root" WLAN_ROOT="$wlan_root" \
		WLAN_COMMON_INC="$vendor_root/qca-wifi-host-cmn" WLAN_FW_API="$vendor_root/fw-api" \
		WLAN_PROFILE=qca6490 DEVNAME=qca6490 MODNAME=qca_cld3_qca6490 \
		CONFIG_CNSS_QCA6490=y CONFIG_ROME_IF=pci \
		WLAN_CTRL_NAME=wlan TARGET_BUILD_VARIANT=user DYNAMIC_SINGLE_CHIP=qca6490 \
		CONFIG_QCA_CLD_WLAN=m CONFIG_QCA_WIFI_ISOC=0 CONFIG_QCA_WIFI_2_0=1 modules
	test -s $wlan_root/cmn/hif/src/dispatcher/multibus_pci.o
	test ! -e $wlan_root/cmn/hif/src/dispatcher/multibus_snoc.o
	modinfo -F depends $wlan_root/qca_cld3_qca6490.ko
}

etapa_display(){
	display=$GH/kernel/techpack/display
	"${MK[@]}" -j3 M="$display/msm" DISPLAY_ROOT="$display" \
		KERNEL_SRC="$GH/kernel" KERNEL_ROOT="$GH/kernel" OUT="$OUT" \
		KBUILD_EXTRA_SYMBOLS="$GH/upstream/qualcomm/mmrm/driver/Module.symvers" modules
	modinfo -F name $display/msm/msm_drm.ko | grep -Fx msm_drm
}

etapa_camera(){
	python3 tools/verify_xiaomi_camera_submodule.py
	if ! grep -Fq '"qcom,csiphy-v2.1.3-xiaomi-m11a"' xiaomi-camera-source/drivers/cam_sensor_module/cam_csiphy/cam_csiphy_soc.c; then
		python3 tools/apply_xiaomi_camera_clang23_fix.py --source xiaomi-camera-source --apply \
			--evidence $RT/camera-clang23-fix-evidence.json
		python3 tools/select_mondrian_pmic_flash.py --source xiaomi-camera-source --device-tree device-tree \
			--manifest mondrian-camera-flash-policy.json --apply --evidence $RT/camera-pmic-selection-evidence.json
		for p in mondrian-m11a-csiphy mondrian-wl2866d-power-rollback mondrian-camera-shared-pinctrl-gpios \
				mondrian-camera-ois-driver-init-rollback; do
			git -C xiaomi-camera-source apply $GH/patches/$p.patch
		done
	fi
	cam=$GH/xiaomi-camera-source
	"${MK[@]}" -j3 M="$cam" CAMERA_KERNEL_ROOT="$cam" KERNEL_ROOT="$GH/kernel" \
		KBUILD_EXTRA_SYMBOLS="$GH/upstream/qualcomm/mmrm/driver/Module.symvers" modules
	test -s $cam/camera.ko; test -s $cam/cameralog.ko
}

etapa_media(){ rm -rf "${RT:?}/media-abi"
	# Estas etapas exigen codigo original: se restaura lo que dejo un intento anterior
	for d in upstream/xiaomi-audio upstream/qualcomm/video; do git -C $GH/$d checkout -- .; done
	bash tools/build_mondrian_audio_video.sh; }
etapa_data(){ rm -rf "${RT:?}/qcom-data-eva-abi"
	for d in dataipa datarmnet datarmnet-ext eva; do git -C $GH/upstream/qualcomm/$d checkout -- .; done
	bash tools/build_mondrian_data_eva.sh; }

etapa_dt(){
	test -x $RT/pe-bsp-dt-venv/bin/python || { python3 -m venv $RT/pe-bsp-dt-venv; \
		$RT/pe-bsp-dt-venv/bin/python -m pip install --disable-pip-version-check lz4==4.4.5; }
	py=$RT/pe-bsp-dt-venv/bin/python
	# Al repetir la etapa: los constructores exigen carpetas de salida vacias
	rm -rf "${RT:?}/mondrian-coherent-board" "${RT:?}/mondrian-coherent-camera-platform" \
		"${RT:?}/mondrian-coherent-m11a" "${RT:?}/mondrian-coherent-multimedia"
	$py device-tree/tools/build_oem_dtbo.py --kernel kernel --expected-kernel-commit "$PE_KERNEL_SHA" \
		--out $RT/mondrian-coherent-board
	$py device-tree/tools/build_mondrian_camera_platform.py --kernel kernel --camera-kernel xiaomi-camera-source \
		--board-build $RT/mondrian-coherent-board --out $RT/mondrian-coherent-camera-platform
	$py device-tree/tools/build_mondrian_m11a.py --kernel kernel \
		--camera-build $RT/mondrian-coherent-camera-platform --out $RT/mondrian-coherent-m11a
	$py device-tree/tools/build_mondrian_multimedia.py --kernel kernel \
		--m11a-build $RT/mondrian-coherent-m11a --out $RT/mondrian-coherent-multimedia
	$py device-tree/tools/verify_dt_driver_coverage.py \
		--dtb $RT/mondrian-coherent-multimedia/cape-mondrian-full.dtb \
		--dtb $RT/mondrian-coherent-multimedia/cape-v2-mondrian-full.dtb \
		--dtb $RT/mondrian-coherent-multimedia/capep-mondrian-full.dtb \
		--kernel kernel --kernel-config $OUT/.config \
		--module-source display=kernel/techpack/display --module-source xiaomi-audio=upstream/xiaomi-audio \
		--module-source xiaomi-camera=xiaomi-camera-source --module-source xiaomi-wlan=upstream/xiaomi-wlan \
		--module-source qcom-video=upstream/qualcomm/video --module-source qcom-mmrm=upstream/qualcomm/mmrm \
		--module-source qcom-dataipa=upstream/qualcomm/dataipa --module-source qcom-datarmnet=upstream/qualcomm/datarmnet \
		--module-source qcom-datarmnet-ext=upstream/qualcomm/datarmnet-ext --module-source qcom-eva=upstream/qualcomm/eva \
		--out $RT/mondrian-dt-driver-coverage.json
	python3 -I -c 'import json,sys; c=json.load(open(sys.argv[1])); print("fallas de cobertura:", c["failures"]); sys.exit(1 if c["failures"] else 0)' \
		$RT/mondrian-dt-driver-coverage.json
}

# Paso 32 tal cual, salvo el clone de mondrian-kernel (se usa el clon local de b061433)
etapa_package(){
	stage=$RT/mondrian-release-modules
	rm -rf "${stage:?}" "${RT:?}/mondrian-dtbo" "${RT:?}/mondrian-kernel-release"
	"${MK[@]}" LLVM=1 LLVM_IAS=1 ARCH=arm64 INSTALL_MOD_PATH="$stage" modules_install
	$RT/pe-bsp-dt-venv/bin/python device-tree/tools/build_mondrian_dtbo.py \
		--board-build $RT/mondrian-coherent-board --camera-build $RT/mondrian-coherent-camera-platform \
		--m11a-build $RT/mondrian-coherent-m11a --multimedia-build $RT/mondrian-coherent-multimedia \
		--out $RT/mondrian-dtbo
	python3 tools/package_mondrian_kernel_release.py \
		--image $OUT/arch/arm64/boot/Image \
		--modules "$stage/lib/modules" --modules kernel/techpack --modules upstream --modules xiaomi-camera-source \
		--dt $RT/mondrian-dtbo --strip "$(command -v llvm-strip)" \
		--kernel-commit "$PE_KERNEL_SHA" --modules-commit "$GITHUB_SHA" --devicetrees-commit "$PE_DT_SHA" \
		--clang clang-r614150 --clang-prebuilt-commit c9ed23e2ba198658b630d4b10e09fa980cd43119 \
		--ci-repository "$GITHUB_REPOSITORY" --ci-workflow "$GITHUB_WORKFLOW" --ci-run-id "$GITHUB_RUN_ID" \
		--out $RT/mondrian-kernel-release | tee -a $GITHUB_STEP_SUMMARY
	rm -rf "${RT:?}/mondrian-kernel-verifier"
	git clone -q "${VERIFIER_REPO:?apunta VERIFIER_REPO a un clon de android_device_xiaomi_mondrian-kernel}" $RT/mondrian-kernel-verifier
	python3 $RT/mondrian-kernel-verifier/tools/verify_prebuilt.py --root $RT/mondrian-kernel-release | tee -a $GITHUB_STEP_SUMMARY
}

ETAPAS=(prep config kernel mmrm wlan display camera media data dt package)
[ $# -gt 0 ] && ETAPAS=("$@")
for e in "${ETAPAS[@]}"; do
	if hecho $e && [ $# -eq 0 ]; then log "$e: ya hecha, se salta"; continue; fi
	log "$e: empieza"; inicio=$SECONDS
	etapa_$e
	touch $RT/marcas/$e
	log "$e: OK en $(( (SECONDS-inicio)/60 )) min"
done
log "TODO OK"
