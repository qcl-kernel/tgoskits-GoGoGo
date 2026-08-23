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

#include <arpa/inet.h>
#include <errno.h>
#include <netdev.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

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
#define RTBENCH_WORKER_PRIORITY 20U
#define RTBENCH_SGI_INTID 7
#define RTBENCH_NET_EVENT_PORT 9878
#define RTBENCH_NET_TRIGGER_PORT 9879
#define RTBENCH_NET_MAGIC UINT32_C(0x5254424e)
#define RTBENCH_NET_READY UINT32_C(0xffffffff)
#define RTBENCH_NET_PROBE_READY UINT32_C(0xfffffffe)
#define RTBENCH_NET_TIMEOUT_PER_SAMPLE_MS 15U
#define RTBENCH_NET_TIMEOUT_MARGIN_MS 30000U

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
static inline uint64_t rtbench_read_counter(void);

struct rtbench_net_event_context
{
    volatile rt_bool_t capturing;
    volatile uint32_t irq_dropped;
    volatile uint32_t irq_coalesced;
    volatile uint32_t probe_received;
    volatile uint32_t probe_acked;
    volatile uint32_t probe_no_irq;
    volatile uint32_t probe_duplicates;
    volatile uint32_t trigger_attempts;
    volatile uint32_t trigger_socket_failures;
    volatile uint32_t trigger_send_failures;
    uint64_t *irq_ticks;
    volatile uint8_t *irq_valid;
    uint32_t irq_capacity;
};

static struct rtbench_net_event_context rtbench_net_event;

static uint32_t rtbench_net_read_be32(const uint8_t *data)
{
    uint32_t value;

    memcpy(&value, data, sizeof(value));
    return ntohl(value);
}

static rt_bool_t rtbench_net_event_probe_sequence(const void *payload,
                                                  rt_uint32_t length,
                                                  uint32_t *sequence)
{
    const uint8_t *packet = (const uint8_t *)payload;
    const uint8_t *ip;
    const uint8_t *udp;
    rt_uint32_t ip_header_length;
    rt_uint16_t destination_port;
    uint32_t wire_sequence;

    if (packet == RT_NULL || sequence == RT_NULL ||
        length < 14U + 20U + 8U + 8U)
    {
        return RT_FALSE;
    }
    if (packet[12] != 0x08U || packet[13] != 0x00U)
    {
        return RT_FALSE;
    }

    ip = packet + 14U;
    if ((ip[0] >> 4) != 4U)
    {
        return RT_FALSE;
    }
    ip_header_length = (rt_uint32_t)(ip[0] & 0x0fU) * 4U;
    if (ip_header_length < 20U ||
        length < 14U + ip_header_length + 8U + 8U || ip[9] != 17U)
    {
        return RT_FALSE;
    }

    udp = ip + ip_header_length;
    destination_port = (rt_uint16_t)(((rt_uint16_t)udp[2] << 8) | udp[3]);
    if (destination_port != RTBENCH_NET_EVENT_PORT ||
        rtbench_net_read_be32(udp + 8U) != RTBENCH_NET_MAGIC)
    {
        return RT_FALSE;
    }

    memcpy(&wire_sequence, udp + 12U, sizeof(wire_sequence));
    *sequence = ntohl(wire_sequence);
    return *sequence != RTBENCH_NET_READY;
}

/* Called by the patched virtio-net ISR. Store the timestamp by sequence so
 * interrupt coalescing and lwIP receive ordering cannot pair two packets
 * incorrectly. */
void rt_virtio_net_rx_irq_hook(rt_uint16_t used_idx,
                               const void *payload,
                               rt_uint32_t length)
{
    struct rtbench_net_event_context *context = &rtbench_net_event;
    uint32_t sequence;

    (void)used_idx;
    if (!context->capturing ||
        !rtbench_net_event_probe_sequence(payload, length, &sequence))
    {
        return;
    }

    if (sequence >= context->irq_capacity || context->irq_ticks == RT_NULL ||
        context->irq_valid == RT_NULL)
    {
        context->irq_dropped++;
        return;
    }

    if (context->irq_valid[sequence])
    {
        context->irq_coalesced++;
        return;
    }

    context->irq_ticks[sequence] = rtbench_read_counter();
    __asm__ volatile("dmb ish" ::: "memory");
    context->irq_valid[sequence] = 1;
}

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

static void rtbench_net_event_reset(void)
{
    rtbench_net_event.capturing = RT_FALSE;
    rtbench_net_event.irq_dropped = 0;
    rtbench_net_event.irq_coalesced = 0;
    rtbench_net_event.probe_received = 0;
    rtbench_net_event.probe_acked = 0;
    rtbench_net_event.probe_no_irq = 0;
    rtbench_net_event.probe_duplicates = 0;
    rtbench_net_event.trigger_attempts = 0;
    rtbench_net_event.trigger_socket_failures = 0;
    rtbench_net_event.trigger_send_failures = 0;
    if (rtbench_net_event.irq_ticks != RT_NULL &&
        rtbench_net_event.irq_capacity != 0)
    {
        memset(rtbench_net_event.irq_ticks,
               0,
               rtbench_net_event.irq_capacity * sizeof(*rtbench_net_event.irq_ticks));
    }
    if (rtbench_net_event.irq_valid != RT_NULL &&
        rtbench_net_event.irq_capacity != 0)
    {
        memset((void *)rtbench_net_event.irq_valid,
               0,
               rtbench_net_event.irq_capacity * sizeof(*rtbench_net_event.irq_valid));
    }
}

static rt_bool_t rtbench_net_event_take_irq(uint32_t sequence,
                                            uint64_t *ticks)
{
    struct rtbench_net_event_context *context = &rtbench_net_event;

    if (sequence >= context->irq_capacity || context->irq_ticks == RT_NULL ||
        context->irq_valid == RT_NULL || !context->irq_valid[sequence])
    {
        return RT_FALSE;
    }

    __asm__ volatile("dmb ish" ::: "memory");
    *ticks = context->irq_ticks[sequence];
    __asm__ volatile("dmb ish" ::: "memory");
    context->irq_valid[sequence] = 0;
    return RT_TRUE;
}

static int rtbench_net_event_socket(int port)
{
    struct sockaddr_in address;
    struct timeval timeout = {
        .tv_sec = 0,
        .tv_usec = 100000,
    };
    int socket_fd;

    socket_fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (socket_fd < 0)
    {
        return -1;
    }
    if (setsockopt(socket_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   sizeof(timeout)) != 0)
    {
        closesocket(socket_fd);
        return -1;
    }
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons((uint16_t)port);
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(socket_fd, (struct sockaddr *)&address, sizeof(address)) != 0)
    {
        closesocket(socket_fd);
        return -1;
    }
    return socket_fd;
}

static void rtbench_net_event_trigger_linux(uint64_t expected)
{
    struct rtbench_net_event_context *context = &rtbench_net_event;
    struct sockaddr_in peer;
    uint32_t payload[2];
    int socket_fd;
    ssize_t sent;

    context->trigger_attempts++;
    socket_fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (socket_fd < 0)
    {
        context->trigger_socket_failures++;
        return;
    }
    memset(&peer, 0, sizeof(peer));
    peer.sin_family = AF_INET;
    peer.sin_port = htons(RTBENCH_NET_TRIGGER_PORT);
    inet_aton("192.168.77.11", &peer.sin_addr);
    payload[0] = htonl(RTBENCH_NET_MAGIC);
    payload[1] = htonl((uint32_t)expected);
    sent = sendto(socket_fd, payload, sizeof(payload), 0,
                  (struct sockaddr *)&peer, sizeof(peer));
    if (sent != (ssize_t)sizeof(payload))
    {
        context->trigger_send_failures++;
    }
    closesocket(socket_fd);
}

static int rtbench_run_net_event_latency(uint64_t expected)
{
    struct rtbench_result result;
    struct rtbench_net_event_context *context = &rtbench_net_event;
    uint64_t *samples;
    uint8_t *seen_sequences;
    uint64_t *irq_ticks;
    uint8_t *irq_valid;
    uint64_t collected = 0;
    uint64_t deadline_ms;
    uint64_t next_trigger_ms;
    int socket_fd;
    rt_bool_t trigger_pending;

    samples = rt_calloc((rt_size_t)expected, sizeof(*samples));
    if (samples == RT_NULL)
    {
        rt_kprintf("RTBENCH_ERROR metric=net_event_latency reason=allocation\n");
        return -RT_ENOMEM;
    }
    seen_sequences = rt_calloc((rt_size_t)expected, sizeof(*seen_sequences));
    if (seen_sequences == RT_NULL)
    {
        rt_kprintf("RTBENCH_ERROR metric=net_event_latency reason=allocation\n");
        rt_free(samples);
        return -RT_ENOMEM;
    }
    irq_ticks = rt_calloc((rt_size_t)expected, sizeof(*irq_ticks));
    if (irq_ticks == RT_NULL)
    {
        rt_kprintf("RTBENCH_ERROR metric=net_event_latency reason=allocation\n");
        rt_free(seen_sequences);
        rt_free(samples);
        return -RT_ENOMEM;
    }
    irq_valid = rt_calloc((rt_size_t)expected, sizeof(*irq_valid));
    if (irq_valid == RT_NULL)
    {
        rt_kprintf("RTBENCH_ERROR metric=net_event_latency reason=allocation\n");
        rt_free(irq_ticks);
        rt_free(seen_sequences);
        rt_free(samples);
        return -RT_ENOMEM;
    }
    socket_fd = rtbench_net_event_socket(RTBENCH_NET_EVENT_PORT);
    if (socket_fd < 0)
    {
        rt_kprintf("RTBENCH_ERROR metric=net_event_latency reason=socket\n");
        rt_free(irq_valid);
        rt_free(irq_ticks);
        rt_free(seen_sequences);
        rt_free(samples);
        return -RT_ERROR;
    }

    context->irq_ticks = irq_ticks;
    context->irq_valid = irq_valid;
    context->irq_capacity = (uint32_t)expected;
    rtbench_net_event_reset();
    context->capturing = RT_TRUE;
    rt_kprintf("RTBENCH_NET_READY port=%u expected=%llu\n",
               RTBENCH_NET_EVENT_PORT,
               (unsigned long long)expected);
    /* C's Linux guest listens for this trigger. A/B use the host-forwarded
     * QEMU port and ignore it. */
    rtbench_net_event_trigger_linux(expected);
    trigger_pending = RT_TRUE;
    next_trigger_ms = rt_tick_get_millisecond() + 100U;

    deadline_ms = rt_tick_get_millisecond() +
                  expected * RTBENCH_NET_TIMEOUT_PER_SAMPLE_MS +
                  RTBENCH_NET_TIMEOUT_MARGIN_MS;
    while (collected < expected &&
           rt_tick_get_millisecond() < deadline_ms)
    {
        uint8_t payload[64];
        uint32_t magic;
        uint32_t sequence;
        uint32_t wire_sequence;
        uint64_t irq_ticks;
        struct sockaddr_in peer;
        socklen_t peer_length = sizeof(peer);
        ssize_t received;

        if (trigger_pending &&
            rt_tick_get_millisecond() >= next_trigger_ms)
        {
            /* The first UDP trigger can be lost while AxVisor switches the
             * active console/guest under load. Retry until Linux confirms
             * readiness; do not add retries to the measured probe stream. */
            rtbench_net_event_trigger_linux(expected);
            next_trigger_ms = rt_tick_get_millisecond() + 100U;
        }

        received = recvfrom(socket_fd, payload, sizeof(payload), 0,
                            (struct sockaddr *)&peer, &peer_length);
        if (received < 0)
        {
            if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR ||
                errno == ETIMEDOUT)
            {
                continue;
            }
            break;
        }
        if (received < (ssize_t)sizeof(magic))
        {
            continue;
        }
        memcpy(&magic, payload, sizeof(magic));
        if (ntohl(magic) != RTBENCH_NET_MAGIC)
        {
            continue;
        }
        if (received < (ssize_t)(sizeof(magic) + sizeof(sequence)))
        {
            continue;
        }
        memcpy(&wire_sequence, payload + sizeof(magic), sizeof(wire_sequence));
        sequence = ntohl(wire_sequence);
        if (sequence == RTBENCH_NET_PROBE_READY)
        {
            /* Linux did not receive a previous trigger. Ask it to retry
             * without treating this readiness control packet as the final
             * trigger acknowledgement. */
            rtbench_net_event_trigger_linux(expected);
            trigger_pending = RT_TRUE;
            next_trigger_ms = rt_tick_get_millisecond() + 100U;
            continue;
        }
        if (sequence == RTBENCH_NET_READY)
        {
            (void)sendto(socket_fd, payload,
                         sizeof(magic) + sizeof(sequence),
                         0, (struct sockaddr *)&peer, peer_length);
            trigger_pending = RT_FALSE;
            context->capturing = RT_TRUE;
            continue;
        }
        if (sequence >= expected)
        {
            continue;
        }
        context->probe_received++;
        if (seen_sequences[sequence])
        {
            context->probe_duplicates++;
            (void)sendto(socket_fd, payload, sizeof(magic) + sizeof(sequence),
                         0, (struct sockaddr *)&peer, peer_length);
            context->probe_acked++;
            continue;
        }
        if (!context->capturing ||
            !rtbench_net_event_take_irq(sequence, &irq_ticks))
        {
            context->probe_no_irq++;
            continue;
        }
        samples[collected++] = rtbench_ticks_to_ns(
            rtbench_read_counter() - irq_ticks,
            rtbench_frequency);
        seen_sequences[sequence] = 1;
        (void)sendto(socket_fd, payload, sizeof(magic) + sizeof(sequence),
                     0, (struct sockaddr *)&peer, peer_length);
        context->probe_acked++;
    }
    context->capturing = RT_FALSE;
    closesocket(socket_fd);

    rtbench_summarize(samples, expected, collected, &result);
    rtbench_print_result("net_event_latency", 1, &result);
    rt_kprintf("RTBENCH_NET_DIAGNOSTIC irq_dropped=%u irq_coalesced=%u "
               "probe_received=%u probe_acked=%u probe_no_irq=%u "
               "probe_duplicates=%u trigger_attempts=%u "
               "trigger_socket_failures=%u trigger_send_failures=%u\n",
               context->irq_dropped,
               context->irq_coalesced,
               context->probe_received,
               context->probe_acked,
               context->probe_no_irq,
               context->probe_duplicates,
               context->trigger_attempts,
               context->trigger_socket_failures,
               context->trigger_send_failures);
    rt_free(seen_sequences);
    rt_free(samples);
    rt_free(irq_valid);
    rt_free(irq_ticks);
    context->irq_valid = RT_NULL;
    context->irq_ticks = RT_NULL;
    context->irq_capacity = 0;
    return result.missing == 0 && context->irq_dropped == 0 ? RT_EOK
                                                            : -RT_ETIMEOUT;
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
                                rt_bool_t strict_tail,
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
    return jitter_result.missing == 0 &&
               (!strict_tail || jitter_result.miss_1ms == 0)
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

struct rtbench_irq_task_context
{
    struct rt_semaphore completed;
    struct rt_semaphore wake;
    uint64_t *samples;
    uint64_t expected;
    volatile uint64_t collected;
    volatile uint64_t trigger_ticks;
    volatile rt_bool_t armed;
};

static struct rtbench_irq_task_context rtbench_irq_task;

static void rtbench_irq_task_handler(int vector, void *parameter)
{
    struct rtbench_irq_task_context *context = parameter;

    if (vector == RTBENCH_SGI_INTID && context->armed)
    {
        context->armed = RT_FALSE;
        rt_sem_release(&context->wake);
    }
}

static void rtbench_irq_task_high(void *parameter)
{
    struct rtbench_irq_task_context *context = parameter;
    uint64_t i;

    for (i = 0; i < context->expected; ++i)
    {
        if (rt_sem_take(&context->wake, RT_WAITING_FOREVER) != RT_EOK)
        {
            break;
        }
        context->samples[context->collected++] = rtbench_ticks_to_ns(
            rtbench_read_counter() - context->trigger_ticks,
            rtbench_frequency);
        rt_sem_release(&context->completed);
    }
}

static int rtbench_run_irq_to_task(uint64_t expected)
{
    struct rtbench_irq_task_context *context = &rtbench_irq_task;
    struct rtbench_result result;
    struct rt_irq_desc old_descriptor;
    rt_thread_t high_thread;
    rt_base_t irq_level;
    rt_bool_t was_enabled;
    rt_tick_t timeout;
    uint64_t i;

    memset(context, 0, sizeof(*context));
    context->samples = rt_calloc((rt_size_t)expected,
                                 sizeof(*context->samples));
    if (context->samples == RT_NULL)
    {
        rt_kprintf("RTBENCH_ERROR metric=irq_to_task reason=allocation\n");
        return -RT_ENOMEM;
    }
    context->expected = expected;
    rt_sem_init(&context->completed, "rtirqtsk", 0, RT_IPC_FLAG_FIFO);
    rt_sem_init(&context->wake, "rtirqwak", 0, RT_IPC_FLAG_FIFO);

    high_thread = rt_thread_create("rtbi2th",
                                   rtbench_irq_task_high,
                                   context,
                                   4096,
                                   4,
                                   5);
    if (high_thread == RT_NULL)
    {
        rt_kprintf("RTBENCH_ERROR metric=irq_to_task reason=thread_create\n");
        rt_sem_detach(&context->wake);
        rt_sem_detach(&context->completed);
        rt_free(context->samples);
        context->samples = RT_NULL;
        return -RT_ENOMEM;
    }

    irq_level = rt_hw_local_irq_disable();
    was_enabled = rt_hw_interrupt_get_enable(RTBENCH_SGI_INTID);
    rt_hw_interrupt_mask(RTBENCH_SGI_INTID);
    rt_hw_interrupt_clear_pending(RTBENCH_SGI_INTID);
    old_descriptor = isr_table[RTBENCH_SGI_INTID];
    rt_hw_interrupt_install(RTBENCH_SGI_INTID,
                            rtbench_irq_task_handler,
                            context,
                            "rtbench_irq_task");
    rt_hw_interrupt_umask(RTBENCH_SGI_INTID);
    rt_hw_local_irq_enable(irq_level);

    rt_thread_startup(high_thread);
    timeout = rt_tick_from_millisecond(
        (rt_int32_t)(expected * 10 + RTBENCH_TIMEOUT_MARGIN_MS));
    for (i = 0; i < expected; ++i)
    {
        context->trigger_ticks = rtbench_read_counter();
        context->armed = RT_TRUE;
        __asm__ volatile("dmb ish" ::: "memory");
        rt_hw_interrupt_set_pending(RTBENCH_SGI_INTID);
        if (rt_sem_take(&context->completed, timeout) != RT_EOK)
        {
            context->armed = RT_FALSE;
            rt_hw_interrupt_clear_pending(RTBENCH_SGI_INTID);
            break;
        }
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

    if (context->collected != expected)
    {
        rt_thread_delete(high_thread);
    }
    else
    {
        rt_sem_release(&context->wake);
        rt_thread_mdelay(1);
    }

    rtbench_summarize(context->samples,
                      expected,
                      context->collected,
                      &result);
    rtbench_print_result("irq_to_task", 1, &result);
    rt_sem_detach(&context->wake);
    rt_sem_detach(&context->completed);
    rt_free(context->samples);
    context->samples = RT_NULL;
    return result.missing == 0 ? RT_EOK : -RT_ETIMEOUT;
}

static int rtbench_run_irq_disabled_duration(uint64_t expected)
{
    struct rtbench_result result;
    uint64_t *samples;
    uint64_t start;
    uint64_t i;
    volatile uint64_t work = 0;
    rt_base_t level;

    samples = rt_calloc((rt_size_t)expected, sizeof(*samples));
    if (samples == RT_NULL)
    {
        rt_kprintf("RTBENCH_ERROR metric=irq_disabled_duration reason=allocation\n");
        return -RT_ENOMEM;
    }

    for (i = 0; i < expected; ++i)
    {
        unsigned int spin;

        start = rtbench_read_counter();
        level = rt_hw_local_irq_disable();
        for (spin = 0; spin < 64; ++spin)
        {
            work += spin;
        }
        rt_hw_local_irq_enable(level);
        samples[i] = rtbench_ticks_to_ns(rtbench_read_counter() - start,
                                         rtbench_frequency);
    }
    (void)work;

    rtbench_summarize(samples, expected, expected, &result);
    rtbench_print_result("irq_disabled_duration", 1, &result);
    rt_free(samples);
    return result.missing == 0 ? RT_EOK : -RT_ETIMEOUT;
}

struct rtbench_mutex_context
{
    struct rt_mutex mutex;
    struct rt_semaphore low_acquired;
    struct rt_semaphore high_go;
    struct rt_semaphore high_acquired;
    struct rt_semaphore high_done;
    struct rt_semaphore medium_go;
    struct rt_semaphore medium_done;
    struct rt_semaphore release_now;
    struct rt_semaphore low_done;
    rt_thread_t high_thread;
    rt_thread_t medium_thread;
    rt_thread_t low_thread;
    uint64_t *samples;
    uint64_t expected;
    volatile uint64_t collected;
    volatile uint64_t request_ticks;
};

static struct rtbench_mutex_context rtbench_mutex;

static void rtbench_mutex_high(void *parameter)
{
    struct rtbench_mutex_context *context = parameter;
    uint64_t i;

    for (i = 0; i < context->expected; ++i)
    {
        if (rt_sem_take(&context->high_go, RT_WAITING_FOREVER) != RT_EOK)
        {
            break;
        }
        context->request_ticks = rtbench_read_counter();
        if (rt_mutex_take(&context->mutex, RT_WAITING_FOREVER) != RT_EOK)
        {
            break;
        }
        context->samples[context->collected++] = rtbench_ticks_to_ns(
            rtbench_read_counter() - context->request_ticks,
            rtbench_frequency);
        rt_mutex_release(&context->mutex);
        rt_sem_release(&context->high_acquired);
    }
    rt_sem_release(&context->high_done);
}

static void rtbench_mutex_low(void *parameter)
{
    struct rtbench_mutex_context *context = parameter;
    uint64_t i;

    for (i = 0; i < context->expected; ++i)
    {
        if (rt_mutex_take(&context->mutex, RT_WAITING_FOREVER) != RT_EOK)
        {
            break;
        }
        rt_sem_release(&context->low_acquired);
        rt_sem_release(&context->medium_go);
        if (rt_sem_take(&context->release_now,
                        rt_tick_from_millisecond(100)) != RT_EOK)
        {
            rt_mutex_release(&context->mutex);
            break;
        }
        rt_mutex_release(&context->mutex);
    }
    rt_sem_release(&context->low_done);
}

static void rtbench_mutex_medium(void *parameter)
{
    struct rtbench_mutex_context *context = parameter;
    volatile uint64_t work = 0;
    uint64_t i;
    uint64_t spin;

    for (i = 0; i < context->expected; ++i)
    {
        if (rt_sem_take(&context->medium_go, RT_WAITING_FOREVER) != RT_EOK)
        {
            break;
        }
        for (spin = 0; spin < 1000; ++spin)
        {
            work += spin;
        }
    }
    rt_sem_release(&context->medium_done);
    (void)work;
}

static int rtbench_run_mutex_inversion(uint64_t expected)
{
    struct rtbench_mutex_context *context = &rtbench_mutex;
    struct rtbench_result result;
    rt_tick_t timeout;

    memset(context, 0, sizeof(*context));
    context->samples = rt_calloc((rt_size_t)expected,
                                 sizeof(*context->samples));
    if (context->samples == RT_NULL)
    {
        rt_kprintf("RTBENCH_ERROR metric=mutex_inversion reason=allocation\n");
        return -RT_ENOMEM;
    }
    context->expected = expected;
    rt_mutex_init(&context->mutex, "rtbmtx", RT_IPC_FLAG_FIFO);
    rt_sem_init(&context->low_acquired, "rtbmlac", 0, RT_IPC_FLAG_FIFO);
    rt_sem_init(&context->high_go, "rtbmhgo", 0, RT_IPC_FLAG_FIFO);
    rt_sem_init(&context->high_acquired, "rtbmha", 0, RT_IPC_FLAG_FIFO);
    rt_sem_init(&context->high_done, "rtbmhd", 0, RT_IPC_FLAG_FIFO);
    rt_sem_init(&context->medium_go, "rtbmmgo", 0, RT_IPC_FLAG_FIFO);
    rt_sem_init(&context->medium_done, "rtbmmd", 0, RT_IPC_FLAG_FIFO);
    rt_sem_init(&context->release_now, "rtbmrel", 0, RT_IPC_FLAG_FIFO);
    rt_sem_init(&context->low_done, "rtbmld", 0, RT_IPC_FLAG_FIFO);

    context->high_thread = rt_thread_create("rtbmhigh",
                                            rtbench_mutex_high,
                                            context,
                                            4096,
                                            4,
                                            5);
    context->medium_thread = rt_thread_create("rtbmmed",
                                              rtbench_mutex_medium,
                                              context,
                                              4096,
                                              10,
                                              5);
    context->low_thread = rt_thread_create("rtbmlow",
                                           rtbench_mutex_low,
                                           context,
                                           4096,
                                           20,
                                           5);
    if (context->high_thread == RT_NULL || context->medium_thread == RT_NULL ||
        context->low_thread == RT_NULL)
    {
        rt_kprintf("RTBENCH_ERROR metric=mutex_inversion reason=thread_create\n");
        if (context->high_thread != RT_NULL) rt_thread_delete(context->high_thread);
        if (context->medium_thread != RT_NULL) rt_thread_delete(context->medium_thread);
        if (context->low_thread != RT_NULL) rt_thread_delete(context->low_thread);
        rt_sem_detach(&context->low_acquired);
        rt_sem_detach(&context->high_go);
        rt_sem_detach(&context->medium_go);
        rt_sem_detach(&context->medium_done);
        rt_sem_detach(&context->low_done);
        rt_sem_detach(&context->release_now);
        rt_sem_detach(&context->high_done);
        rt_sem_detach(&context->high_acquired);
        rt_mutex_detach(&context->mutex);
        rt_free(context->samples);
        context->samples = RT_NULL;
        return -RT_ENOMEM;
    }

    /*
     * All workers start blocked. For every sample low takes the mutex first;
     * the controller then starts medium interference and finally unblocks the
     * high-priority waiter, which triggers priority inheritance in low.
     */
    rt_thread_startup(context->low_thread);
    rt_thread_startup(context->medium_thread);
    rt_thread_startup(context->high_thread);

    timeout = rt_tick_from_millisecond(
        (rt_int32_t)(expected * 10 + RTBENCH_TIMEOUT_MARGIN_MS));
    while (context->collected < expected)
    {
        rt_sem_release(&context->high_go);
        if (rt_sem_take(&context->low_acquired, timeout) != RT_EOK)
        {
            break;
        }
        rt_sem_release(&context->medium_go);
        rt_sem_release(&context->high_go);
        rt_sem_release(&context->release_now);
        if (rt_sem_take(&context->high_acquired, timeout) != RT_EOK)
        {
            break;
        }
    }

    rt_sem_release(&context->high_go);
    rt_sem_release(&context->medium_go);
    rt_sem_release(&context->release_now);
    if (context->collected != expected)
    {
        rt_kprintf("RTBENCH_ERROR metric=mutex_inversion reason=sample_timeout\n");
    }
    (void)rt_sem_take(&context->high_done, timeout);
    (void)rt_sem_take(&context->medium_done, timeout);
    (void)rt_sem_take(&context->low_done, timeout);

    rtbench_summarize(context->samples,
                      expected,
                      context->collected,
                      &result);
    rtbench_print_result("mutex_inversion", 1, &result);
    rt_sem_detach(&context->low_acquired);
    rt_sem_detach(&context->high_go);
    rt_sem_detach(&context->medium_go);
    rt_sem_detach(&context->medium_done);
    rt_sem_detach(&context->low_done);
    rt_sem_detach(&context->release_now);
    rt_sem_detach(&context->high_done);
    rt_sem_detach(&context->high_acquired);
    rt_mutex_detach(&context->mutex);
    rt_free(context->samples);
    context->samples = RT_NULL;
    return result.missing == 0 ? RT_EOK : -RT_ETIMEOUT;
}

struct rtbench_wake_load_context
{
    struct rt_semaphore wake;
    struct rt_semaphore completed;
    struct rt_semaphore done;
    struct rt_semaphore load_go;
    struct rt_semaphore load_done;
    rt_thread_t high_thread;
    rt_thread_t load_threads[4];
    uint64_t *samples;
    uint64_t expected;
    volatile uint64_t collected;
    volatile uint64_t release_ticks;
};

static struct rtbench_wake_load_context rtbench_wake_context;

static void rtbench_wake_high(void *parameter)
{
    struct rtbench_wake_load_context *context = parameter;
    uint64_t i;

    for (i = 0; i < context->expected; ++i)
    {
        if (rt_sem_take(&context->wake, RT_WAITING_FOREVER) != RT_EOK)
        {
            break;
        }
        context->samples[context->collected++] = rtbench_ticks_to_ns(
            rtbench_read_counter() - context->release_ticks,
            rtbench_frequency);
        rt_sem_release(&context->completed);
    }
    rt_sem_release(&context->done);
}

static void rtbench_wake_load(void *parameter)
{
    struct rtbench_wake_load_context *context = parameter;
    volatile uint64_t work = 0;
    uint64_t i;
    uint64_t spin;

    for (i = 0; i < context->expected; ++i)
    {
        if (rt_sem_take(&context->load_go, RT_WAITING_FOREVER) != RT_EOK)
        {
            break;
        }
        for (spin = 0; spin < 1000; ++spin)
        {
            work += spin;
        }
    }
    rt_sem_release(&context->load_done);
    (void)work;
}

static int rtbench_run_wake_under_load(uint64_t expected)
{
    struct rtbench_wake_load_context *context = &rtbench_wake_context;
    struct rtbench_result result;
    rt_tick_t timeout;
    unsigned int i;

    memset(context, 0, sizeof(*context));
    context->samples = rt_calloc((rt_size_t)expected,
                                 sizeof(*context->samples));
    if (context->samples == RT_NULL)
    {
        rt_kprintf("RTBENCH_ERROR metric=wake_under_load reason=allocation\n");
        return -RT_ENOMEM;
    }
    context->expected = expected;
    rt_sem_init(&context->wake, "rtbwake", 0, RT_IPC_FLAG_FIFO);
    rt_sem_init(&context->completed, "rtbwdone", 0, RT_IPC_FLAG_FIFO);
    rt_sem_init(&context->done, "rtbwfin", 0, RT_IPC_FLAG_FIFO);
    rt_sem_init(&context->load_go, "rtbwlgo", 0, RT_IPC_FLAG_FIFO);
    rt_sem_init(&context->load_done, "rtbwld", 0, RT_IPC_FLAG_FIFO);

    context->high_thread = rt_thread_create("rtbwhigh",
                                            rtbench_wake_high,
                                            context,
                                            4096,
                                            4,
                                            5);
    if (context->high_thread == RT_NULL)
    {
        rt_kprintf("RTBENCH_ERROR metric=wake_under_load reason=thread_create\n");
        rt_sem_detach(&context->done);
        rt_sem_detach(&context->completed);
        rt_sem_detach(&context->wake);
        rt_free(context->samples);
        context->samples = RT_NULL;
        return -RT_ENOMEM;
    }
    for (i = 0; i < 4; ++i)
    {
        char name[RT_NAME_MAX + 1];
        rt_snprintf(name, sizeof(name), "rtbw%u", i);
        context->load_threads[i] = rt_thread_create(name,
                                                     rtbench_wake_load,
                                                     context,
                                                     4096,
                                                     12 + (rt_uint8_t)i,
                                                     5);
        if (context->load_threads[i] == RT_NULL)
        {
            break;
        }
        /* Wait until the thread exists in the scheduler before proceeding. */
    }
    if (i != 4)
    {
        unsigned int created = i;
        rt_kprintf("RTBENCH_ERROR metric=wake_under_load reason=thread_create\n");
        rt_thread_delete(context->high_thread);
        for (i = 0; i < created; ++i)
        {
            rt_thread_delete(context->load_threads[i]);
        }
        rt_sem_detach(&context->done);
        rt_sem_detach(&context->completed);
        rt_sem_detach(&context->wake);
        rt_sem_detach(&context->load_go);
        rt_sem_detach(&context->load_done);
        rt_free(context->samples);
        context->samples = RT_NULL;
        return -RT_ENOMEM;
    }

    rt_thread_startup(context->high_thread);
    for (i = 0; i < 4; ++i)
    {
        rt_thread_startup(context->load_threads[i]);
    }
    timeout = rt_tick_from_millisecond(
        (rt_int32_t)(expected * 10 + RTBENCH_TIMEOUT_MARGIN_MS));
    for (i = 0; i < expected; ++i)
    {
        unsigned int load;

        for (load = 0; load < 4; ++load)
        {
            rt_sem_release(&context->load_go);
        }
        context->release_ticks = rtbench_read_counter();
        rt_sem_release(&context->wake);
        if (rt_sem_take(&context->completed, timeout) != RT_EOK)
        {
            break;
        }
    }

    for (i = 0; i < 4; ++i)
    {
        rt_sem_release(&context->load_go);
    }
    if (context->collected != expected)
    {
        rt_kprintf("RTBENCH_ERROR metric=wake_under_load reason=sample_timeout\n");
    }
    else
    {
        (void)rt_sem_take(&context->done, timeout);
    }
    (void)rt_sem_take(&context->load_done, timeout);

    rtbench_summarize(context->samples,
                      expected,
                      context->collected,
                      &result);
    rtbench_print_result("wake_under_load", 1, &result);
    rt_sem_detach(&context->done);
    rt_sem_detach(&context->completed);
    rt_sem_detach(&context->wake);
    rt_sem_detach(&context->load_go);
    rt_sem_detach(&context->load_done);
    rt_free(context->samples);
    context->samples = RT_NULL;
    return result.missing == 0 ? RT_EOK : -RT_ETIMEOUT;
}

static int rtbench_run_suite_metrics(uint64_t samples, rt_bool_t include_network)
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
        if (rtbench_run_periodic(samples, RT_FALSE, 0, RT_FALSE, run,
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
    if (rtbench_run_irq_to_task(samples) != RT_EOK)
    {
        status = -RT_ERROR;
    }
    if (rtbench_run_irq_disabled_duration(samples) != RT_EOK)
    {
        status = -RT_ERROR;
    }
    if (rtbench_run_mutex_inversion(samples) != RT_EOK)
    {
        status = -RT_ERROR;
    }
    if (rtbench_run_wake_under_load(samples) != RT_EOK)
    {
        status = -RT_ERROR;
    }
    if (include_network && rtbench_run_net_event_latency(samples) != RT_EOK)
    {
        status = -RT_ERROR;
    }
    rt_kprintf("RTBENCH_END status=%s\n", status == RT_EOK ? "PASS" : "FAIL");
    return status;
}

static int rtbench_run_suite(uint64_t samples)
{
    return rtbench_run_suite_metrics(samples, RT_TRUE);
}

static int rtbench_run_core_suite(uint64_t samples)
{
    return rtbench_run_suite_metrics(samples, RT_FALSE);
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
    /* The BEGIN marker is printed synchronously by rtbench_start_job in the
     * shell context (see the msh prompt race note there); the worker only
     * reports the metrics and the END marker. */
    status = rtbench_run_periodic(expected,
                                  RT_FALSE,
                                  seconds * 1000U,
                                  RT_TRUE,
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
    RTBENCH_JOB_CORE_SUITE,
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
    else if (job->kind == RTBENCH_JOB_CORE_SUITE)
    {
        rtbench_run_core_suite(job->argument);
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

    if (kind == RTBENCH_JOB_STABILITY)
    {
        /* Print the BEGIN marker from the shell context before the worker
         * thread exists: rt_kprintf output is not atomic across threads, so
         * a marker printed by the worker races with the msh prompt echo and
         * the result gate can see the marker line corrupted mid-string. */
        rt_uint64_t expected = argument * (1000U / RTBENCH_PERIOD_MS) - 1U;
        rt_kprintf("RTBENCH_STABILITY_BEGIN seconds=%llu expected=%llu\n",
                   (unsigned long long)argument,
                   (unsigned long long)expected);
    }

    worker = rt_thread_create("rtbench",
                              rtbench_worker,
                              &rtbench_job,
                              RTBENCH_WORKER_STACK_SIZE,
                              RTBENCH_WORKER_PRIORITY,
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
MSH_CMD_EXPORT(benchmark, run extended RT-Thread latency benchmarks);

static int benchmark_core(int argc, char **argv)
{
    uint64_t samples = RTBENCH_DEFAULT_SAMPLES;

    if (argc > 1)
    {
        samples = rtbench_parse_bounded(argv[1],
                                        RTBENCH_DEFAULT_SAMPLES,
                                        RTBENCH_MAX_SAMPLES);
    }
    return rtbench_start_job(RTBENCH_JOB_CORE_SUITE, samples);
}
MSH_CMD_EXPORT(benchmark_core, run RT-Thread latency benchmarks without network peer);

int rtbench_stability(int argc, char **argv)
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
