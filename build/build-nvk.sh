#!/bin/bash
# build-nvk.sh <out>: libvulkan_nouveau.dylib (NVK with the NVRM backend) from Mesa 17ca6174 + nvk/nvk-macos.patch,
# on an x86_64 Mac with MacPorts. Like build263.sh, without its fixed build directories.
#
#   MESA   Mesa checkout at nvk/MESA_BASE (default ~/mesa-17ca6174); the patch is applied if it is not yet
#   OGKM   open-gpu-kernel-modules 610.57.04 (default ~/ogkm610), linked in as nvkmd/nvrm/open-gpu-kernel-modules
#   TOOLS  prefix for the host tools built here (default ~/nvmtl-tools)
#
# Needs: sudo port install llvm-22 clang-22 spirv-tools spirv-headers glslang py314-mako py314-yaml \
#                         py314-packaging cbindgen bison flex pkgconfig  (meson and ninja too)
#        rustup (stable) and `cargo install bindgen-cli`
# NVK compiles its OpenCL kernels with Mesa's mesa_clc and vtn_bindgen2 (-Dmesa-clc=system). Those need LLVM
# with clang and SPIRV-LLVM-Translator, so they are built once into $TOOLS from the same Mesa tree; NVK itself
# is built without LLVM.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); TREE=$(dirname "$HERE")
OUT=${1:?usage: build-nvk.sh <out dir>}; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
MESA=${MESA:-$HOME/mesa-17ca6174}; OGKM=${OGKM:-$HOME/ogkm610}; TOOLS=${TOOLS:-$HOME/nvmtl-tools}
LLVM_BIN=/opt/local/libexec/llvm-22/bin
# LLVM stays off PATH: its clang has no SDK, and meson would take it for C/ObjC. It is named in a native file.
export PATH="$TOOLS/bin:$HOME/.cargo/bin:/opt/local/bin:/opt/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
export CC=/usr/bin/clang CXX=/usr/bin/clang++ OBJC=/usr/bin/clang OBJCXX=/usr/bin/clang++
export PKG_CONFIG_PATH="$TOOLS/lib/pkgconfig:/opt/local/lib/pkgconfig"
LOG=$OUT/logs; mkdir -p "$LOG"
for t in meson ninja pkg-config glslangValidator cbindgen bindgen rustc bison flex; do
	command -v "$t" > /dev/null || { echo "STOP: $t not found (see the header of this script)"; exit 1; }
done
[ -x "$LLVM_BIN/llvm-config" ] || { echo "STOP: no MacPorts llvm-22 ($LLVM_BIN/llvm-config)"; exit 1; }
[ -f "$MESA/VERSION" ] || { echo "STOP: no Mesa tree at $MESA"; exit 1; }
[ -f "$OGKM/src/common/inc/nvUnixVersion.h" ] || { echo "STOP: no open-gpu-kernel-modules at $OGKM"; exit 1; }

# the patch, once
if [ ! -f "$MESA/src/nouveau/vulkan/nvkmd/nvrm/nvkmd_nvrm.h" ]; then
	(cd "$MESA" && patch -p1 --forward < "$TREE/nvk/nvk-macos.patch" > "$LOG/patch.log") ||
		{ echo "STOP: nvk-macos.patch does not apply to $MESA (needs Mesa $(cat "$TREE/nvk/MESA_BASE"))"; tail "$LOG/patch.log"; exit 1; }
	echo "applied nvk-macos.patch"
fi
ln -sfn "$OGKM" "$MESA/src/nouveau/vulkan/nvkmd/nvrm/open-gpu-kernel-modules"

# SPIRV-LLVM-Translator for LLVM 22 (the patched clc_helpers.cpp includes clang/Options/OptionUtils.h, new in 22) (mesa_clc links it)
if [ ! -f "$TOOLS/lib/pkgconfig/LLVMSPIRVLib.pc" ]; then
	S=$TOOLS/src/spirv-llvm-translator
	[ -d "$S" ] || git clone -q --depth 1 --branch v22.1.7 https://github.com/KhronosGroup/SPIRV-LLVM-Translator.git "$S"
	cmake -S "$S" -B "$S/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$TOOLS" \
		-DLLVM_DIR="$("$LLVM_BIN/llvm-config" --cmakedir)" -DLLVM_EXTERNAL_SPIRV_HEADERS_SOURCE_DIR=/opt/local \
		-DLLVM_SPIRV_INCLUDE_TESTS=OFF -DBUILD_SHARED_LIBS=OFF > "$LOG/spirv-llvm-translator.log" 2>&1 &&
	ninja -C "$S/build" install >> "$LOG/spirv-llvm-translator.log" 2>&1 ||
		{ echo "STOP: SPIRV-LLVM-Translator failed"; tail -20 "$LOG/spirv-llvm-translator.log"; exit 1; }
	echo "SPIRV-LLVM-Translator -> $TOOLS"
fi

# mesa_clc and vtn_bindgen2 from this Mesa tree
NATIVE=$OUT/llvm22-native.ini
printf "[binaries]\nllvm-config = '%s'\n" "$LLVM_BIN/llvm-config" > "$NATIVE"
if [ ! -x "$TOOLS/bin/mesa_clc" ] || [ ! -x "$TOOLS/bin/vtn_bindgen2" ]; then
	B=$OUT/build-clc
	[ -f "$B/build.ninja" ] || meson setup "$B" "$MESA" --native-file "$NATIVE" -Dbuildtype=release -Dllvm=enabled -Dshared-llvm=enabled \
		-Dmesa-clc=enabled -Dinstall-mesa-clc=true -Dvulkan-drivers= -Dgallium-drivers= -Dplatforms= \
		-Degl=disabled -Dglx=disabled -Dglvnd=disabled -Dopengl=false -Dgles1=disabled -Dgles2=disabled \
		-Dtools= -Dbuild-tests=false -Dexpat=disabled -Dzstd=disabled -Dlibunwind=disabled -Dlmsensors=disabled \
		-Dvalgrind=disabled -Dgallium-rusticl=false -Dspirv-tools=enabled > "$LOG/clc-setup.log" 2>&1 ||
		{ echo "STOP: meson setup (mesa_clc) failed"; tail -30 "$LOG/clc-setup.log"; exit 1; }
	ninja -C "$B" src/compiler/clc/mesa_clc src/compiler/spirv/vtn_bindgen2 > "$LOG/clc-ninja.log" 2>&1 ||
		{ echo "STOP: mesa_clc build failed"; grep -E 'error|FAILED' "$LOG/clc-ninja.log" | head -20; exit 1; }
	mkdir -p "$TOOLS/bin"
	cp "$B/src/compiler/clc/mesa_clc" "$B/src/compiler/spirv/vtn_bindgen2" "$TOOLS/bin/"
	echo "mesa_clc, vtn_bindgen2 -> $TOOLS/bin"
fi

# NVK (build263.sh's configuration). Neither pkg-config nor cmake may see /opt/local, so zlib is the system one:
# a MacPorts libz in the dylib would be loaded into WindowServer.
B=$OUT/build-nvk; mkdir -p "$OUT/no-pkgconfig"
printf "[binaries]\ncmake = '/usr/bin/false'\n" > "$OUT/no-cmake.ini"   # MacPorts cmake finds /opt/local zlib too
[ -f "$B/build.ninja" ] || PKG_CONFIG_LIBDIR="$OUT/no-pkgconfig" PKG_CONFIG_PATH= meson setup "$B" "$MESA" --native-file "$OUT/no-cmake.ini" -Dbuildtype=debugoptimized -Dvulkan-drivers=nouveau -Dgallium-drivers= \
	-Dplatforms= -Degl=disabled -Dglx=disabled -Dglvnd=disabled -Dllvm=disabled -Dmesa-clc=system \
	-Dshared-glapi=disabled -Dvulkan-layers= -Dtools= -Dbuild-tests=false -Dexpat=disabled -Dzstd=disabled \
	-Dlibunwind=disabled -Dlmsensors=disabled -Dvalgrind=disabled -Dxlib-lease=disabled -Dgallium-rusticl=false \
	-Dspirv-tools=disabled > "$LOG/nvk-setup.log" 2>&1 ||
	{ echo "STOP: meson setup (NVK) failed"; tail -30 "$LOG/nvk-setup.log"; exit 1; }
meson configure "$B" "-Dc_args=-ffile-prefix-map=$MESA=/src -ffile-prefix-map=$HOME=/build" \
	"-Dcpp_args=-ffile-prefix-map=$MESA=/src -ffile-prefix-map=$HOME=/build" \
	"-Drust_args=--remap-path-prefix=$MESA=/src --remap-path-prefix=$HOME=/build" > "$LOG/nvk-configure.log" 2>&1
nice ninja -C "$B" src/nouveau/vulkan/libvulkan_nouveau.dylib > "$LOG/nvk-ninja.log" 2>&1 ||
	{ echo "STOP: NVK build failed"; grep -E 'error(\[E[0-9]+\])?:|FAILED' "$LOG/nvk-ninja.log" | head -20; exit 1; }
L=$(otool -L "$B/src/nouveau/vulkan/libvulkan_nouveau.dylib" | awk 'NR > 1 && $1 !~ "^(/usr/lib/|/System/Library/|@rpath/)" {print $1}')
[ -z "$L" ] || { echo "STOP: links libraries outside macOS:"; echo "$L"; exit 1; }
U=$(nm -m "$B/src/nouveau/vulkan/libvulkan_nouveau.dylib" | grep '(undefined)' | grep -v weak | grep 'dynamically looked up' || true)
[ -z "$U" ] || { echo "STOP: unresolved strong references (dlopen fails in WindowServer):"; echo "$U"; exit 1; }
D=$OUT/libvulkan_nouveau.dylib; cp "$B/src/nouveau/vulkan/libvulkan_nouveau.dylib" "$D"; strip -S "$D"   # debug-map stabs name every .o by path
codesign -f -s - "$D" 2> /dev/null
echo "libvulkan_nouveau.dylib $(stat -f %z "$D") B  uuid $(otool -l "$D" | awk '/uuid/{print $2; exit}')"
