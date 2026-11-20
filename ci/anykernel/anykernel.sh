### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers

### AnyKernel setup
# 基于 osm0sis/AnyKernel3 的示例脚本修改（中文注释为本项目所加）。
# 注意：ui_print 的提示保持英文，Recovery 不一定能显示中文字体。
#
# 全局属性：
#   do.devicecheck=1  只允许刷到下面列出的机型（ro.product.device 匹配）
#   do.modules=0      不安装内核模块
#   do.systemless=0   模块不以 systemless（Magisk 模块）方式安装
#   do.cleanup=1      刷完删除临时文件
properties() { '
kernel.string=LineageOS sm8150 4.14 + YouYouSU-Next (manual hook) + SUSFS v1.5.5
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=OnePlus7Pro
device.name2=guacamole
device.name3=OnePlus7
device.name4=guacamoleb
device.name5=OnePlus7ProTMO
device.name6=guacamolet
device.name7=OnePlus7T
device.name8=hotdogb
device.name9=OnePlus7TPro
device.name10=hotdog
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties


### AnyKernel install
# boot 分区参数：A/B 设备，自动选择当前槽位的 boot
# （ci/build.sh 打 -OTA-inactive 包时会在 IS_SLOT_DEVICE 下面插入 SLOT_SELECT=inactive;，改刷另一个槽位）
BLOCK=boot;
IS_SLOT_DEVICE=1;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# 载入 AnyKernel3 的核心函数（不能删）
. tools/ak3-core.sh;

## 刷入前检查内核版本后缀。
## 厂商 WiFi 模块会校验 vermagic，包里内核的版本字符串必须和目标槽位系统自带的官方内核完全一致，
## 否则能开机但 WiFi 打不开。split_boot 已经把目标槽位的 boot 导出到 $BOOTIMG（官方内核未压缩，
## 版本横幅 "Linux version x.y.z-..." 可以直接读到），在 flash_boot 之前对比，不一致就中止，什么都不写。
## 目标槽位已经是 KSU 内核时（重刷、修复之前刷错的后缀）读不到官方版本，只提示不拦截。
## 版本读不出来时（工具或格式异常）也只提示，保持和没有这个检查时一样的行为。
kernel_release() {
  local v;
  v=$(strings "$1" 2>/dev/null | grep -o 'Linux version [0-9][^ ]*' | head -n1);
  echo "${v#Linux version }";
}
check_kernel_release() {
  local want have;
  have=$(kernel_release $AKHOME/Image);
  want=$(kernel_release $BOOTIMG);
  ui_print " " "Target: $BLOCK" "Current kernel: ${want:-unknown}" "This zip:       ${have:-unknown}";
  if [ -z "$want" -o -z "$have" ]; then
    ui_print "Warning: cannot read kernel version, skipping version check.";
  elif [ "$want" = "$have" ]; then
    ui_print "Kernel version matches.";
  elif strings $BOOTIMG | grep -q 'KernelSU:'; then
    ui_print "Warning: target already has a KernelSU kernel with a different version." \
      "Flashing anyway. Make sure ${have##*-perf} matches the system (WiFi needs it).";
  else
    abort "Version mismatch, nothing was flashed!" \
      "The system on $BLOCK needs: ${want##*-perf}" \
      "Download the zip with this suffix from Releases," \
      "or run the workflow with localversion=${want##*-perf}";
  fi;
}

# 刷入 boot：只替换内核 Image，ramdisk、dtb、cmdline 都保持原样
# （split_boot 不解包 ramdisk，跨 OTA 兼容性最好）
split_boot;
check_kernel_release;
flash_boot;
## end boot install

## 安装 ksu_susfs：与本内核 SUSFS 版本配套的用户态工具，装到 /data/adb/ksu/bin。
## Lineage Recovery 访问不了 /data，这时跳过，开机后在电脑上运行 push_ksu_susfs.sh 推送。
install_ksu_susfs() {
  local bin=/data/adb/ksu/bin;
  [ -f $AKHOME/ksu_susfs ] || return 0;
  if [ ! -d /data/adb ]; then
    ui_print " " "Warning: /data/adb not accessible, ksu_susfs not installed." \
      "After boot run push_ksu_susfs.sh on the PC";
    return 0;
  fi;
  mount -o remount,rw /data 2>/dev/null;
  # 目录不存在（还没装过 KSU）就创建，权限和 SELinux 上下文与 KSU 自己创建的一致
  if [ ! -d $bin ]; then
    mkdir -p $bin || { ui_print " " "Warning: cannot create $bin, ksu_susfs not installed."; return 0; };
    chmod 700 /data/adb/ksu $bin;
    chcon u:object_r:adb_data_file:s0 /data/adb/ksu $bin 2>/dev/null;
  fi;
  # 先写临时文件再改名，避免写到一半留下损坏的文件
  if cp -f $AKHOME/ksu_susfs $bin/ksu_susfs.tmp && mv -f $bin/ksu_susfs.tmp $bin/ksu_susfs; then
    chown 0:0 $bin/ksu_susfs;
    chmod 755 $bin/ksu_susfs;
    chcon u:object_r:adb_data_file:s0 $bin/ksu_susfs 2>/dev/null;
    ui_print " " "ksu_susfs installed to $bin";
  else
    rm -f $bin/ksu_susfs.tmp;
    ui_print " " "Warning: failed to write $bin/ksu_susfs (is /data read-only?)";
  fi;
}
install_ksu_susfs;
