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
#   VARIANTS             要出包的管理器签名，空格分隔（默认：youyou official）
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

# 内核只认一个签名的管理器，所以每种管理器各编一次内核、各出一套刷机包：
#   youyou    YouYouSU-Next（自签名，RSA 2048，证书不能超过 1024 字节），
#             换签名密钥后用 ksu_cert_hash.sh 重新计算
#   official  官方 KernelSU-Next 管理器，签名取 KernelSU-Next Kbuild 里的默认值，
#             自动跟着 submodule 走。YouYouSU-Next 来不及跟进官方时可以先用它
# 第二次编译只有 KernelSU 的几个文件要重新编译，再加一次 LTO 链接。
# 本地只想要其中一种时设 VARIANTS=youyou。
VARIANTS=${VARIANTS:-youyou official}
YOUYOU_MANAGER_SIZE=${KSU_NEXT_MANAGER_SIZE:-0x2cf}
YOUYOU_MANAGER_HASH=${KSU_NEXT_MANAGER_HASH:-3ba777f7e137c0a3bc0b8da19d32415ba68078d9d2a4ec57d30ad5c965281804}
OFFICIAL_MANAGER_SIZE=$(sed -n 's/^KSU_NEXT_MANAGER_SIZE := \(0x[0-9a-fA-F]*\)$/\1/p' "$SRC/drivers/kernelsu/Kbuild")
OFFICIAL_MANAGER_HASH=$(sed -n 's/^KSU_NEXT_MANAGER_HASH := \([0-9a-f]\{64\}\)$/\1/p' "$SRC/drivers/kernelsu/Kbuild")
if [ -z "$OFFICIAL_MANAGER_SIZE" ] || [ -z "$OFFICIAL_MANAGER_HASH" ]; then
	echo "从 drivers/kernelsu/Kbuild 读不出官方管理器签名（KernelSU-Next 改了写法？）" >&2
	exit 1
fi

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

# KernelSU-Next 的 Kbuild 发现内核里缺它要的函数或字段时，会在编译时用 sed 直接改内核源码
# （比如往 seccomp.h 插字段，不加 genksyms 保护，符号 CRC 就变了）。本分支已经手动加好，
# 正常不会触发；触发了说明新版 KernelSU-Next 又加了自动修改，要照“关键设计”第 2 条手动处理。
# 对比编译前后的 git diff，本地有没提交的改动也不会误报；ci/、.github/、文档不算内核源码，
# 编译期间改它们也不会误报。
SRC_PATHS=(. ':!ci' ':!.github' ':!*.md')
src_diff() { git -C "$SRC" diff --ignore-submodules -- "${SRC_PATHS[@]}" | sha1sum; }
src_before=$(src_diff)

# 编译一种管理器签名的内核，并做各项检查
build_kernel() {
	local size=$1 hash=$2
	make "${MAKE_ARGS[@]}" -j"$JOBS" \
		KSU_NEXT_MANAGER_SIZE="$size" KSU_NEXT_MANAGER_HASH="$hash" \
		Image 2>&1 | tee -a "$OUT/build.log"

	if [ "$(src_diff)" != "$src_before" ]; then
		git -C "$SRC" diff --stat --ignore-submodules -- "${SRC_PATHS[@]}" >&2
		echo "编译过程中内核源码被修改了（多半是 KernelSU-Next 的 Kbuild 自动打的补丁），" \
		     "可能改变符号 CRC。请把改动手动加进源码并对 genksyms 隐藏，见 KERNELSU.md" >&2
		exit 1
	fi

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

	# 确认 Image 里编进去的确实是这次要的签名（Image 未压缩，哈希以字符串形式存在）
	if ! grep -qaF "$hash" "$OUT/arch/arm64/boot/Image"; then
		echo "Image 里找不到管理器签名哈希 $hash" >&2
		exit 1
	fi
}

# 打包一套刷机包（普通包 + OTA 包）。$1 是 zip 文件名前缀，也是刷机时显示的管理器名
package() {
	local name=$1
	# 每次都用干净的 AnyKernel3 目录，避免把旧的 Image 或 ksu_susfs 打进包里
	local ak3=$WORK/AnyKernel3
	if [ ! -d "$ak3/.git" ]; then
		git clone -q "$AK3_REPO" "$ak3"
	fi
	git -C "$ak3" cat-file -e "$AK3_COMMIT^{commit}" 2>/dev/null || git -C "$ak3" fetch -q origin
	git -C "$ak3" checkout -q -f --detach "$AK3_COMMIT"
	git -C "$ak3" clean -qfdx
	find "$ak3" -name placeholder -delete
	sed "s/^kernel\.string=.*/kernel.string=LineageOS sm8150 4.14 + $name (manual hook) + SUSFS $SUSFS_VERSION/" \
		"$CI/anykernel/anykernel.sh" >"$ak3/anykernel.sh"
	cp "$OUT/arch/arm64/boot/Image" "$ak3/Image"
	# 刷机时由 anykernel.sh 安装到 /data/adb/ksu/bin/ksu_susfs
	cp "$DIST/ksu_susfs" "$ak3/ksu_susfs"

	ZIP_NAME=$name-legacy-SUSFS-$SUSFS_VERSION-guacamole-${RELEASE##*-perf-}-$STAMP.zip
	(cd "$ak3" && zip -qr9 "$DIST/$ZIP_NAME" . -x '.git*' -x '.github/*' -x 'README.md')
	echo "刷机包: $DIST/$ZIP_NAME"

	# OTA 专用包：与普通包只差 anykernel.sh 里的一行 SLOT_SELECT=inactive，
	# AnyKernel3 会把目标从当前槽位换成另一个槽位。用于 OTA 装完、还没重启时，
	# 在管理器里“刷入 AnyKernel”，把内核写进新系统所在的槽位，重启后 root 不丢。
	ZIP_OTA_NAME=${ZIP_NAME%.zip}-OTA-inactive.zip
	sed -i 's/^IS_SLOT_DEVICE=1;$/&\n# OTA 专用包：写入非活动槽位（由 ci\/build.sh 插入）\nSLOT_SELECT=inactive;/' "$ak3/anykernel.sh"
	if [ "$(grep -cx 'SLOT_SELECT=inactive;' "$ak3/anykernel.sh")" != 1 ]; then
		echo "生成 OTA 包失败：anykernel.sh 里找不到 IS_SLOT_DEVICE=1; 这一行" >&2
		exit 1
	fi
	(cd "$ak3" && zip -qr9 "$DIST/$ZIP_OTA_NAME" . -x '.git*' -x '.github/*' -x 'README.md')
	echo "OTA 刷机包: $DIST/$ZIP_OTA_NAME"
}

# 文件名里的时间用北京时间（GitHub 的机器默认是 UTC），所有包用同一个时间
STAMP=$(TZ=Asia/Shanghai date +%Y%m%d-%H%M)
: >"$OUT/build.log"
for v in $VARIANTS; do
	case $v in
	youyou)   build_kernel "$YOUYOU_MANAGER_SIZE" "$YOUYOU_MANAGER_HASH";     package YouYouSU-Next ;;
	official) build_kernel "$OFFICIAL_MANAGER_SIZE" "$OFFICIAL_MANAGER_HASH"; package KernelSU-Next ;;
	*) echo "未知的 VARIANTS 取值：$v（可选 youyou、official）" >&2; exit 1 ;;
	esac
	# 给工作流后续步骤用：每种管理器的 zip 路径，如 zip_youyou、zip_ota_official
	if [ -n "${GITHUB_OUTPUT:-}" ]; then
		{
			echo "zip_$v=$DIST/$ZIP_NAME"
			echo "zip_ota_$v=$DIST/$ZIP_OTA_NAME"
		} >>"$GITHUB_OUTPUT"
	fi
	# 第一个变体的 zip 名用作 Artifact 名
	FIRST_ZIP_NAME=${FIRST_ZIP_NAME:-$ZIP_NAME}
done

if [ -n "${GITHUB_OUTPUT:-}" ]; then
	{
		echo "zip_name=$FIRST_ZIP_NAME"
		echo "release=$RELEASE"
		echo "susfs_version=$SUSFS_VERSION"
	} >>"$GITHUB_OUTPUT"
fi
