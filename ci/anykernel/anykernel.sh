### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers

### AnyKernel setup
# global properties
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
# boot shell variables
BLOCK=boot;
IS_SLOT_DEVICE=1;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

# boot install: only replace the kernel, keep ramdisk/dtb/cmdline untouched
split_boot;
flash_boot;
## end boot install

## ksu_susfs: userspace tool matching this kernel's SUSFS version
install_ksu_susfs() {
  local bin=/data/adb/ksu/bin;
  [ -f $AKHOME/ksu_susfs ] || return 0;
  if [ ! -d /data/adb ]; then
    ui_print " " "Warning: /data/adb not accessible, ksu_susfs not installed." \
      "After boot run push_ksu_susfs.sh on the PC";
    return 0;
  fi;
  mount -o remount,rw /data 2>/dev/null;
  if [ ! -d $bin ]; then
    mkdir -p $bin || { ui_print " " "Warning: cannot create $bin, ksu_susfs not installed."; return 0; };
    chmod 700 /data/adb/ksu $bin;
    chcon u:object_r:adb_data_file:s0 /data/adb/ksu $bin 2>/dev/null;
  fi;
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
