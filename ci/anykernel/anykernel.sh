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
BLOCK=boot;
IS_SLOT_DEVICE=1;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# 载入 AnyKernel3 的核心函数（不能删）
. tools/ak3-core.sh;

# 刷入 boot：只替换内核 Image，ramdisk、dtb、cmdline 都保持原样
# （split_boot 不解包 ramdisk，跨 OTA 兼容性最好）
split_boot;
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
