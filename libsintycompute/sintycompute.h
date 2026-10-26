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

typedef struct sinty_compute_ctx sinty_compute_ctx_t;
typedef int (*sinty_compute_fn)(void *arg, void *out, size_t out_len);

sinty_compute_ctx_t *sinty_compute_ctx_new(size_t budget);
void sinty_compute_ctx_free(sinty_compute_ctx_t *ctx);
void sinty_compute_ctx_set_verify(sinty_compute_ctx_t *ctx, uint32_t every);
int sinty_compute_input(sinty_compute_ctx_t *ctx, const void *addr, size_t len, uint32_t *handle);
int sinty_compute_input_drop(sinty_compute_ctx_t *ctx, uint32_t handle);
int sinty_compute_call(sinty_compute_ctx_t *ctx, uint32_t region, const void *key, size_t key_len,
		       const uint32_t *inputs, size_t n_inputs, void *out, size_t out_len,
		       sinty_compute_fn fn, void *arg);
void sinty_compute_ctx_report(sinty_compute_ctx_t *ctx, sinty_compute_report_t *report);
size_t sinty_compute_ctx_used(sinty_compute_ctx_t *ctx);

#ifdef __cplusplus
}
#endif

#endif
