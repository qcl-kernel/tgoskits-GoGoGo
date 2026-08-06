use alloc::{boxed::Box, vec::Vec};
use core::sync::atomic::{AtomicU64, Ordering};

use ax_hal::time::{NANOS_PER_SEC, TimeValue, monotonic_time, monotonic_time_nanos};
use ax_kernel_guard::{NoOp, NoPreemptIrqSave};
use ax_timer_list::{TimerEvent, TimerList};

#[cfg(feature = "smp")]
use crate::select_run_queue;
use crate::{AxTaskRef, current_run_queue};

static TIMER_TICKET_ID: AtomicU64 = AtomicU64::new(1);

/// Returns the current CPU's next deadline from one external timer source.
///
/// The broker calls the provider with local IRQs and preemption disabled, after
/// releasing all mutable axtask timer borrows. Providers must be bounded,
/// nonblocking, nonallocating, and must not acquire or depend on mutable axtask
/// timer borrows. Reprogram requests made by a provider are coalesced by the
/// outer broker call. On unwind-capable hosts, provider panics propagate after
/// the broker restores its in-progress state; recovery never programs hardware
/// during unwind, and a later reprogram request retries normally.
#[doc(hidden)]
pub type TimerDeadlineProvider = fn() -> Option<u64>;

#[derive(Clone, Copy, Default)]
struct DeadlineBrokerState {
    periodic_deadline_nanos: Option<u64>,
    external_provider: Option<TimerDeadlineProvider>,
    programmed_deadline_nanos: Option<u64>,
    callback_dispatch_depth: usize,
    programming_depth: usize,
    reprogram_pending: bool,
}

impl DeadlineBrokerState {
    const fn new() -> Self {
        Self {
            periodic_deadline_nanos: None,
            external_provider: None,
            programmed_deadline_nanos: None,
            callback_dispatch_depth: 0,
            programming_depth: 0,
            reprogram_pending: false,
        }
    }

    fn register_external_provider(&mut self, provider: TimerDeadlineProvider) {
        assert!(
            self.external_provider.is_none(),
            "timer deadline provider already registered on this CPU"
        );
        self.external_provider = Some(provider);
    }

    fn set_periodic_deadline_nanos(&mut self, deadline_nanos: Option<u64>) {
        self.periodic_deadline_nanos = deadline_nanos;
    }

    fn request_reprogram(&mut self) -> bool {
        if self.callback_dispatch_depth == 0 && self.programming_depth == 0 {
            true
        } else {
            self.reprogram_pending = true;
            false
        }
    }

    fn begin_callback_dispatch(&mut self) {
        self.callback_dispatch_depth = self
            .callback_dispatch_depth
            .checked_add(1)
            .expect("timer callback dispatch depth overflow");
    }

    fn end_callback_dispatch(&mut self) -> bool {
        assert!(
            self.callback_dispatch_depth > 0,
            "timer callback dispatch depth underflow"
        );
        self.callback_dispatch_depth -= 1;
        if self.callback_dispatch_depth == 0 {
            core::mem::take(&mut self.reprogram_pending)
        } else {
            false
        }
    }

    fn abort_callback_dispatch(&mut self) {
        assert!(
            self.callback_dispatch_depth > 0,
            "timer callback dispatch depth underflow"
        );
        self.callback_dispatch_depth -= 1;
        self.reprogram_pending = true;
    }

    fn begin_programming(&mut self) {
        self.programming_depth = self
            .programming_depth
            .checked_add(1)
            .expect("timer broker programming depth overflow");
    }

    fn take_reprogram_pending(&mut self) -> bool {
        core::mem::take(&mut self.reprogram_pending)
    }

    fn end_programming(&mut self) {
        assert!(
            self.programming_depth > 0,
            "timer broker programming depth underflow"
        );
        self.programming_depth -= 1;
        self.reprogram_pending = false;
    }

    fn abort_programming(&mut self) {
        assert!(
            self.programming_depth > 0,
            "timer broker programming depth underflow"
        );
        self.programming_depth -= 1;
        self.reprogram_pending = true;
    }

    fn program_with(
        &mut self,
        now_nanos: u64,
        task_deadline_nanos: Option<u64>,
        future_deadline_nanos: Option<u64>,
        external_deadline_nanos: Option<u64>,
        program: impl FnOnce(u64),
    ) {
        let deadline_nanos = [
            self.periodic_deadline_nanos,
            task_deadline_nanos,
            future_deadline_nanos,
            external_deadline_nanos,
        ]
        .into_iter()
        .flatten()
        .min()
        .unwrap_or_else(|| now_nanos.saturating_add(NANOS_PER_SEC));

        program(deadline_nanos);
        self.programmed_deadline_nanos = Some(deadline_nanos);
    }
}

percpu_static! {
    TIMER_LIST: TimerList<TaskWakeupEvent> = TimerList::new(),
    TIMER_CALLBACKS: Vec<Box<dyn Fn(TimeValue) + Send + Sync>> = Vec::new(),
    DEADLINE_BROKER: DeadlineBrokerState = DeadlineBrokerState::new(),
}

struct TaskWakeupEvent {
    ticket_id: u64,
    task: AxTaskRef,
}

struct CallbackDispatchGuard {
    active: bool,
}

struct TimerProgrammingGuard {
    active: bool,
}

impl TimerProgrammingGuard {
    fn begin(pin: &ax_hal::percpu::CpuPin<'_>) -> Self {
        with_deadline_broker(pin, DeadlineBrokerState::begin_programming);
        Self { active: true }
    }

    fn finish(mut self, pin: &ax_hal::percpu::CpuPin<'_>) {
        with_deadline_broker(pin, DeadlineBrokerState::end_programming);
        self.active = false;
    }
}

impl Drop for TimerProgrammingGuard {
    fn drop(&mut self) {
        if self.active {
            with_local_pin(|pin| with_deadline_broker(pin, DeadlineBrokerState::abort_programming));
        }
    }
}

impl CallbackDispatchGuard {
    fn begin() -> Self {
        with_local_pin(|pin| {
            with_deadline_broker(pin, DeadlineBrokerState::begin_callback_dispatch)
        });
        Self { active: true }
    }

    fn finish(mut self) {
        let should_program = with_local_pin(|pin| {
            with_deadline_broker(pin, |state| {
                state.request_reprogram();
                state.end_callback_dispatch()
            })
        });
        self.active = false;
        if should_program {
            reprogram_current_cpu_timer();
        }
    }
}

impl Drop for CallbackDispatchGuard {
    fn drop(&mut self) {
        if self.active {
            with_local_pin(|pin| {
                with_deadline_broker(pin, DeadlineBrokerState::abort_callback_dispatch)
            });
        }
    }
}

impl TimerEvent for TaskWakeupEvent {
    fn callback(self, _now: TimeValue) {
        // Ignore the timer event if timeout was set but not triggered
        // (wake up by `WaitQueue::notify()`).
        // Judge if this timer event is still valid by checking the ticket ID.
        if self.task.timer_ticket() != self.ticket_id {
            // Timer ticket ID is not matched.
            // Just ignore this timer event and return.
            return;
        }

        // Timer ticket match. Timers are per-CPU, so prefer waking the task on
        // the CPU that owns and expires this timer event. Falling back to the
        // affinity selector is only needed if the task's affinity changed while
        // it was sleeping.
        wake_task_from_timer(self.task)
    }
}

#[cfg(feature = "smp")]
fn wake_task_from_timer(task: AxTaskRef) {
    if task.cpumask().get(ax_hal::percpu::this_cpu_id()) {
        current_run_queue::<NoOp>().unblock_task(task, true);
    } else {
        select_run_queue::<NoOp>(&task).unblock_task(task, true);
    }
}

#[cfg(not(feature = "smp"))]
fn wake_task_from_timer(task: AxTaskRef) {
    current_run_queue::<NoOp>().unblock_task(task, true);
}

/// Registers a callback function to be called on each timer tick.
pub fn register_timer_callback<F>(callback: F)
where
    F: Fn(TimeValue) + Send + Sync + 'static,
{
    with_local_exclusive(|exclusive| {
        TIMER_CALLBACKS.with_current_mut(exclusive, |callbacks| callbacks.push(Box::new(callback)))
    });
}

#[doc(hidden)]
pub fn register_current_cpu_timer_deadline_provider(provider: TimerDeadlineProvider) {
    with_local_pin(|pin| {
        with_deadline_broker(pin, |state| state.register_external_provider(provider))
    });
}

#[doc(hidden)]
pub fn set_current_cpu_periodic_timer_deadline_nanos(deadline_nanos: Option<u64>) {
    with_local_pin(|pin| {
        with_deadline_broker(pin, |state| {
            state.set_periodic_deadline_nanos(deadline_nanos)
        })
    });
}

#[doc(hidden)]
pub fn reprogram_current_cpu_timer() {
    with_local_pin(|pin| {
        if with_deadline_broker(pin, DeadlineBrokerState::request_reprogram) {
            program_current_cpu_timer_with_pin(pin);
        }
    });
}

fn check_callbacks() {
    with_local_pin(|pin| {
        TIMER_CALLBACKS.with_current(pin, |callbacks| {
            for callback in callbacks {
                callback(monotonic_time());
            }
        })
    });
}

fn deadline_to_nanos(deadline: TimeValue) -> u64 {
    deadline.as_nanos().min(u64::MAX as u128) as u64
}

pub(crate) fn maybe_reprogram_timer(deadline: TimeValue) {
    let deadline_nanos = deadline_to_nanos(deadline);
    with_local_pin(|pin| {
        let should_program = with_deadline_broker(pin, |state| {
            if state
                .programmed_deadline_nanos
                .is_none_or(|programmed| deadline_nanos < programmed)
            {
                state.request_reprogram()
            } else {
                false
            }
        });
        if should_program {
            program_current_cpu_timer_with_pin(pin);
        }
    });
}

fn program_current_cpu_timer_with_pin(pin: &ax_hal::percpu::CpuPin<'_>) {
    let programming_guard = TimerProgrammingGuard::begin(pin);
    program_current_cpu_timer_once(pin);
    if with_deadline_broker(pin, DeadlineBrokerState::take_reprogram_pending) {
        program_current_cpu_timer_once(pin);
    }
    programming_guard.finish(pin);
}

fn program_current_cpu_timer_once(pin: &ax_hal::percpu::CpuPin<'_>) {
    // SAFETY: the caller holds NoPreemptIrqSave, so the CPU pin cannot migrate
    // and local IRQ re-entry cannot overlap the timer-list borrow.
    let task_deadline = unsafe {
        ax_hal::percpu::with_exclusive_cpu(pin, |exclusive| {
            TIMER_LIST.with_current_mut(exclusive, |timer_list| timer_list.next_deadline())
        })
    };
    let future_deadline = crate::future::next_timer_deadline();
    let external_provider = DEADLINE_BROKER.with_current(pin, |state| state.external_provider);

    // Timer-list and future-runtime borrows have ended before external code runs.
    let external_deadline_nanos = external_provider.and_then(|provider| provider());
    let now_nanos = monotonic_time_nanos();
    with_deadline_broker(pin, |state| {
        state.program_with(
            now_nanos,
            task_deadline.map(deadline_to_nanos),
            future_deadline.map(deadline_to_nanos),
            external_deadline_nanos,
            ax_hal::time::set_oneshot_timer,
        )
    });
}

pub(crate) fn set_alarm_wakeup(deadline: TimeValue, task: AxTaskRef) {
    with_local_exclusive(|exclusive| {
        TIMER_LIST.with_current_mut(exclusive, |timer_list| {
            let ticket_id = TIMER_TICKET_ID.fetch_add(1, Ordering::AcqRel);
            task.set_timer_ticket(ticket_id);
            timer_list.set(deadline, TaskWakeupEvent { ticket_id, task });
        })
    });
    maybe_reprogram_timer(deadline);
}

// SAFETY: only called in timer irq handler, so irq and preemption are
// both disabled here.
pub fn check_events(run_callbacks: bool) {
    let dispatch_guard = CallbackDispatchGuard::begin();
    if run_callbacks {
        check_callbacks();
    }
    loop {
        let now = monotonic_time();
        let event = with_local_exclusive(|exclusive| {
            TIMER_LIST.with_current_mut(exclusive, |timer_list| timer_list.expire_one(now))
        });
        if let Some((_deadline, event)) = event {
            event.callback(now);
        } else {
            break;
        }
    }

    // Handle async timer events
    crate::future::check_timer_events();

    dispatch_guard.finish();
}

fn with_deadline_broker<R>(
    pin: &ax_hal::percpu::CpuPin<'_>,
    operation: impl FnOnce(&mut DeadlineBrokerState) -> R,
) -> R {
    // SAFETY: every caller holds NoPreemptIrqSave, which prevents migration,
    // local IRQ re-entry, and conflicting access for the complete borrow.
    unsafe {
        ax_hal::percpu::with_exclusive_cpu(pin, |exclusive| {
            DEADLINE_BROKER.with_current_mut(exclusive, operation)
        })
    }
}

fn with_local_pin<R>(
    operation: impl for<'scope> FnOnce(&ax_hal::percpu::CpuPin<'scope>) -> R,
) -> R {
    let _guard = NoPreemptIrqSave::new();
    // SAFETY: the guard prevents migration for the complete callback.
    unsafe { ax_hal::percpu::with_cpu_pin(operation) }
        .expect("timer access requires an installed CPU-local area")
}

fn with_local_exclusive<R>(
    operation: impl for<'exclusive> FnOnce(&ax_hal::percpu::ExclusiveCpu<'exclusive>) -> R,
) -> R {
    let _guard = NoPreemptIrqSave::new();
    // SAFETY: the guard excludes migration, local IRQ/re-entry, and conflicting
    // local access for the complete callback.
    unsafe {
        ax_hal::percpu::with_cpu_pin(|pin| ax_hal::percpu::with_exclusive_cpu(pin, operation))
    }
    .expect("timer access requires an installed CPU-local area")
}

#[cfg(test)]
mod tests {
    use core::cell::Cell;

    use super::*;

    fn empty_external_deadline() -> Option<u64> {
        None
    }

    #[test]
    fn broker_keeps_external_deadline_after_periodic_epilogue() {
        let mut state = DeadlineBrokerState::default();
        let programmed = Cell::new(None);
        state.set_periodic_deadline_nanos(Some(20_000_000));

        state.program_with(
            10_000_000,
            Some(30_000_000),
            None,
            Some(15_000_000),
            |deadline| programmed.set(Some(deadline)),
        );

        assert_eq!(programmed.get(), Some(15_000_000));
    }

    #[test]
    fn tickless_broker_keeps_external_deadline() {
        let mut state = DeadlineBrokerState::default();
        let programmed = Cell::new(None);

        state.program_with(10_000_000, None, None, Some(15_000_000), |deadline| {
            programmed.set(Some(deadline))
        });

        assert_eq!(programmed.get(), Some(15_000_000));
    }

    #[test]
    fn empty_broker_parks_for_one_second() {
        let mut state = DeadlineBrokerState::default();
        let programmed = Cell::new(None);

        state.program_with(10_000_000, None, None, None, |deadline| {
            programmed.set(Some(deadline));
        });

        assert_eq!(programmed.get(), Some(1_010_000_000));
    }

    #[test]
    #[should_panic(expected = "timer deadline provider already registered on this CPU")]
    fn duplicate_external_provider_registration_fails() {
        let mut state = DeadlineBrokerState::default();

        state.register_external_provider(empty_external_deadline);
        state.register_external_provider(empty_external_deadline);
    }

    #[test]
    fn nested_callback_reprogramming_waits_for_outermost_exit() {
        let mut state = DeadlineBrokerState::default();
        state.begin_callback_dispatch();
        state.begin_callback_dispatch();

        assert!(!state.request_reprogram());
        assert!(!state.end_callback_dispatch());
        assert!(state.end_callback_dispatch());
    }
}
