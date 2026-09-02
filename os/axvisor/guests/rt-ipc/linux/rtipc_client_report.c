#include "rtipc_client_report.h"

#include <stdlib.h>

static int compare_u64(const void *first, const void *second)
{
    uint64_t first_value = *(const uint64_t *)first;
    uint64_t second_value = *(const uint64_t *)second;

    return first_value < second_value
               ? -1
               : (first_value > second_value ? 1 : 0);
}

int rtipc_client_prepare_rtt_samples(uint64_t *samples, size_t capacity,
                                     size_t received)
{
    if (samples == NULL || received > capacity)
        return -1;
    if (received > 1)
        qsort(samples, received, sizeof(*samples), compare_u64);
    return 0;
}
