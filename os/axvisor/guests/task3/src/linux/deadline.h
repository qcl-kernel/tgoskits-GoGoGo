#ifndef TASK3_DEADLINE_H
#define TASK3_DEADLINE_H

#include <stdint.h>

typedef enum {
    TASK3_DEADLINE_WAIT = 0,
    TASK3_DEADLINE_START_RECOVERY,
    TASK3_DEADLINE_EXPIRED,
} task3_deadline_action_t;

task3_deadline_action_t task3_deadline_action(uint64_t now_ns,
                                              uint64_t timeout_deadline_ns,
                                              uint64_t final_deadline_ns,
                                              int recovery_started);
int task3_deadline_poll_ms(uint64_t now_ns, uint64_t deadline_ns,
                           int maximum_wait_ms);
int task3_deadline_received_in_time(uint64_t received_ns,
                                    uint64_t deadline_ns);

#endif
