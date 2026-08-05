//! Low-perturbation timing markers for cross-layer RTOS latency diagnosis.

use core::sync::atomic::{AtomicU64, AtomicUsize, Ordering};

#[cfg(not(target_arch = "aarch64"))]
use crate::host::HostTime;

const CAPACITY: usize = 4096;
const REPORT_AFTER_GUEST_EXITS: usize = 10000;
const STREAMS: usize = 32;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct CounterMetadata {
    unit: &'static str,
    frequency_hz: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CounterSource {
    #[cfg(any(target_arch = "aarch64", test))]
    Architectural { frequency_hz: u64 },
    #[cfg(any(not(target_arch = "aarch64"), test))]
    MonotonicNanoseconds,
}

impl CounterSource {
    const fn metadata(self) -> CounterMetadata {
        match self {
            #[cfg(any(target_arch = "aarch64", test))]
            Self::Architectural { frequency_hz } => CounterMetadata {
                unit: "counter_ticks",
                frequency_hz,
            },
            #[cfg(any(not(target_arch = "aarch64"), test))]
            Self::MonotonicNanoseconds => CounterMetadata {
                unit: "ns",
                frequency_hz: 1_000_000_000,
            },
        }
    }
}

#[repr(u8)]
#[derive(Clone, Copy)]
enum TraceEvent {
    GuestEntry        = 1,
    GuestExit         = 2,
    #[cfg(target_arch = "aarch64")]
    ExitHandlerReturn = 3,
    #[cfg(target_arch = "aarch64")]
    DeferredFinish    = 4,
    HostTimerProgram  = 5,
}

struct TraceRecord {
    event: AtomicUsize,
    vm_id: AtomicUsize,
    vcpu_id: AtomicUsize,
    counter: AtomicU64,
    arg: AtomicU64,
}

impl TraceRecord {
    const fn new() -> Self {
        Self {
            event: AtomicUsize::new(0),
            vm_id: AtomicUsize::new(0),
            vcpu_id: AtomicUsize::new(0),
            counter: AtomicU64::new(0),
            arg: AtomicU64::new(0),
        }
    }
}

static WRITE_INDEX: AtomicUsize = AtomicUsize::new(0);
static GUEST_EXIT_COUNT: AtomicUsize = AtomicUsize::new(0);
static EXTERNAL_EXIT_COUNT: AtomicUsize = AtomicUsize::new(0);
static REPORT_EMITTED: AtomicUsize = AtomicUsize::new(0);
static LAST_ENTRY: [AtomicU64; STREAMS] = [const { AtomicU64::new(0) }; STREAMS];
static LAST_EXIT: [AtomicU64; STREAMS] = [const { AtomicU64::new(0) }; STREAMS];
#[cfg(target_arch = "aarch64")]
static LAST_HANDLER: [AtomicU64; STREAMS] = [const { AtomicU64::new(0) }; STREAMS];
static MAX_ENTRY_TO_EXIT: AtomicU64 = AtomicU64::new(0);
static MAX_EXIT_TO_HANDLER: AtomicU64 = AtomicU64::new(0);
static MAX_HANDLER_TO_FINISH: AtomicU64 = AtomicU64::new(0);
static HOST_TIMER_PROGRAM_COUNT: AtomicUsize = AtomicUsize::new(0);
static EVENTS: [TraceRecord; CAPACITY] = [const { TraceRecord::new() }; CAPACITY];

#[inline]
fn counter() -> u64 {
    #[cfg(target_arch = "aarch64")]
    {
        let value: u64;
        unsafe { core::arch::asm!("mrs {0}, CNTVCT_EL0", out(reg) value) };
        return value;
    }

    #[cfg(not(target_arch = "aarch64"))]
    {
        crate::host::default_host().monotonic_time().as_nanos() as u64
    }
}

#[inline]
fn counter_source() -> CounterSource {
    #[cfg(target_arch = "aarch64")]
    {
        let frequency_hz: u64;
        unsafe { core::arch::asm!("mrs {0}, CNTFRQ_EL0", out(reg) frequency_hz) };
        return CounterSource::Architectural { frequency_hz };
    }

    #[cfg(not(target_arch = "aarch64"))]
    {
        CounterSource::MonotonicNanoseconds
    }
}

#[inline]
fn update_max(slot: &AtomicU64, value: u64) {
    let mut current = slot.load(Ordering::Relaxed);
    while value > current {
        match slot.compare_exchange_weak(current, value, Ordering::Relaxed, Ordering::Relaxed) {
            Ok(_) => break,
            Err(observed) => current = observed,
        }
    }
}

#[inline]
fn record(event: TraceEvent, vm_id: usize, vcpu_id: usize, arg: u64) -> u64 {
    let now = counter();
    let slot = &EVENTS[WRITE_INDEX.fetch_add(1, Ordering::Relaxed) % CAPACITY];
    slot.vm_id.store(vm_id, Ordering::Relaxed);
    slot.vcpu_id.store(vcpu_id, Ordering::Relaxed);
    slot.counter.store(now, Ordering::Relaxed);
    slot.arg.store(arg, Ordering::Relaxed);
    slot.event.store(event as usize, Ordering::Release);
    now
}

#[inline]
fn stream_index(vm_id: usize, vcpu_id: usize) -> usize {
    vm_id.wrapping_mul(8).wrapping_add(vcpu_id) % STREAMS
}

pub(crate) fn guest_entry(vm_id: usize, vcpu_id: usize) {
    let now = record(TraceEvent::GuestEntry, vm_id, vcpu_id, 0);
    LAST_ENTRY[stream_index(vm_id, vcpu_id)].store(now, Ordering::Relaxed);
}

pub(crate) fn guest_exit(vm_id: usize, vcpu_id: usize) {
    let now = record(TraceEvent::GuestExit, vm_id, vcpu_id, 0);
    let stream = stream_index(vm_id, vcpu_id);
    let entry = LAST_ENTRY[stream].swap(0, Ordering::Relaxed);
    if entry != 0 {
        update_max(&MAX_ENTRY_TO_EXIT, now.wrapping_sub(entry));
    }
    LAST_EXIT[stream].store(now, Ordering::Relaxed);
    let count = GUEST_EXIT_COUNT.fetch_add(1, Ordering::Relaxed) + 1;
    maybe_report(count);
}

#[cfg(target_arch = "aarch64")]
pub(crate) fn exit_handler_return(vm_id: usize, vcpu_id: usize, vector: usize) {
    let now = record(TraceEvent::ExitHandlerReturn, vm_id, vcpu_id, vector as u64);
    let stream = stream_index(vm_id, vcpu_id);
    let exit = LAST_EXIT[stream].swap(0, Ordering::Relaxed);
    if exit != 0 {
        update_max(&MAX_EXIT_TO_HANDLER, now.wrapping_sub(exit));
    }
    LAST_HANDLER[stream].store(now, Ordering::Relaxed);
    EXTERNAL_EXIT_COUNT.fetch_add(1, Ordering::Relaxed);
}

#[cfg(target_arch = "aarch64")]
pub(crate) fn deferred_finish(vm_id: usize, vcpu_id: usize) {
    let now = record(TraceEvent::DeferredFinish, vm_id, vcpu_id, 0);
    let handler = LAST_HANDLER[stream_index(vm_id, vcpu_id)].swap(0, Ordering::Relaxed);
    if handler != 0 {
        update_max(&MAX_HANDLER_TO_FINISH, now.wrapping_sub(handler));
    }
}

pub(crate) fn host_timer_program(deadline_ns: u64) {
    record(TraceEvent::HostTimerProgram, 0, 0, deadline_ns);
    HOST_TIMER_PROGRAM_COUNT.fetch_add(1, Ordering::Relaxed);
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct TraceReportState {
    guest_exits: usize,
    external_exits: usize,
    host_timer_programs: usize,
    entry_to_exit_ticks: u64,
    exit_to_handler_ticks: u64,
    handler_to_finish_ticks: u64,
    records_written: usize,
}

fn report_state() -> TraceReportState {
    TraceReportState {
        guest_exits: GUEST_EXIT_COUNT.load(Ordering::Relaxed),
        external_exits: EXTERNAL_EXIT_COUNT.load(Ordering::Relaxed),
        host_timer_programs: HOST_TIMER_PROGRAM_COUNT.load(Ordering::Relaxed),
        entry_to_exit_ticks: MAX_ENTRY_TO_EXIT.load(Ordering::Relaxed),
        exit_to_handler_ticks: MAX_EXIT_TO_HANDLER.load(Ordering::Relaxed),
        handler_to_finish_ticks: MAX_HANDLER_TO_FINISH.load(Ordering::Relaxed),
        records_written: WRITE_INDEX.load(Ordering::Relaxed),
    }
}

fn maybe_report(guest_exits: usize) {
    if guest_exits < REPORT_AFTER_GUEST_EXITS || REPORT_EMITTED.swap(1, Ordering::AcqRel) != 0 {
        return;
    }
    let report = report_state();
    let counter = counter_source().metadata();
    info!(
        "RTTRACE summary counter_unit={} counter_frequency_hz={} guest_exits={} external_exits={} \
         host_timer_programs={} entry_to_exit_ticks={} exit_to_handler_ticks={} \
         handler_to_finish_ticks={} ring_records={}",
        counter.unit,
        counter.frequency_hz,
        report.guest_exits,
        report.external_exits,
        report.host_timer_programs,
        report.entry_to_exit_ticks,
        report.exit_to_handler_ticks,
        report.handler_to_finish_ticks,
        report.records_written.min(CAPACITY),
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn architectural_counter_reports_ticks_and_frequency() {
        let metadata = CounterSource::Architectural {
            frequency_hz: 62_500_000,
        }
        .metadata();

        assert_eq!(metadata.unit, "counter_ticks");
        assert_eq!(metadata.frequency_hz, 62_500_000);
    }

    #[test]
    fn runtime_hooks_update_trace_report_state() {
        let before = report_state();

        guest_entry(usize::MAX, usize::MAX);
        guest_exit(usize::MAX, usize::MAX);
        host_timer_program(123_456);

        let after = report_state();
        assert_eq!(after.guest_exits, before.guest_exits + 1);
        assert_eq!(after.host_timer_programs, before.host_timer_programs + 1);
        assert_eq!(after.records_written, before.records_written + 3);
    }
}
