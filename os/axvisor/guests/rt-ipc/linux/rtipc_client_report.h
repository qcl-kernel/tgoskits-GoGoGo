#ifndef RTIPC_CLIENT_REPORT_H
#define RTIPC_CLIENT_REPORT_H

#include <stddef.h>
#include <stdint.h>

int rtipc_client_prepare_rtt_samples(uint64_t *samples, size_t capacity,
                                     size_t received);

#endif
