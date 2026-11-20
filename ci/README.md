# 云编译（KernelSU-Next + SUSFS）

工作流：[.github/workflows/build-ksu.yml](../.github/workflows/build-ksu.yml)，编译脚本：[build.sh](build.sh)。

| 文件 | 作用 |
|---|---|
| `build.sh` | 编译内核 + ksu_susfs，打包 AnyKernel3 zip（云端和本地通用） |
| `device_config` | 手机上 LineageOS 内核的配置（`adb shell zcat /proc/config.gz`） |
| `anykernel/anykernel.sh` | AnyKernel3 刷机脚本（只换内核，顺带安装 ksu_susfs） |
| `pack_clang.sh` | 把 AOSP clang 精简打包，供云端下载 |

## 一次性设置

1. 打包工具链并上传到 Release：
   ```bash
   ci/pack_clang.sh ~/android_kernel/toolchains/clang-r596125 clang-r596125-slim.tar.zst
   ```
   在 GitHub 仓库新建 Release，tag 填 `toolchain-clang-r596125`，附件上传 `clang-r596125-slim.tar.zst`。
2. （可选）想要每天自动跟进 LineageOS 上游：Settings → General → Default branch 改为 `lineage-24.0-ksu`。定时任务只在默认分支上运行。

## 什么时候会编译

- **push 到 `lineage-24.0-ksu`**：编译，zip 在该次运行页面的 Artifacts 里。
- **Actions → Build KSU kernel → Run workflow**：手动编译，可选先 rebase 到上游最新、发布 Release。
- **每天 04:00**：LineageOS `lineage-24.0` 有新提交时，在云端 rebase 并编译发布 Release。冲突会失败并发邮件，分支本身不会被改动。

## 版本后缀

厂商 WiFi 模块会校验内核版本字符串，必须和手机上的完全一致（如 `4.14.357-openela-perf-g9f007fac27dc`）。
`-gxxxxxxxxxxxx` 默认取本分支所基于的 LineageOS 提交。如果手机上的系统版本和它不一致（`adb shell uname -r` 对比），手动运行时在 `localversion` 里填手机上的后缀。

## 需要更新的时候

- **OTA 后**：如果上游改了内核配置，重新导出 `device_config` 并提交。
- **升级 SUSFS**：同时更新内核补丁和 `build.sh` 里的 `SUSFS_COMMIT`（脚本会检查头文件是否一致）。
- **更换管理器签名**：更新 `build.sh` 里的 `KSU_NEXT_MANAGER_SIZE/HASH`。
- **更换 clang**：重新打包上传，并在仓库 Variables 里设置 `CLANG_URL`、`CLANG_SHA256`（或改工作流里的默认值）。
