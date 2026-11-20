#!/usr/bin/env bash
# Pack the parts of an AOSP clang prebuilt that the kernel build needs into a
# small tarball for GitHub Actions. AOSP no longer publishes new clang
# prebuilts on android.googlesource.com, so the workflow downloads this
# tarball from a release of this repository instead.
#
#   ci/pack_clang.sh ~/android_kernel/toolchains/clang-r596125 out.tar.zst
#
# Then upload out.tar.zst as asset "clang-r596125-slim.tar.zst" of a release
# tagged "toolchain-clang-r596125" (see .github/workflows/build-ksu.yml).
set -euo pipefail

CLANG=${1:?usage: $0 <clang dir> <out.tar.zst>}
OUTFILE=$(realpath -m "${2:?usage: $0 <clang dir> <out.tar.zst>}")
CLANG=$(cd "$CLANG" && pwd)
NAME=$(basename "$CLANG")
VER=$(ls "$CLANG/lib/clang")

# bin/clang is a wrapper that execs clang-real -> clang-22.
files=(
	AndroidVersion.txt clang_source_info.md
	bin/clang bin/clang++ bin/clang-real bin/clang++-real "bin/clang-$VER"
	bin/lld bin/ld.lld
	bin/llvm-ar bin/llvm-nm bin/llvm-objcopy bin/llvm-strip bin/llvm-objdump
	bin/llvm-readobj bin/llvm-readelf bin/llvm-dis
	"lib/clang/$VER/include"
)
# shared libraries the tools above load from lib/ (e.g. libxml2 for lld)
while read -r lib; do
	files+=("lib/$lib")
done < <(cd "$CLANG" && for b in "${files[@]}"; do
	case $b in bin/*) ldd "$b" 2>/dev/null || true ;; esac; done |
	sed -n "s#.*=> $CLANG/bin/../lib/\([^ ]*\) .*#\1#p" | sort -u)
for lib in "${files[@]}"; do
	case $lib in lib/*.so*) ;; *) continue ;; esac
	# keep the symlink chain (libxml2.so.16 -> ...)
	for l in "$CLANG"/"${lib%%.so*}".so*; do files+=("lib/$(basename "$l")"); done
done

mapfile -t files < <(printf '%s\n' "${files[@]}" | sort -u)
tar -C "$(dirname "$CLANG")" -cf - "${files[@]/#/$NAME/}" | zstd -19 -T0 -q -o "$OUTFILE" -f
ls -lh "$OUTFILE"
sha256sum "$OUTFILE"
