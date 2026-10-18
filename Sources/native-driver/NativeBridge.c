#include "NativeBridge.h"
#include <cups/cups.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
extern char **environ;
static volatile sig_atomic_t interrupted;
static void stop_after_card(int signal_number) { (void)signal_number; interrupted = 1; }
void avansia_install_signals(void) {
    struct sigaction action = {0};
    action.sa_handler = stop_after_card;
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGINT, &action, NULL);
}
int avansia_interrupted(void) { return interrupted; }
static int failure(char *error, size_t capacity, const char *message) {
    snprintf(error, capacity, "%s", message); return -1;
}
int avansia_job_cancelled(const char *uri, char *error, size_t capacity) {
    char scheme[32], user[256], host[256], resource[1024];
    int port = 0;
    if (httpSeparateURI(HTTP_URI_CODING_ALL, uri, scheme, sizeof(scheme), user, sizeof(user),
                        host, sizeof(host), &port, resource, sizeof(resource)) != HTTP_URI_STATUS_OK ||
        strcmp(scheme, "ipp") || user[0] || port != 18631 ||
        (strcmp(host, "localhost") && strcmp(host, "127.0.0.1") && strcmp(host, "::1")) ||
        strncmp(resource, "/ipp/print/", 11) || !resource[11])
        return failure(error, capacity, "Invalid local IPP job URI");
    for (const char *p = resource + 11; *p; ++p)
        if (*p < '0' || *p > '9') return failure(error, capacity, "Invalid local IPP job URI");
    http_t *http = httpConnect2(host, 18631, NULL, AF_UNSPEC, HTTP_ENCRYPTION_IF_REQUESTED, 1, 3000, NULL);
    if (!http) return failure(error, capacity, "Cannot verify cancellation state; no next card will start");
    httpSetTimeout(http, 3.0, NULL, NULL);
    ipp_t *request = ippNewRequest(IPP_OP_GET_JOB_ATTRIBUTES);
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "job-uri", NULL, uri);
    const char *names[] = {"job-state", "job-state-reasons"};
    ippAddStrings(request, IPP_TAG_OPERATION, IPP_TAG_KEYWORD, "requested-attributes", 2, NULL, names);
    ipp_t *response = cupsDoRequest(http, request, "/ipp/print");
    int result = -1;
    if (!response || ippGetStatusCode(response) >= IPP_STATUS_ERROR_BAD_REQUEST)
        failure(error, capacity, "The IPP job state is unavailable; no next card will start");
    else {
        ipp_attribute_t *state = ippFindAttribute(response, "job-state", IPP_TAG_ENUM);
        ipp_attribute_t *reasons = ippFindAttribute(response, "job-state-reasons", IPP_TAG_KEYWORD);
        if (!state || !reasons || ippGetCount(state) != 1 || ippGetCount(reasons) < 1)
            failure(error, capacity, "The IPP cancellation response is incomplete");
        else {
            int value = ippGetInteger(state, 0);
            if (value < 3 || value > 9) failure(error, capacity, "Invalid IPP job state");
            else {
                result = value >= 7;
                for (int i = 0; i < ippGetCount(reasons); ++i) {
                    const char *reason = ippGetString(reasons, i, NULL);
                    if (!reason) { result = failure(error, capacity, "Invalid IPP job state reason"); break; }
                    if (!strcmp(reason, "processing-to-stop-point")) result = 1;
                }
                if (result == 0 && value != IPP_JSTATE_PROCESSING)
                    result = failure(error, capacity, "The IPP job is not processing; no next card will start");
            }
        }
    }
    if (response) ippDelete(response);
    httpClose(http);
    return result;
}
int avansia_lock(char *error, size_t capacity) {
    char path[128]; snprintf(path, sizeof(path), "/private/tmp/avansia-mac-%u.lock", getuid());
    int fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
    struct stat st;
    if (fd < 0) return failure(error, capacity, "Cannot open the printer lock");
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != getuid() || (st.st_mode & 077) || st.st_nlink != 1) {
        close(fd); return failure(error, capacity, "Invalid printer lock file");
    }
    if (flock(fd, LOCK_EX | LOCK_NB)) {
        int lock_error = errno;
        close(fd);
        if (lock_error == EWOULDBLOCK || lock_error == EAGAIN) {
            failure(error, capacity, "Another process is using the printer");
            return AVANSIA_LOCK_BUSY;
        }
        return failure(error, capacity, "Cannot acquire the printer lock");
    }
    return fd;
}
int avansia_run(const char *path, char *const argv[], int lock_fd, const char *output, const char *errors, int timeout_seconds) {
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, output, O_CREAT | O_TRUNC | O_WRONLY, 0600);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, errors, O_CREAT | O_TRUNC | O_WRONLY, 0600);
    if (lock_fd >= 0) posix_spawn_file_actions_adddup2(&actions, lock_fd, 198);
    pid_t child;
    int error = posix_spawn(&child, path, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    if (error) { errno = error; return -1; }
    int status = 0;
    if (timeout_seconds > 0) {
        time_t started = time(NULL);
        for (;;) {
            pid_t result = waitpid(child, &status, WNOHANG);
            if (result == child) break;
            if (result < 0) {
                if (errno == EINTR) continue;
                return -1;
            }
            if (time(NULL) - started >= timeout_seconds) {
                kill(child, SIGKILL);
                while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
                return 124;
            }
            struct timespec interval = {0, 100000000}; nanosleep(&interval, NULL);
        }
    } else {
        pid_t result;
        do { result = waitpid(child, &status, 0); } while (result < 0 && errno == EINTR);
        if (result < 0) return -1;
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
