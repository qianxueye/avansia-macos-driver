#ifndef AVANSIA_NATIVE_BRIDGE_H
#define AVANSIA_NATIVE_BRIDGE_H
#include <stddef.h>
#define AVANSIA_LOCK_BUSY (-2)
int avansia_job_cancelled(const char *uri, char *error, size_t capacity);
int avansia_lock(char *error, size_t capacity);
int avansia_run(const char *path, char *const argv[], int lock_fd, const char *output, const char *errors, int timeout_seconds);
void avansia_install_signals(void);
int avansia_interrupted(void);
#endif
