#include "metrics.h"

#include <stdint.h>
#include <stdio.h>

#define ASSERT_EQ(expected, actual)                                                \
    do {                                                                          \
        long long expected_value = (long long)(expected);                         \
        long long actual_value = (long long)(actual);                             \
        if (expected_value != actual_value) {                                     \
            fprintf(stderr, "%s:%d expected %lld got %lld\n", __FILE__,        \
                    __LINE__, expected_value, actual_value);                       \
            return 1;                                                             \
        }                                                                         \
    } while (0)

int main(void)
{
    const uint64_t values[] = {10, 20, 30, 40, 100};
    const int16_t targets[] = {0, 0, 1000, 1000, 1000, 1000, 1000, 1000, 1000};
    const int16_t positions[] = {0, 0, 0, 950, 960, 700, 940, 980, 1020};
    task3_metric_summary_t summary;
    size_t settling_frames;

    ASSERT_EQ(0, task3_metric_summarize(values, 5, &summary));
    ASSERT_EQ(10, summary.minimum);
    ASSERT_EQ(40, summary.mean);
    ASSERT_EQ(30, summary.p50);
    ASSERT_EQ(100, summary.p95);
    ASSERT_EQ(100, summary.p99);
    ASSERT_EQ(100, summary.maximum);

    ASSERT_EQ(0, task3_find_settling_frames(targets, positions, 9, 2, 100, 3,
                                             &settling_frames));
    ASSERT_EQ(4, settling_frames);
    ASSERT_EQ(-1, task3_find_settling_frames(targets, positions, 6, 2, 100, 3,
                                              &settling_frames));
    puts("test_metrics: PASS");
    return 0;
}
