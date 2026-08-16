#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <stdlib.h>
#include <time.h>

static unsigned clock_calls;

int __real_clock_gettime(clockid_t clock_id, struct timespec *time);

int __wrap_clock_gettime(clockid_t clock_id, struct timespec *time)
{
    int result = __real_clock_gettime(clock_id, time);
    const char *failure = getenv("RTIPC_FAIL_CLOCK_CALL");

    clock_calls++;
    if (failure != NULL && strtoul(failure, NULL, 10) == clock_calls) {
        errno = EIO;
        return -1;
    }
    return result;
}
