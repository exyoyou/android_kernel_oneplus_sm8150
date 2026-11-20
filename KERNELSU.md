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
| `ci/build.sh` | 编译脚本：内核 + ksu_susfs + AnyKernel3 zip（普通包和 `-OTA-inactive` 包），云端和本地通用 |
| `ci/device_config` | 手机上 LineageOS 内核的配置（`adb shell zcat /proc/config.gz`），编译以它为起点 |
| `ci/anykernel/anykernel.sh` | 刷机脚本：只换内核（`split_boot` + `flash_boot`），刷入前检查版本后缀，并把 ksu_susfs 装到 `/data/adb/ksu/bin` |
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

**SUSFS v1.5.5**：用来对普通应用隐藏 KSU 的挂载、路径、kstat、maps、cmdline、kallsyms 符号等，详见下一节。

## SUSFS 各文件的作用

### 工作方式

1. 模块或脚本调用用户态工具 `ksu_susfs`（如 `ksu_susfs add_sus_path /xxx`）设置隐藏规则。
2. `ksu_susfs` 通过 `prctl(0xDEADBEEF, CMD_SUSFS_*, ...)` 把命令交给内核：`kernel/sys.c` 的 prctl 入口 → `fs/susfs_ksu.c` 的 `susfs_handle_prctl()` → `fs/susfs.c` 保存规则。
3. 规则落到 inode、mount 的标志位上。`fs/susfs_ksu.c` 的 LSM hook（`task_fix_setuid`）在 zygote 派生出普通应用进程时，给进程打上“非 root 应用”标记（`task_struct.susfs_task_state`），同时对它执行 try_umount。
4. 下面这些 VFS/proc 里的 hook 只对带标记的进程生效，root 进程和 KSU 自己看到的都是真实情况。

### 核心文件

| 文件 | 来源 | 作用 |
|---|---|---|
| `fs/susfs.c` | 与 susfs4ksu 原版完全一致 | SUSFS 主体：保存各类隐藏规则，提供给各 hook 调用的判断和伪造函数 |
| `include/linux/susfs.h` | 原版，**不能改** | 命令号、规则结构体、函数声明。编译脚本会与 susfs4ksu 原文件逐字节比对 |
| `include/linux/susfs_def.h` | 原版，**不能改** | inode/mount 标志位、特殊 mnt_id 等常量。同样会被比对 |
| `fs/susfs_ksu.c` | **本项目自写** | SUSFS 与 KSU-Next legacy 的对接代码，见下方“与原版的差异” |
| `fs/Kconfig.susfs` | 本项目调整 | SUSFS 的配置菜单，由 `fs/Kconfig` 引入 |

### hook 所在文件

| 文件 | 配置项 | 作用 |
|---|---|---|
| `fs/namei.c` | `SUS_PATH`、`OPEN_REDIRECT` | 路径查找时，对应用把隐藏路径当作不存在；按规则把打开某路径重定向到另一路径 |
| `fs/dcache.c` | `SUS_PATH` | dentry 缓存查找（`__d_lookup`）时跳过隐藏路径 |
| `fs/readdir.c` | `SUS_PATH` | 列目录（`filldir` 系列）时不返回隐藏的条目 |
| `fs/stat.c` | `SUS_KSTAT` | `generic_fillattr` 中对标记的文件返回伪造的 ino、dev 等，让被替换的文件看起来像原文件 |
| `fs/proc/task_mmu.c` | `SUS_KSTAT` | `/proc/<pid>/maps` 中伪造被标记文件的 dev、ino |
| `fs/namespace.c` | `SUS_MOUNT`、`TRY_UMOUNT`、`AUTO_ADD_*` | KSU 创建的挂载从单独的号段分配 mnt_id，不在普通挂载的编号里留下空洞；自动把 KSU 默认挂载和 bind mount 加入隐藏列表、try_umount 列表；zygote 复制挂载命名空间时的处理 |
| `fs/proc_namespace.c` | `SUS_MOUNT` | `/proc/<pid>/mounts`、`mountinfo`、`mountstats` 中不显示隐藏的挂载 |
| `fs/proc/fd.c` | `SUS_MOUNT` | `/proc/<pid>/fdinfo` 里的 mnt_id 改为伪造值 |
| `fs/notify/fdinfo.c` | `SUS_MOUNT` | inotify 的 fdinfo 里隐藏相关挂载信息 |
| `fs/statfs.c` | `SUS_MOUNT` | statfs 对隐藏挂载返回伪造的结果 |
| `fs/proc/cmdline.c` | `SPOOF_CMDLINE_OR_BOOTCONFIG` | 按规则伪造 `/proc/cmdline` 的内容（如隐藏解锁相关参数） |
| `kernel/sys.c` | `SPOOF_UNAME`，以及 prctl 入口 | 伪造 `uname` 返回的内核版本；prctl 入口把 SUSFS 命令交给 `fs/susfs_ksu.c` |
| `kernel/kallsyms.c` | `HIDE_KSU_SUSFS_SYMBOLS` | `/proc/kallsyms` 中不显示名字含 `ksu_`、`susfs`、`kernelsu`、`ksud`、`ksuver` 的符号 |
| `include/linux/mount.h` | `KSU_SUSFS` | `struct vfsmount` 新增 `susfs_mnt_id_backup`，保存挂载原本的 mnt_id |
| `include/linux/sched.h` | `KSU_SUSFS` | `struct task_struct` 新增 `susfs_task_state`（进程标记）、`susfs_last_fake_mnt_id` |
| `fs/overlayfs/*` | `SUS_OVERLAYFS` | 伪造 overlayfs 文件的 kstat/statfs。**本内核没开这个选项，这些改动不生效**：KSU-Next legacy 用 magic mount 挂模块（`HAS_MAGIC_MOUNT=y`），不用 overlayfs |

当前开启的选项（`ci/build.sh` 编译出的 `.config`）：`HAS_MAGIC_MOUNT`、`SUS_PATH`、`SUS_MOUNT`、`AUTO_ADD_SUS_KSU_DEFAULT_MOUNT`、`AUTO_ADD_SUS_BIND_MOUNT`、`SUS_KSTAT`、`TRY_UMOUNT`、`AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT`、`SPOOF_UNAME`、`ENABLE_LOG`、`HIDE_KSU_SUSFS_SYMBOLS`、`SPOOF_CMDLINE_OR_BOOTCONFIG`、`OPEN_REDIRECT`（均省略 `CONFIG_KSU_SUSFS_` 前缀）。没开的只有 `SUS_OVERLAYFS`。

### 与 susfs4ksu 原版的差异（升级 SUSFS 时要重做）

用 susfs4ksu `77905b5a071e` 的 `kernel_patches/50_add_susfs_in_kernel-4.14.patch` 和原版文件对比，差异如下：

1. **新增 `fs/susfs_ksu.c`**。原版通过 `kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch` 修改 KernelSU 本身（`core_hook.c`、`selinux.c`），但 KSU-Next legacy 的内部结构不同，也没有 prctl 接口，那个补丁打不上。所以同样的功能改写在这个文件里，用 KSU-Next 现有的符号实现：
   - SELinux 域判断（是不是 KSU 进程、zygote 进程），供 `fs/namespace.c` 等 hook 使用
   - `ksu_try_umount()`、`susfs_try_umount_all()`
   - prctl 命令接口 `susfs_handle_prctl()`，供 `ksu_susfs` 使用
   - `task_fix_setuid` LSM hook：给普通应用进程打标记，并对它执行 try_umount
2. **`kernel/sys.c`** 的 prctl 系统调用开头加了调用 `susfs_handle_prctl()` 的入口（原版这部分在 KernelSU 里）。
3. **`fs/Kconfig.susfs`**：配置菜单原版放在 KernelSU 的 Kconfig 里，这里移到 `fs/`，由 `fs/Kconfig` 引入。
4. **`fs/Makefile`**：多编译 `susfs_ksu.o`。
5. **保持 CRC 不变**（原因同“关键设计”第 2 条）：
   - `include/linux/mount.h`、`include/linux/sched.h` 新增的字段加了 `!defined(__GENKSYMS__)`，对 genksyms 隐藏；
   - `fs/statfs.c` 对 `susfs_def.h` 和 `mount.h` 的 include 也对 genksyms 隐藏，否则 `vfs_statfs()` 原型里类型的展开方式会变，CRC 跟着变。
6. **`kernel/kallsyms.c`**：原版只匹配 `ksu_` 和以 `susfs_`、`ksud` 开头的名字。这里改成子串匹配，并加了 `kernelsu`、`ksuver`，这样 LTO 改过名的局部符号（如 `__func__.susfs_init.llvm.123`）也能藏住。不用单独的 `ksu`，因为它会误伤 `cksum`。
7. **`fs/proc/cmdline.c`、`fs/proc/task_mmu.c`**：原版补丁在这两个文件上打不上（上下文与本内核不同），是手动按原意移植的。

### 升级 SUSFS 的步骤

1. 在 KSU 提交（只含 KSU、不含 SUSFS 的状态）上打新版 `50_add_susfs_in_kernel-4.14.patch`，复制新版的 `fs/susfs.c`、`include/linux/susfs*.h`。
2. 把上面 7 处差异重做一遍。`fs/susfs_ksu.c` 要对照新版 `10_enable_susfs_for_ksu.patch` 的变化同步修改（比如新增的命令）。
3. 改 `ci/build.sh` 里的 `SUSFS_COMMIT`。
4. 编译，对比新旧 `vmlinux` 的 `__crc_*` 符号确认 CRC 没变，再刷机测试。刷完记得更新手机上的 `ksu_susfs`。

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

每次编译出两个包，内核和 ksu_susfs 完全相同，只是刷入的槽位不同：

| 文件 | 刷入方式 | 刷到哪 | 什么时候用 |
|---|---|---|---|
| `YouYouSU-Next-...-<日期>.zip` | 电脑 `adb sideload`（系统没更新时也可以用管理器“刷入 AnyKernel”） | 当前槽位 | 首次刷入、root 丢了要恢复、只换内核 |
| `YouYouSU-Next-...-<日期>-OTA-inactive.zip` | 手机管理器“刷入 AnyKernel (.zip)” | 另一个槽位 | OTA 装完、还没重启时 |

OTA 包只比普通包多 `anykernel.sh` 里的一行 `SLOT_SELECT=inactive;`（`ci/build.sh` 打包时插入），AnyKernel3 会把目标槽位 `_a`/`_b` 对调。
它不能在 Recovery 里用，也不能在没装 OTA 时用，否则会写到没在用的槽位。
管理器自带的“刷入 AnyKernel”只会刷当前槽位，OTA 后不重启就刷普通包，内核会进旧系统，重启后 root 就没了。

只用手机（推荐，2026-11-21 从 1019 OTA 到 1116 实测通过）：

1. 系统设置 → 更新器，安装 OTA，**装完先不要重启**。
2. 在 Releases 下载最新的 **`-OTA-inactive.zip`**。
3. YouYouSU-Next → 安装 → 刷入 AnyKernel (.zip) → 选这个包。日志里 `Target` 应该是**另一个槽位**的 `by-name/boot_x`。
   - 显示 `Kernel version matches.` 并且最后是 `Done!`：刷好了。
   - 显示 `Version mismatch, nothing was flashed!`：这次 OTA 的内核后缀和包不一样，什么都没写。日志里 `needs: -gxxxxxxxxxxxx` 就是需要的后缀，到 Releases 找这个后缀的包；没有就手动运行工作流（勾选 `rebase_upstream`，`localversion` 填这个后缀，勾选 `release`），编完再刷。
4. 重启，root 保持不丢。

想在刷之前自己确认后缀：LineageOS 下载页该版本的 `build-manifest.xml` 里 `kernel_oneplus_sm8150` 的 `revision` 前 12 位；或 OTA 装完后用 Kernel Flasher 查看另一个槽位；或 root 终端运行
`su -c 'cur=$(getprop ro.boot.slot_suffix); [ "$cur" = _a ] && t=_b || t=_a; grep -a -o -m1 "4\.14\.[0-9]*-openela-perf-g[0-9a-f]\{12\}" /dev/block/by-name/boot$t | head -1'`。

有电脑（OTA 后已经重启、root 丢了时也用这个）：

1. 更新器安装 OTA 并重启（root 暂时消失）。
2. `adb shell uname -r` 查看新的后缀 `-gxxxxxxxxxxxx`。
3. 在 Releases 下载后缀相同的**普通 zip**（不带 `-OTA-inactive`）。
4. `adb reboot recovery` → Apply update → Apply from ADB → `adb sideload <zip>`。

后缀对不上的表现：能开机、KSU 正常，但 WiFi 打不开。重刷后缀正确的 zip 就能恢复。

**刷入前的版本检查**（`anykernel.sh` 的 `check_kernel_release`）：`split_boot` 导出目标槽位的 boot 后，读出里面内核的版本横幅（官方内核未压缩，`Linux version x.y.z-...` 可以直接读到），和包里 `Image` 的对比。
一致才执行 `flash_boot`；目标是官方内核且不一致就 `abort`，不写入；目标已经是 KSU 内核（含 `KernelSU:` 字符串，比如重刷或修复之前刷错的后缀）时只提示不拦截；版本读不出来时也只提示。

GitHub Actions 的 Artifact 下载下来是外面又包了一层的 zip（里面是两个刷机包、`ksu_susfs`、`build.log`），要先解开，刷里面的包。Release 里的文件可以直接刷。

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

见上面“SUSFS 各文件的作用 → 升级 SUSFS 的步骤”。注意本项目的 SUSFS 有 7 处与原版不同，不能直接整体替换。
刷完后 ksu_susfs 也要更新（刷机脚本会装，Lineage Recovery 下需要 `push_ksu_susfs.sh`）。

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
| `1a0eabaa8` | 注释: 给 KSU hook 和云编译脚本加中文注释 | 说明每个 hook 的作用。SUSFS 相关文件不加注释（说明写在本文档“SUSFS 各文件的作用”），减少升级时的冲突。编译验证通过，符号 CRC 不变 |
| `4ef2b0f07` | docs: 补充 SUSFS 各文件的作用 | 新增“SUSFS 各文件的作用”一节，含与 susfs4ksu 原版的 7 处差异和升级步骤 |
| `a76e2198f` | ci: zip 文件名里的时间改用北京时间 | GitHub 机器默认 UTC，生成文件名时指定 `TZ=Asia/Shanghai` |
| `4a51b6ffc` | ci: 额外生成 OTA 后刷另一个槽位的刷机包 | 每次编译多出一个 `-OTA-inactive.zip`（`anykernel.sh` 多一行 `SLOT_SELECT=inactive;`），OTA 装完不重启就能在管理器里刷进新系统的槽位；Release 说明标注两个包的用法 |
| （最新） | ci: 刷入前自动检查内核版本后缀 | `anykernel.sh` 在写入前对比目标槽位官方内核和包里内核的版本，不一致就中止并提示需要的后缀，避免刷完 WiFi 打不开 |

### 历程

- **2026-11-20**：在 LineageOS 24.0 内核（`9f007fac2`）上接入 KernelSU-Next legacy（manual hook），先只编译 KSU 测试，再加入 SUSFS v1.5.5。
  本地脚本 `build_ksu.sh` 用 clang r596125 编译。处理过三个问题：WiFi 模块 vermagic（固定版本后缀）、厂商模块 CRC（seccomp 字段藏进空洞并对 genksyms 隐藏）、管理器换成自签名的 YouYouSU-Next。
- **2026-11-20**：KSU 和 SUSFS 拆成两个提交放到 `lineage-24.0-ksu`，加入 GitHub Actions 云编译。随后切到 AOSP 公开的 clang r547379，本地编译刷机测试正常。
- **2026-11-21**：实测 OTA 流程。手机刷纯净的 24.0-20261019（内核 `-g0521dc291cf1`，是 `9f007fac2` 的父提交），刷对应后缀的 KSU 内核，再用更新器 OTA 到 20261116（`-g9f007fac27dc`），不重启，用管理器“刷入 AnyKernel”刷加了 `SLOT_SELECT=inactive` 的包，写入另一个槽位 `boot_a`，重启后 root、WiFi 正常。之后把这种包加进 CI。
  经验：sideload 旧版本时必须先用同一版本的 boot.img 进 recovery，新版 recovery 会拒绝降级（只在手机屏幕上报错，电脑端看不出）；LineageOS 每个构建的内核提交可以从下载页的 `build-manifest.xml` 里查 `kernel/oneplus/sm8150` 的 revision。
