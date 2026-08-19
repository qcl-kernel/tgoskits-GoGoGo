#include "deadline.h"

#include <limits.h>

task3_deadline_action_t task3_deadline_action(uint64_t now_ns,
                                              uint64_t timeout_deadline_ns,
                                              uint64_t final_deadline_ns,
                                              int recovery_started)
{
    if (now_ns >= final_deadline_ns) {
        return TASK3_DEADLINE_EXPIRED;
    }
    if (!recovery_started && now_ns >= timeout_deadline_ns) {
        return TASK3_DEADLINE_START_RECOVERY;
    }
    return TASK3_DEADLINE_WAIT;
}

int task3_deadline_poll_ms(uint64_t now_ns, uint64_t deadline_ns,
                           int maximum_wait_ms)
{
    uint64_t remaining_ns;
    uint64_t wait_ms;

    if (maximum_wait_ms <= 0 || now_ns >= deadline_ns) {
        return 0;
    }
    remaining_ns = deadline_ns - now_ns;
    wait_ms = remaining_ns / UINT64_C(1000000);
    if (remaining_ns % UINT64_C(1000000) != 0) {
        wait_ms++;
    }
    if (wait_ms > (uint64_t)maximum_wait_ms) {
        wait_ms = (uint64_t)maximum_wait_ms;
    }
    return wait_ms > INT_MAX ? INT_MAX : (int)wait_ms;
}

int task3_deadline_received_in_time(uint64_t received_ns,
                                    uint64_t deadline_ns)
{
    return received_ns < deadline_ns;
}
