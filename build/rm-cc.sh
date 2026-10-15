#!/bin/bash
# rm-cc.sh <compiler> <args...>: the CC that build-nvrm.sh hands to open-gpu-kernel-modules' makefiles.
# Their flags target an ELF kernel; this turns them into Mach-O kernel flags and records the final
# command next to the object (<obj>.cmd), from which build-nvrm.sh assembles compile_cmds.sh.
#   - -mcmodel=kernel and -fno-pic describe ELF kernel addressing; -mkernel gives the kext model.
#   - -ffunction/data-sections only feed the ELF --gc-sections link, which is replaced by an archive.
#   - -mindirect-branch* are GCC retpoline flags.
#   - NV_UNIX/NV_BSD: clang predefines neither on Darwin; the shipped NVRM was built without NV_LINUX
#     (nvlink top-level locking compiled out), so the BSD flavour matches it.
set -u
cc=$1; shift
out=; args=(-mkernel -nostdlibinc -DNV_UNIX -DNV_BSD)
prev=
for a in "$@"; do
	case "$a" in
	-mcmodel=kernel|-fno-pic|-ffunction-sections|-fdata-sections|-mindirect-branch=*|-mindirect-branch-register) ;;
	*) args+=("$a") ;;
	esac
	[ "$prev" = -o ] && out=$a
	prev=$a
done
if [ -n "$out" ]; then
	# Same shape as the makefile's own line: -D"X=<y>" keeps the quotes that accel_build.sh strips.
	line=$cc
	for a in "${args[@]}"; do
		case "$a" in
		-D*[\<\>\ ]*) line+=" -D\"${a#-D}\"" ;;
		*) line+=" $a" ;;
		esac
	done
	printf '%s\n' "$line" > "$out.cmd"
fi
exec "$cc" "${args[@]}"
