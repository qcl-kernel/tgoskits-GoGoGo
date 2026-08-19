#ifndef TEST_RTTHREAD_H
#define TEST_RTTHREAD_H

int test_rt_kprintf(const char *format, ...);
#define rt_kprintf test_rt_kprintf

#endif
