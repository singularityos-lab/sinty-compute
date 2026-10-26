#ifndef SINTY_COMPUTE_H
#define SINTY_COMPUTE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
	uint64_t hits;
	uint64_t misses;
	uint64_t verified;
	uint64_t mismatches;
	uint64_t saved_ns;
	uint64_t spent_ns;
} sinty_compute_report_t;

enum {
	SINTY_COMPUTE_MEASURE = 0,
	SINTY_COMPUTE_ACTIVE = 1,
	SINTY_COMPUTE_VERIFY = 2,
};

int sinty_compute_open(void);
void sinty_compute_close(int fd);
int sinty_compute_state(int fd, int *enabled, int *mode);
int sinty_compute_track(int fd, const void *addr, size_t len, uint64_t *id);
int sinty_compute_untrack(int fd, uint64_t id);
int sinty_compute_generation(int fd, uint64_t id, uint64_t *generation);
int sinty_compute_report(int fd, const sinty_compute_report_t *report);

#ifdef __cplusplus
}
#endif

#endif
