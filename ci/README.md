# 云编译（KernelSU-Next + SUSFS）

工作流：[.github/workflows/build-ksu.yml](../.github/workflows/build-ksu.yml)，编译脚本：[build.sh](build.sh)。

| 文件 | 作用 |
|---|---|
| `build.sh` | 编译内核 + ksu_susfs，打包 AnyKernel3 zip（云端和本地通用） |
| `device_config` | 手机上 LineageOS 内核的配置（`adb shell zcat /proc/config.gz`） |
| `anykernel/anykernel.sh` | AnyKernel3 刷机脚本（只换内核，顺带安装 ksu_susfs） |
| `check_deps.sh` | 检查 KernelSU-Next、SUSFS、管理器的更新，有就开 Issue |

## 工具链

用 AOSP clang r547379（clang 20），云端自动从谷歌公开仓库下载（固定在该仓库最后一个公开提交），不用手动上传。
本地编译：`CLANG_DIR=~/android_kernel/toolchains/clang-r547379 NDK=... ci/build.sh`

## 可选设置

想要每天自动跟进 LineageOS 上游：Settings → General → Default branch 改为 `lineage-24.0-ksu`。定时任务只在默认分支上运行。

## 什么时候会编译

- **push 到 `lineage-24.0-ksu`**：编译，zip 在该次运行页面的 Artifacts 里。
- **Actions → Build KSU kernel → Run workflow**：手动编译，可选先 rebase 到上游最新、发布 Release。
- **每天 04:00**：LineageOS `lineage-24.0` 有新提交时，在云端 rebase 并编译发布 Release。冲突会失败并发邮件，分支本身不会被改动。
- **每天 03:30**（[check-deps.yml](../.github/workflows/check-deps.yml)）：KernelSU-Next、SUSFS 有新提交，或管理器要求的最低内核版本超过当前内核时，开 Issue 提醒（只通知，不改代码）。KernelSU-Next 有新提交时还会自动试编译，结果回复到 Issue。需要在 Settings → General → Features 打开 Issues。本地试运行：`DRY_RUN=1 ci/check_deps.sh`。

## 两种管理器

内核只认一种签名的管理器，所以 `build.sh` 每次编译两遍内核（第二遍只重新编译 KernelSU 的几个文件，再加一次 LTO 链接），出两套包：

| 文件名开头 | 认哪个管理器 | 签名来源 |
|---|---|---|
| `YouYouSU-Next-` | YouYouSU-Next（自签名） | `build.sh` 里的 `YOUYOU_MANAGER_SIZE/HASH` |
| `KernelSU-Next-` | 官方 KernelSU-Next | KernelSU-Next `Kbuild` 里的默认值，跟着 submodule 自动更新 |

官方包用于 YouYouSU-Next 来不及跟进官方（比如合并冲突没空处理）时。两种包内核其余部分完全相同，切换时只要刷另一种包、装对应的管理器，`/data/adb` 里的模块和设置不受影响。
本地只要其中一种时设 `VARIANTS=youyou`（或 `official`）。

## 两个刷机包（每种管理器各一套）

| 文件 | 刷入方式 | 用途 |
|---|---|---|
| `...-<日期>.zip` | 电脑 `adb sideload`（系统没更新时也可用管理器“刷入 AnyKernel”） | 刷当前槽位：首次刷入、root 丢了要恢复、只换内核 |
| `...-<日期>-OTA-inactive.zip` | 手机管理器“刷入 AnyKernel (.zip)” | 刷另一个槽位：OTA 装完、还没重启时用，重启后 root 不丢 |

两个包只差 `anykernel.sh` 里的一行 `SLOT_SELECT=inactive;`。OTA 包不要在 Recovery 里用。
刷入前会自动对比目标槽位官方内核的版本后缀，不一致就中止、不写入，并在日志里显示需要的后缀。完整步骤见 [KERNELSU.md](../KERNELSU.md) 的“OTA 更新系统”。

## 版本后缀

厂商 WiFi 模块会校验内核版本字符串，必须和手机上的完全一致（如 `4.14.357-openela-perf-g9f007fac27dc`）。
`-gxxxxxxxxxxxx` 默认取本分支所基于的 LineageOS 提交。如果手机上的系统版本和它不一致（`adb shell uname -r` 对比），手动运行时在 `localversion` 里填手机上的后缀。

## 需要更新的时候

- **OTA 后**：如果上游改了内核配置，重新导出 `device_config` 并提交。
- **升级 SUSFS**：同时更新内核补丁和 `build.sh` 里的 `SUSFS_COMMIT`（脚本会检查头文件是否一致）。
- **更换 YouYouSU-Next 签名**：更新 `build.sh` 里的 `YOUYOU_MANAGER_SIZE/HASH`（也可以用环境变量 `KSU_NEXT_MANAGER_SIZE/HASH` 临时覆盖）。
- **更换 clang**：改工作流里的 `CLANG_NAME`、`CLANG_URL`，本地编译刷机测试后再推送。
