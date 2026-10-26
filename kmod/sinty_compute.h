#ifndef SINTY_COMPUTE_UAPI_H
#define SINTY_COMPUTE_UAPI_H

#include <linux/ioctl.h>
#include <linux/types.h>

#define SINTY_COMPUTE_ABI 1

struct sc_range {
	__u64 start;
	__u64 len;
	__u64 id;
};

struct sc_generation {
	__u64 id;
	__u64 generation;
};

struct sc_report {
	__u64 hits;
	__u64 misses;
	__u64 verified;
	__u64 mismatches;
	__u64 saved_ns;
	__u64 spent_ns;
};

enum sc_mode {
	SC_MODE_MEASURE = 0,
	SC_MODE_ACTIVE = 1,
	SC_MODE_VERIFY = 2,
};

#define SC_IOC_MAGIC 0xC5
#define SC_IOC_ABI _IOR(SC_IOC_MAGIC, 0, __u32)
#define SC_IOC_STATE _IOR(SC_IOC_MAGIC, 1, __u32)
#define SC_IOC_ADD_RANGE _IOWR(SC_IOC_MAGIC, 2, struct sc_range)
#define SC_IOC_REMOVE_RANGE _IOW(SC_IOC_MAGIC, 3, __u64)
#define SC_IOC_GENERATION _IOWR(SC_IOC_MAGIC, 4, struct sc_generation)
#define SC_IOC_REPORT _IOW(SC_IOC_MAGIC, 5, struct sc_report)

#define SC_STATE_ENABLED 0x100
#define SC_STATE_MODE_MASK 0xff

#endif
