#include <linux/atomic.h>
#include <linux/fs.h>
#include <linux/kobject.h>
#include <linux/miscdevice.h>
#include <linux/mm.h>
#include <linux/mmu_notifier.h>
#include <linux/module.h>
#include <linux/sched/mm.h>
#include <linux/slab.h>
#include <linux/spinlock.h>
#include <linux/sysfs.h>
#include <linux/uaccess.h>

#include "sinty_compute.h"

#define SC_MAX_RANGES 4096

struct sc_tracked {
	struct list_head node;
	u64 id;
	unsigned long start;
	unsigned long end;
	atomic64_t generation;
};

struct sc_context {
	struct mmu_notifier mn;
	struct mm_struct *mm;
	spinlock_t lock;
	struct list_head ranges;
	unsigned int count;
	u64 next_id;
	bool registered;
};

static bool sc_enabled;
static unsigned int sc_mode = SC_MODE_MEASURE;
static atomic64_t sc_hits, sc_misses, sc_verified, sc_mismatches, sc_saved_ns, sc_spent_ns;
static atomic64_t sc_invalidations;
static atomic_t sc_contexts, sc_ranges;

static const char *const sc_mode_names[] = { "measure", "active", "verify" };

static bool sc_drops_contents(enum mmu_notifier_event event)
{
	switch (event) {
	case MMU_NOTIFY_PROTECTION_VMA:
	case MMU_NOTIFY_PROTECTION_PAGE:
	case MMU_NOTIFY_SOFT_DIRTY:
	case MMU_NOTIFY_MIGRATE:
	case MMU_NOTIFY_EXCLUSIVE:
		return false;
	default:
		return true;
	}
}

static int sc_invalidate_start(struct mmu_notifier *mn, const struct mmu_notifier_range *range)
{
	struct sc_context *ctx = container_of(mn, struct sc_context, mn);
	struct sc_tracked *t;
	unsigned long flags;

	if (!sc_drops_contents(range->event))
		return 0;
	spin_lock_irqsave(&ctx->lock, flags);
	list_for_each_entry(t, &ctx->ranges, node) {
		if (t->start < range->end && range->start < t->end) {
			atomic64_inc(&t->generation);
			atomic64_inc(&sc_invalidations);
		}
	}
	spin_unlock_irqrestore(&ctx->lock, flags);
	return 0;
}

static void sc_release_mm(struct mmu_notifier *mn, struct mm_struct *mm)
{
	struct sc_context *ctx = container_of(mn, struct sc_context, mn);
	struct sc_tracked *t;
	unsigned long flags;

	spin_lock_irqsave(&ctx->lock, flags);
	list_for_each_entry(t, &ctx->ranges, node)
		atomic64_inc(&t->generation);
	spin_unlock_irqrestore(&ctx->lock, flags);
}

static const struct mmu_notifier_ops sc_mn_ops = {
	.invalidate_range_start = sc_invalidate_start,
	.release = sc_release_mm,
};

static int sc_open(struct inode *inode, struct file *file)
{
	struct sc_context *ctx;
	int err;

	if (!current->mm)
		return -EINVAL;
	ctx = kzalloc(sizeof(*ctx), GFP_KERNEL);
	if (!ctx)
		return -ENOMEM;
	spin_lock_init(&ctx->lock);
	INIT_LIST_HEAD(&ctx->ranges);
	ctx->next_id = 1;
	ctx->mm = current->mm;
	mmgrab(ctx->mm);
	ctx->mn.ops = &sc_mn_ops;
	err = mmu_notifier_register(&ctx->mn, ctx->mm);
	if (err) {
		mmdrop(ctx->mm);
		kfree(ctx);
		return err;
	}
	ctx->registered = true;
	file->private_data = ctx;
	atomic_inc(&sc_contexts);
	return 0;
}

static int sc_release(struct inode *inode, struct file *file)
{
	struct sc_context *ctx = file->private_data;
	struct sc_tracked *t, *n;

	if (ctx->registered)
		mmu_notifier_unregister(&ctx->mn, ctx->mm);
	list_for_each_entry_safe(t, n, &ctx->ranges, node) {
		list_del(&t->node);
		kfree(t);
		atomic_dec(&sc_ranges);
	}
	mmdrop(ctx->mm);
	kfree(ctx);
	atomic_dec(&sc_contexts);
	return 0;
}

static struct sc_tracked *sc_find(struct sc_context *ctx, u64 id)
{
	struct sc_tracked *t;

	list_for_each_entry(t, &ctx->ranges, node)
		if (t->id == id)
			return t;
	return NULL;
}

static long sc_add_range(struct sc_context *ctx, struct sc_range __user *arg)
{
	struct sc_range r;
	struct sc_tracked *t;
	unsigned long flags, end;

	if (copy_from_user(&r, arg, sizeof(r)))
		return -EFAULT;
	if (!r.len || check_add_overflow((unsigned long)r.start, (unsigned long)r.len, &end) || end > TASK_SIZE)
		return -EINVAL;
	t = kzalloc(sizeof(*t), GFP_KERNEL);
	if (!t)
		return -ENOMEM;
	t->start = r.start;
	t->end = end;
	atomic64_set(&t->generation, 1);
	spin_lock_irqsave(&ctx->lock, flags);
	if (ctx->count >= SC_MAX_RANGES) {
		spin_unlock_irqrestore(&ctx->lock, flags);
		kfree(t);
		return -ENOSPC;
	}
	t->id = ctx->next_id++;
	list_add_tail(&t->node, &ctx->ranges);
	ctx->count++;
	spin_unlock_irqrestore(&ctx->lock, flags);
	atomic_inc(&sc_ranges);
	r.id = t->id;
	if (copy_to_user(arg, &r, sizeof(r)))
		return -EFAULT;
	return 0;
}

static long sc_remove_range(struct sc_context *ctx, u64 __user *arg)
{
	struct sc_tracked *t;
	unsigned long flags;
	u64 id;

	if (get_user(id, arg))
		return -EFAULT;
	spin_lock_irqsave(&ctx->lock, flags);
	t = sc_find(ctx, id);
	if (t) {
		list_del(&t->node);
		ctx->count--;
	}
	spin_unlock_irqrestore(&ctx->lock, flags);
	if (!t)
		return -ENOENT;
	kfree(t);
	atomic_dec(&sc_ranges);
	return 0;
}

static long sc_generation(struct sc_context *ctx, struct sc_generation __user *arg)
{
	struct sc_generation g;
	struct sc_tracked *t;
	unsigned long flags;

	if (copy_from_user(&g, arg, sizeof(g)))
		return -EFAULT;
	spin_lock_irqsave(&ctx->lock, flags);
	t = sc_find(ctx, g.id);
	g.generation = t ? atomic64_read(&t->generation) : 0;
	spin_unlock_irqrestore(&ctx->lock, flags);
	if (!t)
		return -ENOENT;
	if (copy_to_user(arg, &g, sizeof(g)))
		return -EFAULT;
	return 0;
}

static long sc_report(struct sc_report __user *arg)
{
	struct sc_report r;

	if (copy_from_user(&r, arg, sizeof(r)))
		return -EFAULT;
	atomic64_add(r.hits, &sc_hits);
	atomic64_add(r.misses, &sc_misses);
	atomic64_add(r.verified, &sc_verified);
	atomic64_add(r.mismatches, &sc_mismatches);
	atomic64_add(r.saved_ns, &sc_saved_ns);
	atomic64_add(r.spent_ns, &sc_spent_ns);
	return 0;
}

static long sc_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
	struct sc_context *ctx = file->private_data;
	void __user *uarg = (void __user *)arg;

	if (current->mm != ctx->mm)
		return -EBADF;
	switch (cmd) {
	case SC_IOC_ABI:
		return put_user((u32)SINTY_COMPUTE_ABI, (u32 __user *)uarg);
	case SC_IOC_STATE:
		return put_user((u32)((READ_ONCE(sc_enabled) ? SC_STATE_ENABLED : 0) | READ_ONCE(sc_mode)), (u32 __user *)uarg);
	case SC_IOC_ADD_RANGE:
		return sc_add_range(ctx, uarg);
	case SC_IOC_REMOVE_RANGE:
		return sc_remove_range(ctx, uarg);
	case SC_IOC_GENERATION:
		return sc_generation(ctx, uarg);
	case SC_IOC_REPORT:
		return sc_report(uarg);
	default:
		return -ENOTTY;
	}
}

static const struct file_operations sc_fops = {
	.owner = THIS_MODULE,
	.open = sc_open,
	.release = sc_release,
	.unlocked_ioctl = sc_ioctl,
	.compat_ioctl = compat_ptr_ioctl,
	.llseek = noop_llseek,
};

static struct miscdevice sc_device = {
	.minor = MISC_DYNAMIC_MINOR,
	.name = "sinty-compute",
	.fops = &sc_fops,
	.mode = 0666,
};

static ssize_t enabled_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%d\n", READ_ONCE(sc_enabled));
}

static ssize_t enabled_store(struct kobject *kobj, struct kobj_attribute *attr, const char *buf, size_t count)
{
	bool v;
	int err = kstrtobool(buf, &v);

	if (err)
		return err;
	WRITE_ONCE(sc_enabled, v);
	return count;
}

static ssize_t mode_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%s\n", sc_mode_names[READ_ONCE(sc_mode)]);
}

static ssize_t mode_store(struct kobject *kobj, struct kobj_attribute *attr, const char *buf, size_t count)
{
	int i = sysfs_match_string(sc_mode_names, buf);

	if (i < 0)
		return i;
	WRITE_ONCE(sc_mode, i);
	return count;
}

static ssize_t reset_store(struct kobject *kobj, struct kobj_attribute *attr, const char *buf, size_t count)
{
	atomic64_set(&sc_hits, 0);
	atomic64_set(&sc_misses, 0);
	atomic64_set(&sc_verified, 0);
	atomic64_set(&sc_mismatches, 0);
	atomic64_set(&sc_saved_ns, 0);
	atomic64_set(&sc_spent_ns, 0);
	atomic64_set(&sc_invalidations, 0);
	return count;
}

#define SC_COUNTER(name, var) \
	static ssize_t name##_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf) \
	{ \
		return sysfs_emit(buf, "%lld\n", (long long)atomic64_read(&var)); \
	} \
	static struct kobj_attribute sc_attr_##name = __ATTR_RO(name)

SC_COUNTER(hits, sc_hits);
SC_COUNTER(misses, sc_misses);
SC_COUNTER(verified, sc_verified);
SC_COUNTER(mismatches, sc_mismatches);
SC_COUNTER(saved_ns, sc_saved_ns);
SC_COUNTER(spent_ns, sc_spent_ns);
SC_COUNTER(invalidations, sc_invalidations);

static ssize_t contexts_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%d\n", atomic_read(&sc_contexts));
}

static ssize_t ranges_show(struct kobject *kobj, struct kobj_attribute *attr, char *buf)
{
	return sysfs_emit(buf, "%d\n", atomic_read(&sc_ranges));
}

static struct kobj_attribute sc_attr_enabled = __ATTR_RW(enabled);
static struct kobj_attribute sc_attr_mode = __ATTR_RW(mode);
static struct kobj_attribute sc_attr_reset = __ATTR_WO(reset);
static struct kobj_attribute sc_attr_contexts = __ATTR_RO(contexts);
static struct kobj_attribute sc_attr_ranges = __ATTR_RO(ranges);

static struct attribute *sc_attrs[] = {
	&sc_attr_enabled.attr,
	&sc_attr_mode.attr,
	&sc_attr_reset.attr,
	&sc_attr_contexts.attr,
	&sc_attr_ranges.attr,
	&sc_attr_hits.attr,
	&sc_attr_misses.attr,
	&sc_attr_verified.attr,
	&sc_attr_mismatches.attr,
	&sc_attr_saved_ns.attr,
	&sc_attr_spent_ns.attr,
	&sc_attr_invalidations.attr,
	NULL,
};

static const struct attribute_group sc_group = {
	.attrs = sc_attrs,
};

static struct kobject *sc_kobj;

static int __init sc_init(void)
{
	int err;

	sc_kobj = kobject_create_and_add("sinty_compute", kernel_kobj);
	if (!sc_kobj)
		return -ENOMEM;
	err = sysfs_create_group(sc_kobj, &sc_group);
	if (err)
		goto put;
	err = misc_register(&sc_device);
	if (err)
		goto put;
	return 0;
put:
	kobject_put(sc_kobj);
	return err;
}

static void __exit sc_exit(void)
{
	misc_deregister(&sc_device);
	kobject_put(sc_kobj);
}

module_init(sc_init);
module_exit(sc_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Sinty Compute: versioned memory ranges and reuse statistics");
MODULE_AUTHOR("Mirko Brombin");
