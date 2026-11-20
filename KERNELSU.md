# OnePlus 7 Pro 内核：KernelSU-Next + SUSFS

本分支在 LineageOS 官方内核上加入 KernelSU-Next（manual hook）和 SUSFS，并配置了 GitHub Actions 云编译。
这份文档记录项目结构、关键设计、日常操作和改动历史，供以后人工或 AI 接手时查阅。

## 基本信息

| 项目 | 内容 |
|---|---|
| 设备 | OnePlus 7 Pro（guacamole），sm8150，A/B 分区，非 GKI |
| 系统 | LineageOS 24.0 |
| 内核 | 4.14.357-openela（LineageOS `lineage-24.0` 分支） |
| 上游仓库 | https://github.com/LineageOS/android_kernel_oneplus_sm8150 （`lineage-24.0`） |
| 本仓库 | https://github.com/exyoyou/android_kernel_oneplus_sm8150 |
| 工作分支 | `lineage-24.0-ksu`（`lineage-24.0` 保持与上游一致，不放自己的改动） |
| KernelSU-Next | submodule，官方仓库 `legacy` 分支，当前 `v3.4.0-legacy-33-ge5f5ec99`（内核内版本号 33327） |
| SUSFS | v1.5.5，来自 susfs4ksu `kernel-4.14` 分支提交 `77905b5a071e`，直接写进内核源码 |
| 管理器 | YouYouSU-Next（自签名的 KernelSU-Next 管理器），源码在 https://github.com/exyoyou/KernelSU-Next 的 `youyou` 分支 |
| 编译器 | AOSP clang r547379（clang 20.0.0） |
| 刷机包 | AnyKernel3（osm0sis，固定提交 `41f04bd`），只替换内核 Image |

## 目录与文件

| 路径 | 说明 |
|---|---|
| `KernelSU-Next/` | submodule，KernelSU-Next 官方源码 |
| `drivers/kernelsu` | 软链接 → `../KernelSU-Next/kernel` |
| `fs/susfs.c`、`fs/susfs_ksu.c`、`include/linux/susfs*.h`、`fs/Kconfig.susfs` | SUSFS 主体 |
| `ci/build.sh` | 编译脚本：内核 + ksu_susfs + AnyKernel3 zip，云端和本地通用 |
| `ci/device_config` | 手机上 LineageOS 内核的配置（`adb shell zcat /proc/config.gz`），编译以它为起点 |
| `ci/anykernel/anykernel.sh` | 刷机脚本：只换内核（`split_boot` + `flash_boot`），并把 ksu_susfs 装到 `/data/adb/ksu/bin` |
| `ci/README.md` | 云编译的使用说明 |
| `.github/workflows/build-ksu.yml` | GitHub Actions 工作流 |

### 内核源码改动

**KernelSU-Next manual hook**（不用 kprobes，`CONFIG_KPROBES` 必须关闭）：

| 文件 | 内容 |
|---|---|
| `fs/exec.c` | `ksu_handle_execveat_ksud`、`ksu_handle_execveat_sucompat` |
| `fs/open.c` | `ksu_handle_faccessat` |
| `fs/read_write.c` | `ksu_handle_vfs_read` |
| `fs/stat.c` | `ksu_handle_stat`、`ksu_handle_newfstat_ret` |
| `drivers/input/input.c` | `ksu_handle_input_handle_event`（音量键安全模式） |
| `kernel/reboot.c` | `ksu_handle_sys_reboot` |
| `security/selinux/avc.c` | `ksu_handle_slow_avc_audit` |
| `fs/namespace.c`、`fs/internal.h` | 从 v5.9 移植 `can_umount()`/`path_umount()`，供模块卸载挂载用。KSU-Next 编译时 grep 本文件里的 `path_umount` 定义来决定是否使用它，函数定义的写法不要改 |
| `include/linux/seccomp.h` | 新增 `filter_count` 字段，见下方“关键设计” |
| `drivers/Kconfig`、`drivers/Makefile` | 接入 `drivers/kernelsu` |

**SUSFS v1.5.5**：`fs/namei.c`、`fs/namespace.c`、`fs/dcache.c`、`fs/readdir.c`、`fs/stat.c`、`fs/statfs.c`、`fs/proc/*`、`fs/proc_namespace.c`、`fs/notify/fdinfo.c`、`fs/overlayfs/*`、`include/linux/mount.h`、`include/linux/sched.h`、`kernel/kallsyms.c`、`kernel/sys.c`。
用来对普通应用隐藏 KSU 的挂载、路径、kstat、maps、cmdline、kallsyms 符号等。

## 关键设计（改动前必读）

1. **内核版本字符串必须和手机上的官方内核完全一致。**
   厂商 WiFi 模块 `qca_cld3_wlan.ko` 加载时会校验 vermagic，字符串不一致 WiFi 就打不开。
   格式是 `4.14.357-openela-perf-g<12 位提交号>`：`-perf` 来自配置里的 `CONFIG_LOCALVERSION`，`-g...` 是官方构建所用的 LineageOS 提交。
   改了源码之后 `LOCALVERSION_AUTO` 算出来的值会变，所以要关掉它，再通过 `LOCALVERSION=` 手动指定。
   `ci/build.sh` 默认取“本分支与上游的 merge-base”的前 12 位，可以用 `PINNED_LOCALVERSION` 覆盖。编译完会检查后缀，不对就报错。

2. **不能改变内核导出符号的 CRC。**
   开启了 `MODVERSIONS`，厂商的预编译模块依赖符号 CRC。
   `seccomp.filter_count` 这个字段 4.14 上 KSU 运行时其实用不到，但 KSU-Next 编译时如果在 `include/linux/seccomp.h` 里找不到它，会自动用 sed 插入，而且不加 genksyms 保护，CRC 就变了。
   所以手动加上：放在 `struct seccomp` 中 `mode` 后面的对齐空洞里，结构体大小和后续字段偏移都不变，再用 `#ifndef __GENKSYMS__` 对 genksyms 隐藏，CRC 也就不变。
   以后加字段要遵循同样的原则。改完可以对比新旧 `vmlinux` 的 `__crc_*` 符号（`llvm-nm vmlinux | grep __crc_`）确认没变。

3. **从手机的配置编译，不用 defconfig。**
   `ci/device_config` 是手机上正在运行的配置，`build.sh` 在它基础上打开 `KSU`、`KSU_MANUAL_HOOK`、`KSU_SUSFS`，关闭 `KSU_DEBUG`、`LOCALVERSION_AUTO`，再跑 `olddefconfig`。
   `sm8150-perf_defconfig` 里虽然也加了 KSU 选项，但编译时实际不用它。

4. **管理器签名。**
   内核只认指定签名的管理器。通过 make 参数 `KSU_NEXT_MANAGER_SIZE=0x2cf`、`KSU_NEXT_MANAGER_HASH=3ba777f7...` 指定为 YouYouSU-Next 的签名（官方管理器装上会不被识别）。
   换签名密钥后，用 `~/android_kernel/ksu_cert_hash.sh <keystore> <alias>` 重新计算，再改 `ci/build.sh`。

5. **KernelSU-Next 的版本号来自 submodule 的 git 历史。**
   它的 Kbuild 用 `git rev-list --count` 和 `git describe --tags` 计算版本（33327）。submodule 如果是浅克隆或缺 tag，版本号会出错，管理器可能提示版本不对。云端会完整拉取 submodule 和 tag。

6. **SUSFS 内核补丁和 ksu_susfs 用户态工具必须同一版本。**
   `build.sh` 从 susfs4ksu 的 `SUSFS_COMMIT` 编译 ksu_susfs，并比对 `include/linux/susfs.h`、`susfs_def.h` 与该提交是否一致，不一致就报错。
   ksu_susfs 由刷机脚本装到 `/data/adb/ksu/bin`。Lineage Recovery 访问不了 `/data`，这时会跳过，需要开机后运行 `~/android_kernel/push_ksu_susfs.sh` 推送。它存在 `/data` 里，OTA 和重刷内核都不会丢，只有 SUSFS 版本变了才需要更新。

7. **内核的 `.gitignore` 忽略了所有点开头的文件。**
   `.github/` 下的文件要用 `git add -f` 才能提交。

## 云编译（GitHub Actions）

| 触发 | 行为 |
|---|---|
| push 到 `lineage-24.0-ksu`（只改 `.md` 的提交不触发） | 编译，zip 在运行页面的 Artifacts 里 |
| Actions 页面手动运行 | 可选：先 rebase 到上游最新（只在云端，不推送）、手动指定 `localversion`、发布 Release |
| 每天北京时间 04:00 | 上游 `lineage-24.0` 有新提交时，在云端 rebase、编译、发布 Release；冲突则运行失败并发邮件。只有当 `lineage-24.0-ksu` 是仓库默认分支时才会运行 |

- clang 从 AOSP 公开仓库 `platform/prebuilts/clang/host/linux-x86` 的最后一个公开提交 `70a12c4fe889` 下载，删掉不用的部分后缓存。
- NDK r27 用来编译 ksu_susfs。
- 本机 12 核编译大约 3–7 分钟。GitHub 的 4 核机器预计要慢好几倍，以第一次实际运行为准。

## 本地编译

```bash
CLANG_DIR=~/android_kernel/toolchains/clang-r547379 \
NDK=~/Android/Sdk/ndk/27.0.12077973 \
PINNED_LOCALVERSION=-g9f007fac27dc \
ci/build.sh
```

输出在 `../ci-work/dist/`。没有配置 `upstream` 远程时，要手动给 `PINNED_LOCALVERSION`。

仓库外 `~/android_kernel/` 下的相关文件（不在 git 里）：

| 文件 | 说明 |
|---|---|
| `build_ksu.sh` | 早期的本地编译脚本（clang r596125），功能已被 `ci/build.sh` 取代 |
| `push_ksu_susfs.sh` | 开机后通过 adb 把 ksu_susfs 推到手机 |
| `ksu_cert_hash.sh` | 从 keystore 计算管理器签名的大小和哈希 |
| `toolchains/` | clang、AnyKernel3、susfs4ksu |
| `KernelSU-Next-fork/` | YouYouSU-Next 管理器源码 |
| `dist/` | 编译出的 zip 和 ksu_susfs |

## 日常操作

### OTA 更新系统

有电脑：

1. 系统设置 → 更新器，安装 OTA 并重启（root 暂时消失）。
2. `adb shell uname -r` 查看新的后缀 `-gxxxxxxxxxxxx`。
3. 在 Releases 下载文件名后缀相同的 zip。没有的话，手动运行工作流：勾选 `rebase_upstream`，`localversion` 填这个后缀。
4. `adb reboot recovery` → Apply update → Apply from ADB → `adb sideload <zip>`。

只用手机（需要 root 状态下的 Kernel Flasher）：

1. 更新器安装 OTA，**先不要重启**。
2. Kernel Flasher 查看另一个槽位的内核版本后缀，下载对应 zip，刷入**另一个槽位**。
3. 重启，root 保持不丢。

后缀对不上的表现：能开机、KSU 正常，但 WiFi 打不开。重刷后缀正确的 zip 就能恢复。

### 跟进 LineageOS 上游

```bash
git remote add upstream https://github.com/LineageOS/android_kernel_oneplus_sm8150.git   # 首次
git fetch --unshallow origin                                                            # 本地是浅克隆时，首次
git fetch upstream lineage-24.0
git rebase upstream/lineage-24.0
git push -f origin lineage-24.0-ksu
```

冲突一般出现在上游改了 `fs/namespace.c`、`fs/namei.c` 等 hook 所在文件时。
如果上游改了内核配置，从更新后的手机重新导出 `ci/device_config`。

### 升级 KernelSU-Next

```bash
cd KernelSU-Next && git fetch origin --tags
git log --oneline HEAD..origin/legacy        # 先看改了什么，留意 hook 和 susfs 相关的提交
git checkout <新的 legacy tag 或提交>
cd .. && git add KernelSU-Next && git commit
```

- hook 函数签名变了会编译报错，按新版文档修改上面那几处 hook。
- 新版可能要求更新的 SUSFS。
- 手机上的管理器（YouYouSU-Next）最好同步升级到对应版本。
- 建议只跟正式的 `*-legacy` tag。

### 升级 SUSFS

1. 用 susfs4ksu `kernel-4.14` 分支的新版补丁更新内核源码。
2. 把 `ci/build.sh` 里的 `SUSFS_COMMIT` 改成同一个提交。
3. 编译、刷机测试。刷完后 ksu_susfs 也要更新（刷机脚本会装，Lineage Recovery 下需要 `push_ksu_susfs.sh`）。

### LineageOS 大版本升级（如 24 → 25）

上游会开新分支。在新分支上开 `lineage-25.0-ksu`，cherry-pick 本分支的 KSU、SUSFS、CI 提交，再改工作流里的分支名。旧内核包不要刷到新系统上。

### 刷机测试清单

能开机 → WiFi 正常 → `cat /proc/version` 确认是新内核 → 管理器显示已工作 → root 和模块正常 → `ksu_susfs show version` → 日常使用一两天。
出问题就 sideload 上一个能用的 zip。

## 改动历史

本分支在上游 `9f007fac2`（power: oplus: Move OEM power supply props to oplus_chg class）之上，共有以下提交。提交号以 2026-11-21 时为准，rebase 后会变。提交说明统一用中文。

| 提交 | 标题 | 说明 |
|---|---|---|
| `4fb8fcf70` | drivers: 加入 KernelSU-Next（manual hook） | 加 submodule 和软链接，加 manual hook、`path_umount` 移植、seccomp `filter_count`，defconfig 开启 KSU |
| `566a6a7b3` | fs: 加入 SUSFS v1.5.5 | 打入 susfs4ksu `77905b5a071e` 的内核补丁 |
| `70bee9718` | ci: 用 GitHub Actions 云编译 KernelSU-Next + SUSFS 内核 | 加入 `ci/` 和工作流，最初用 clang r596125（从仓库 Release 下载精简包） |
| `c1c04fa1c` | ci: 改用 AOSP 公开的 clang r547379 | r596125 来自 Android CI 内部构建，已无法匿名下载，改用 AOSP 公开的 r547379，删掉 `ci/pack_clang.sh`。已刷机测试通过 |
| `9b124b7ca` | docs: 加入 KernelSU-Next + SUSFS 项目说明 | 新增本文档和 CLAUDE.md |
| （最新） | 注释: 给 KSU hook 和云编译脚本加中文注释 | 说明每个 hook 的作用。SUSFS 补丁文件保持原样，不加注释，方便以后整体替换升级。编译验证通过，符号 CRC 不变 |

### 历程

- **2026-11-20**：在 LineageOS 24.0 内核（`9f007fac2`）上接入 KernelSU-Next legacy（manual hook），先只编译 KSU 测试，再加入 SUSFS v1.5.5。
  本地脚本 `build_ksu.sh` 用 clang r596125 编译。处理过三个问题：WiFi 模块 vermagic（固定版本后缀）、厂商模块 CRC（seccomp 字段藏进空洞并对 genksyms 隐藏）、管理器换成自签名的 YouYouSU-Next。
- **2026-11-20**：KSU 和 SUSFS 拆成两个提交放到 `lineage-24.0-ksu`，加入 GitHub Actions 云编译。随后切到 AOSP 公开的 clang r547379，本地编译刷机测试正常。
