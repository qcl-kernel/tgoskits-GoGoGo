#!/usr/bin/env bash
# Verify invariants that the RT-Thread virtio-net patch set must preserve.
# Usage: test-rtthread-patches.sh [rt-thread-source-dir]

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)"
RTDIR="${1:-$ROOT/tmp/rt-thread-5.2.2-full}"
DRIVER="$RTDIR/components/drivers/virtio/virtio_net.c"
VIRTIO_HEADER="$RTDIR/components/drivers/virtio/virtio.h"
GICV3="$RTDIR/libcpu/aarch64/common/gicv3.c"
INTERRUPT="$RTDIR/libcpu/aarch64/common/interrupt.c"
INTERRUPT_HEADER="$RTDIR/libcpu/aarch64/common/include/interrupt.h"
GICV3_HEADER="$RTDIR/libcpu/aarch64/common/include/gicv3.h"
GTIMER="$RTDIR/libcpu/aarch64/common/gtimer.c"
GTIMER_HEADER="$RTDIR/libcpu/aarch64/common/include/gtimer.h"
MM_PAGE="$RTDIR/components/mm/mm_page.c"
KSERVICE="$RTDIR/src/kservice.c"
LWIPOPTS="$RTDIR/components/net/lwip/port/lwipopts.h"
RTCONFIG="$RTDIR/bsp/qemu-virt64-aarch64/rtconfig.h"
APPLY_SCRIPT="$ROOT/os/axvisor/patches/rtthread/apply-rtthread-patches.sh"
GTIMER_PATCH="$ROOT/os/axvisor/patches/rtthread/0008-aarch64-gtimer-use-absolute-deadlines.patch"
LEGACY_NO_POLL_PATCH="$ROOT/os/axvisor/patches/rtthread/0001-virtio-net-remove-rx-polling.patch"
BENCHMARK="$ROOT/os/axvisor/guests/rt-benchmark/rtthread/rt_benchmark.c"
INSTALLED_BENCHMARK="$RTDIR/bsp/qemu-virt64-aarch64/applications/rt_benchmark.c"

if [[ ! -f "$DRIVER" ]]; then
    echo "FAIL: RT-Thread source not available: $DRIVER" >&2
    exit 1
fi

failures=0
if [[ -e "$LEGACY_NO_POLL_PATCH" ]]; then
    echo "FAIL: obsolete virtio-net polling/debug cleanup patch must be removed" >&2
    failures=$((failures + 1))
fi
if ! git apply --numstat "$GTIMER_PATCH" >/dev/null 2>&1; then
    echo "FAIL: AArch64 absolute-deadline patch is syntactically valid" >&2
    failures=$((failures + 1))
elif ! git -C "$RTDIR" apply --check "$GTIMER_PATCH" >/dev/null 2>&1 && \
    ! git -C "$RTDIR" apply --check --reverse "$GTIMER_PATCH" >/dev/null 2>&1; then
    echo "FAIL: AArch64 absolute-deadline patch matches upstream or applied RT-Thread state" >&2
    failures=$((failures + 1))
fi
require_pattern() {
    local description="$1"
    local pattern="$2"
    local file="${3:-$DRIVER}"
    if ! grep -Eq -- "$pattern" "$file"; then
        echo "FAIL: $description" >&2
        failures=$((failures + 1))
    fi
}
reject_pattern() {
    local description="$1"
    local pattern="$2"
    local file="$3"
    if grep -Eq -- "$pattern" "$file"; then
        echo "FAIL: $description" >&2
        failures=$((failures + 1))
    fi
}
require_order() {
    local description="$1"
    local first_pattern="$2"
    local second_pattern="$3"
    local file="$4"
    local first_line
    local second_line

    first_line="$(grep -nEm1 -- "$first_pattern" "$file" | cut -d: -f1 || true)"
    second_line="$(grep -nEm1 -- "$second_pattern" "$file" | cut -d: -f1 || true)"
    if [[ -z "$first_line" || -z "$second_line" || "$first_line" -ge "$second_line" ]]; then
        echo "FAIL: $description" >&2
        failures=$((failures + 1))
    fi
}
require_function_pattern() {
    local description="$1"
    local function_name="$2"
    local pattern="$3"
    local file="$4"
    local body

    body="$(sed -n "/^static .* ${function_name}(/,/^}/p" "$file")"
    if [[ -z "$body" ]] || ! grep -Eq -- "$pattern" <<<"$body"; then
        echo "FAIL: $description" >&2
        failures=$((failures + 1))
    fi
}
reject_function_pattern() {
    local description="$1"
    local function_name="$2"
    local pattern="$3"
    local file="$4"
    local body

    body="$(sed -n "/^static .* ${function_name}(/,/^}/p" "$file")"
    if [[ -z "$body" ]] || grep -Eq -- "$pattern" <<<"$body"; then
        echo "FAIL: $description" >&2
        failures=$((failures + 1))
    fi
}
require_pattern \
    "RX queue exposes each two-descriptor buffer chain exactly once" \
    'for \(i = 0; i < \(queue_rx->num / 2\); \+\+i)'
require_pattern \
    "RX avail index matches the number of buffer chains" \
    'queue_rx->avail->idx = queue_rx->num / 2;'
require_pattern \
    "completed RX chains are resubmitted using their used-ring head" \
    'virtio_submit_chain\(virtio_dev, VIRTIO_NET_QUEUE_RX, used_id\);'
require_pattern \
    "RX completion reads the exact used-ring chain head" \
    'id = used_id;'
require_pattern \
    "RX header descriptor references the matching header storage" \
    'void \*addr = &virtio_net_dev->info\[i\]\.hdr;'
require_pattern \
    "RX data descriptor references the matching receive buffer" \
    'VIRTIO_VA2PA\(virtio_net_dev->info\[i\]\.rx_buffer\)'
require_pattern \
    "RX completion copies the matching receive buffer" \
    'rt_memcpy\(p->payload, virtio_net_dev->info\[id / 2\]\.rx_buffer, len\);'
require_pattern \
    "UDP receive mailbox size is configurable per BSP" \
    '#define DEFAULT_UDP_RECVMBOX_SIZE[[:space:]]+RT_LWIP_UDP_RECVMBOX_SIZE' \
    "$LWIPOPTS"
require_pattern \
    "RT-IPC guest can queue a 16-datagram UDP burst" \
    '#define RT_LWIP_UDP_RECVMBOX_SIZE[[:space:]]+16' \
    "$RTCONFIG"
require_pattern \
    "RT-IPC guest has one netbuf for every UDP receive mailbox slot" \
    '#define MEMP_NUM_NETBUF[[:space:]]+16' \
    "$RTCONFIG"
require_pattern \
    "GICv3 set-pending uses the current CPU redistributor for SGIs and PPIs" \
    'GIC_RDISTSGI_ISPENDR0\(_gic_table\[index\]\.redist_hw_base\[cpu_id\]\) = mask;' \
    "$GICV3"
require_pattern \
    "GICv3 clear-pending uses the current CPU redistributor for SGIs and PPIs" \
    'GIC_RDISTSGI_ICPENDR0\(_gic_table\[index\]\.redist_hw_base\[cpu_id\]\) = mask;' \
    "$GICV3"
require_pattern \
    "GICv3 exposes an IRQ enable-state query" \
    'rt_uint64_t arm_gic_get_enable_irq\(rt_uint64_t index, int irq\)' \
    "$GICV3"
require_pattern \
    "GICv3 enable-state query reads the local redistributor for SGIs and PPIs" \
    'GIC_RDISTSGI_ISENABLER0\(_gic_table\[index\]\.redist_hw_base\[cpu_id\]\)' \
    "$GICV3"
require_pattern \
    "AArch64 interrupt API exposes the IRQ enable state" \
    'unsigned int rt_hw_interrupt_get_enable\(int vector\)' \
    "$INTERRUPT"
require_pattern \
    "AArch64 interrupt header declares the IRQ enable-state query" \
    'unsigned int rt_hw_interrupt_get_enable\(int vector\);' \
    "$INTERRUPT_HEADER"
require_pattern \
    "GICv3 header declares the IRQ enable-state query" \
    'rt_uint64_t arm_gic_get_enable_irq\(rt_uint64_t index, int irq\);' \
    "$GICV3_HEADER"
require_pattern \
    "AArch64 tick timer advances an absolute virtual deadline" \
    'timer_deadline \+= timer_step;' \
    "$GTIMER"
require_pattern \
    "AArch64 tick timer programs CNTV_CVAL rather than a relative TVAL" \
    'rt_hw_sysreg_write\(CNTV_CVAL_EL0, timer_deadline\);' \
    "$GTIMER"
require_pattern \
    "AArch64 tick timer compensates every elapsed period" \
    'while \(timer_deadline <= now\)' \
    "$GTIMER"
require_pattern \
    "AArch64 virtual timer disable writes CNTV_CTL" \
    'msr CNTV_CTL_EL0, xzr' \
    "$GTIMER_HEADER"
reject_pattern \
    "AArch64 virtual timer disable must not write CNTP_CTL" \
    'msr CNTP_CTL_EL0, xzr' \
    "$GTIMER_HEADER"
reject_pattern \
    "page allocator contains no ad hoc UART progress markers" \
    "0x09000000.*'[PQR]'" \
    "$MM_PAGE"
reject_pattern \
    "assert handler does not bypass the configured console" \
    'assert_uart|0x09000000' \
    "$KSERVICE"
reject_pattern \
    "virtio-net TX exhaustion path contains no temporary debug print" \
    'VNET_TX FULL' \
    "$DRIVER"
reject_pattern \
    "virtio-net uses interrupt-driven RX without a polling timer fallback" \
    'g_virtio_net_poll_timer|virtio_net_poll_timer_cb' \
    "$DRIVER"
require_pattern \
    "virtio DMA translation has the rt_kmem_v2p declaration on AArch64" \
    '^#include <mm_aspace\.h>$' \
    "$VIRTIO_HEADER"

if grep -q -- 'VIRTIO_NET_QUEUE_RX, id - 1' "$DRIVER"; then
    echo "FAIL: RX resubmission still uses wrap-unsafe id - 1" >&2
    failures=$((failures + 1))
fi

if [[ ! -f "$BENCHMARK" ]]; then
    echo "FAIL: canonical RT benchmark source is missing: $BENCHMARK" >&2
    failures=$((failures + 1))
elif ! git -C "$ROOT" ls-files --error-unmatch \
    -- 'os/axvisor/guests/rt-benchmark/rtthread/rt_benchmark.c' >/dev/null 2>&1; then
    echo "FAIL: canonical RT benchmark source is not in the git index" >&2
    failures=$((failures + 1))
else
    require_pattern \
        "benchmark emits the complete machine-readable result schema" \
        'RTBENCH .*expected=%llu collected=%llu missing=%llu p50_ns=%llu p95_ns=%llu p99_ns=%llu p99_9_ns=%llu max_ns=%llu miss_100us=%llu miss_500us=%llu miss_1ms=%llu' \
        "$BENCHMARK"
    require_pattern \
        "tick-to-nanosecond conversion uses quotient and remainder" \
        'ticks / frequency' \
        "$BENCHMARK"
    require_pattern \
        "tick-to-nanosecond conversion scales only the bounded remainder" \
        '\(ticks % frequency\) \* RTBENCH_NS_PER_SECOND' \
        "$BENCHMARK"
    reject_pattern \
        "tick-to-nanosecond conversion can overflow ticks times one billion" \
        'ticks[[:space:]]*\*[[:space:]]*RTBENCH_NS_PER_SECOND' \
        "$BENCHMARK"
    require_pattern \
        "sample sorting is limited to collected samples" \
        'qsort\(samples, collected, sizeof\(\*samples\), rtbench_compare_u64\)' \
        "$BENCHMARK"
    require_pattern \
        "sample summation is limited to collected samples" \
        'for \(i = 0; i < collected; \+\+i\)' \
        "$BENCHMARK"
    require_pattern \
        "missing samples are derived from expected minus collected" \
        'result->missing = result->expected - result->collected;' \
        "$BENCHMARK"
    require_pattern \
        "periodic benchmark fails when samples are missing" \
        'jitter_result\.missing == 0' \
        "$BENCHMARK"
    require_pattern \
        "periodic benchmark fails when a deadline exceeds one millisecond" \
        'jitter_result\.miss_1ms == 0' \
        "$BENCHMARK"
    require_pattern \
        "periodic benchmark discards one timer warm-up callback" \
        'if \(!context->warmed_up\)' \
        "$BENCHMARK"
    require_pattern \
        "periodic timer jitter runs in the hard-timer interrupt path" \
        'RT_TIMER_FLAG_PERIODIC[[:space:]]*\|[[:space:]]*RT_TIMER_FLAG_HARD_TIMER' \
        "$BENCHMARK"
    reject_pattern \
        "periodic timer jitter does not include soft-timer thread scheduling" \
        'RT_TIMER_FLAG_PERIODIC[[:space:]]*\|[[:space:]]*RT_TIMER_FLAG_SOFT_TIMER' \
        "$BENCHMARK"
    require_pattern \
        "benchmark worker has an explicit stack budget" \
        '#define RTBENCH_WORKER_STACK_SIZE[[:space:]]+32768U' \
        "$BENCHMARK"
    require_pattern \
        "benchmark commands execute measurements outside the shell thread" \
        'rt_thread_create\("rtbench",' \
        "$BENCHMARK"
    require_pattern \
        "benchmark suite is exported under the documented shell command" \
        'static int benchmark\(int argc, char \*\*argv\)' \
        "$BENCHMARK"
    require_pattern \
        "benchmark suite export uses the documented shell command" \
        'MSH_CMD_EXPORT\(benchmark,' \
        "$BENCHMARK"
    require_pattern \
        "benchmark worker rejects overlapping jobs" \
        'RTBENCH_ERROR metric=suite reason=busy' \
        "$BENCHMARK"
    require_pattern \
        "periodic warm-up establishes the interval origin" \
        'context->last_ticks = callback_start;' \
        "$BENCHMARK"
    require_order \
        "periodic state is reset before allocations can fail" \
        'memset\(&rtbench_periodic, 0, sizeof\(rtbench_periodic\)\);' \
        'jitter_samples = rt_calloc' \
        "$BENCHMARK"
    require_pattern \
        "collected samples are clamped to expected samples" \
        'if \(collected > expected\)' \
        "$BENCHMARK"
    require_pattern \
        "stability command accepts an explicit seconds argument" \
        'rtbench_stability\(int argc, char \*\*argv\)' \
        "$BENCHMARK"
    require_pattern \
        "stability checks the sample conservation invariant" \
        'collected \+ missing != expected' \
        "$BENCHMARK"
    require_function_pattern \
        "stability waits for exact samples within the bounded timeout" \
        'rtbench_run_stability' \
        'RT_FALSE' \
        "$BENCHMARK"
    reject_function_pattern \
        "stability does not stop its timer on the racing duration boundary" \
        'rtbench_run_stability' \
        'RT_TRUE' \
        "$BENCHMARK"
    require_pattern \
        "stability emits a completion marker after its complete result" \
        'RTBENCH_STABILITY_DONE' \
        "$BENCHMARK"
    require_order \
        "stability emits its completion marker after the complete result" \
        'RTBENCH_STABILITY_END status=' \
        'RTBENCH_STABILITY_DONE' \
        "$BENCHMARK"
    require_pattern \
        "IRQ benchmark reserves SGI INTID 7" \
        '#define RTBENCH_SGI_INTID[[:space:]]+7' \
        "$BENCHMARK"
    require_pattern \
        "IRQ benchmark installs a real SGI handler" \
        'rt_hw_interrupt_install\(RTBENCH_SGI_INTID,' \
        "$BENCHMARK"
    require_pattern \
        "IRQ benchmark triggers the SGI through interrupt pending state" \
        'rt_hw_interrupt_set_pending\(RTBENCH_SGI_INTID\)' \
        "$BENCHMARK"
    require_pattern \
        "IRQ benchmark clears the SGI pending state" \
        'rt_hw_interrupt_clear_pending\(RTBENCH_SGI_INTID\)' \
        "$BENCHMARK"
    require_pattern \
        "IRQ benchmark saves the complete previous SGI descriptor" \
        'old_descriptor[[:space:]]*=[[:space:]]*isr_table\[RTBENCH_SGI_INTID\];' \
        "$BENCHMARK"
    require_pattern \
        "IRQ benchmark masks the SGI before restoring its handler" \
        'rt_hw_interrupt_mask\(RTBENCH_SGI_INTID\)' \
        "$BENCHMARK"
    require_pattern \
        "IRQ benchmark restores the complete previous SGI descriptor" \
        'isr_table\[RTBENCH_SGI_INTID\][[:space:]]*=[[:space:]]*old_descriptor;' \
        "$BENCHMARK"
    require_pattern \
        "IRQ benchmark records the original enable state" \
        'was_enabled[[:space:]]*=[[:space:]]*rt_hw_interrupt_get_enable\(RTBENCH_SGI_INTID\);' \
        "$BENCHMARK"
    require_pattern \
        "IRQ benchmark restores an originally enabled SGI" \
        'if \(was_enabled\)' \
        "$BENCHMARK"
    reject_pattern \
        "IRQ benchmark does not call the unavailable AArch64 uninstall API" \
        'rt_hw_interrupt_uninstall\(' \
        "$BENCHMARK"
    require_pattern \
        "preemption waiter blocks before the low-priority wake" \
        'rt_sem_take\(&context->wake, RT_WAITING_FOREVER\)' \
        "$BENCHMARK"
    require_pattern \
        "low-priority preemption thread wakes the waiter" \
        'rt_sem_release\(&context->wake\)' \
        "$BENCHMARK"
fi

require_pattern \
    "apply script installs the canonical RT benchmark" \
    'cp .*RTBENCH.*rt_benchmark\.c.*APPDIR' \
    "$APPLY_SCRIPT"
for patch_variable in \
    RX_MAILBOX_PATCH \
    TX_USED_RECLAIM_PATCH \
    RX_USED_HEAD_PATCH \
    UDP_RECV_MBOX_PATCH \
    GICV3_PENDING_PATCH \
    GIC_ENABLE_QUERY_PATCH \
    GTIMER_DEADLINE_PATCH; do
    require_pattern \
        "apply script checks the exact state of $patch_variable" \
        "apply_patch_exactly .*\\\$$patch_variable" \
        "$APPLY_SCRIPT"
done
reject_pattern \
    "apply script does not accept marker text as proof of complete patches" \
    'elif[[:space:]]+![[:space:]]+rg' \
    "$APPLY_SCRIPT"
require_pattern \
    "apply script installs the GICv3 enable-state query" \
    '0007-gicv3-query-interrupt-enable-state\.patch' \
    "$APPLY_SCRIPT"
require_pattern \
    "apply script installs absolute AArch64 tick deadlines" \
    '0008-aarch64-gtimer-use-absolute-deadlines\.patch' \
    "$APPLY_SCRIPT"

if [[ ! -f "$INSTALLED_BENCHMARK" ]]; then
    echo "FAIL: installed RT benchmark source is missing: $INSTALLED_BENCHMARK" >&2
    failures=$((failures + 1))
elif [[ -f "$BENCHMARK" ]] && ! cmp -s "$BENCHMARK" "$INSTALLED_BENCHMARK"; then
    echo "FAIL: installed RT benchmark differs from canonical source" >&2
    failures=$((failures + 1))
fi

if (( failures != 0 )); then
    exit 1
fi

echo "PASS: RT-Thread patch and benchmark invariants"
