#!/usr/bin/env bash
# 编译带 KernelSU-Next（manual hook）+ SUSFS 的一加 sm8150 4.14 内核，
# 并打包成 AnyKernel3 刷机包。GitHub Actions（.github/workflows/build-ksu.yml）
# 调用它，本地也可以直接用：
#
#   CLANG_DIR=~/android_kernel/toolchains/clang-r547379 \
#   NDK=~/Android/Sdk/ndk/27.0.12077973 ci/build.sh
#
# 环境变量（除标注“必填”外都可省略）：
#   CLANG_DIR            clang 工具链根目录（含 bin/clang、bin/ld.lld 等）      [必填]
#   NDK                  Android NDK 根目录，用来编译 ksu_susfs 用户态工具       [必填]
#   WORK                 工作目录，放 out/、AnyKernel3、susfs4ksu（默认：<源码>/../ci-work）
#   DIST                 输出 zip 和 ksu_susfs 的目录                 （默认：$WORK/dist）
#   PINNED_LOCALVERSION  版本字符串的 git 后缀，如 -g9f007fac27dc。
#                        默认：-g<与 UPSTREAM_REF 的 merge-base 的前 12 位>
#   UPSTREAM_REF         用来计算上面后缀的 LineageOS 分支（默认：upstream/lineage-24.0）
#   JOBS                 make 并行数（默认：nproc）
set -euo pipefail

SRC=$(cd "$(dirname "$0")/.." && pwd)
CI=$SRC/ci
WORK=${WORK:-$(cd "$SRC/.." && pwd)/ci-work}
OUT=$WORK/out
DIST=${DIST:-$WORK/dist}
JOBS=${JOBS:-$(nproc)}
: "${CLANG_DIR:?请把 CLANG_DIR 设为 clang 工具链根目录}"
: "${NDK:?请把 NDK 设为 Android NDK 根目录}"

# AnyKernel3：固定版本，除 ci/anykernel/anykernel.sh 外原样使用
AK3_REPO=https://github.com/osm0sis/AnyKernel3.git
AK3_COMMIT=41f04bd

# ksu_susfs 用户态工具：必须和内核里的 SUSFS 补丁（fs/susfs.c、
# include/linux/susfs*.h）来自 susfs4ksu 的同一个提交。
# 升级内核侧 SUSFS 补丁时，SUSFS_COMMIT 要一起改。
SUSFS_REPO=https://gitlab.com/simonpunk/susfs4ksu.git
SUSFS_BRANCH=kernel-4.14
SUSFS_COMMIT=77905b5a071e6f3669e3b1814cea30147c0801da # v1.5.5

# YouYouSU-Next 管理器的签名证书（RSA 2048，证书不能超过 1024 字节）。
# 内核只认这个签名的管理器；换签名密钥后用 ksu_cert_hash.sh 重新计算。
KSU_NEXT_MANAGER_SIZE=${KSU_NEXT_MANAGER_SIZE:-0x2cf}
KSU_NEXT_MANAGER_HASH=${KSU_NEXT_MANAGER_HASH:-3ba777f7e137c0a3bc0b8da19d32415ba68078d9d2a4ec57d30ad5c965281804}

# 厂商 WiFi 模块（qca_cld3_wlan.ko）加载时会校验 vermagic，所以版本字符串
# 必须和手机上 LineageOS 内核的完全一致，如 4.14.357-openela-perf-g9f007fac27dc。
# 其中 -perf 来自配置里的 CONFIG_LOCALVERSION；-g... 是本分支所基于的
# LineageOS 提交，也就是官方用这个提交编译时报告的后缀。
UPSTREAM_REF=${UPSTREAM_REF:-upstream/lineage-24.0}
if [ -z "${PINNED_LOCALVERSION:-}" ]; then
	if ! base=$(git -C "$SRC" merge-base HEAD "$UPSTREAM_REF" 2>/dev/null); then
		echo "找不到与 $UPSTREAM_REF 的 merge-base：请先拉取上游" \
		     "（git fetch upstream lineage-24.0），或设置 PINNED_LOCALVERSION" >&2
		exit 1
	fi
	PINNED_LOCALVERSION=-g${base:0:12}
fi
echo "LOCALVERSION: $PINNED_LOCALVERSION"

# 全部用 LLVM 工具链编译（含集成汇编器），不需要 GCC 交叉编译器
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

# 编译 ksu_susfs（SUSFS 的用户态命令行工具，模块通过它配置隐藏规则）
build_ksu_susfs() {
	local susfs_src=$WORK/susfs4ksu
	if [ ! -d "$susfs_src/.git" ]; then
		git clone --branch "$SUSFS_BRANCH" "$SUSFS_REPO" "$susfs_src"
	fi
	if ! git -C "$susfs_src" cat-file -e "$SUSFS_COMMIT^{commit}" 2>/dev/null; then
		git -C "$susfs_src" fetch origin "$SUSFS_BRANCH"
	fi
	git -C "$susfs_src" checkout -q --detach "$SUSFS_COMMIT"

	# 工具通过这两个头文件里的命令号和结构体与内核通信，
	# 内核和工具的版本不一致就拒绝编译
	local h
	for h in include/linux/susfs.h include/linux/susfs_def.h; do
		if ! cmp -s "$susfs_src/kernel_patches/$h" "$SRC/$h"; then
			echo "ksu_susfs：$h 与 susfs4ksu@$SUSFS_COMMIT 不一致，" \
			     "请更新 SUSFS_COMMIT" >&2
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

# 以手机上正在运行的 LineageOS 内核配置为起点
# （adb shell zcat /proc/config.gz > ci/device_config），再打开 KernelSU 相关选项。
# 关闭 LOCALVERSION_AUTO：源码改过后自动算出的后缀会变，改为上面手动指定。
cp "$CI/device_config" "$OUT/.config"
"$SRC/scripts/config" --file "$OUT/.config" \
	--disable LOCALVERSION_AUTO \
	--enable KSU \
	--enable KSU_MANUAL_HOOK \
	--disable KSU_DEBUG \
	--enable KSU_SUSFS
make "${MAKE_ARGS[@]}" olddefconfig

grep -E '^CONFIG_KSU|^# CONFIG_KSU' "$OUT/.config"
# manual hook 方式要求关闭 kprobes，否则 KSU 会走 kprobes 那套 hook
if grep -q '^CONFIG_KPROBES=y' "$OUT/.config"; then
	echo "CONFIG_KPROBES 被打开了，manual hook 方式要求关闭它" >&2
	exit 1
fi

make "${MAKE_ARGS[@]}" -j"$JOBS" Image 2>&1 | tee "$OUT/build.log"

# 检查版本后缀，对不上的话刷进去 WiFi 会打不开
RELEASE=$(cat "$OUT/include/config/kernel.release")
echo "kernel.release: $RELEASE"
case $RELEASE in
*-perf"$PINNED_LOCALVERSION") ;;
*)
	echo "版本字符串 $RELEASE 不是以 -perf$PINNED_LOCALVERSION 结尾，" \
	     "厂商 WiFi 模块会拒绝加载" >&2
	exit 1
	;;
esac

# 每次都用干净的 AnyKernel3 目录，避免把旧的 Image 或 ksu_susfs 打进包里
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
# 刷机时由 anykernel.sh 安装到 /data/adb/ksu/bin/ksu_susfs
cp "$DIST/ksu_susfs" "$ak3/ksu_susfs"

ZIP_NAME=YouYouSU-Next-legacy-SUSFS-$SUSFS_VERSION-guacamole-${RELEASE##*-perf-}-$(date +%Y%m%d-%H%M).zip
(cd "$ak3" && zip -qr9 "$DIST/$ZIP_NAME" . -x '.git*' -x '.github/*' -x 'README.md')
echo "刷机包: $DIST/$ZIP_NAME"

# 给工作流后续步骤用：输出 zip 路径、版本等信息
if [ -n "${GITHUB_OUTPUT:-}" ]; then
	{
		echo "zip=$DIST/$ZIP_NAME"
		echo "zip_name=$ZIP_NAME"
		echo "release=$RELEASE"
		echo "susfs_version=$SUSFS_VERSION"
	} >>"$GITHUB_OUTPUT"
fi
