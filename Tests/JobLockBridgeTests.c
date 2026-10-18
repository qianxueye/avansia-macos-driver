#define open test_open
#define close test_close
#define fstat test_fstat
#define flock test_flock
#include "../Sources/native-driver/NativeBridge.c"
#include <assert.h>
#include <stdarg.h>
static int open_error, metadata_error, flock_error, close_count;
int test_open(const char *path, int flags, ...) {
    char expected[128]; snprintf(expected, sizeof(expected), "/private/tmp/avansia-mac-%u.lock", getuid());
    assert(!strcmp(path, expected));
    assert((flags & O_NOFOLLOW) && (flags & O_CLOEXEC));
    if (open_error) { errno = open_error; return -1; }
    return 42;
}
int test_close(int fd) { assert(fd == 42); ++close_count; errno = EBADF; return 0; }
int test_fstat(int fd, struct stat *status) {
    assert(fd == 42); memset(status, 0, sizeof(*status));
    status->st_mode = S_IFREG | (metadata_error ? 0666 : 0600);
    status->st_uid = getuid(); status->st_nlink = 1;
    return 0;
}
int test_flock(int fd, int operation) {
    assert(fd == 42 && operation == (LOCK_EX | LOCK_NB));
    if (flock_error) { errno = flock_error; return -1; }
    return 0;
}
int main(void) {
    char error[256];
    assert(avansia_lock(error, sizeof(error)) == 42);
    flock_error = EWOULDBLOCK;
    assert(avansia_lock(error, sizeof(error)) == AVANSIA_LOCK_BUSY);
    flock_error = EAGAIN;
    assert(avansia_lock(error, sizeof(error)) == AVANSIA_LOCK_BUSY);
    flock_error = EACCES;
    assert(avansia_lock(error, sizeof(error)) == -1);
    flock_error = EINTR;
    assert(avansia_lock(error, sizeof(error)) == -1);
    flock_error = 0; metadata_error = 1;
    assert(avansia_lock(error, sizeof(error)) == -1);
    metadata_error = 0; open_error = EACCES;
    assert(avansia_lock(error, sizeof(error)) == -1);
    assert(close_count == 5);
    puts("PASS: Actual C lock classifies only EWOULDBLOCK/EAGAIN as busy, preserves errno across close, and keeps validation/open/other lock failures hard");
    return 0;
}
