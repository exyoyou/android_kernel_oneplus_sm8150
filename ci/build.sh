#!/usr/bin/env bash
# Build the OnePlus sm8150 4.14 kernel with KernelSU-Next (manual hook) +
# SUSFS and pack it into an AnyKernel3 zip. Used by GitHub Actions
# (.github/workflows/build-ksu.yml) and usable locally:
#
#   CLANG_DIR=~/android_kernel/toolchains/clang-r596125 \
#   NDK=~/Android/Sdk/ndk/27.0.12077973 ci/build.sh
#
# Environment (all optional except where noted):
#   CLANG_DIR            clang toolchain root (bin/clang, bin/ld.lld, ...)   [required]
#   NDK                  Android NDK root, for the ksu_susfs userspace tool  [required]
#   WORK                 scratch dir for out/, AnyKernel3, susfs4ksu  (default: <src>/../ci-work)
#   DIST                 where the zip and ksu_susfs land             (default: $WORK/dist)
#   PINNED_LOCALVERSION  git part of the release string, e.g. -g9f007fac27dc.
#                        Default: -g<first 12 chars of the merge-base with UPSTREAM_REF>.
#   UPSTREAM_REF         LineageOS branch ref used to derive the above (default: upstream/lineage-24.0)
#   JOBS                 make -j (default: nproc)
set -euo pipefail

SRC=$(cd "$(dirname "$0")/.." && pwd)
CI=$SRC/ci
WORK=${WORK:-$(cd "$SRC/.." && pwd)/ci-work}
OUT=$WORK/out
DIST=${DIST:-$WORK/dist}
JOBS=${JOBS:-$(nproc)}
: "${CLANG_DIR:?set CLANG_DIR to the clang toolchain root}"
: "${NDK:?set NDK to the Android NDK root}"

# AnyKernel3 is used unmodified except for ci/anykernel/anykernel.sh.
AK3_REPO=https://github.com/osm0sis/AnyKernel3.git
AK3_COMMIT=41f04bd

# ksu_susfs userspace tool: must come from the same susfs4ksu revision as the
# SUSFS patches in the kernel tree (fs/susfs.c, include/linux/susfs*.h).
# Bump SUSFS_COMMIT together with the kernel-side SUSFS patches.
SUSFS_REPO=https://gitlab.com/simonpunk/susfs4ksu.git
SUSFS_BRANCH=kernel-4.14
SUSFS_COMMIT=77905b5a071e6f3669e3b1814cea30147c0801da # v1.5.5

# YouYouSU-Next manager release signing cert (RSA 2048; cert must be <= 1024
# bytes). Regenerate with ksu_cert_hash.sh when the signing key changes.
KSU_NEXT_MANAGER_SIZE=${KSU_NEXT_MANAGER_SIZE:-0x2cf}
KSU_NEXT_MANAGER_HASH=${KSU_NEXT_MANAGER_HASH:-3ba777f7e137c0a3bc0b8da19d32415ba68078d9d2a4ec57d30ad5c965281804}

# The vendor wlan module (qca_cld3_wlan.ko) is loaded with a vermagic check,
# so the release string must match the LineageOS kernel on the phone exactly,
# e.g. 4.14.357-openela-perf-g9f007fac27dc. CONFIG_LOCALVERSION="-perf" comes
# from the config; the git part is the LineageOS commit this branch sits on,
# which is what the official build of that commit reports.
UPSTREAM_REF=${UPSTREAM_REF:-upstream/lineage-24.0}
if [ -z "${PINNED_LOCALVERSION:-}" ]; then
	if ! base=$(git -C "$SRC" merge-base HEAD "$UPSTREAM_REF" 2>/dev/null); then
		echo "cannot find the merge-base with $UPSTREAM_REF; fetch it" \
		     "(git fetch upstream lineage-24.0) or set PINNED_LOCALVERSION" >&2
		exit 1
	fi
	PINNED_LOCALVERSION=-g${base:0:12}
fi
echo "LOCALVERSION: $PINNED_LOCALVERSION"

export PATH=$CLANG_DIR/bin:$PATH
MAKE_ARGS=(
	-C "$SRC" O="$OUT" ARCH=arm64
	CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy
	OBJDUMP=llvm-objdump STRIP=llvm-strip READELF=llvm-readelf
	HOSTCC=clang HOSTCXX=clang++ HOSTLD=ld.lld
	CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-gnu-
	CROSS_COMPILE_ARM32=arm-linux-gnueabi-
	LLVM=1 LLVM_IAS=1
	LOCALVERSION="$PINNED_LOCALVERSION"
	KBUILD_BUILD_USER=root KBUILD_BUILD_HOST=localhost
	KSU_NEXT_MANAGER_SIZE="$KSU_NEXT_MANAGER_SIZE"
	KSU_NEXT_MANAGER_HASH="$KSU_NEXT_MANAGER_HASH"
)

mkdir -p "$OUT" "$DIST"

build_ksu_susfs() {
	local susfs_src=$WORK/susfs4ksu
	if [ ! -d "$susfs_src/.git" ]; then
		git clone --branch "$SUSFS_BRANCH" "$SUSFS_REPO" "$susfs_src"
	fi
	if ! git -C "$susfs_src" cat-file -e "$SUSFS_COMMIT^{commit}" 2>/dev/null; then
		git -C "$susfs_src" fetch origin "$SUSFS_BRANCH"
	fi
	git -C "$susfs_src" checkout -q --detach "$SUSFS_COMMIT"

	# The tool talks to the kernel through the command numbers and structs in
	# these headers; refuse to build a mismatched pair.
	local h
	for h in include/linux/susfs.h include/linux/susfs_def.h; do
		if ! cmp -s "$susfs_src/kernel_patches/$h" "$SRC/$h"; then
			echo "ksu_susfs: $h differs between susfs4ksu@$SUSFS_COMMIT" \
			     "and the kernel tree; update SUSFS_COMMIT" >&2
			exit 1
		fi
	done

	rm -rf "$OUT/ksu_susfs"
	"$NDK/ndk-build" -s \
		NDK_PROJECT_PATH="$susfs_src/ksu_susfs" \
		NDK_OUT="$OUT/ksu_susfs/obj" NDK_LIBS_OUT="$OUT/ksu_susfs/libs" \
		APP_PLATFORM=android-29
	cp "$OUT/ksu_susfs/libs/arm64-v8a/ksu_susfs" "$DIST/ksu_susfs"
	echo "ksu_susfs ($SUSFS_VERSION): $DIST/ksu_susfs"
}

SUSFS_VERSION=$(sed -n 's/^#define SUSFS_VERSION "\(.*\)"/\1/p' "$SRC/include/linux/susfs.h")
build_ksu_susfs

# Start from the config of the LineageOS kernel running on the phone
# (adb shell zcat /proc/config.gz > ci/device_config), then add KernelSU.
cp "$CI/device_config" "$OUT/.config"
"$SRC/scripts/config" --file "$OUT/.config" \
	--disable LOCALVERSION_AUTO \
	--enable KSU \
	--enable KSU_MANUAL_HOOK \
	--disable KSU_DEBUG \
	--enable KSU_SUSFS
make "${MAKE_ARGS[@]}" olddefconfig

grep -E '^CONFIG_KSU|^# CONFIG_KSU' "$OUT/.config"
if grep -q '^CONFIG_KPROBES=y' "$OUT/.config"; then
	echo "CONFIG_KPROBES is enabled; manual hook build expects it off" >&2
	exit 1
fi

make "${MAKE_ARGS[@]}" -j"$JOBS" Image 2>&1 | tee "$OUT/build.log"

RELEASE=$(cat "$OUT/include/config/kernel.release")
echo "kernel.release: $RELEASE"
case $RELEASE in
*-perf"$PINNED_LOCALVERSION") ;;
*)
	echo "release string $RELEASE does not end in -perf$PINNED_LOCALVERSION;" \
	     "the vendor wlan module would refuse to load" >&2
	exit 1
	;;
esac

# Fresh AnyKernel3 tree every time, so no stale Image or ksu_susfs is zipped.
ak3=$WORK/AnyKernel3
if [ ! -d "$ak3/.git" ]; then
	git clone -q "$AK3_REPO" "$ak3"
fi
git -C "$ak3" cat-file -e "$AK3_COMMIT^{commit}" 2>/dev/null || git -C "$ak3" fetch -q origin
git -C "$ak3" checkout -q -f --detach "$AK3_COMMIT"
git -C "$ak3" clean -qfdx
find "$ak3" -name placeholder -delete
cp "$CI/anykernel/anykernel.sh" "$ak3/anykernel.sh"
cp "$OUT/arch/arm64/boot/Image" "$ak3/Image"
# anykernel.sh installs it to /data/adb/ksu/bin/ksu_susfs while flashing
cp "$DIST/ksu_susfs" "$ak3/ksu_susfs"

ZIP_NAME=YouYouSU-Next-legacy-SUSFS-$SUSFS_VERSION-guacamole-${RELEASE##*-perf-}-$(date +%Y%m%d-%H%M).zip
(cd "$ak3" && zip -qr9 "$DIST/$ZIP_NAME" . -x '.git*' -x '.github/*' -x 'README.md')
echo "Flashable zip: $DIST/$ZIP_NAME"

# For the workflow: hand the results to later steps.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
	{
		echo "zip=$DIST/$ZIP_NAME"
		echo "zip_name=$ZIP_NAME"
		echo "release=$RELEASE"
		echo "susfs_version=$SUSFS_VERSION"
	} >>"$GITHUB_OUTPUT"
fi
