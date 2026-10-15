#!/bin/bash
# build-kexts.sh <out>: NVRM, NVAccel (macOS 15), NVRMFB and NVRMAGDC from this tree on macOS, into <out>/*.kext.
# Needs Xcode and NVIDIA's open-gpu-kernel-modules at tag 610.57.04 in $OGKM (default ~/ogkm610):
#   git clone --depth 1 --branch 610.57.04 https://github.com/NVIDIA/open-gpu-kernel-modules.git ~/ogkm610
#
# NVRM links NVIDIA's RM and modeset cores unchanged, built here as Darwin archives:
#   src/nvidia/_out/Darwin_x86_64/libnvkernel.a          RM objects
#   src/nvidia-modeset/_out/Darwin_x86_64/libnvkms.a     modeset objects (shaders come from nvkms_shaders.cpp)
#   */_out/Darwin_x86_64/compile_cmds.sh                 each object's final compile command, read by
#                                                        rmcc.py, accel_build.sh and build-completion-archive.py
# OGKM's makefiles target an ELF kernel; build/rm-cc.sh adapts their flags, and the ELF links
# (nv-kernel.o, nv-modeset-kernel.o, the objcopy shader objects) are replaced by the archives above.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); TREE=$(dirname "$HERE")
OUT=${1:?usage: build-kexts.sh <out dir>}; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
OGKM=${OGKM:-$HOME/ogkm610}; export OGKM
[ -f "$OGKM/src/nvidia/Makefile" ] || { echo "STOP: no open-gpu-kernel-modules 610.57.04 at $OGKM"; exit 1; }
grep -q '"610.57.04"' "$OGKM/src/common/inc/nvUnixVersion.h" || { echo "STOP: $OGKM is not 610.57.04"; exit 1; }
NV=$OGKM/src/nvidia; KMS=$OGKM/src/nvidia-modeset; DO=_out/Darwin_x86_64
CLANG=$(xcrun -f clang); CLANGXX=$(xcrun -f clang++); JOBS=$(sysctl -n hw.ncpu)
LOG=$OUT/logs; mkdir -p "$LOG"

# RM fixes that go into the OGKM tree itself (the display completion patch is applied to a copy by
# build-completion-archive.py).
for p in "$TREE"/kexts/NVRM/patches/610-fsp-timer-double-destroy.patch; do
	if git -C "$OGKM" apply --reverse --check "$p" 2>/dev/null; then :
	else git -C "$OGKM" apply "$p" && echo "applied $(basename "$p")"; fi
done

# compile_objects <dir> <archive> [make args...]: build every compiled object of the makefile in <dir>,
# then archive them and write compile_cmds.sh in makefile order.
compile_objects() {
	local dir=$1 lib=$2; shift 2
	(
	cd "$dir"; mkdir -p "$DO"
	make -n -B NV_VERBOSE=1 CC=clang CXX=clang++ 2>/dev/null |
		grep -o -E ' -c [^ ]+ -o '"$DO"'/[^ ]+\.o' | awk '{print $4}' | awk '!s[$0]++' > "$DO/objs.order"
	xargs make -j"$JOBS" NV_VERBOSE=0 CC="$HERE/rm-cc.sh $CLANG" CXX="$HERE/rm-cc.sh $CLANGXX" "$@" \
		< "$DO/objs.order" > "$LOG/$(basename "$dir").log" 2>&1 ||
		{ echo "STOP: $(basename "$dir") failed:"; grep -E ' error:|\*\*\*' "$LOG/$(basename "$dir").log" | head; exit 1; }
	: > "$DO/compile_cmds.sh"
	while read -r o; do cat "$o.cmd" >> "$DO/compile_cmds.sh"; done < "$DO/objs.order"
	rm -f "$DO/$lib"
	xargs xcrun ar rcs "$DO/$lib" < "$DO/objs.order" 2>/dev/null
	echo "$(basename "$dir"): $(wc -l < "$DO/objs.order" | tr -d ' ') objects -> $DO/$lib"
	)
}
compile_objects "$NV" libnvkernel.a
# modeset's ID string depends on the ELF shader objects; -o keeps make from trying to build them
SKIP=(); for s in turing ampere hopper blackwell gb20x; do SKIP+=(-o "$DO/${s}_shaders.xz.o" -o "$DO/${s}_shaders.xz"); done
compile_objects "$KMS" libnvkms.a "${SKIP[@]}"

rm -rf "$OUT/paired-completion"
python3 "$TREE/kexts/NVRM/build-completion-archive.py" --vendor "$KMS" --output "$OUT/paired-completion" > "$LOG/completion.log" 2>&1 ||
	{ echo "STOP: build-completion-archive.py failed"; tail -5 "$LOG/completion.log"; exit 1; }

# flags shared by the kexts' C++: Kernel.framework, the RM/modeset headers and RM's own defines
SDK=$(xcrun --show-sdk-path); KHDR="$SDK/System/Library/Frameworks/Kernel.framework/Headers"
RMINC=( -I"$NV/arch/nvalloc/unix/include" -I"$NV/arch/nvalloc/common/inc" -I"$NV/arch/nvalloc/common/inc/gsp"
  -I"$OGKM/src/common/sdk/nvidia/inc" -I"$OGKM/src/common/sdk/nvidia/inc/hw" -I"$OGKM/src/common/inc"
  -I"$OGKM/src/common/shared/inc" -I"$NV/inc" -I"$NV/inc/os" -I"$NV/inc/kernel" -I"$NV/kernel/inc" -I"$NV/interface"
  -I"$OGKM/src/common/nvlink/interface" -I"$OGKM/src/common/inc/swref" -I"$OGKM/src/common/inc/swref/published"
  -I"$NV/inc/libraries" -I"$NV/src/libraries" -I"$NV/generated" -I"$NV/src/mm/uvm/interface"
  -I"$OGKM/src/common/uproc/os/libos-v2.0.0/include" -I"$OGKM/src/common/uproc/os/common/include"
  -I"$OGKM/src/common/inc/displayport" -I"$OGKM/src/common/nvlink/inband/interface" )
KMSINC=( -I"$KMS/os-interface/include" -I"$KMS/kapi/interface" -I"$KMS/kapi/include" -I"$OGKM/src/common/unix/nvidia-push/interface"
  -I"$KMS/interface" -I"$KMS/include" -I"$OGKM/src/common/unix/common/inc" -I"$OGKM/src/common/modeset"
  -I"$OGKM/src/common/unix/common/utils/interface" )
RMDEFS=(); while read -r d; do RMDEFS+=("$d"); done < <(head -1 "$NV/$DO/compile_cmds.sh" | tr ' ' '\n' | grep -E '^-D' | sed -e 's/"//g' | grep -v -E '^-D(NVRM|_LANGUAGE_C)$')
KXX=( -arch x86_64 -fapple-kext -mkernel -nostdinc -I"$KHDR" -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT
  -std=c++17 -fno-rtti -fno-exceptions -fno-builtin -fno-common
  -Wall -Wno-unused-parameter -Wno-inconsistent-missing-override -Wno-unused-function -O2 )
KLD=( -arch x86_64 -fapple-kext -nostdlib -Xlinker -kext -lkmodc++ -lkmod -lcc_kext )

# kext <name> <Info.plist> <objects...>
kext() {
	local name=$1 plist=$2; shift 2
	rm -rf "$OUT/$name.kext"; mkdir -p "$OUT/$name.kext/Contents/MacOS"
	xcrun clang++ "${KLD[@]}" "$@" -o "$OUT/$name.kext/Contents/MacOS/$name" 2> "$LOG/$name-ld.log" ||
		{ echo "STOP: $name link failed"; head "$LOG/$name-ld.log"; exit 1; }
	cp "$plist" "$OUT/$name.kext/Contents/Info.plist"
	codesign -f -s - "$OUT/$name.kext" 2>/dev/null
	echo "$name.kext $(stat -f %z "$OUT/$name.kext/Contents/MacOS/$name") B"
}
cxx() { xcrun clang++ "${KXX[@]}" "$@" 2>> "$LOG/kext-cc.log" || { echo "STOP: compile failed:"; grep -A2 ' error:' "$LOG/kext-cc.log" | head -20; exit 1; }; }

# NVRM: the XNU glue (C++), plus two C files that read RM's and modeset's private structs and so are
# built with those trees' own command lines
O=$OUT/obj/NVRM; rm -rf "$O"; mkdir -p "$O"; : > "$LOG/kext-cc.log"
for f in NVRM os-xnu os-xnu2 os-nvkms-xnu nv_xnu_stubs nvrm_fbinfo nvrm_gpuva nvrm_surfshare nvkms_shaders; do
	cxx -I"$TREE/kexts/NVRM" "${RMINC[@]}" "${KMSINC[@]}" "${RMDEFS[@]}" -c "$TREE/kexts/NVRM/$f.cpp" -o "$O/$f.o"
done
python3 "$TREE/kexts/NVRM/rmcc.py" "$TREE/kexts/NVRM/nvrm_pageoff.c" "$O/nvrm_pageoff.o" 2>> "$LOG/kext-cc.log"
python3 - "$TREE/kexts/NVRM/nvrm_kapi_fields.c" "$O/nvrm_kapi_fields.o" "$KMS" <<'EOF' 2>> "$LOG/kext-cc.log"
import os, shlex, subprocess, sys
src, out, kms = sys.argv[1:4]
line = next(l for l in open(os.path.join(kms, "_out/Darwin_x86_64/compile_cmds.sh")) if " -c kapi/src/nvkms-kapi.c " in l)
t = shlex.split(line.split(" && ")[0])
t[t.index("-c") + 1] = src
for flag, val in (("-o", out), ("-MF", out + ".d"), ("-MT", out)):
    t[t.index(flag) + 1] = val
sys.exit(subprocess.run(t, cwd=kms).returncode)
EOF
kext NVRM "$TREE/kexts/NVRM/Info.plist" "$O"/*.o "$NV/$DO/libnvkernel.a" "$OUT/paired-completion/libnvkms.a"

# NVAccel through its own script (macOS 15 build; accel_build_all.sh also makes the macOS 26 one)
env -u NM_TAHOE bash "$HERE/accel_build.sh" "$TREE/kexts/NVRM" "$OUT/obj/accel" > "$LOG/NVAccel.log" 2>&1 ||
	{ echo "STOP: NVAccel failed"; tail -5 "$LOG/NVAccel.log"; exit 1; }
rm -rf "$OUT/NVAccel.kext"; cp -R "$OUT/obj/accel/NVAccel.kext" "$OUT/"; codesign -f -s - "$OUT/NVAccel.kext" 2>/dev/null
echo "NVAccel.kext $(stat -f %z "$OUT/NVAccel.kext/Contents/MacOS/NVAccel") B"

# NVRMFB and NVRMAGDC: the current trees are kexts/NVRMFB and kexts/NVRMAGDC (kexts/NVRM/fb and /agdc are older)
O=$OUT/obj; cxx -I"$TREE/kexts/NVRMFB/fb" -I"$TREE/kexts/NVRMFB" "${RMINC[@]}" "${KMSINC[@]}" -c "$TREE/kexts/NVRMFB/fb/nvrm-fb.cpp" -o "$O/nvrm-fb.o"
kext NVRMFB "$TREE/kexts/NVRMFB/fb/Info.plist" "$O/nvrm-fb.o"
cxx -I"$TREE/kexts/NVRMAGDC" -c "$TREE/kexts/NVRMAGDC/nvrm-agdc.cpp" -o "$O/nvrm-agdc.o"
kext NVRMAGDC "$TREE/kexts/NVRMAGDC/Info.plist" "$O/nvrm-agdc.o"
echo "built from $(git -C "$TREE" rev-parse --short HEAD 2>/dev/null) into $OUT"
