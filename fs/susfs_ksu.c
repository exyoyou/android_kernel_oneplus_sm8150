// SPDX-License-Identifier: GPL-2.0
/*
 * Glue between SUSFS v1.5.5 (susfs4ksu, kernel-4.14 branch) and
 * KernelSU-Next legacy.
 *
 * Upstream SUSFS ships a patch against the original KernelSU that adds
 * these pieces to KernelSU itself (core_hook.c, selinux.c). KernelSU-Next
 * legacy has a different internal layout and no prctl interface, so the
 * same functionality lives here instead, built on the symbols KernelSU-Next
 * already provides:
 *
 *   - SELinux domain checks used by the fs/ hooks
 *   - ksu_try_umount() / susfs_try_umount_all()
 *   - the prctl(0xDEADBEEF, CMD_SUSFS_*) interface used by ksu_susfs
 *   - a task_fix_setuid LSM hook that tags non-root app processes and
 *     umounts the try_umount list for them
 */
#include <linux/cred.h>
#include <linux/fs.h>
#include <linux/init.h>
#include <linux/lsm_hooks.h>
#include <linux/mount.h>
#include <linux/namei.h>
#include <linux/path.h>
#include <linux/sched.h>
#include <linux/sched/task.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/task_work.h>
#include <linux/uaccess.h>
#include <linux/uidgid.h>
#include <linux/susfs.h>

#include "internal.h"

#define KERNEL_SU_OPTION 0xDEADBEEF

#define PER_USER_RANGE 100000
#define FIRST_APPLICATION_UID 10000
#define LAST_APPLICATION_UID 19999
#define FIRST_ISOLATED_UID 99000
#define LAST_ISOLATED_UID 99999
#define FIRST_SYSTEM_UID 1000

/* Provided by KernelSU-Next (drivers/kernelsu) */
extern bool is_ksu_domain(void);
extern bool is_zygote(const struct cred *cred);
extern bool __ksu_is_allow_uid(uid_t uid);
extern bool ksu_uid_should_umount(uid_t uid);
extern struct cred *ksu_cred;

/* Provided by fs/susfs.c and fs/namespace.c */
extern bool susfs_is_mnt_devname_ksu(struct path *path);
#ifdef CONFIG_KSU_SUSFS_ENABLE_LOG
extern bool susfs_is_log_enabled;
#endif
#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
extern void susfs_run_try_umount_for_current_mnt_ns(void);
#endif
#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT
extern bool susfs_is_auto_add_sus_bind_mount_enabled;
#endif
#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT
extern bool susfs_is_auto_add_sus_ksu_default_mount_enabled;
#endif
#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT
extern bool susfs_is_auto_add_try_umount_for_bind_mount_enabled;
#endif

static inline bool susfs_is_appuid(uid_t uid)
{
	uid_t appid = uid % PER_USER_RANGE;

	return appid >= FIRST_APPLICATION_UID && appid <= LAST_APPLICATION_UID;
}

static inline bool susfs_is_isolated_uid(uid_t uid)
{
	uid_t appid = uid % PER_USER_RANGE;

	return appid >= FIRST_ISOLATED_UID && appid <= LAST_ISOLATED_UID;
}

/* ---------------------------------------------------------------------- */
/* SELinux domain checks used by fs/namespace.c and fs/susfs.c             */
/* ---------------------------------------------------------------------- */

bool susfs_is_current_ksu_domain(void)
{
	return unlikely(is_ksu_domain());
}

bool susfs_is_current_zygote_domain(void)
{
	return unlikely(is_zygote(current_cred()));
}

/* ---------------------------------------------------------------------- */
/* try_umount                                                             */
/* ---------------------------------------------------------------------- */

void ksu_try_umount(const char *mnt, bool check_mnt, int flags, uid_t uid)
{
	struct path path;
	int err;

	err = kern_path(mnt, 0, &path);
	if (err)
		return;

	if (path.dentry != path.mnt->mnt_root) {
		/* not a mountpoint root, maybe umounted already */
		path_put(&path);
		return;
	}

	/* only umount what KernelSU mounted */
	if (check_mnt && !susfs_is_mnt_devname_ksu(&path)) {
		path_put(&path);
		return;
	}

#ifdef CONFIG_KSU_SUSFS_ENABLE_LOG
	if (susfs_is_log_enabled)
		pr_info("susfs: umounting '%s' for uid: %u\n", mnt, uid);
#endif

	/* path_umount() drops the reference taken by kern_path() */
	err = path_umount(&path, flags);
	if (err)
		pr_warn("susfs: umount %s failed: %d\n", mnt, err);
}

void susfs_try_umount_all(uid_t uid)
{
#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
	/* user added paths first, in reversed order */
	susfs_try_umount(uid);
#endif
	ksu_try_umount("/system", true, 0, uid);
	ksu_try_umount("/system_ext", true, 0, uid);
	ksu_try_umount("/vendor", true, 0, uid);
	ksu_try_umount("/product", true, 0, uid);
	ksu_try_umount("/odm", true, 0, uid);
	/* a loop device whose dev_name can't be checked; safe to detach */
	ksu_try_umount("/data/adb/modules", false, MNT_DETACH, uid);
	ksu_try_umount("/debug_ramdisk", true, MNT_DETACH, uid);
}

/* ---------------------------------------------------------------------- */
/* Flags read from /data/adb once userdata is available                   */
/* ---------------------------------------------------------------------- */

static bool susfs_data_flags_loaded;
static bool susfs_umount_for_zygote_system_process;

static bool susfs_path_exists(const char *name)
{
	struct path path;

	if (kern_path(name, 0, &path))
		return false;
	path_put(&path);
	return true;
}

/* Must run with credentials that may look into /data/adb (ksu_cred). */
static void susfs_load_data_flags(void)
{
	if (READ_ONCE(susfs_data_flags_loaded))
		return;

	susfs_umount_for_zygote_system_process =
		susfs_path_exists(DATA_ADB_UMOUNT_FOR_ZYGOTE_SYSTEM_PROCESS);
#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT
	if (susfs_path_exists(DATA_ADB_NO_AUTO_ADD_SUS_BIND_MOUNT))
		susfs_is_auto_add_sus_bind_mount_enabled = false;
#endif
#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT
	if (susfs_path_exists(DATA_ADB_NO_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT))
		susfs_is_auto_add_sus_ksu_default_mount_enabled = false;
#endif
#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT
	if (susfs_path_exists(DATA_ADB_NO_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT))
		susfs_is_auto_add_try_umount_for_bind_mount_enabled = false;
#endif
	pr_info("susfs: umount_for_zygote_system_process: %d\n",
		susfs_umount_for_zygote_system_process);
	WRITE_ONCE(susfs_data_flags_loaded, true);
}

/* ---------------------------------------------------------------------- */
/* setuid hook: tag non-root apps, umount for them                        */
/* ---------------------------------------------------------------------- */

struct susfs_umount_tw {
	struct callback_head cb;
	uid_t uid;
	bool system_process;
};

static void susfs_umount_tw_func(struct callback_head *cb)
{
	struct susfs_umount_tw *tw =
		container_of(cb, struct susfs_umount_tw, cb);
	const struct cred *saved;

	if (!ksu_cred)
		goto out;

	saved = override_creds(ksu_cred);
	susfs_load_data_flags();
	if (!tw->system_process || susfs_umount_for_zygote_system_process)
		susfs_try_umount_all(tw->uid);
	revert_creds(saved);
out:
	kfree(tw);
}

static int susfs_task_fix_setuid(struct cred *new, const struct cred *old,
				 int flags)
{
	uid_t old_uid = old->uid.val;
	uid_t new_uid = new->uid.val;
	struct susfs_umount_tw *tw;
	bool system_process = false;

	/* only processes forked by zygote (root -> app/system uid) */
	if (old_uid != 0 || !is_zygote(old))
		return 0;

	if (susfs_is_appuid(new_uid) && !__ksu_is_allow_uid(new_uid)) {
		task_lock(current);
		current->susfs_task_state |= TASK_STRUCT_NON_ROOT_USER_APP_PROC;
		task_unlock(current);
	}

	if (susfs_is_appuid(new_uid) || susfs_is_isolated_uid(new_uid)) {
		if (!ksu_uid_should_umount(new_uid) &&
		    !susfs_is_isolated_uid(new_uid))
			return 0;
	} else if (new_uid >= FIRST_SYSTEM_UID &&
		   new_uid < FIRST_APPLICATION_UID) {
		/* opt-in, see DATA_ADB_UMOUNT_FOR_ZYGOTE_SYSTEM_PROCESS */
		if (READ_ONCE(susfs_data_flags_loaded) &&
		    !susfs_umount_for_zygote_system_process)
			return 0;
		system_process = true;
	} else {
		return 0;
	}

	if (!ksu_cred)
		return 0;

	/*
	 * Umount later, on return to userspace, with KernelSU's credentials:
	 * the zygote child itself is not allowed to umount by the policy.
	 */
	tw = kzalloc(sizeof(*tw), GFP_ATOMIC);
	if (!tw)
		return 0;
	tw->cb.func = susfs_umount_tw_func;
	tw->uid = new_uid;
	tw->system_process = system_process;
	if (task_work_add(current, &tw->cb, true))
		kfree(tw);

	return 0;
}

static struct security_hook_list susfs_hooks[] __lsm_ro_after_init = {
	LSM_HOOK_INIT(task_fix_setuid, susfs_task_fix_setuid),
};

/* ---------------------------------------------------------------------- */
/* prctl interface for ksu_susfs                                          */
/* ---------------------------------------------------------------------- */

static void susfs_reply(unsigned long arg5, int error)
{
	if (copy_to_user((void __user *)arg5, &error, sizeof(error)))
		pr_info("susfs: copy_to_user() failed\n");
}

static int susfs_copy_str(unsigned long dst, const char *str)
{
	size_t len = strlen(str) + 1;

	return copy_to_user((void __user *)dst, str, len) ? -EFAULT : 0;
}

static u64 susfs_enabled_features(void)
{
	u64 f = 0;

#ifdef CONFIG_KSU_SUSFS_SUS_PATH
	f |= (1 << 0);
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
	f |= (1 << 1);
#endif
#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT
	f |= (1 << 2);
#endif
#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT
	f |= (1 << 3);
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
	f |= (1 << 4);
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_OVERLAYFS
	f |= (1 << 5);
#endif
#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
	f |= (1 << 6);
#endif
#ifdef CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT
	f |= (1 << 7);
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
	f |= (1 << 8);
#endif
#ifdef CONFIG_KSU_SUSFS_ENABLE_LOG
	f |= (1 << 9);
#endif
#ifdef CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
	f |= (1 << 10);
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
	f |= (1 << 11);
#endif
#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
	f |= (1 << 12);
#endif
#ifdef CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT
	f |= (1 << 14);
#endif
	return f;
}

/*
 * Returns true when the call was a SUSFS command and has been handled.
 * Only root may use it; for anyone else prctl() behaves as if SUSFS
 * did not exist.
 */
bool susfs_handle_prctl(int option, unsigned long arg2, unsigned long arg3,
			unsigned long arg4, unsigned long arg5)
{
	int error = 0;

	if (option != KERNEL_SU_OPTION)
		return false;
	if (!uid_eq(current_uid(), GLOBAL_ROOT_UID))
		return false;
	if (arg2 < CMD_SUSFS_ADD_SUS_PATH || arg2 > CMD_SUSFS_IS_SUS_SU_READY)
		return false;

	switch (arg2) {
#ifdef CONFIG_KSU_SUSFS_SUS_PATH
	case CMD_SUSFS_ADD_SUS_PATH:
		error = susfs_add_sus_path(
			(struct st_susfs_sus_path __user *)arg3);
		break;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
	case CMD_SUSFS_ADD_SUS_MOUNT:
		error = susfs_add_sus_mount(
			(struct st_susfs_sus_mount __user *)arg3);
		break;
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
	case CMD_SUSFS_ADD_SUS_KSTAT:
	case CMD_SUSFS_ADD_SUS_KSTAT_STATICALLY:
		error = susfs_add_sus_kstat(
			(struct st_susfs_sus_kstat __user *)arg3);
		break;
	case CMD_SUSFS_UPDATE_SUS_KSTAT:
		error = susfs_update_sus_kstat(
			(struct st_susfs_sus_kstat __user *)arg3);
		break;
#endif
#ifdef CONFIG_KSU_SUSFS_TRY_UMOUNT
	case CMD_SUSFS_ADD_TRY_UMOUNT:
		error = susfs_add_try_umount(
			(struct st_susfs_try_umount __user *)arg3);
		break;
	case CMD_SUSFS_RUN_UMOUNT_FOR_CURRENT_MNT_NS:
		susfs_run_try_umount_for_current_mnt_ns();
		break;
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
	case CMD_SUSFS_SET_UNAME:
		error = susfs_set_uname((struct st_susfs_uname __user *)arg3);
		break;
#endif
#ifdef CONFIG_KSU_SUSFS_ENABLE_LOG
	case CMD_SUSFS_ENABLE_LOG:
		if (arg3 != 0 && arg3 != 1) {
			pr_err("susfs: CMD_SUSFS_ENABLE_LOG -> arg3 can only be 0 or 1\n");
			return true;
		}
		susfs_set_log(arg3);
		break;
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
	case CMD_SUSFS_SET_CMDLINE_OR_BOOTCONFIG:
		error = susfs_set_cmdline_or_bootconfig((char __user *)arg3);
		break;
#endif
#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
	case CMD_SUSFS_ADD_OPEN_REDIRECT:
		error = susfs_add_open_redirect(
			(struct st_susfs_open_redirect __user *)arg3);
		break;
#endif
	case CMD_SUSFS_SHOW_VERSION:
		error = susfs_copy_str(arg3, SUSFS_VERSION);
		break;
	case CMD_SUSFS_SHOW_ENABLED_FEATURES: {
		u64 features = susfs_enabled_features();

		error = copy_to_user((void __user *)arg3, &features,
				     sizeof(features)) ? -EFAULT : 0;
		break;
	}
	case CMD_SUSFS_SHOW_VARIANT:
		error = susfs_copy_str(arg3, SUSFS_VARIANT);
		break;
	default:
		/* not compiled in, or sus_su (not supported here) */
		return true;
	}

	pr_info("susfs: cmd 0x%lx -> ret: %d\n", arg2, error);
	susfs_reply(arg5, error);
	return true;
}

/* ---------------------------------------------------------------------- */

static int __init susfs_ksu_init(void)
{
	susfs_init();
	security_add_hooks(susfs_hooks, ARRAY_SIZE(susfs_hooks), "susfs");
	return 0;
}
fs_initcall(susfs_ksu_init);
