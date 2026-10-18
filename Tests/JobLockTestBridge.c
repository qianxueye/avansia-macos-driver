#include "JobLockTestBridge.h"
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
static int mode, attempts, checks, core_calls;
void job_lock_test_reset(int value) { mode = value; attempts = checks = core_calls = 0; }
int job_lock_test_attempts(void) { return attempts; }
int job_lock_test_core_calls(void) { return core_calls; }
int avansia_job_cancelled(const char *uri, char *error, size_t capacity) {
    ++checks;
    if (strcmp(uri, "ipp://localhost:18631/ipp/print/123")) {
        snprintf(error, capacity, "The test received the wrong job URI"); return -1;
    }
    if (mode == 2 && checks >= 2) return 1;
    if (mode == 3 && checks >= 2) { snprintf(error, capacity, "Cannot verify cancellation state"); return -1; }
    return 0;
}
int avansia_lock(char *error, size_t capacity) {
    ++attempts;
    if (mode == 1) { snprintf(error, capacity, "Invalid printer lock file"); return -1; }
    snprintf(error, capacity, "Fixture lock is busy");
    return AVANSIA_LOCK_BUSY;
}
int avansia_interrupted(void) { return mode == 4 && attempts > 0; }
void avansia_install_signals(void) {}
int avansia_run(const char *path, char *const argv[], int lock_fd, const char *output, const char *errors, int timeout_seconds) {
    (void)path; (void)argv; (void)lock_fd; (void)output; (void)errors; (void)timeout_seconds;
    ++core_calls;
    return 1;
}
