/*
 * Reproducible real-time benchmarks for the RT-Thread AArch64 guest.
 *
 * Every result line uses a stable key=value schema so host-side runners can
 * reject incomplete runs instead of silently treating zero-filled slots as
 * valid latency samples.
 */
#include <interrupt.h>
#include <rthw.h>
#include <rtthread.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define RTBENCH_NS_PER_SECOND 1000000000ULL
#define RTBENCH_PERIOD_NS 1000000ULL
#define RTBENCH_PERIOD_MS 1U
#define RTBENCH_DEFAULT_SAMPLES 1000U
#define RTBENCH_MAX_SAMPLES 100000U
#define RTBENCH_DEFAULT_STABILITY_SECONDS 300U
#define RTBENCH_MAX_STABILITY_SECONDS 3600U
#define RTBENCH_WAIT_SLICE_MS 10U
#define RTBENCH_TIMEOUT_MARGIN_MS 5000U
#define RTBENCH_WORKER_STACK_SIZE 32768U
#define RTBENCH_SGI_INTID 7

struct rtbench_result
{
    uint64_t expected;
    uint64_t collected;
    uint64_t missing;
    uint64_t p50_ns;
    uint64_t p95_ns;
    uint64_t p99_ns;
    uint64_t p99_9_ns;
    uint64_t max_ns;
    uint64_t miss_100us;
    uint64_t miss_500us;
    uint64_t miss_1ms;
    uint64_t mean_ns;
};

static uint64_t rtbench_frequency;

static inline uint64_t rtbench_read_counter(void)
{
    uint64_t value;

    __asm__ volatile("mrs %0, cntvct_el0" : "=r"(value));
    return value;
}

static inline uint64_t rtbench_read_frequency(void)
{
    uint64_t value;

    __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(value));
    return value;
}

static uint64_t rtbench_ticks_to_ns(uint64_t ticks, uint64_t frequency)
{
    if (frequency == 0)
    {
        return 0;
    }

    return (ticks / frequency) * RTBENCH_NS_PER_SECOND +
           ((ticks % frequency) * RTBENCH_NS_PER_SECOND) / frequency;
}

static uint64_t rtbench_abs_delta(uint64_t value, uint64_t target)
{
    return value >= target ? value - target : target - value;
}

static int rtbench_compare_u64(const void *left, const void *right)
{
    uint64_t left_value = *(const uint64_t *)left;
    uint64_t right_value = *(const uint64_t *)right;

    return left_value < right_value ? -1 : left_value > right_value;
}

static uint64_t rtbench_percentile(const uint64_t *samples,
                                   uint64_t collected,
                                   uint64_t numerator,
                                   uint64_t denominator)
{
    uint64_t rank;

    if (collected == 0)
    {
        return 0;
    }

    rank = (collected * numerator + denominator - 1) / denominator;
    if (rank == 0)
    {
        rank = 1;
    }
    if (rank > collected)
    {
        rank = collected;
    }
    return samples[rank - 1];
}

static void rtbench_summarize(uint64_t *samples,
                              uint64_t expected,
                              uint64_t collected,
                              struct rtbench_result *result)
{
    uint64_t sum = 0;
    uint64_t i;

    memset(result, 0, sizeof(*result));
    if (collected > expected)
    {
        collected = expected;
    }

    result->expected = expected;
    result->collected = collected;
    result->missing = result->expected - result->collected;

    qsort(samples, collected, sizeof(*samples), rtbench_compare_u64);
    for (i = 0; i < collected; ++i)
    {
        uint64_t value = samples[i];

        sum += value;
        if (value > 100000ULL)
        {
            result->miss_100us++;
        }
        if (value > 500000ULL)
        {
            result->miss_500us++;
        }
        if (value > 1000000ULL)
        {
            result->miss_1ms++;
        }
    }

    result->p50_ns = rtbench_percentile(samples, collected, 50, 100);
    result->p95_ns = rtbench_percentile(samples, collected, 95, 100);
    result->p99_ns = rtbench_percentile(samples, collected, 99, 100);
    result->p99_9_ns = rtbench_percentile(samples, collected, 999, 1000);
    result->max_ns = collected == 0 ? 0 : samples[collected - 1];
    result->mean_ns = collected == 0 ? 0 : sum / collected;
}

static void rtbench_print_result(const char *metric,
                                 unsigned int run,
                                 const struct rtbench_result *result)
{
    rt_kprintf("RTBENCH metric=%s run=%u expected=%llu collected=%llu missing=%llu p50_ns=%llu p95_ns=%llu p99_ns=%llu p99_9_ns=%llu max_ns=%llu miss_100us=%llu miss_500us=%llu miss_1ms=%llu mean_ns=%llu\n",
               metric,
               run,
               (unsigned long long)result->expected,
               (unsigned long long)result->collected,
               (unsigned long long)result->missing,
               (unsigned long long)result->p50_ns,
               (unsigned long long)result->p95_ns,
               (unsigned long long)result->p99_ns,
               (unsigned long long)result->p99_9_ns,
               (unsigned long long)result->max_ns,
               (unsigned long long)result->miss_100us,
               (unsigned long long)result->miss_500us,
               (unsigned long long)result->miss_1ms,
               (unsigned long long)result->mean_ns);
}

static uint64_t rtbench_parse_bounded(const char *text,
                                      uint64_t default_value,
                                      uint64_t maximum)
{
    char *end = RT_NULL;
    unsigned long parsed;

    if (text == RT_NULL || *text == '\0')
    {
        return default_value;
    }

    parsed = strtoul(text, &end, 10);
    if (end == text || *end != '\0' || parsed == 0 || parsed > maximum)
    {
        return default_value;
    }
    return (uint64_t)parsed;
}

static void rtbench_wait_for_samples(volatile uint64_t *collected,
                                     uint64_t expected,
                                     uint64_t nominal_ms)
{
    uint64_t waited_ms = 0;
    uint64_t timeout_ms = nominal_ms + RTBENCH_TIMEOUT_MARGIN_MS;

    while (*collected < expected && waited_ms < timeout_ms)
    {
        rt_thread_mdelay(RTBENCH_WAIT_SLICE_MS);
        waited_ms += RTBENCH_WAIT_SLICE_MS;
    }
}

struct rtbench_periodic_context
{
    struct rt_timer timer;
    uint64_t *jitter_samples;
    uint64_t *callback_samples;
    uint64_t capacity;
    volatile uint64_t collected;
    uint64_t last_ticks;
    rt_bool_t warmed_up;
};

static struct rtbench_periodic_context rtbench_periodic;

static void rtbench_periodic_callback(void *parameter)
{
    struct rtbench_periodic_context *context = parameter;
    uint64_t callback_start = rtbench_read_counter();
    uint64_t index = context->collected;
    uint64_t interval_ns;
    volatile unsigned int work = 0;
    unsigned int i;

    if (index >= context->capacity)
    {
        return;
    }

    if (!context->warmed_up)
    {
        context->last_ticks = callback_start;
        context->warmed_up = RT_TRUE;
        return;
    }

    interval_ns = rtbench_ticks_to_ns(callback_start - context->last_ticks,
                                      rtbench_frequency);
    context->last_ticks = callback_start;
    context->jitter_samples[index] =
        rtbench_abs_delta(interval_ns, RTBENCH_PERIOD_NS);

    for (i = 0; i < 10; ++i)
    {
        work += i;
    }
    (void)work;

    context->callback_samples[index] = rtbench_ticks_to_ns(
        rtbench_read_counter() - callback_start, rtbench_frequency);
    context->collected = index + 1;
}

static int rtbench_run_periodic(uint64_t expected,
                                rt_bool_t fixed_duration,
                                uint64_t duration_ms,
                                unsigned int run,
                                const char *metric)
{
    struct rtbench_result jitter_result;
    struct rtbench_result callback_result;
    uint64_t *jitter_samples;
    uint64_t *callback_samples;
    rt_err_t error;

    memset(&rtbench_periodic, 0, sizeof(rtbench_periodic));
    jitter_samples = rt_calloc((rt_size_t)expected, sizeof(*jitter_samples));
    callback_samples = rt_calloc((rt_size_t)expected,
                                 sizeof(*callback_samples));
    if (jitter_samples == RT_NULL || callback_samples == RT_NULL)
    {
        rt_kprintf("RTBENCH_ERROR metric=%s reason=allocation expected=%llu\n",
                   metric,
                   (unsigned long long)expected);
        rt_free(jitter_samples);
        rt_free(callback_samples);
        return -RT_ENOMEM;
    }

    rtbench_periodic.jitter_samples = jitter_samples;
    rtbench_periodic.callback_samples = callback_samples;
    rtbench_periodic.capacity = expected;

    rt_timer_init(&rtbench_periodic.timer,
                  "rtperiod",
                  rtbench_periodic_callback,
                  &rtbench_periodic,
                  rt_tick_from_millisecond(RTBENCH_PERIOD_MS),
                  RT_TIMER_FLAG_PERIODIC | RT_TIMER_FLAG_HARD_TIMER);
    error = rt_timer_start(&rtbench_periodic.timer);
    if (error != RT_EOK)
    {
        rt_kprintf("RTBENCH_ERROR metric=%s reason=timer_start error=%d\n",
                   metric,
                   error);
        rt_timer_detach(&rtbench_periodic.timer);
        rt_free(jitter_samples);
        rt_free(callback_samples);
        return error;
    }

    if (fixed_duration)
    {
        rt_thread_mdelay((rt_int32_t)duration_ms);
    }
    else
    {
        rtbench_wait_for_samples(&rtbench_periodic.collected,
                                 expected,
                                 (expected + 1) * RTBENCH_PERIOD_MS);
    }

    rt_timer_stop(&rtbench_periodic.timer);
    rt_timer_detach(&rtbench_periodic.timer);

    rtbench_summarize(jitter_samples,
                      expected,
                      rtbench_periodic.collected,
                      &jitter_result);
    rtbench_summarize(callback_samples,
                      expected,
                      rtbench_periodic.collected,
                      &callback_result);
    rtbench_print_result(metric, run, &jitter_result);
    rtbench_print_result("callback_exec", run, &callback_result);

    rt_free(jitter_samples);
    rt_free(callback_samples);
    return jitter_result.missing == 0 && jitter_result.miss_1ms == 0
               ? RT_EOK
               : -RT_ETIMEOUT;
}

struct rtbench_preempt_context
{
    struct rt_semaphore ready;
    struct rt_semaphore wake;
    struct rt_semaphore done;
    struct rt_semaphore high_finished;
    struct rt_semaphore low_finished;
    rt_thread_t high_thread;
    rt_thread_t low_thread;
    uint64_t *samples;
    uint64_t expected;
    volatile uint64_t collected;
    volatile uint64_t release_ticks;
};

static struct rtbench_preempt_context rtbench_preempt;

static void rtbench_preempt_high(void *parameter)
{
    struct rtbench_preempt_context *context = parameter;
    uint64_t i;

    for (i = 0; i < context->expected; ++i)
    {
        rt_sem_release(&context->ready);
        if (rt_sem_take(&context->wake, RT_WAITING_FOREVER) != RT_EOK)
        {
            break;
        }
        context->samples[context->collected++] = rtbench_ticks_to_ns(
            rtbench_read_counter() - context->release_ticks,
            rtbench_frequency);
        rt_sem_release(&context->done);
    }
    rt_sem_release(&context->high_finished);
}

static void rtbench_preempt_low(void *parameter)
{
    struct rtbench_preempt_context *context = parameter;
    uint64_t i;

    for (i = 0; i < context->expected; ++i)
    {
        if (rt_sem_take(&context->ready, RT_WAITING_FOREVER) != RT_EOK)
        {
            break;
        }
        rt_thread_mdelay(1);
        context->release_ticks = rtbench_read_counter();
        rt_sem_release(&context->wake);
        if (rt_sem_take(&context->done, RT_WAITING_FOREVER) != RT_EOK)
        {
            break;
        }
    }
    rt_sem_release(&context->low_finished);
}

static int rtbench_run_preemption(uint64_t expected)
{
    struct rtbench_preempt_context *context = &rtbench_preempt;
    struct rtbench_result result;
    rt_tick_t timeout;
    rt_bool_t high_finished = RT_FALSE;
    rt_bool_t low_finished = RT_FALSE;

    memset(context, 0, sizeof(*context));
    context->samples = rt_calloc((rt_size_t)expected,
                                 sizeof(*context->samples));
    if (context->samples == RT_NULL)
    {
        rt_kprintf("RTBENCH_ERROR metric=preemption reason=allocation\n");
        return -RT_ENOMEM;
    }
    context->expected = expected;

    rt_sem_init(&context->ready, "rtready", 0, RT_IPC_FLAG_FIFO);
    rt_sem_init(&context->wake, "rtwake", 0, RT_IPC_FLAG_FIFO);
    rt_sem_init(&context->done, "rtdone", 0, RT_IPC_FLAG_FIFO);
    rt_sem_init(&context->high_finished, "rthfin", 0, RT_IPC_FLAG_FIFO);
    rt_sem_init(&context->low_finished, "rtlfin", 0, RT_IPC_FLAG_FIFO);

    context->high_thread = rt_thread_create("rtbhigh",
                                            rtbench_preempt_high,
                                            context,
                                            4096,
                                            5,
                                            5);
    context->low_thread = rt_thread_create("rtblow",
                                           rtbench_preempt_low,
                                           context,
                                           4096,
                                           20,
                                           5);
    if (context->high_thread == RT_NULL || context->low_thread == RT_NULL)
    {
        rt_kprintf("RTBENCH_ERROR metric=preemption reason=thread_create\n");
        if (context->high_thread != RT_NULL)
        {
            rt_thread_delete(context->high_thread);
        }
        if (context->low_thread != RT_NULL)
        {
            rt_thread_delete(context->low_thread);
        }
        goto cleanup;
    }

    rt_thread_startup(context->high_thread);
    rt_thread_startup(context->low_thread);
    timeout = rt_tick_from_millisecond(
        (rt_int32_t)(expected * 5 + RTBENCH_TIMEOUT_MARGIN_MS));
    high_finished = rt_sem_take(&context->high_finished, timeout) == RT_EOK;
    low_finished = rt_sem_take(&context->low_finished, timeout) == RT_EOK;
    if (!high_finished)
    {
        rt_thread_delete(context->high_thread);
    }
    if (!low_finished)
    {
        rt_thread_delete(context->low_thread);
    }

    rtbench_summarize(context->samples,
                      expected,
                      context->collected,
                      &result);
    rtbench_print_result("preemption", 1, &result);

cleanup:
    rt_sem_detach(&context->ready);
    rt_sem_detach(&context->wake);
    rt_sem_detach(&context->done);
    rt_sem_detach(&context->high_finished);
    rt_sem_detach(&context->low_finished);
    rt_free(context->samples);
    context->samples = RT_NULL;
    return context->collected == expected ? RT_EOK : -RT_ETIMEOUT;
}

struct rtbench_irq_context
{
    struct rt_semaphore completed;
    uint64_t *samples;
    uint64_t expected;
    volatile uint64_t collected;
    volatile uint64_t trigger_ticks;
    volatile rt_bool_t armed;
};

static struct rtbench_irq_context rtbench_irq;
extern struct rt_irq_desc isr_table[];

static void rtbench_irq_handler(int vector, void *parameter)
{
    struct rtbench_irq_context *context = parameter;
    uint64_t index = context->collected;

    if (vector == RTBENCH_SGI_INTID && context->armed &&
        index < context->expected)
    {
        context->samples[index] = rtbench_ticks_to_ns(
            rtbench_read_counter() - context->trigger_ticks,
            rtbench_frequency);
        context->collected = index + 1;
        context->armed = RT_FALSE;
        rt_sem_release(&context->completed);
    }
}

static int rtbench_run_irq(uint64_t expected)
{
    struct rtbench_irq_context *context = &rtbench_irq;
    struct rtbench_result result;
    struct rt_irq_desc old_descriptor;
    rt_base_t irq_level;
    rt_bool_t was_enabled;
    uint64_t i;

    memset(context, 0, sizeof(*context));
    context->samples = rt_calloc((rt_size_t)expected,
                                 sizeof(*context->samples));
    if (context->samples == RT_NULL)
    {
        rt_kprintf("RTBENCH_ERROR metric=irq reason=allocation\n");
        return -RT_ENOMEM;
    }
    context->expected = expected;
    rt_sem_init(&context->completed, "rtirq", 0, RT_IPC_FLAG_FIFO);

    irq_level = rt_hw_local_irq_disable();
    was_enabled = rt_hw_interrupt_get_enable(RTBENCH_SGI_INTID);
    rt_hw_interrupt_mask(RTBENCH_SGI_INTID);
    rt_hw_interrupt_clear_pending(RTBENCH_SGI_INTID);
    old_descriptor = isr_table[RTBENCH_SGI_INTID];
    rt_hw_interrupt_install(RTBENCH_SGI_INTID,
                            rtbench_irq_handler,
                            context,
                            "rtbench_sgi");
    rt_hw_interrupt_umask(RTBENCH_SGI_INTID);
    rt_hw_local_irq_enable(irq_level);

    for (i = 0; i < expected; ++i)
    {
        context->trigger_ticks = rtbench_read_counter();
        context->armed = RT_TRUE;
        __asm__ volatile("dmb ish" ::: "memory");
        rt_hw_interrupt_set_pending(RTBENCH_SGI_INTID);
        if (rt_sem_take(&context->completed,
                        rt_tick_from_millisecond(100)) != RT_EOK)
        {
            context->armed = RT_FALSE;
            rt_hw_interrupt_clear_pending(RTBENCH_SGI_INTID);
        }
        rt_thread_mdelay(1);
    }

    irq_level = rt_hw_local_irq_disable();
    rt_hw_interrupt_mask(RTBENCH_SGI_INTID);
    rt_hw_interrupt_clear_pending(RTBENCH_SGI_INTID);
    isr_table[RTBENCH_SGI_INTID] = old_descriptor;
    if (was_enabled)
    {
        rt_hw_interrupt_umask(RTBENCH_SGI_INTID);
    }
    rt_hw_local_irq_enable(irq_level);

    rtbench_summarize(context->samples,
                      expected,
                      context->collected,
                      &result);
    rtbench_print_result("irq", 1, &result);
    rt_sem_detach(&context->completed);
    rt_free(context->samples);
    context->samples = RT_NULL;
    return result.missing == 0 ? RT_EOK : -RT_ETIMEOUT;
}

static int rtbench_run_suite(uint64_t samples)
{
    unsigned int run;
    int status = RT_EOK;

    rtbench_frequency = rtbench_read_frequency();
    if (rtbench_frequency == 0)
    {
        rt_kprintf("RTBENCH_ERROR metric=suite reason=zero_counter_frequency\n");
        return -RT_ERROR;
    }

    rt_kprintf("RTBENCH_BEGIN samples=%llu frequency=%llu\n",
               (unsigned long long)samples,
               (unsigned long long)rtbench_frequency);
    for (run = 1; run <= 3; ++run)
    {
        if (rtbench_run_periodic(samples, RT_FALSE, 0, run,
                                 "timer_jitter") != RT_EOK)
        {
            status = -RT_ERROR;
        }
    }
    if (rtbench_run_preemption(samples) != RT_EOK)
    {
        status = -RT_ERROR;
    }
    if (rtbench_run_irq(samples) != RT_EOK)
    {
        status = -RT_ERROR;
    }
    rt_kprintf("RTBENCH_END status=%s\n", status == RT_EOK ? "PASS" : "FAIL");
    return status;
}

static int rtbench_run_stability(uint64_t seconds)
{
    uint64_t expected;
    struct rtbench_result conservation;
    uint64_t collected;
    uint64_t missing;
    int status;

    rtbench_frequency = rtbench_read_frequency();
    if (rtbench_frequency == 0)
    {
        rt_kprintf("RTBENCH_ERROR metric=stability reason=zero_counter_frequency\n");
        return -RT_ERROR;
    }

    expected = seconds * (1000U / RTBENCH_PERIOD_MS) - 1U;
    rt_kprintf("RTBENCH_STABILITY_BEGIN seconds=%llu expected=%llu\n",
               (unsigned long long)seconds,
               (unsigned long long)expected);
    status = rtbench_run_periodic(expected,
                                  RT_FALSE,
                                  seconds * 1000U,
                                  1,
                                  "stability_jitter");

    collected = rtbench_periodic.collected > expected
                    ? expected
                    : rtbench_periodic.collected;
    missing = expected - collected;
    if (collected + missing != expected)
    {
        rt_kprintf("RTBENCH_ERROR metric=stability reason=sample_conservation\n");
        status = -RT_ERROR;
    }
    memset(&conservation, 0, sizeof(conservation));
    conservation.expected = expected;
    conservation.collected = collected;
    conservation.missing = missing;
    rt_kprintf("RTBENCH_STABILITY_END status=%s expected=%llu collected=%llu "
               "missing=%llu\n",
               status == RT_EOK ? "PASS" : "FAIL",
               (unsigned long long)conservation.expected,
               (unsigned long long)conservation.collected,
               (unsigned long long)conservation.missing);
    rt_kprintf("RTBENCH_STABILITY_DONE\n");
    return status;
}

enum rtbench_job_kind
{
    RTBENCH_JOB_SUITE,
    RTBENCH_JOB_STABILITY,
};

struct rtbench_job
{
    enum rtbench_job_kind kind;
    uint64_t argument;
    volatile rt_bool_t running;
};

static struct rtbench_job rtbench_job;

static void rtbench_worker(void *parameter)
{
    struct rtbench_job *job = parameter;
    rt_base_t irq_level;

    if (job->kind == RTBENCH_JOB_SUITE)
    {
        rtbench_run_suite(job->argument);
    }
    else
    {
        rtbench_run_stability(job->argument);
    }

    irq_level = rt_hw_local_irq_disable();
    job->running = RT_FALSE;
    rt_hw_local_irq_enable(irq_level);
}

static int rtbench_start_job(enum rtbench_job_kind kind, uint64_t argument)
{
    rt_thread_t worker;
    rt_base_t irq_level;
    rt_err_t error;

    irq_level = rt_hw_local_irq_disable();
    if (rtbench_job.running)
    {
        rt_hw_local_irq_enable(irq_level);
        rt_kprintf("RTBENCH_ERROR metric=suite reason=busy\n");
        return -RT_EBUSY;
    }
    rtbench_job.kind = kind;
    rtbench_job.argument = argument;
    rtbench_job.running = RT_TRUE;
    rt_hw_local_irq_enable(irq_level);

    worker = rt_thread_create("rtbench",
                              rtbench_worker,
                              &rtbench_job,
                              RTBENCH_WORKER_STACK_SIZE,
                              10,
                              10);
    if (worker == RT_NULL)
    {
        irq_level = rt_hw_local_irq_disable();
        rtbench_job.running = RT_FALSE;
        rt_hw_local_irq_enable(irq_level);
        rt_kprintf("RTBENCH_ERROR metric=suite reason=thread_create\n");
        return -RT_ENOMEM;
    }

    error = rt_thread_startup(worker);
    if (error != RT_EOK)
    {
        rt_thread_delete(worker);
        irq_level = rt_hw_local_irq_disable();
        rtbench_job.running = RT_FALSE;
        rt_hw_local_irq_enable(irq_level);
        rt_kprintf("RTBENCH_ERROR metric=suite reason=thread_start error=%d\n",
                   error);
    }
    return error;
}

static int benchmark(int argc, char **argv)
{
    uint64_t samples = RTBENCH_DEFAULT_SAMPLES;

    if (argc > 1)
    {
        samples = rtbench_parse_bounded(argv[1],
                                        RTBENCH_DEFAULT_SAMPLES,
                                        RTBENCH_MAX_SAMPLES);
    }
    return rtbench_start_job(RTBENCH_JOB_SUITE, samples);
}
MSH_CMD_EXPORT(benchmark, run jitter preemption and SGI benchmarks);

static int rtbench_stability(int argc, char **argv)
{
    uint64_t seconds = RTBENCH_DEFAULT_STABILITY_SECONDS;

    if (argc > 1)
    {
        seconds = rtbench_parse_bounded(argv[1],
                                        RTBENCH_DEFAULT_STABILITY_SECONDS,
                                        RTBENCH_MAX_STABILITY_SECONDS);
    }
    return rtbench_start_job(RTBENCH_JOB_STABILITY, seconds);
}
MSH_CMD_EXPORT(rtbench_stability, run an explicit-duration stability test);
