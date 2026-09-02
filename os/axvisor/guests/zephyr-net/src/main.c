/*
 * Minimal static-IP Zephyr guest for the Axvisor virtio-net experiment.
 *
 * The network stack answers IPv4 ARP and ICMP echo requests. No POSIX
 * sockets or shared-memory channel is used by this guest.
 */

#include <zephyr/kernel.h>
#include <zephyr/irq.h>
#include <zephyr/devicetree.h>
#include <zephyr/device.h>
#include <zephyr/dt-bindings/interrupt-controller/arm-gic.h>
#include <zephyr/drivers/virtio.h>
#include <zephyr/drivers/interrupt_controller/gic.h>
#include <zephyr/logging/log.h>
#include <zephyr/net/net_if.h>
#include <zephyr/net/net_ip.h>
#include <zephyr/sys/byteorder.h>
#include <zephyr/sys/sys_io.h>

#include <errno.h>
#include <stdlib.h>
#include <stdint.h>

LOG_MODULE_REGISTER(axvisor_zephyr_net, LOG_LEVEL_INF);

/* Exported by Zephyr's common virtio layer; the MMIO wrapper normally calls it. */
extern void virtio_isr(const struct device *dev, uint8_t isr_status,
	uint16_t virtqueue_count);

#define VIRTIO_MMIO_STATUS 0x70
#define VIRTIO_MMIO_MAGIC 0x00
#define VIRTIO_MMIO_VERSION 0x04
#define VIRTIO_MMIO_DEVICE_ID 0x08
#define VIRTIO_MMIO_VENDOR_ID 0x0c
#define VIRTIO_MMIO_QUEUE_SIZE_MAX 0x34
#define VIRTIO_MMIO_QUEUE_SIZE 0x38
#define VIRTIO_MMIO_QUEUE_READY 0x44
#define VIRTIO_MMIO_INTERRUPT_STATUS 0x60
#define VIRTIO_MMIO_INTERRUPT_ACK 0x64
#define RTBENCH_PERIOD_US 1000U
#define RTBENCH_SAMPLES 10000U
#define RTBENCH_HIST_MAX_US 5000U

static struct k_timer rtbench_timer;
K_SEM_DEFINE(rtbench_done, 0, 1);
static volatile uint32_t rtbench_samples;
static volatile uint32_t rtbench_first_cycle;
static volatile uint32_t rtbench_last_cycle;
static int64_t rtbench_first_tick;
static uint32_t rtbench_period_cycles;
static uint32_t rtbench_period_ticks;
static uint32_t rtbench_clock_hz;
static uint32_t rtbench_late_hist[RTBENCH_HIST_MAX_US + 1U];
/* Keep the raw timing boundary; integer microseconds hide sub-us jitter. */
static int64_t rtbench_phase_error_cycles[RTBENCH_SAMPLES - 1U];
static int64_t rtbench_interval_error_cycles[RTBENCH_SAMPLES - 1U];
static int32_t rtbench_tick_gap[RTBENCH_SAMPLES - 1U];
static uint64_t rtbench_sorted_late_ns[RTBENCH_SAMPLES - 1U];
static uint32_t rtbench_callback_max_cycles;

static int64_t rtbench_cycles_to_ns(int64_t cycles);

#if defined(AXVISOR_RT_IRQ_TRACE)
#define RTBENCH_IRQ_TRACE_CAPACITY 256U

struct rtbench_irq_sample {
	uint64_t entry_counter;
	uint64_t compare_value;
	uint32_t control;
};

static volatile struct rtbench_irq_sample rtbench_irq_samples[RTBENCH_IRQ_TRACE_CAPACITY];
static volatile uint32_t rtbench_irq_sample_count;
static volatile uint32_t rtbench_irq_sample_overflow;
static volatile uint64_t rtbench_last_irq_entry;
static volatile uint64_t rtbench_last_irq_compare;
static volatile uint32_t rtbench_last_irq_control;
static uint32_t rtbench_irq_callback_count;
static uint64_t rtbench_irq_entry_to_callback_max;
static uint64_t rtbench_irq_overdue_at_entry_max;
static uint32_t rtbench_irq_overdue_max_sample;
static uint64_t rtbench_irq_overdue_max_compare;
static uint64_t rtbench_irq_overdue_max_entry;
static uint64_t rtbench_irq_trace_start_counter;

extern unsigned int __real_arm_gic_get_active(void);

static inline uint64_t rtbench_read_cntvct(void)
{
	uint64_t value;

	__asm__ volatile("mrs %0, CNTVCT_EL0" : "=r"(value));
	return value;
}

static inline uint64_t rtbench_read_cntv_cval(void)
{
	uint64_t value;

	__asm__ volatile("mrs %0, CNTV_CVAL_EL0" : "=r"(value));
	return value;
}

static inline uint32_t rtbench_read_cntv_ctl(void)
{
	uint64_t value;

	__asm__ volatile("mrs %0, CNTV_CTL_EL0" : "=r"(value));
	return (uint32_t)value;
}

unsigned int __wrap_arm_gic_get_active(void)
{
	const unsigned int irq = __real_arm_gic_get_active();

	if (irq == 27U) {
		const uint64_t entry_counter = rtbench_read_cntvct();
		const uint64_t compare_value = rtbench_read_cntv_cval();
		const uint32_t control = rtbench_read_cntv_ctl();
		const uint32_t slot = rtbench_irq_sample_count % RTBENCH_IRQ_TRACE_CAPACITY;

		rtbench_irq_samples[slot].entry_counter = entry_counter;
		rtbench_irq_samples[slot].compare_value = compare_value;
		rtbench_irq_samples[slot].control = control;
		if (rtbench_irq_sample_count >= RTBENCH_IRQ_TRACE_CAPACITY) {
			rtbench_irq_sample_overflow++;
		}
		rtbench_irq_sample_count++;
		rtbench_last_irq_entry = entry_counter;
		rtbench_last_irq_compare = compare_value;
		rtbench_last_irq_control = control;
	}

	return irq;
}

static void rtbench_irq_entry_to_callback(void)
{
	const uint64_t callback_counter = rtbench_read_cntvct();

	if (rtbench_last_irq_entry == 0U) {
		return;
	}

	const uint64_t entry_to_callback = callback_counter - rtbench_last_irq_entry;
	if (entry_to_callback > rtbench_irq_entry_to_callback_max) {
		rtbench_irq_entry_to_callback_max = entry_to_callback;
	}
	if (rtbench_last_irq_entry > rtbench_last_irq_compare) {
		const uint64_t overdue = rtbench_last_irq_entry - rtbench_last_irq_compare;
		if (overdue > rtbench_irq_overdue_at_entry_max) {
			rtbench_irq_overdue_at_entry_max = overdue;
			rtbench_irq_overdue_max_sample = rtbench_samples;
			rtbench_irq_overdue_max_compare = rtbench_last_irq_compare;
			rtbench_irq_overdue_max_entry = rtbench_last_irq_entry;
		}
	}
	rtbench_irq_callback_count++;
}

static void rtbench_irq_trace_reset(void)
{
	rtbench_irq_sample_count = 0;
	rtbench_irq_sample_overflow = 0;
	rtbench_last_irq_entry = 0;
	rtbench_last_irq_compare = 0;
	rtbench_last_irq_control = 0;
	rtbench_irq_callback_count = 0;
	rtbench_irq_entry_to_callback_max = 0;
	rtbench_irq_overdue_at_entry_max = 0;
	rtbench_irq_overdue_max_sample = 0;
	rtbench_irq_overdue_max_compare = 0;
	rtbench_irq_overdue_max_entry = 0;
	rtbench_irq_trace_start_counter = rtbench_read_cntvct();
}

static void rtbench_irq_trace_report(void)
{
	const uint64_t report_counter = rtbench_read_cntvct();

	printk("RTBENCH irq_trace entries=%u callbacks=%u overflow=%u "
		"entry_to_callback_max_ns=%llu overdue_at_entry_max_ns=%llu "
		"overdue_max_sample=%u overdue_max_compare=%llu overdue_max_entry=%llu "
		"trace_start_counter=%llu report_counter=%llu "
		"last_ctl=0x%02x last_cval=%llu\n",
		rtbench_irq_sample_count, rtbench_irq_callback_count,
		rtbench_irq_sample_overflow,
		(unsigned long long)rtbench_cycles_to_ns(
			(int64_t)rtbench_irq_entry_to_callback_max),
		(unsigned long long)rtbench_cycles_to_ns(
			(int64_t)rtbench_irq_overdue_at_entry_max),
		rtbench_irq_overdue_max_sample,
		(unsigned long long)rtbench_irq_overdue_max_compare,
		(unsigned long long)rtbench_irq_overdue_max_entry,
		(unsigned long long)rtbench_irq_trace_start_counter,
		(unsigned long long)report_counter,
		rtbench_last_irq_control,
		(unsigned long long)rtbench_last_irq_compare);
}

static uint64_t rtbench_irq_trace_start(void)
{
	return rtbench_irq_trace_start_counter;
}
#else
static void rtbench_irq_trace_reset(void) {}
static void rtbench_irq_entry_to_callback(void) {}
static void rtbench_irq_trace_report(void) {}
static uint64_t rtbench_irq_trace_start(void) { return 0; }
#endif

static int32_t rtbench_cycles_to_us(int32_t cycles)
{
	return (int32_t)(((int64_t)cycles * 1000000LL) / rtbench_clock_hz);
}

static int64_t rtbench_cycles_to_ns(int64_t cycles)
{
	return (cycles * 1000000000LL) / rtbench_clock_hz;
}

static int rtbench_compare_u64(const void *left, const void *right)
{
	const uint64_t lhs = *(const uint64_t *)left;
	const uint64_t rhs = *(const uint64_t *)right;

	return (lhs > rhs) - (lhs < rhs);
}

static void rtbench_expiry(struct k_timer *timer)
{
	uint32_t now = k_cycle_get_32();
	int64_t now_ticks = k_uptime_ticks();
	uint32_t index;

	rtbench_irq_entry_to_callback();

	if (rtbench_samples >= RTBENCH_SAMPLES) {
		k_timer_stop(timer);
		return;
	}
	index = rtbench_samples++;
	if (index == 0U) {
		rtbench_first_cycle = now;
		rtbench_last_cycle = now;
		rtbench_first_tick = now_ticks;
		return;
	}

	int64_t phase_error_cycles = (int64_t)(int32_t)(now -
		(rtbench_first_cycle + index * rtbench_period_cycles));
	int64_t interval_error_cycles = (int64_t)(int32_t)(now -
		rtbench_last_cycle) - rtbench_period_cycles;
	int32_t tick_gap = (int32_t)(now_ticks -
		(rtbench_first_tick + index * rtbench_period_ticks));
	rtbench_phase_error_cycles[index - 1U] = phase_error_cycles;
	rtbench_interval_error_cycles[index - 1U] = interval_error_cycles;
	rtbench_tick_gap[index - 1U] = tick_gap;
	rtbench_last_cycle = now;
	uint32_t callback_duration_cycles = k_cycle_get_32() - now;
	if (callback_duration_cycles > rtbench_callback_max_cycles) {
		rtbench_callback_max_cycles = callback_duration_cycles;
	}
	if (rtbench_samples >= RTBENCH_SAMPLES) {
		k_timer_stop(timer);
		k_sem_give(&rtbench_done);
		printk("RTBENCH network_callback_complete samples=%u\n", rtbench_samples - 1U);
	}
}

static uint32_t rtbench_percentile(const uint32_t *hist, uint32_t percentile_x10,
	uint32_t measured)
{
	uint32_t target = ((measured - 1U) * percentile_x10) / 1000U + 1U;
	uint32_t cumulative = 0;

	for (uint32_t bucket = 0; bucket <= RTBENCH_HIST_MAX_US; bucket++) {
		cumulative += hist[bucket];
		if (cumulative >= target) {
			return bucket;
		}
	}
	return RTBENCH_HIST_MAX_US;
}

static uint64_t rtbench_precise_percentile(uint32_t percentile_x10, uint32_t measured)
{
	uint32_t target = ((measured - 1U) * percentile_x10) / 1000U + 1U;

	return rtbench_sorted_late_ns[target - 1U];
}

static uint64_t rtbench_precise_percentile_bp(uint32_t percentile_bp, uint32_t measured)
{
	uint32_t target = ((measured - 1U) * percentile_bp) / 10000U + 1U;

	return rtbench_sorted_late_ns[target - 1U];
}

static void rtbench_report(void)
{
	uint32_t measured = rtbench_samples - 1U;
	int32_t max_late_us = INT32_MIN;
	int32_t min_late_us = INT32_MAX;
	int64_t sum_late_us = 0;
	uint32_t miss_100us = 0;
	uint32_t miss_500us = 0;
	uint32_t miss_1ms = 0;
	int64_t phase_min_cycles = INT64_MAX;
	int64_t phase_max_cycles = INT64_MIN;
	int64_t phase_sum_cycles = 0;
	int64_t interval_min_cycles = INT64_MAX;
	int64_t interval_max_abs_cycles = 0;
	int64_t interval_sum_abs_cycles = 0;
	int32_t tick_gap_min = INT32_MAX;
	int32_t tick_gap_max = INT32_MIN;

	for (uint32_t i = 0; i <= RTBENCH_HIST_MAX_US; i++) {
		rtbench_late_hist[i] = 0;
	}

	for (uint32_t i = 0; i < measured; i++) {
		const int64_t phase_cycles = rtbench_phase_error_cycles[i];
		const int64_t interval_cycles = rtbench_interval_error_cycles[i];
		const int32_t tick_gap = rtbench_tick_gap[i];
		const int64_t late_cycles = phase_cycles > 0 ? phase_cycles : 0;
		const int32_t late_us = rtbench_cycles_to_us((int32_t)late_cycles);
		const int64_t abs_interval_cycles = interval_cycles < 0 ?
			-interval_cycles : interval_cycles;
		uint32_t bucket = (uint32_t)late_us;

		if (late_us > max_late_us) {
			max_late_us = late_us;
		}
		if (late_us < min_late_us) {
			min_late_us = late_us;
		}
		sum_late_us += late_us;
		if (bucket > RTBENCH_HIST_MAX_US) {
			bucket = RTBENCH_HIST_MAX_US;
		}
		rtbench_late_hist[bucket]++;
		if (late_cycles * 1000000LL > (int64_t)rtbench_clock_hz * 100LL) {
			miss_100us++;
		}
		if (late_cycles * 1000000LL > (int64_t)rtbench_clock_hz * 500LL) {
			miss_500us++;
		}
		if (late_cycles * 1000000LL > (int64_t)rtbench_clock_hz * 1000LL) {
			miss_1ms++;
		}

		if (phase_cycles < phase_min_cycles) {
			phase_min_cycles = phase_cycles;
		}
		if (phase_cycles > phase_max_cycles) {
			phase_max_cycles = phase_cycles;
		}
		if (interval_cycles < interval_min_cycles) {
			interval_min_cycles = interval_cycles;
		}
		if (abs_interval_cycles > interval_max_abs_cycles) {
			interval_max_abs_cycles = abs_interval_cycles;
		}
		if (tick_gap < tick_gap_min) {
			tick_gap_min = tick_gap;
		}
		if (tick_gap > tick_gap_max) {
			tick_gap_max = tick_gap;
		}
		phase_sum_cycles += phase_cycles;
		interval_sum_abs_cycles += abs_interval_cycles;
		rtbench_sorted_late_ns[i] = (uint64_t)rtbench_cycles_to_ns(late_cycles);
	}
	qsort(rtbench_sorted_late_ns, measured, sizeof(rtbench_sorted_late_ns[0]),
		rtbench_compare_u64);

	printk("RTBENCH network samples=%u expected=%u period_us=%u clock_hz=%u "
		"min_late_us=%d avg_late_us=%d p50=%u p95=%u p99=%u p99_9=%u max_late_us=%d "
		"miss_gt100us=%u miss_gt500us=%u miss_gt1ms=%u "
		"phase_min_ns=%lld phase_avg_ns=%lld phase_p50_ns=%llu "
		"phase_p95_ns=%llu phase_p99_ns=%llu phase_p99_9_ns=%llu "
		"phase_p99_99_ns=%llu phase_max_ns=%lld "
		"interval_min_ns=%lld interval_avg_abs_ns=%lld interval_max_abs_ns=%lld "
		"tick_gap_min=%d tick_gap_max=%d callback_duration_max_ns=%lld\n",
		rtbench_samples - 1U, RTBENCH_SAMPLES - 1U, RTBENCH_PERIOD_US,
		rtbench_clock_hz, min_late_us,
		(int32_t)(sum_late_us / measured),
		rtbench_percentile(rtbench_late_hist, 500, measured),
		rtbench_percentile(rtbench_late_hist, 950, measured),
		rtbench_percentile(rtbench_late_hist, 990, measured),
		rtbench_percentile(rtbench_late_hist, 999, measured),
		max_late_us, miss_100us, miss_500us,
		miss_1ms, (long long)rtbench_cycles_to_ns(phase_min_cycles),
		(long long)rtbench_cycles_to_ns(phase_sum_cycles / measured),
		(unsigned long long)rtbench_precise_percentile(500, measured),
		(unsigned long long)rtbench_precise_percentile(950, measured),
		(unsigned long long)rtbench_precise_percentile(990, measured),
		(unsigned long long)rtbench_precise_percentile(999, measured),
		(unsigned long long)rtbench_precise_percentile_bp(9999, measured),
		(long long)rtbench_cycles_to_ns(phase_max_cycles),
		(long long)rtbench_cycles_to_ns(interval_min_cycles),
		(long long)rtbench_cycles_to_ns(interval_sum_abs_cycles / measured),
		(long long)rtbench_cycles_to_ns(interval_max_abs_cycles), tick_gap_min,
		tick_gap_max, (long long)rtbench_cycles_to_ns(rtbench_callback_max_cycles));
}

static void start_rtbench(void)
{
	rtbench_clock_hz = sys_clock_hw_cycles_per_sec();
	rtbench_period_cycles = (uint32_t)(((uint64_t)rtbench_clock_hz * RTBENCH_PERIOD_US) /
		1000000U);
	rtbench_period_ticks = (uint32_t)(((uint64_t)CONFIG_SYS_CLOCK_TICKS_PER_SEC *
		RTBENCH_PERIOD_US) / 1000000U);
	k_sem_reset(&rtbench_done);
	rtbench_callback_max_cycles = 0;
	rtbench_samples = 0;
	rtbench_irq_trace_reset();
	k_timer_init(&rtbench_timer, rtbench_expiry, NULL);
	k_timer_start(&rtbench_timer, K_USEC(RTBENCH_PERIOD_US), K_USEC(RTBENCH_PERIOD_US));
	printk("RTBENCH network_start period_cycles=%u trace_start_counter=%llu\n",
		rtbench_period_cycles, (unsigned long long)rtbench_irq_trace_start());
}

static void configure_virtio_interrupt(void)
{
	const unsigned int irq = DT_IRQN(DT_NODELABEL(virtio_mmio2));

	LOG_INF("virtio IRQ INTID=%u", irq);

	/* The Zephyr virtio-mmio driver hard-codes IRQ_CONNECT flags to zero. */
	irq_disable(irq);
	arm_gic_irq_set_priority(irq, IRQ_DEFAULT_PRIORITY, IRQ_TYPE_EDGE);
	irq_enable(irq);
}

static int configure_network(void)
{
	struct net_if *iface = net_if_get_default();
	struct net_in_addr address;
	struct net_in_addr netmask;
	int ret;

	if (iface == NULL) {
		return -ENODEV;
	}

	ret = net_addr_pton(NET_AF_INET, "192.168.77.13", &address);
	if (ret != 0) {
		return ret;
	}

	ret = net_addr_pton(NET_AF_INET, "255.255.255.0", &netmask);
	if (ret != 0) {
		return ret;
	}

	if (net_if_ipv4_addr_add(iface, &address, NET_ADDR_MANUAL, 0) == NULL) {
		return -ENOMEM;
	}

	if (!net_if_ipv4_set_netmask_by_addr(iface, &address, &netmask)) {
		return -EINVAL;
	}

	ret = net_if_up(iface);
	if (ret < 0 && ret != -EALREADY) {
		return ret;
	}

	return 0;
}

static void log_network_health(struct net_if *iface)
{
	const struct device *vdev = DEVICE_DT_GET(DT_NODELABEL(virtio_mmio2));
	const struct device *netdev = DEVICE_DT_GET(DT_NODELABEL(virtio_net));
	const struct net_linkaddr *link = net_if_get_link_addr(iface);
	const uintptr_t mmio_base = DT_REG_ADDR(DT_NODELABEL(virtio_mmio2));

	LOG_INF("virtio parent %s ready=%d net device %s ready=%d",
		vdev->name, device_is_ready(vdev), netdev->name, device_is_ready(netdev));
	LOG_INF("interface device %s up=%d oper=%d mac=%02x:%02x:%02x:%02x:%02x:%02x",
		net_if_get_device(iface)->name, net_if_is_up(iface), net_if_oper_state(iface),
		link->addr[0], link->addr[1], link->addr[2], link->addr[3], link->addr[4],
		link->addr[5]);
	LOG_INF("virtio status=0x%02x queue_size=%u queue_ready=%u",
		sys_read32(mmio_base + VIRTIO_MMIO_STATUS),
		sys_read32(mmio_base + VIRTIO_MMIO_QUEUE_SIZE),
		sys_read32(mmio_base + VIRTIO_MMIO_QUEUE_READY));
	LOG_INF("virtio regs magic=0x%08x version=%u device=%u vendor=0x%08x queue_max=%u",
		sys_read32(mmio_base + VIRTIO_MMIO_MAGIC),
		sys_read32(mmio_base + VIRTIO_MMIO_VERSION),
		sys_read32(mmio_base + VIRTIO_MMIO_DEVICE_ID),
		sys_read32(mmio_base + VIRTIO_MMIO_VENDOR_ID),
		sys_read32(mmio_base + VIRTIO_MMIO_QUEUE_SIZE_MAX));
}

#if !defined(AXVISOR_DISABLE_VIRTIO_IRQ_POLL)
static void poll_virtio_interrupt(const struct device *vdev)
{
	const uintptr_t mmio_base = DT_REG_ADDR(DT_NODELABEL(virtio_mmio2));
	const uint32_t status = sys_read32(mmio_base + VIRTIO_MMIO_INTERRUPT_STATUS);

	if (status == 0U) {
		return;
	}

	/* Keep networking alive while passthrough SPI delivery is unavailable. */
	sys_write32(status, mmio_base + VIRTIO_MMIO_INTERRUPT_ACK);
	virtio_isr(vdev, status, 2);
}
#endif

int main(void)
{
	#if !defined(AXVISOR_DISABLE_VIRTIO_IRQ_POLL)
	const struct device *vdev = DEVICE_DT_GET(DT_NODELABEL(virtio_mmio2));
	#endif

	configure_virtio_interrupt();

	int ret = configure_network();

	if (ret != 0) {
		LOG_ERR("Unable to configure network: %d", ret);
		return ret;
	}

	log_network_health(net_if_get_default());
	LOG_INF("Axvisor Zephyr network guest ready: 192.168.77.13/24");
	start_rtbench();

	#if !defined(AXVISOR_DISABLE_VIRTIO_IRQ_POLL)
	for (;;) {
		poll_virtio_interrupt(vdev);
		if (k_sem_take(&rtbench_done, K_NO_WAIT) == 0) {
			break;
		}
		k_sleep(K_MSEC(10));
	}
	#else
	k_sem_take(&rtbench_done, K_FOREVER);
	#endif
	rtbench_report();
	rtbench_irq_trace_report();

	for (;;) {
		k_sleep(K_FOREVER);
	}

	return 0;
}
