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
APPLICATION_SCONSCRIPT="$RTDIR/bsp/qemu-virt64-aarch64/applications/SConscript"
TASK3_SOURCE="$ROOT/os/axvisor/guests/task3"
TASK3_APPDIR="$RTDIR/bsp/qemu-virt64-aarch64/applications/task3"

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
extract_function() {
    local function_name="$1"
    local file="$2"

    awk -v function_name="$function_name" '
        !in_function && $0 ~ "^[[:space:]]*static[[:space:]].*[[:space:]]" function_name "[[:space:]]*\\(" {
            in_function = 1
        }
        in_function {
            print
            line = $0
            opens = gsub(/\{/, "{", line)
            line = $0
            closes = gsub(/\}/, "}", line)
            depth += opens - closes
            if (opens > 0)
                saw_body = 1
            if (saw_body && depth == 0)
                exit
        }
    ' "$file"
}
require_function_pattern() {
    local description="$1"
    local function_name="$2"
    local pattern="$3"
    local file="$4"
    local body

    body="$(extract_function "$function_name" "$file")"
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

    body="$(extract_function "$function_name" "$file")"
    if [[ -z "$body" ]] || grep -Eq -- "$pattern" <<<"$body"; then
        echo "FAIL: $description" >&2
        failures=$((failures + 1))
    fi
}
require_function_count() {
    local description="$1"
    local function_name="$2"
    local pattern="$3"
    local expected="$4"
    local file="$5"
    local body
    local actual

    body="$(extract_function "$function_name" "$file")"
    actual="$( { grep -Eo -- "$pattern" <<<"$body" || true; } | wc -l)"
    if [[ -z "$body" || "$actual" -ne "$expected" ]]; then
        echo "FAIL: $description (expected $expected, found $actual)" >&2
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
require_function_pattern \
    "AArch64 tick ISR programs CNTV_CVAL rather than a relative TVAL" \
    'rt_hw_timer_isr' \
    'rt_hw_sysreg_write\(CNTV_CVAL_EL0, timer_deadline\);' \
    "$GTIMER"
require_pattern \
    "AArch64 tick timer computes elapsed periods arithmetically" \
    '\(rt_uint64_t\)lateness / timer_step' \
    "$GTIMER"
require_pattern \
    "AArch64 tick timer handles generic-counter wrap with a signed delta" \
    'lateness = \(rt_int64_t\)\(now - timer_deadline\);' \
    "$GTIMER"
require_pattern \
    "AArch64 tick timer bounds one kernel tick jump below half the tick range" \
    'GTIMER_MAX_ELAPSED_TICKS.*RT_TICK_MAX / 2 - 1' \
    "$GTIMER"
require_pattern \
    "AArch64 tick timer detects an out-of-range elapsed tick count" \
    'elapsed_ticks >= GTIMER_MAX_ELAPSED_TICKS' \
    "$GTIMER"
require_pattern \
    "AArch64 tick timer saturates elapsed ticks before the kernel update" \
    'elapsed_ticks = GTIMER_MAX_ELAPSED_TICKS;' \
    "$GTIMER"
require_order \
    "AArch64 tick saturation precedes the bulk kernel tick update" \
    'elapsed_ticks = GTIMER_MAX_ELAPSED_TICKS;' \
    'rt_tick_increase_tick\(\(rt_tick_t\)elapsed_ticks\);' \
    "$GTIMER"
require_pattern \
    "AArch64 tick timer resynchronizes after an out-of-range pause" \
    'timer_deadline = now \+ timer_step;' \
    "$GTIMER"
require_pattern \
    "AArch64 tick timer advances the deadline in one bounded operation" \
    'timer_deadline \+= elapsed_ticks \* timer_step;' \
    "$GTIMER"
require_function_count \
    "AArch64 tick ISR accounts elapsed periods in exactly one kernel call" \
    'rt_hw_timer_isr' \
    'rt_tick_increase_tick\(\(rt_tick_t\)elapsed_ticks\);' \
    1 \
    "$GTIMER"
reject_function_pattern \
    "AArch64 tick ISR contains no loop proportional to delayed work" \
    'rt_hw_timer_isr' \
    '(^|[[:space:]])(while|for)[[:space:]]*\(' \
    "$GTIMER"
reject_pattern \
    "AArch64 tick timer does not use a non-wrap-safe raw counter comparison" \
    'if \(now >= timer_deadline\)' \
    "$GTIMER"
require_pattern \
    "AArch64 tick timer establishes a nonzero timer-step invariant" \
    'RT_ASSERT\(timer_step > 0\);' \
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
        "stability benchmark exposes a stable ELF entry symbol" \
        '^int[[:space:]]+rtbench_stability\(int argc, char \*\*argv\)' \
        "$BENCHMARK"
    reject_pattern \
        "stability benchmark entry is not private to one translation unit" \
        '^static[[:space:]]+int[[:space:]]+rtbench_stability\(' \
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

require_pattern \
    "RT-Thread applications include the Task 3 SCons group" \
    "group[[:space:]]*\+=[[:space:]]*SConscript\('task3/SConscript'\)" \
    "$APPLICATION_SCONSCRIPT"
for task3_file in \
    task3_server.c SConscript controller.c controller.h task3_protocol.c \
    task3_protocol.h session.c session.h rt_ipc.h; do
    if [[ ! -f "$TASK3_APPDIR/$task3_file" ]]; then
        echo "FAIL: installed Task 3 file is missing: $task3_file" >&2
        failures=$((failures + 1))
    fi
done
if [[ -e "$TASK3_APPDIR/rt_ipc.c" ]]; then
    echo "FAIL: Task 3 must reuse the RT-IPC server's protocol implementation" >&2
    failures=$((failures + 1))
fi
for mapping in \
    "src/rtthread/task3_server.c:task3_server.c" \
    "src/rtthread/SConscript:SConscript" \
    "src/common/controller.c:controller.c" \
    "src/common/controller.h:controller.h" \
    "src/common/task3_protocol.c:task3_protocol.c" \
    "src/common/task3_protocol.h:task3_protocol.h" \
    "src/common/session.c:session.c" \
    "src/common/session.h:session.h"; do
    source_file="${mapping%%:*}"
    installed_file="${mapping#*:}"
    if [[ -f "$TASK3_APPDIR/$installed_file" ]] && \
       ! cmp -s "$TASK3_SOURCE/$source_file" "$TASK3_APPDIR/$installed_file"; then
        echo "FAIL: installed Task 3 file differs from canonical source: $installed_file" >&2
        failures=$((failures + 1))
    fi
done
if [[ -f "$TASK3_APPDIR/rt_ipc.h" ]] && \
   ! cmp -s "$ROOT/os/axvisor/guests/rt-ipc/common/rt_ipc.h" \
       "$TASK3_APPDIR/rt_ipc.h"; then
    echo "FAIL: installed Task 3 RT-IPC header differs from v2 common header" >&2
    failures=$((failures + 1))
fi
if [[ -f "$TASK3_APPDIR/SConscript" ]]; then
    require_pattern \
        "Task 3 SCons supports one dropped status packet" \
        'TASK3_FAULT_DROP_STATUS_ONCE' \
        "$TASK3_APPDIR/SConscript"
    require_pattern \
        "Task 3 SCons supports delayed server startup" \
        'TASK3_FAULT_DELAY_START_MS' \
        "$TASK3_APPDIR/SConscript"
fi
if [[ -f "$TASK3_APPDIR/task3_server.c" ]]; then
    require_pattern \
        "Task 3 delayed startup emits RT-Thread evidence" \
        'TASK3_FAULT_DELAYED_SERVER delay_ms=%d' \
        "$TASK3_APPDIR/task3_server.c"
    require_pattern \
        "Task 3 delayed startup stays in the server application thread" \
        'rt_thread_mdelay\(TASK3_FAULT_DELAY_START_MS\);' \
        "$TASK3_APPDIR/task3_server.c"
    require_order \
        "Task 3 delayed startup evidence precedes the application-thread delay" \
        'TASK3_FAULT_DELAYED_SERVER delay_ms=%d' \
        'rt_thread_mdelay\(TASK3_FAULT_DELAY_START_MS\);' \
        "$TASK3_APPDIR/task3_server.c"
    require_pattern \
        "Task 3 waits for the shared static address" \
        'ip_addr_cmp\(&device->ip_addr, &address\)' \
        "$TASK3_APPDIR/task3_server.c"
    reject_pattern \
        "Task 3 does not compete with Task 2 for netdev configuration" \
        'netdev_set_(ipaddr|netmask|gw)\(' \
        "$TASK3_APPDIR/task3_server.c"
fi

if (( failures != 0 )); then
    exit 1
fi

echo "PASS: RT-Thread patch and benchmark invariants"
