#define _POSIX_C_SOURCE 200809L

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>

#include "../common/rt_ipc.h"

#define THREAD_COUNT 8
#define ITERATIONS 10000

static pthread_barrier_t start_barrier;
static int failures;

static void *crc_worker(void *argument)
{
    (void)argument;
    static const uint8_t vector[] = "123456789";

    pthread_barrier_wait(&start_barrier);
    for (unsigned iteration = 0; iteration < ITERATIONS; iteration++) {
        if (rtipc_crc16(vector, sizeof(vector) - 1) != 0x29b1)
            __atomic_fetch_add(&failures, 1, __ATOMIC_RELAXED);
    }
    return NULL;
}

int main(void)
{
    pthread_t threads[THREAD_COUNT];

    if (pthread_barrier_init(&start_barrier, NULL, THREAD_COUNT) != 0)
        return 1;
    for (unsigned index = 0; index < THREAD_COUNT; index++) {
        if (pthread_create(&threads[index], NULL, crc_worker, NULL) != 0)
            return 1;
    }
    for (unsigned index = 0; index < THREAD_COUNT; index++)
        pthread_join(threads[index], NULL);
    pthread_barrier_destroy(&start_barrier);

    if (failures != 0) {
        fprintf(stderr, "CRC concurrency failures: %d\n", failures);
        return 1;
    }
    puts("PASS: concurrent CRC results are stable");
    return 0;
}
