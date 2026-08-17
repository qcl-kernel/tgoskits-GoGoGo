#include "deadline.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define CHECK(condition)                                                        \
    do {                                                                        \
        if (!(condition)) {                                                     \
            fprintf(stderr, "CHECK failed at %s:%d: %s\n", __FILE__, __LINE__, \
                    #condition);                                                \
            exit(EXIT_FAILURE);                                                 \
        }                                                                       \
    } while (0)

int main(void)
{
    const uint64_t timeout = UINT64_C(500000000);
    const uint64_t final = UINT64_C(1500000000);

    CHECK(task3_deadline_action(timeout - 1, timeout, final, 0) ==
          TASK3_DEADLINE_WAIT);
    CHECK(task3_deadline_action(timeout, timeout, final, 0) ==
          TASK3_DEADLINE_START_RECOVERY);
    CHECK(task3_deadline_action(timeout + 1, timeout, final, 0) ==
          TASK3_DEADLINE_START_RECOVERY);
    CHECK(task3_deadline_action(final - 1, timeout, final, 1) ==
          TASK3_DEADLINE_WAIT);
    CHECK(task3_deadline_action(final, timeout, final, 1) ==
          TASK3_DEADLINE_EXPIRED);
    CHECK(task3_deadline_action(final + 1, timeout, final, 0) ==
          TASK3_DEADLINE_EXPIRED);
    CHECK(task3_deadline_received_in_time(timeout - 1, timeout));
    CHECK(!task3_deadline_received_in_time(timeout, timeout));
    CHECK(!task3_deadline_received_in_time(timeout + 1, timeout));

    CHECK(task3_deadline_poll_ms(0, UINT64_C(20000000), 10) == 10);
    CHECK(task3_deadline_poll_ms(0, UINT64_C(9100000), 10) == 10);
    CHECK(task3_deadline_poll_ms(0, UINT64_C(100000), 10) == 1);
    CHECK(task3_deadline_poll_ms(timeout, timeout, 10) == 0);

    puts("test_deadline: PASS");
    return EXIT_SUCCESS;
}
