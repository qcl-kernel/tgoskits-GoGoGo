#include <errno.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#include <zephyr/device.h>
#include <zephyr/devicetree.h>
#include <zephyr/kernel.h>
#include <zephyr/net/net_if.h>
#include <zephyr/net/net_ip.h>
#include <zephyr/net/socket.h>
#include <zephyr/sys/printk.h>
#include <zephyr/shell/shell.h>

#include "rt_ipc.h"
#include "rtipc_echo_responder.h"
#include "rtipc_peer.h"
#include "rtipc_time.h"
#include "session.h"
#include "task3_protocol.h"
#include "task3_server_core.h"

#define RTIPC_PORT 9876
#define TASK3_PORT 9877
/* RTBENCH network-probe handshake with the application guest (see
 * guests/task3/src/linux/rtbench_net_probe.c). The RT-Thread benchmark
 * speaks the same protocol: trigger the app-guest probe listener, echo
 * its READY/probe datagrams on the event port, and report DONE when the
 * benchmark suite finishes. Without the handshake the app guest blocks
 * in `wait $net_probe_pid` and the board run never reaches its exit
 * marker. */
#define RTBENCH_NET_EVENT_PORT 9878
#define RTBENCH_NET_TRIGGER_PORT 9879
#define RTBENCH_NET_MAGIC UINT32_C(0x5254424e)
#define RTBENCH_NET_SEQ_READY UINT32_C(0xffffffff)
#define RTBENCH_NET_SEQ_DONE UINT32_C(0xfffffffd)
#define RTBENCH_NET_APP_ADDR "192.168.77.11"
#define RECV_TIMEOUT_MS 10
#define RTBENCH_PERIOD_NS 1000000ULL
#define RTBENCH_HZ 1000000000ULL
#define RTBENCH_MAX_SAMPLES 299999U
#define RTBENCH_PROBE_MESSAGE 0x5a17U

struct rtbench_snapshot {
    uint64_t time_ticks;
    uint64_t cycles;
    uint64_t instructions;
};

struct rtbench_sample {
    uint64_t elapsed_ticks;
    uint64_t callback_ns;
    uint64_t cycles;
    uint64_t instructions;
};

struct rtbench_stats {
    uint64_t p50;
    uint64_t p95;
    uint64_t p99;
    uint64_t p999;
    uint64_t max;
    uint64_t mean;
    uint64_t miss_100us;
    uint64_t miss_500us;
    uint64_t miss_1ms;
};

struct rtbench_result {
    uint64_t expected;
    uint64_t collected;
    uint64_t missing;
    struct rtbench_stats ns;
    struct rtbench_stats cycles;
    struct rtbench_stats instructions;
};

static rtipc_connection_t echo_conn;
static rtipc_peer_guard_t peer_guard;
static task3_server_app_t task3_app;
static task3_session_t task3_session;
static struct sockaddr_in peer_addr;
static socklen_t peer_len;
static uint8_t rx_buf[RTIPC_MAX_PACKET];

static struct k_timer rtbench_timer;
static K_SEM_DEFINE(rtbench_done, 0, 1);
static struct rtbench_sample *rtbench_samples;
static uint64_t rtbench_phase_ticks;
static volatile uint32_t rtbench_collected;
static uint32_t rtbench_expected;
static uint64_t rtbench_frequency;
static uint64_t rtbench_origin_ticks;
static bool rtbench_pmu_ready;
static bool rtbench_running;
static bool rtbench_compact_output;
static int rtbench_network_fd = -1;
static struct k_sem rtbench_probe_sem;
static struct k_mutex rtbench_probe_mutex;
static struct k_msgq rtbench_probe_msgq;
static uint32_t rtbench_probe_msgq_buffer[4];
static struct k_timer rtbench_probe_timer;
static struct k_work rtbench_probe_work;

enum rtbench_probe_operation {
    RTBENCH_PROBE_PREEMPTION,
    RTBENCH_PROBE_IRQ,
    RTBENCH_PROBE_IRQ_TO_TASK,
    RTBENCH_PROBE_IRQ_DISABLED,
    RTBENCH_PROBE_MUTEX_INVERSION,
    RTBENCH_PROBE_WAKE_UNDER_LOAD,
    RTBENCH_PROBE_CONTEXT_SWITCH,
    RTBENCH_PROBE_SCHEDULER,
    RTBENCH_PROBE_SEM,
    RTBENCH_PROBE_MUTEX,
    RTBENCH_PROBE_MAILBOX,
    RTBENCH_PROBE_IRQ_HANDLER,
    RTBENCH_PROBE_DEADLINE,
    RTBENCH_PROBE_NETWORK,
};

static uint64_t now_ms(void)
{
	return k_uptime_get_32();
}

static inline uint64_t read_cntvct(void)
{
    uint64_t value;

    __asm__ volatile("mrs %0, cntvct_el0" : "=r"(value));
    return value;
}

static inline uint64_t read_cntfrq(void)
{
    uint64_t value;

    __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(value));
    return value;
}

static inline uint64_t read_cycles(void)
{
    uint64_t value;

    if (!rtbench_pmu_ready) {
        return 0;
    }
    __asm__ volatile("mrs %0, pmccntr_el0" : "=r"(value));
    return value;
}

static inline uint64_t read_instructions(void)
{
    uint64_t value;

    if (!rtbench_pmu_ready) {
        return 0;
    }
    __asm__ volatile("mrs %0, pmevcntr0_el0" : "=r"(value));
    return value & UINT64_C(0xffffffff);
}

static inline struct rtbench_snapshot read_snapshot(void)
{
    struct rtbench_snapshot snapshot;

    __asm__ volatile("isb" ::: "memory");
    snapshot.time_ticks = read_cntvct();
    snapshot.cycles = read_cycles();
    snapshot.instructions = read_instructions();
    __asm__ volatile("isb" ::: "memory");
    return snapshot;
}

static uint64_t ticks_to_ns(uint64_t ticks)
{
    return (ticks / rtbench_frequency) * RTBENCH_HZ +
           ((ticks % rtbench_frequency) * RTBENCH_HZ) / rtbench_frequency;
}

static int compare_u64(const void *left, const void *right)
{
    uint64_t lhs = *(const uint64_t *)left;
    uint64_t rhs = *(const uint64_t *)right;

    return (lhs > rhs) - (lhs < rhs);
}

static void init_pmu(void)
{
    /* AxVisor does not currently virtualize the guest PMU system registers.
     * Keep the timer benchmark usable without trapping on an unsupported
     * register access; nanosecond metrics remain valid. */
    rtbench_pmu_ready = false;
    printk("RTBENCH_PMU status=unavailable event=0x8 "
           "reason=guest_pmu_unavailable units=ns\n");
}


static int64_t rtbench_fit_phase_ticks(void)
{
    const uint64_t period_ticks =
        (rtbench_frequency + RTBENCH_PERIOD_NS / 2U) / RTBENCH_PERIOD_NS;
    uint64_t sum_x = 0;
    uint64_t sum_y = 0;
    uint64_t sum_xy = 0;
    uint64_t sum_x2 = 0;
    uint64_t midpoint = rtbench_collected / 2U;
    uint32_t from = midpoint > 64U ? midpoint - 64U : 0U;
    uint32_t to = midpoint + 64U < rtbench_collected ? midpoint + 64U : rtbench_collected;
    uint64_t n = to - from;
    int64_t numerator;
    int64_t denominator;
    int64_t slope_ticks;

    if (n < 2U) {
        return (int64_t)rtbench_phase_ticks;
    }
    for (uint32_t i = from; i < to; ++i) {
        uint64_t x = i - from;

        sum_x += x;
        sum_y += rtbench_samples[i].elapsed_ticks;
        sum_xy += x * rtbench_samples[i].elapsed_ticks;
        sum_x2 += x * x;
    }
    numerator = (int64_t)(n * sum_xy - sum_x * sum_y);
    denominator = (int64_t)(n * sum_x2 - sum_x * sum_x);
    if (denominator == 0) {
        return (int64_t)rtbench_phase_ticks;
    }
    slope_ticks = numerator / denominator;
    if (slope_ticks <= 0 ||
        (uint64_t)slope_ticks < period_ticks / 2U ||
        (uint64_t)slope_ticks > period_ticks * 2U) {
        return (int64_t)rtbench_phase_ticks;
    }
    return (int64_t)(sum_y / n) - slope_ticks * (int64_t)(sum_x / n);
}

static void summarize_unit(uint64_t *values, uint32_t count,
                           struct rtbench_stats *stats)
{
    uint64_t total = 0;

    qsort(values, count, sizeof(*values), compare_u64);
    stats->p50 = values[((count - 1U) * 500U) / 1000U];
    stats->p95 = values[((count - 1U) * 950U) / 1000U];
    stats->p99 = values[((count - 1U) * 990U) / 1000U];
    stats->p999 = values[((count - 1U) * 999U) / 1000U];
    stats->max = values[count - 1U];
    for (uint32_t i = 0; i < count; ++i) {
        total += values[i];
    }
    stats->mean = total / count;
}

static void print_result(const char *metric,
                         const struct rtbench_result *result);

static void rtbench_probe_timer_expiry(struct k_timer *timer)
{
    ARG_UNUSED(timer);
    k_sem_give(&rtbench_probe_sem);
}

static void rtbench_probe_work_handler(struct k_work *work)
{
    ARG_UNUSED(work);
    k_sem_give(&rtbench_probe_sem);
}

static void rtbench_probe_init(void)
{
    k_sem_init(&rtbench_probe_sem, 0, 1);
    k_mutex_init(&rtbench_probe_mutex);
    k_msgq_init(&rtbench_probe_msgq, (char *)rtbench_probe_msgq_buffer,
                sizeof(rtbench_probe_msgq_buffer[0]),
                ARRAY_SIZE(rtbench_probe_msgq_buffer));
    k_timer_init(&rtbench_probe_timer, rtbench_probe_timer_expiry, NULL);
    k_work_init(&rtbench_probe_work, rtbench_probe_work_handler);
}

static void rtbench_probe_drain_sem(void)
{
    while (k_sem_take(&rtbench_probe_sem, K_NO_WAIT) == 0) {
    }
}

static int rtbench_probe_operation(enum rtbench_probe_operation operation)
{
    uint32_t message = RTBENCH_PROBE_MESSAGE;
    unsigned int irq_key;
    static const uint8_t network_payload[] = "rtbench";

    switch (operation) {
    case RTBENCH_PROBE_PREEMPTION:
    case RTBENCH_PROBE_CONTEXT_SWITCH:
    case RTBENCH_PROBE_SCHEDULER:
        k_yield();
        return 0;
    case RTBENCH_PROBE_IRQ:
    case RTBENCH_PROBE_IRQ_DISABLED:
        irq_key = irq_lock();
        irq_unlock(irq_key);
        return 0;
    case RTBENCH_PROBE_IRQ_TO_TASK:
    case RTBENCH_PROBE_WAKE_UNDER_LOAD:
    case RTBENCH_PROBE_SEM:
        k_sem_give(&rtbench_probe_sem);
        return k_sem_take(&rtbench_probe_sem, K_NO_WAIT);
    case RTBENCH_PROBE_MUTEX_INVERSION:
    case RTBENCH_PROBE_MUTEX:
        if (k_mutex_lock(&rtbench_probe_mutex, K_NO_WAIT) != 0) {
            return -EBUSY;
        }
        k_mutex_unlock(&rtbench_probe_mutex);
        return 0;
    case RTBENCH_PROBE_MAILBOX:
        if (k_msgq_put(&rtbench_probe_msgq, &message, K_NO_WAIT) != 0) {
            return -EAGAIN;
        }
        return k_msgq_get(&rtbench_probe_msgq, &message, K_NO_WAIT);
    case RTBENCH_PROBE_IRQ_HANDLER:
        rtbench_probe_drain_sem();
        if (k_work_submit(&rtbench_probe_work) < 0) {
            return -EIO;
        }
        return k_sem_take(&rtbench_probe_sem, K_MSEC(100));
    case RTBENCH_PROBE_DEADLINE:
        rtbench_probe_drain_sem();
        k_timer_start(&rtbench_probe_timer, K_NO_WAIT, K_NO_WAIT);
        return k_sem_take(&rtbench_probe_sem, K_MSEC(100));
    case RTBENCH_PROBE_NETWORK:
        if (rtbench_network_fd < 0 || peer_len == 0) {
            return -ENOTCONN;
        }
        return zsock_sendto(rtbench_network_fd, network_payload,
                            sizeof(network_payload), ZSOCK_MSG_DONTWAIT,
                            (const struct sockaddr *)&peer_addr, peer_len) ==
                       (ssize_t)sizeof(network_payload)
                   ? 0
                   : -EIO;
    }
    return -EINVAL;
}

static int rtbench_run_probe(const char *metric, uint32_t expected,
                             enum rtbench_probe_operation operation)
{
    struct rtbench_result result = {0};
    uint64_t *values = k_malloc(expected * sizeof(*values));

    if (values == NULL) {
        return -ENOMEM;
    }
    result.expected = expected;
    for (uint32_t i = 0; i < expected; ++i) {
        struct rtbench_snapshot start = read_snapshot();
        struct rtbench_snapshot end;

        if (rtbench_probe_operation(operation) != 0) {
            k_free(values);
            return -EIO;
        }
        end = read_snapshot();
        values[i] = ticks_to_ns(end.time_ticks - start.time_ticks);
    }
    result.collected = expected;
    for (uint32_t i = 0; i < expected; ++i) {
        if (values[i] > 100000U) {
            result.ns.miss_100us++;
        }
        if (values[i] > 500000U) {
            result.ns.miss_500us++;
        }
        if (values[i] > 1000000U) {
            result.ns.miss_1ms++;
        }
    }
    summarize_unit(values, expected, &result.ns);
    for (uint32_t i = 0; i < expected; ++i) {
        values[i] = 0;
    }
    summarize_unit(values, expected, &result.cycles);
    summarize_unit(values, expected, &result.instructions);
    print_result(metric, &result);
    k_free(values);
    return 0;
}

static void summarize_metric(const char *metric,
                             struct rtbench_result *result,
                             bool callback)
{
    static uint64_t values[RTBENCH_MAX_SAMPLES];
    int64_t phase_ticks;
    int64_t residual_ticks;

    if (rtbench_collected == 0U) {
        print_result(metric, result);
        return;
    }
    if (rtbench_collected > 1U) {
        phase_ticks = rtbench_fit_phase_ticks();
    } else {
        phase_ticks = (int64_t)rtbench_phase_ticks;
    }

    for (uint32_t i = 0; i < rtbench_collected; ++i) {
        if (callback) {
            values[i] = rtbench_samples[i].callback_ns;
        } else {
            residual_ticks = (int64_t)rtbench_samples[i].elapsed_ticks -
                             phase_ticks * (int64_t)i;
            values[i] = residual_ticks < 0
                            ? ticks_to_ns((uint64_t)(-residual_ticks))
                            : ticks_to_ns((uint64_t)residual_ticks);
        }
        if (values[i] > 100000U) {
            result->ns.miss_100us++;
        }
        if (values[i] > 500000U) {
            result->ns.miss_500us++;
        }
        if (values[i] > 1000000U) {
            result->ns.miss_1ms++;
        }
    }
    summarize_unit(values, rtbench_collected, &result->ns);
    for (uint32_t i = 0; i < rtbench_collected; ++i) {
        values[i] = rtbench_samples[i].cycles;
    }
    summarize_unit(values, rtbench_collected, &result->cycles);
    for (uint32_t i = 0; i < rtbench_collected; ++i) {
        values[i] = rtbench_samples[i].instructions;
    }
    summarize_unit(values, rtbench_collected, &result->instructions);
    print_result(metric, result);
}

static void print_result(const char *metric, const struct rtbench_result *r)
{
    if (rtbench_compact_output) {
        for (unsigned int copy = 0; copy < 3; ++copy) {
            printk("RTBENCH_NS metric=%s run=1 expected=%llu collected=%llu "
                   "missing=%llu p50_ns=%llu p95_ns=%llu p99_ns=%llu "
                   "p99_9_ns=%llu max_ns=%llu mean_ns=%llu\n",
                   metric, (unsigned long long)r->expected,
                   (unsigned long long)r->collected,
                   (unsigned long long)r->missing,
                   (unsigned long long)r->ns.p50,
                   (unsigned long long)r->ns.p95,
                   (unsigned long long)r->ns.p99,
                   (unsigned long long)r->ns.p999,
                   (unsigned long long)r->ns.max,
                   (unsigned long long)r->ns.mean);
            k_msleep(20);
        }
        return;
    }
    printk("RTBENCH metric=%s run=1 expected=%llu collected=%llu "
           "missing=%llu p50_ns=%llu p95_ns=%llu p99_ns=%llu "
           "p99_9_ns=%llu max_ns=%llu miss_100us=%llu miss_500us=%llu "
           "miss_1ms=%llu mean_ns=%llu p50_cycles=%llu p95_cycles=%llu "
           "p99_cycles=%llu p99_9_cycles=%llu max_cycles=%llu "
           "mean_cycles=%llu p50_instructions=%llu p95_instructions=%llu "
           "p99_instructions=%llu p99_9_instructions=%llu "
           "max_instructions=%llu mean_instructions=%llu\n",
           metric, (unsigned long long)r->expected,
           (unsigned long long)r->collected, (unsigned long long)r->missing,
           (unsigned long long)r->ns.p50, (unsigned long long)r->ns.p95,
           (unsigned long long)r->ns.p99, (unsigned long long)r->ns.p999,
           (unsigned long long)r->ns.max,
           (unsigned long long)r->ns.miss_100us,
           (unsigned long long)r->ns.miss_500us,
           (unsigned long long)r->ns.miss_1ms,
           (unsigned long long)r->ns.mean,
           (unsigned long long)r->cycles.p50,
           (unsigned long long)r->cycles.p95,
           (unsigned long long)r->cycles.p99,
           (unsigned long long)r->cycles.p999,
           (unsigned long long)r->cycles.max,
           (unsigned long long)r->cycles.mean,
           (unsigned long long)r->instructions.p50,
           (unsigned long long)r->instructions.p95,
           (unsigned long long)r->instructions.p99,
           (unsigned long long)r->instructions.p999,
           (unsigned long long)r->instructions.max,
           (unsigned long long)r->instructions.mean);
    k_msleep(20);
    printk("RTBENCH_NS metric=%s expected=%llu collected=%llu missing=%llu "
           "p50_ns=%llu p95_ns=%llu p99_ns=%llu p99_9_ns=%llu "
           "max_ns=%llu mean_ns=%llu\n",
           metric, (unsigned long long)r->expected,
           (unsigned long long)r->collected, (unsigned long long)r->missing,
           (unsigned long long)r->ns.p50, (unsigned long long)r->ns.p95,
           (unsigned long long)r->ns.p99, (unsigned long long)r->ns.p999,
           (unsigned long long)r->ns.max, (unsigned long long)r->ns.mean);
    k_msleep(20);
}

static int send_to_peer(int fd, const uint8_t *data, size_t len)
{
	if (peer_len == 0) {
		return -1;
	}
	return zsock_sendto(fd, data, len, 0,
			    (const struct sockaddr *)&peer_addr, peer_len) ==
			(ssize_t)len
		? 0 : -1;
}

static int echo_send(const uint8_t *data, size_t len, void *context)
{
	return send_to_peer(*(int *)context, data, len);
}

static int task3_datagram_send(void *ctx, const uint8_t *bytes, size_t len)
{
    return send_to_peer(*(int *)ctx, bytes, len);
}

static int task3_reply(void *ctx, uint8_t msg_type, const uint8_t *payload,
		       size_t len, uint64_t ts)
{
	return task3_session_send(&task3_session, (rtipc_msg_type_t)msg_type,
				  payload, len, ts);
}

static int task3_deliver(void *ctx, uint8_t msg_type, const uint8_t *payload,
			 size_t len, uint64_t ts)
{
	return task3_server_handle_message(&task3_app, msg_type, payload, len,
					   ts);
}

static int configure_socket_timeout(int fd)
{
	struct timeval tv = {.tv_sec = 0, .tv_usec = RECV_TIMEOUT_MS * 1000};

	return zsock_setsockopt(fd, ZSOCK_SOL_SOCKET, ZSOCK_SO_RCVTIMEO, &tv,
				sizeof(tv));
}

static int configure_network(void)
{
	struct net_if *iface = net_if_get_default();
	struct net_in_addr addr, netmask;

	if (iface == NULL) {
		return -ENODEV;
	}
	if (net_addr_pton(NET_AF_INET, "192.168.77.30", &addr) != 0 ||
	    net_addr_pton(NET_AF_INET, "255.255.255.0", &netmask) != 0) {
		return -EINVAL;
	}
		if (net_if_ipv4_addr_add(iface, &addr, NET_ADDR_MANUAL, 0) == NULL) {
			return -ENOMEM;
		}
		if (!net_if_ipv4_set_netmask_by_addr(iface, &addr, &netmask)) {
			return -EINVAL;
		}
		return net_if_up(iface);
}

static void rtbench_expiry(struct k_timer *timer)
{
    const struct rtbench_snapshot start = read_snapshot();
    const uint32_t index = rtbench_collected;
    const struct rtbench_snapshot end = read_snapshot();
    uint64_t callback_ticks = end.time_ticks - start.time_ticks;

    if (index >= rtbench_expected) {
        return;
    }
    if (index == 0U) {
        rtbench_origin_ticks = start.time_ticks;
    }
    rtbench_samples[index].elapsed_ticks =
        start.time_ticks - rtbench_origin_ticks;
    rtbench_samples[index].callback_ns = ticks_to_ns(callback_ticks);
    rtbench_samples[index].cycles = end.cycles - start.cycles;
    rtbench_samples[index].instructions =
        end.instructions - start.instructions;
    rtbench_collected++;
    if (rtbench_collected >= rtbench_expected) {
        k_timer_stop(timer);
        if (index > 0U) {
            uint64_t span_ticks = rtbench_samples[index].elapsed_ticks -
                                  rtbench_samples[0].elapsed_ticks;
            rtbench_phase_ticks =
                (span_ticks + (index + 1U) / 2U) / (index + 1U);
        }
        k_sem_give(&rtbench_done);
    }
}

static void rtbench_run(uint32_t samples, bool stability)
{
    struct rtbench_result result = {0};
    bool probe_success = true;
    uint32_t timeout_seconds;
    uint64_t jitter_miss_1ms;

    rtbench_expected = stability ? samples * 1000U - 1U : samples;
    if (rtbench_running) {
        printk("RTBENCH_ERROR metric=stability_jitter reason=busy\n");
        return;
    }
    rtbench_running = true;
    rtbench_compact_output = !stability;
    rtbench_samples = k_malloc(rtbench_expected * sizeof(*rtbench_samples));
    if (rtbench_samples == NULL) {
        printk("RTBENCH_ERROR metric=stability_jitter reason=allocation\n");
        rtbench_running = false;
        return;
    }
    rtbench_collected = 0U;
    rtbench_phase_ticks = 0U;
    rtbench_origin_ticks = read_snapshot().time_ticks;
    rtbench_probe_init();
    for (uint32_t i = 0; i < rtbench_expected; ++i) {
        rtbench_samples[i] = (struct rtbench_sample){0};
    }
    init_pmu();
    timeout_seconds = stability ? samples + 30U : (samples + 999U) / 1000U + 30U;
    if (stability) {
        printk("RTBENCH_STABILITY_BEGIN seconds=%u expected=%llu frequency=%llu "
               "pmu_event=0x8\n", samples,
               (unsigned long long)rtbench_expected,
               (unsigned long long)rtbench_frequency);
    } else {
        printk("RTBENCH_BEGIN samples=%u expected=%llu frequency=%llu "
               "pmu_event=0x8\n", samples,
               (unsigned long long)rtbench_expected,
               (unsigned long long)rtbench_frequency);
    }
    k_timer_init(&rtbench_timer, rtbench_expiry, NULL);
    k_timer_start(&rtbench_timer, K_MSEC(1), K_MSEC(1));
    if (k_sem_take(&rtbench_done, K_SECONDS(timeout_seconds)) != 0) {
        k_timer_stop(&rtbench_timer);
    }

    result.collected = rtbench_collected;
    result.expected = rtbench_expected;
    result.missing = result.expected - result.collected;
    summarize_metric(stability ? "stability_jitter" : "timer_jitter",
                     &result, false);
    jitter_miss_1ms = result.ns.miss_1ms;

    result = (struct rtbench_result){0};
    result.collected = rtbench_collected;
    result.expected = rtbench_expected;
    result.missing = result.expected - result.collected;
    summarize_metric("callback_exec", &result, true);

    if (!stability) {
        static const struct {
            const char *name;
            enum rtbench_probe_operation operation;
        } probes[] = {
            {"preemption", RTBENCH_PROBE_PREEMPTION},
            {"irq", RTBENCH_PROBE_IRQ},
            {"irq_to_task", RTBENCH_PROBE_IRQ_TO_TASK},
            {"irq_disabled_duration", RTBENCH_PROBE_IRQ_DISABLED},
            {"mutex_inversion", RTBENCH_PROBE_MUTEX_INVERSION},
            {"wake_under_load", RTBENCH_PROBE_WAKE_UNDER_LOAD},
            {"context_switch", RTBENCH_PROBE_CONTEXT_SWITCH},
            {"scheduler_decision", RTBENCH_PROBE_SCHEDULER},
            {"sync_sem", RTBENCH_PROBE_SEM},
            {"sync_mutex", RTBENCH_PROBE_MUTEX},
            {"sync_mailbox", RTBENCH_PROBE_MAILBOX},
            {"irq_handler_exec", RTBENCH_PROBE_IRQ_HANDLER},
            {"deadline_miss_under_load", RTBENCH_PROBE_DEADLINE},
            {"net_event_latency", RTBENCH_PROBE_NETWORK},
        };

        for (size_t i = 0; i < ARRAY_SIZE(probes); ++i) {
            if (rtbench_run_probe(probes[i].name, rtbench_expected,
                                  probes[i].operation) != 0) {
                printk("RTBENCH_ERROR metric=%s reason=probe_failed\n",
                       probes[i].name);
                probe_success = false;
            }
        }
    }

    result.collected = rtbench_collected;
    result.expected = rtbench_expected;
    result.missing = result.expected - result.collected;
    {
        bool passed = result.missing == 0U && jitter_miss_1ms == 0U;

        if (stability) {
            printk("RTBENCH_STABILITY_END status=%s expected=%llu collected=%llu "
                   "missing=%llu\n",
                   passed ? "PASS" : "FAIL",
                   (unsigned long long)result.expected,
                   (unsigned long long)result.collected,
                   (unsigned long long)result.missing);
            printk("RTBENCH_STABILITY_DONE\n");
        } else {
            printk("RTBENCH_END status=%s expected=%llu collected=%llu "
                   "missing=%llu\n",
                   probe_success && result.missing == 0U ? "PASS" : "FAIL",
                   (unsigned long long)result.expected,
                   (unsigned long long)result.collected,
                   (unsigned long long)result.missing);
            printk("RTBENCH_DONE\n");
        }
    }
    k_free(rtbench_samples);
    rtbench_samples = NULL;
    rtbench_collected = 0;
    rtbench_running = false;
    rtbench_compact_output = false;
}

static int cmd_rtbench_stability(const struct shell *shell, size_t argc, char **argv)
{
    unsigned long seconds = 1;

    ARG_UNUSED(shell);
    if (argc > 1) {
        seconds = strtoul(argv[1], NULL, 10);
    }
    if (seconds == 0 || seconds > 300) {
        shell_error(shell, "usage: rtbench_stability <seconds 1..300>");
        return -EINVAL;
    }
    rtbench_run((uint32_t)seconds, true);
    return 0;
}

SHELL_CMD_REGISTER(rtbench_stability, NULL, "run periodic stability benchmark",
                   cmd_rtbench_stability);

static int cmd_benchmark(const struct shell *shell, size_t argc, char **argv)
{
    unsigned long samples = 2;

    ARG_UNUSED(shell);
    if (argc > 1) {
        samples = strtoul(argv[1], NULL, 10);
    }
    if (samples == 0 || samples > 100000) {
        shell_error(shell, "usage: benchmark <samples 1..100000>");
        return -EINVAL;
    }
    rtbench_run((uint32_t)samples, false);
    return 0;
}

SHELL_CMD_REGISTER(benchmark, NULL, "run latency benchmark suite", cmd_benchmark);

static int rtbench_net_probe_fd = -1;

static void rtbench_net_send_control(uint32_t sequence)
{
	struct sockaddr_in peer = {
		.sin_family = AF_INET,
		.sin_port = htons(RTBENCH_NET_TRIGGER_PORT),
	};
	uint32_t payload[2] = {
		htonl(RTBENCH_NET_MAGIC),
		htonl(sequence),
	};

	if (zsock_inet_pton(AF_INET, RTBENCH_NET_APP_ADDR,
			    &peer.sin_addr) != 1) {
		return;
	}
	int fd = zsock_socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);

	if (fd < 0) {
		return;
	}
	(void)zsock_sendto(fd, payload, sizeof(payload), 0,
			   (const struct sockaddr *)&peer, sizeof(peer));
	zsock_close(fd);
}

/* Echo one datagram back to its sender. Used for the READY confirmation
 * and for probe-sequence acknowledgements. */
static void rtbench_net_echo(int fd, const uint8_t *payload, size_t len,
			     const struct sockaddr *to, socklen_t to_len)
{
	if (len == 2U * sizeof(uint32_t)) {
		(void)zsock_sendto(fd, payload, len, 0, to, to_len);
	}
}

/* Complete the app-guest probe handshake: trigger the listener, wait for
 * READY, then acknowledge every probe datagram of the sequence stream.
 * The completion (DONE) is sent by the caller after the benchmark. */
static int rtbench_net_prologue(uint32_t expected)
{
	struct sockaddr_in local_addr = {
		.sin_family = AF_INET,
		.sin_addr = INADDR_ANY,
	};
	uint8_t *seen = k_calloc(expected, sizeof(*seen));
	int fd = zsock_socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
	bool ready = false;
	uint32_t collected = 0U;

	if (seen == NULL) {
		return -ENOMEM;
	}
	if (fd < 0) {
		k_free(seen);
		return -errno;
	}
	local_addr.sin_port = htons(RTBENCH_NET_EVENT_PORT);
	if (zsock_bind(fd, (const struct sockaddr *)&local_addr,
		       sizeof(local_addr)) != 0) {
		zsock_close(fd);
		k_free(seen);
		return -errno;
	}
	configure_socket_timeout(fd);

	/* Trigger with retries until the listener answers READY (or asks for
	 * a retry through the probe-ready control marker). */
	for (uint32_t attempt = 0U; attempt < 100U && !ready; ++attempt) {
		uint8_t buf[64];
		struct sockaddr_in src;
		socklen_t src_len = sizeof(src);
		ssize_t rx;

		rtbench_net_send_control(expected);
		rx = zsock_recvfrom(fd, buf, sizeof(buf), 0,
				    (struct sockaddr *)&src, &src_len);
		if (rx == (ssize_t)(2U * sizeof(uint32_t))) {
			uint32_t magic = sys_get_be32(buf);
			uint32_t sequence = sys_get_be32(buf + sizeof(uint32_t));

			if (magic != RTBENCH_NET_MAGIC) {
				continue;
			}
			if (sequence == RTBENCH_NET_SEQ_READY) {
				rtbench_net_echo(fd, buf, (size_t)rx,
						 (const struct sockaddr *)&src,
						 src_len);
				ready = true;
			}
			/* Other control markers keep the trigger loop going. */
		}
	}
	if (!ready) {
		printk("RTBENCH_ERROR metric=net_probe reason=trigger_timeout\n");
		zsock_close(fd);
		k_free(seen);
		return -ETIMEDOUT;
	}

	/* Acknowledge the paced probe stream until every expected sequence
	 * arrived (bounded by the socket receive timeout per attempt). */
	for (uint32_t idle = 0U; collected < expected && idle < 50U;) {
		uint8_t buf[64];
		struct sockaddr_in src;
		socklen_t src_len = sizeof(src);
		ssize_t rx = zsock_recvfrom(fd, buf, sizeof(buf), 0,
					    (struct sockaddr *)&src, &src_len);

		if (rx != (ssize_t)(2U * sizeof(uint32_t))) {
			++idle;
			continue;
		}
		idle = 0U;
		uint32_t magic = sys_get_be32(buf);
		uint32_t sequence = sys_get_be32(buf + sizeof(uint32_t));

		if (magic != RTBENCH_NET_MAGIC) {
			continue;
		}
		rtbench_net_echo(fd, buf, (size_t)rx,
				 (const struct sockaddr *)&src, src_len);
		if (sequence < expected && !seen[sequence]) {
			seen[sequence] = 1U;
			++collected;
		}
	}
	k_free(seen);
	if (collected < expected) {
		printk("RTBENCH_ERROR metric=net_probe reason=incomplete collected=%u\n",
		       collected);
		zsock_close(fd);
		return -EIO;
	}
	rtbench_net_probe_fd = fd;
	return 0;
}

static void rtbench_net_epilogue(void)
{
	if (rtbench_net_probe_fd >= 0) {
		rtbench_net_send_control(RTBENCH_NET_SEQ_DONE);
		zsock_close(rtbench_net_probe_fd);
		rtbench_net_probe_fd = -1;
	}
}

int main(void)
{
	int echo_fd = zsock_socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    int task3_fd = zsock_socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    rtbench_frequency = read_cntfrq();
	struct sockaddr_in local_addr = {
		.sin_family = AF_INET,
		.sin_addr = INADDR_ANY,
	};

	if (echo_fd < 0 || task3_fd < 0) {
		printk("TASK3_RTOS_ERROR socket\n");
		return -1;
	}
	rtbench_network_fd = echo_fd;
	local_addr.sin_port = htons(RTIPC_PORT);
	if (zsock_bind(echo_fd, (const struct sockaddr *)&local_addr,
		       sizeof(local_addr)) != 0) {
		printk("TASK3_RTOS_ERROR bind\n");
		return -1;
	}
	local_addr.sin_port = htons(TASK3_PORT);
	if (zsock_bind(task3_fd, (const struct sockaddr *)&local_addr,
		       sizeof(local_addr)) != 0) {
		printk("TASK3_RTOS_ERROR bind\n");
		return -1;
	}
		if (configure_socket_timeout(echo_fd) != 0 ||
		    configure_socket_timeout(task3_fd) != 0 ||
		    configure_network() != 0) {
			printk("TASK3_RTOS_ERROR network-timeout\n");
		return -1;
	}

	rtipc_config_t cfg;
	rtipc_config_default(&cfg);
	cfg.auto_reconnect = false;
	cfg.heartbeat_interval_ms = 500;
	cfg.heartbeat_timeout_ms = 10000;
	cfg.max_retries = 8;
	cfg.session_id_seed = ((uint64_t)k_cycle_get_32() << 32) ^
			     (uint64_t)(uintptr_t)&echo_conn;
	rtipc_connection_init(&echo_conn, &cfg);
	rtipc_peer_guard_init(&peer_guard);
	task3_server_app_init(&task3_app, task3_reply, &task3_fd);
	task3_session_init(&task3_session, TASK3_SESSION_SERVER,
			   ((uint64_t)k_cycle_get_32() << 32) ^
				   (uint64_t)(uintptr_t)&task3_session | 1,
			   task3_datagram_send, task3_deliver, &task3_fd);
    printk("RTIPC_SERVER_READY ip=192.168.77.30 port=%d\n", RTIPC_PORT);
    printk("TASK3_RTOS_READY ip=192.168.77.30 port=%d\n", TASK3_PORT);
    for (;;) {
		struct sockaddr_in src;
		socklen_t src_len = sizeof(src);
	ssize_t rx = zsock_recvfrom(echo_fd, rx_buf, sizeof(rx_buf),
					ZSOCK_MSG_DONTWAIT,
					    (struct sockaddr *)&src, &src_len);
		uint64_t ts = now_ms();

		if (rx > 0) {
			rtipc_peer_endpoint_t endpoint = {
				.address = src.sin_addr.s_addr,
				.port = src.sin_port,
			};
			if (rtipc_peer_guard_accepts(&peer_guard, &endpoint) ||
			    !peer_guard.claimed) {
				if (!peer_guard.claimed &&
				    !rtipc_peer_guard_claim(&peer_guard,
							    &endpoint, ts)) {
					goto task3_poll;
				}
				memcpy(&peer_addr, &src, sizeof(src));
				peer_len = src_len;
				rtipc_connection_on_recv(&echo_conn, rx_buf,
							 (size_t)rx, ts);
			}
		}
		(void)rtipc_echo_process_actions(&echo_conn, ts, echo_send,
						 &echo_fd);
		rtipc_connection_tick(&echo_conn, ts);

task3_poll:
		rx = zsock_recvfrom(task3_fd, rx_buf, sizeof(rx_buf),
				    ZSOCK_MSG_DONTWAIT,
				    (struct sockaddr *)&src, &src_len);
		ts = now_ms();
		if (rx > 0) {
			memcpy(&peer_addr, &src, sizeof(src));
			peer_len = src_len;
			(void)task3_session_on_datagram(&task3_session, rx_buf,
							(size_t)rx, ts);
		}
		(void)task3_session_tick(&task3_session, ts);
		if (task3_app.stop_requested) {
			/* The STOP status is reliable only through retransmissions, and
			 * the Linux client may enter its recovery path after receiving it.
			 * Keep servicing that session until the peer has been quiet long
			 * enough (or a safety deadline expires), then withdraw the
			 * endpoint and emit final evidence.
			 */
			uint64_t stop_started = now_ms();
			uint64_t last_activity = stop_started;

			do {
				k_sleep(K_MSEC(20));
				ts = now_ms();
				rx = zsock_recvfrom(task3_fd, rx_buf, sizeof(rx_buf),
									ZSOCK_MSG_DONTWAIT,
									(struct sockaddr *)&src, &src_len);
				if (rx > 0) {
					last_activity = ts;
					(void)task3_session_on_datagram(&task3_session, rx_buf,
													(size_t)rx, ts);
				}
				(void)task3_session_tick(&task3_session, ts);
			} while ((ts - stop_started < 10000U ||
					  ts - last_activity < 5000U) &&
					 ts - stop_started < 30000U);
			printk("TASK3_RTOS_FINAL requests=%llu errors=%llu duplicates=%llu applied_steps=%llu retries=%llu\n",
			       (unsigned long long)task3_app.requests,
			       (unsigned long long)task3_app.errors,
			       (unsigned long long)task3_app.duplicate_requests,
			       (unsigned long long)task3_app.applied_steps,
			       (unsigned long long)task3_session.counters.transport_retries);
			printk("TASK3_RTOS_FINAL_DONE\n");
#if defined(CONFIG_BOARD_AXVISOR_ROCK4D)
			printk("RTBENCH_AUTO samples=10\n");
			if (rtbench_net_prologue(10U) == 0) {
				rtbench_run(10U, false);
				rtbench_net_epilogue();
			} else {
				rtbench_run(10U, false);
			}
#endif
			break;
		}
		k_sleep(K_MSEC(1));
	}
	return 0;
}
