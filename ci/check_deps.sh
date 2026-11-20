#!/usr/bin/env bash
# 检查 KernelSU-Next、SUSFS、管理器有没有需要跟进的更新，有就在本仓库开 Issue 提醒
# （GitHub 会发邮件）。只通知，不修改任何代码；升级仍按 KERNELSU.md 手动做。
# 由 .github/workflows/check-deps.yml 每天调用，本地也能试运行（只打印，不开 Issue）：
#
#   DRY_RUN=1 ci/check_deps.sh
#   DRY_RUN=1 KSU_CUR=<旧提交> SUSFS_CUR=<旧提交> ci/check_deps.sh   # 模拟有更新
#
# 检查三项：
#   1. KernelSU-Next legacy 分支比 submodule 新 → Issue，并标出是否改了 uapi/（要不要一起更新管理器）、
#      Kbuild（可能在编译时改内核源码、影响 CRC）。非 DRY_RUN 时还会触发一次试编译（不发布），
#      结果由编译工作流回复到这个 Issue 下。
#   2. susfs4ksu kernel-4.14 分支比 build.sh 里的 SUSFS_COMMIT 新 → Issue。
#   3. 官方 dev 或 youyou 分支管理器的 MINIMAL_SUPPORTED_KERNEL 高于当前内核的 KSU 版本号 → Issue。
#
# 环境变量：
#   DRY_RUN       非空 = 只打印 Issue 内容，不调用 gh
#   KSU_CUR       覆盖当前 KernelSU-Next 提交（默认取 submodule 指向的提交）
#   SUSFS_CUR     覆盖当前 SUSFS 提交（默认取 ci/build.sh 的 SUSFS_COMMIT）
#   GITHUB_REPOSITORY、GH_TOKEN  非 DRY_RUN 时 gh 用
#   KSU_BRANCH    触发试编译用的分支（默认 lineage-24.0-ksu）
set -euo pipefail

SRC=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

KSU_URL=https://github.com/KernelSU-Next/KernelSU-Next.git
KSU_LEGACY=legacy
KSU_DEV=dev
MANAGER_URL=https://github.com/exyoyou/KernelSU-Next.git # YouYouSU-Next 管理器
MANAGER_BRANCH=youyou
SUSFS_URL=$(sed -n 's/^SUSFS_REPO=//p' "$SRC/ci/build.sh")
SUSFS_BRANCH=$(sed -n 's/^SUSFS_BRANCH=//p' "$SRC/ci/build.sh")
KSU_BRANCH=${KSU_BRANCH:-lineage-24.0-ksu}
REPO=${GITHUB_REPOSITORY:-exyoyou/android_kernel_oneplus_sm8150}

KSU_CUR=${KSU_CUR:-$(git -C "$SRC" ls-tree HEAD KernelSU-Next | awk '{print $3}')}
SUSFS_CUR=${SUSFS_CUR:-$(sed -n 's/^SUSFS_COMMIT=\([0-9a-f]*\).*/\1/p' "$SRC/ci/build.sh")}
[ -n "$KSU_CUR" ] && [ -n "$SUSFS_CUR" ] || { echo "读不到当前的 KernelSU-Next / SUSFS 提交" >&2; exit 1; }

# 管理器 versionCode 和内核里的 KSU 版本号用同一套算法：30000 + 提交数 + 289
# （见 KernelSU-Next/kernel/Kbuild）
ksu_version() { echo $((30000 + $(git -C "$TMP/ksu" rev-list --count "$1") + 289)); }

# 取某个仓库分支里管理器的 MINIMAL_SUPPORTED_KERNEL（Natives.kt 的路径随包名变，所以按文件名找）
min_kernel() {
	local d=$TMP/mgr-$2
	git clone -q --depth 1 --filter=blob:none --no-checkout --branch "$2" "$1" "$d"
	git -C "$d" grep -h 'MINIMAL_SUPPORTED_KERNEL *=' HEAD -- '*/Natives.kt' |
		grep -o '[0-9]\+' | head -n1
}

# 开 Issue 或更新已有的 Issue。
#   $1 标题前缀（同一类问题只保留一个打开的 Issue）  $2 完整标题  $3 正文文件
# 同样标题的 Issue 已经存在（不管开着还是关了）就跳过，不重复提醒；
# 有同类的旧 Issue 开着就改成新内容并回复一句，触发邮件。
# 新建或更新时在标准输出打印 Issue 编号，跳过时什么都不打印。
upsert_issue() {
	local prefix=$1 title=$2 body=$3 list num
	if [ -n "${DRY_RUN:-}" ]; then
		{ echo "===== [DRY_RUN] Issue: $title"; cat "$body"; echo "====="; } >&2
		return 0
	fi
	if ! list=$(gh issue list -R "$REPO" --state all --limit 300 --json number,title,state 2>&1); then
		echo "::error::读取 Issue 失败（$list）。请在仓库 Settings → General → Features 勾选 Issues" >&2
		exit 1
	fi
	if [ -n "$(jq -r --arg t "$title" '.[] | select(.title == $t) | .number' <<<"$list")" ]; then
		echo "已经提醒过：$title" >&2
		return 0
	fi
	num=$(jq -r --arg p "$prefix" \
		'[.[] | select(.state == "OPEN" and (.title | startswith($p)))][0].number // empty' <<<"$list")
	if [ -n "$num" ]; then
		gh issue edit "$num" -R "$REPO" --title "$title" --body-file "$body" >/dev/null
		gh issue comment "$num" -R "$REPO" --body "有更新的版本，内容已改为：$title" >/dev/null
		echo "已更新 Issue #$num：$title" >&2
	else
		num=$(gh issue create -R "$REPO" --title "$title" --body-file "$body" | grep -o '[0-9]\+$')
		echo "已创建 Issue #$num：$title" >&2
	fi
	echo "$num"
}

# 只拉提交，不拉文件内容，几秒钟就能完成
git clone -q --bare --filter=blob:none "$KSU_URL" "$TMP/ksu"
KSU_NEW=$(git -C "$TMP/ksu" rev-parse "refs/heads/$KSU_LEGACY")
KSU_CUR_VER=$(ksu_version "$KSU_CUR")
KSU_CUR_DESC=$(git -C "$TMP/ksu" describe --tags "$KSU_CUR")
DEV_MIN=$(min_kernel "$KSU_URL" "$KSU_DEV")
MGR_MIN=$(min_kernel "$MANAGER_URL" "$MANAGER_BRANCH")
echo "KernelSU-Next：当前 $KSU_CUR_DESC（$KSU_CUR_VER），legacy 最新 $(git -C "$TMP/ksu" describe --tags "$KSU_NEW")"
echo "管理器最低内核版本：官方 $KSU_DEV = $DEV_MIN，$MANAGER_BRANCH = $MGR_MIN"

# ---------- 1. KernelSU-Next legacy ----------
if [ "$KSU_NEW" != "$KSU_CUR" ]; then
	new_ver=$(ksu_version "$KSU_NEW")
	new_desc=$(git -C "$TMP/ksu" describe --tags "$KSU_NEW")
	count=$(git -C "$TMP/ksu" rev-list --count "$KSU_CUR..$KSU_NEW")
	uapi=$(git -C "$TMP/ksu" diff --stat "$KSU_CUR" "$KSU_NEW" -- uapi/ | tail -n1 | sed 's/^ *//')
	kbuild=$(git -C "$TMP/ksu" diff --stat "$KSU_CUR" "$KSU_NEW" -- kernel/Kbuild kernel/Makefile | tail -n1 | sed 's/^ *//')
	body=$TMP/ksu.md
	{
		echo "KernelSU-Next \`$KSU_LEGACY\` 分支有 $count 个新提交。"
		echo
		echo "| | 提交 | describe | 版本号 |"
		echo "|---|---|---|---|"
		echo "| 本仓库 submodule | \`${KSU_CUR:0:12}\` | \`$KSU_CUR_DESC\` | $KSU_CUR_VER |"
		echo "| 上游 $KSU_LEGACY | [\`${KSU_NEW:0:12}\`](${KSU_URL%.git}/commit/$KSU_NEW) | \`$new_desc\` | $new_ver |"
		echo
		echo "[全部改动](${KSU_URL%.git}/compare/$KSU_CUR...$KSU_NEW)"
		echo
		echo "### 需要注意"
		echo
		if [ -n "$uapi" ]; then
			echo "- ⚠️ **改了 \`uapi/\`**（$uapi）：内核与 ksud/管理器之间的接口变了，**管理器 APK 也要一起更新**（\`$MANAGER_BRANCH\` 分支 rebase 到官方 \`$KSU_DEV\` 后编译）。"
		else
			echo "- ✅ 没改 \`uapi/\`：只升级内核即可，管理器可以不动。"
		fi
		if [ -n "$kbuild" ]; then
			echo "- ⚠️ **改了 \`Kbuild\`/\`Makefile\`**（$kbuild）：可能新增了编译时自动修改内核源码的逻辑（比如往头文件里插字段），会改变符号 CRC，看试编译结果里的“内核源码”一项。"
		fi
		if [ "$new_ver" -lt "$MGR_MIN" ]; then
			echo "- ⚠️ 新版本号 $new_ver 仍低于 \`$MANAGER_BRANCH\` 管理器要求的最低版本 $MGR_MIN。"
		fi
		echo
		echo "### 新提交"
		echo
		echo '```'
		git -C "$TMP/ksu" log --no-merges --format='%h %s' "$KSU_CUR..$KSU_NEW" | head -n 60
		echo '```'
		echo
		echo "### 改动的文件"
		echo
		echo "（文件多时只列最后 40 行，完整的见上面“全部改动”）"
		echo
		echo '```'
		git -C "$TMP/ksu" diff --stat=100 "$KSU_CUR" "$KSU_NEW" | tail -n 40
		echo '```'
		echo
		echo "### 试编译"
		echo
		echo "已在云端用 \`${KSU_NEW:0:12}\` 试编译（不发布 Release），结果会回复在下面。试编译的包没有刷机测试过。"
		echo
		echo "### 升级步骤"
		echo
		echo "按 [KERNELSU.md](https://github.com/$REPO/blob/$KSU_BRANCH/KERNELSU.md) 的“升级 KernelSU-Next”：切换 submodule → 本地编译 → 对比 \`__crc_*\` → 刷机测试 → 提交推送。改完后关闭本 Issue。"
	} >"$body"
	num=$(upsert_issue "KernelSU-Next $KSU_LEGACY 有更新" \
		"KernelSU-Next $KSU_LEGACY 有更新：${KSU_CUR:0:12} → ${KSU_NEW:0:12}（$new_ver）" "$body")
	if [ -n "$num" ] && [ -z "${DRY_RUN:-}" ]; then
		gh workflow run build-ksu.yml -R "$REPO" --ref "$KSU_BRANCH" \
			-f ksu_ref="$KSU_NEW" -f report_issue="$num" -f release=false
		echo "已触发试编译，结果会回复到 Issue #$num"
	fi
else
	echo "KernelSU-Next $KSU_LEGACY 没有新提交"
fi

# ---------- 2. SUSFS ----------
git clone -q --bare --filter=blob:none --single-branch --branch "$SUSFS_BRANCH" "$SUSFS_URL" "$TMP/susfs"
SUSFS_NEW=$(git -C "$TMP/susfs" rev-parse HEAD)
susfs_ver() {
	git -C "$TMP/susfs" show "$1:kernel_patches/include/linux/susfs.h" |
		sed -n 's/^#define SUSFS_VERSION "\(.*\)"/\1/p'
}
if [ "$SUSFS_NEW" != "$SUSFS_CUR" ]; then
	cur_v=$(susfs_ver "$SUSFS_CUR") new_v=$(susfs_ver "$SUSFS_NEW")
	body=$TMP/susfs.md
	# 某几个路径的改动统计，没改就输出“无”
	changed() {
		local s
		s=$(git -C "$TMP/susfs" diff --stat "$SUSFS_CUR" "$SUSFS_NEW" -- "$@" | tail -n1)
		s=${s#"${s%%[! ]*}"}
		echo "${s:-无}"
	}
	{
		echo "susfs4ksu \`$SUSFS_BRANCH\` 分支有新提交。"
		echo
		echo "| | 提交 | SUSFS_VERSION |"
		echo "|---|---|---|"
		echo "| 本仓库（\`ci/build.sh\` 的 SUSFS_COMMIT） | \`${SUSFS_CUR:0:12}\` | $cur_v |"
		echo "| 上游 $SUSFS_BRANCH | [\`${SUSFS_NEW:0:12}\`](${SUSFS_URL%.git}/-/commit/$SUSFS_NEW) | $new_v |"
		echo
		echo "### 改动范围"
		echo
		echo "| 部分 | 改动 | 对本项目的影响 |"
		echo "|---|---|---|"
		echo "| 内核补丁 \`50_add_susfs_in_kernel-4.14.patch\` | $(changed 'kernel_patches/50_add_susfs_in_kernel-4.14.patch') | 要重新打补丁 |"
		echo "| \`fs/susfs.c\`、\`include/linux/susfs*.h\` | $(changed kernel_patches/fs kernel_patches/include) | 复制新文件；头文件变了，\`ksu_susfs\` 必须一起更新 |"
		echo "| KernelSU 对接补丁 \`10_enable_susfs_for_ksu.patch\` | $(changed kernel_patches/KernelSU) | 同步改 \`fs/susfs_ksu.c\`（本项目自写） |"
		echo "| 用户态工具 \`ksu_susfs/\` | $(changed ksu_susfs) | 刷机后手机上的 ksu_susfs 也要更新 |"
		echo
		echo "### 新提交"
		echo
		echo '```'
		git -C "$TMP/susfs" log --no-merges --format='%h %s' "$SUSFS_CUR..$SUSFS_NEW" | head -n 60
		echo '```'
		echo
		echo "### 升级步骤"
		echo
		echo "本项目的 SUSFS 与原版有 7 处差异，不能整体替换。按 [KERNELSU.md](https://github.com/$REPO/blob/$KSU_BRANCH/KERNELSU.md) 的“升级 SUSFS 的步骤”操作，改完 \`SUSFS_COMMIT\` 后关闭本 Issue。"
	} >"$body"
	upsert_issue "SUSFS 有更新" "SUSFS 有更新：$cur_v → $new_v（${SUSFS_NEW:0:12}）" "$body" >/dev/null
else
	echo "SUSFS $SUSFS_BRANCH 没有新提交"
fi

# ---------- 3. 管理器要求的最低内核版本 ----------
if [ "$DEV_MIN" -gt "$KSU_CUR_VER" ] || [ "$MGR_MIN" -gt "$KSU_CUR_VER" ]; then
	body=$TMP/min.md
	{
		echo "管理器要求的最低内核版本（\`MINIMAL_SUPPORTED_KERNEL\`）高于当前内核里的 KernelSU-Next 版本号 **$KSU_CUR_VER**（\`$KSU_CUR_DESC\`）。"
		echo
		echo "| 管理器 | MINIMAL_SUPPORTED_KERNEL |"
		echo "|---|---|"
		echo "| 官方 \`$KSU_DEV\` | $DEV_MIN |"
		echo "| YouYouSU-Next \`$MANAGER_BRANCH\` | $MGR_MIN |"
		echo
		if [ "$MGR_MIN" -gt "$KSU_CUR_VER" ]; then
			echo "- ⚠️ **\`$MANAGER_BRANCH\` 分支编出的管理器已经不认当前内核**：别装这个分支新编的 APK，先升级内核里的 KernelSU-Next，或把 \`$MANAGER_BRANCH\` 退回旧版本。"
			if [ "$DEV_MIN" -le "$KSU_CUR_VER" ]; then
				echo "- 官方管理器还认当前内核：急用可以先装官方 KernelSU-Next 管理器，刷 Release 里 \`KernelSU-Next-\` 开头的包。"
			fi
		else
			echo "- ⚠️ 官方 \`$KSU_DEV\` 已经提高了要求：**暂时不要把 \`$MANAGER_BRANCH\` rebase 到官方 \`$KSU_DEV\`**，否则新管理器会提示内核版本太旧；用官方管理器（\`KernelSU-Next-\` 开头的包）的也先别更新官方 APK。"
		fi
		echo "- 先看 \`$KSU_LEGACY\` 有没有更新到 ≥ $DEV_MIN 的版本（会有单独的 Issue），升级内核后再更新管理器。"
	} >"$body"
	upsert_issue "管理器最低内核版本" \
		"管理器最低内核版本（官方 $DEV_MIN / $MANAGER_BRANCH $MGR_MIN）高于当前内核 $KSU_CUR_VER" "$body" >/dev/null
else
	echo "管理器最低内核版本都不高于当前内核 $KSU_CUR_VER"
fi
