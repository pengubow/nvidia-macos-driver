#!/bin/bash
# build-all.sh <out>: every part of the driver this tree builds, on an x86_64 Mac:
#   <out>/kexts/{NVRM,NVAccel,NVRMFB,NVRMAGDC}.kext     build-kexts.sh
#   <out>/plugin/NVMTLDriver                            Metal plugin (build_plugin.sh's command line)
#   <out>/xlate/libnvmtl_translate.dylib                shader translator (build_xlate.sh's cargo build)
#   <out>/nvk/libvulkan_nouveau.dylib                   NVK, build-nvk.sh
# OGKM, MESA and TOOLS as in build-kexts.sh / build-nvk.sh; VULKAN_HEADERS = Vulkan-Headers v1.4.362
# (default ~/Vulkan-Headers). The release's prebuilt pieces (air-opt, air-runtime, the nvdec/nvenc dylibs, the
# Vulkan loader) are not built here.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); TREE=$(dirname "$HERE")
OUT=${1:?usage: build-all.sh <out dir>}; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
VH=${VULKAN_HEADERS:-$HOME/Vulkan-Headers}
[ -f "$VH/include/vulkan/vulkan_core.h" ] || { echo "STOP: no Vulkan-Headers at $VH (git clone --branch v1.4.362 https://github.com/KhronosGroup/Vulkan-Headers.git)"; exit 1; }

bash "$HERE/build-kexts.sh" "$OUT/kexts"

mkdir -p "$OUT/plugin"
xcrun clang -arch x86_64 -bundle -fobjc-arc -O1 -DNVMTL_RELEASE=1 -Wno-protocol -Wno-incomplete-implementation \
	-I"$VH/include" -o "$OUT/plugin/NVMTLDriver" "$TREE/plugin/NVMTLDevice.m" \
	-framework Foundation -framework Metal -framework IOSurface -framework IOKit 2> "$OUT/plugin/NVMTLDriver.err" ||
	{ echo "STOP: plugin failed"; grep -A2 ': error:' "$OUT/plugin/NVMTLDriver.err" | head -20; exit 1; }
codesign -f -s - "$OUT/plugin/NVMTLDriver" 2> /dev/null
echo "NVMTLDriver $(stat -f %z "$OUT/plugin/NVMTLDriver") B"

mkdir -p "$OUT/xlate"
(cd "$TREE/translator" && PATH="$HOME/.cargo/bin:$PATH" \
	RUSTFLAGS="--remap-path-prefix=$TREE/translator=/src --remap-path-prefix=$HOME/.cargo=/cargo --remap-path-prefix=$HOME=/build" \
	cargo build --release --manifest-path wrapper/Cargo.toml --target-dir "$OUT/xlate/target" > "$OUT/xlate/cargo.log" 2>&1) ||
	{ echo "STOP: translator failed"; grep -E '^error' "$OUT/xlate/cargo.log" | head; exit 1; }
D=$OUT/xlate/libnvmtl_translate.dylib; cp "$OUT/xlate/target/release/libnvmtl_translate.dylib" "$D"; strip -S "$D"
install_name_tool -id @rpath/libnvmtl_translate.dylib "$D" 2> /dev/null; codesign -f -s - "$D" 2> /dev/null
echo "libnvmtl_translate.dylib $(stat -f %z "$D") B"

bash "$HERE/build-nvk.sh" "$OUT/nvk"
