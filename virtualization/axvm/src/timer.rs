//! AxVM-owned CPU-bucketed VM timer wheels.

extern crate alloc;

#[cfg(test)]
use alloc::vec::Vec;
use alloc::{boxed::Box, collections::BTreeMap};
#[cfg(test)]
use core::sync::atomic::AtomicU64;
use core::{
    sync::atomic::{AtomicUsize, Ordering},
    time::Duration,
};
#[cfg(test)]
use std::sync::{Mutex, MutexGuard};

use ax_kernel_guard::NoPreempt;
use ax_kspin::SpinNoIrq;
use ax_lazyinit::LazyInit;
use ax_timer_list::{TimeValue, TimerEvent, TimerList};

#[cfg(not(test))]
use crate::host::{HostTime, default_host, task};

static TOKEN: AtomicUsize = AtomicUsize::new(0);

struct VmTimerEvent {
    token: usize,
    callback: Box<dyn FnOnce(TimeValue) + Send + 'static>,
}

impl VmTimerEvent {
    fn new<F>(token: usize, callback: F) -> Self
    where
        F: FnOnce(TimeValue) + Send + 'static,
    {
        Self {
            token,
            callback: Box::new(callback),
        }
    }
}

impl TimerEvent for VmTimerEvent {
    fn callback(self, now: TimeValue) {
        (self.callback)(now);
    }
}

struct TimerWheels {
    wheels: BTreeMap<usize, TimerList<VmTimerEvent>>,
    owners: BTreeMap<usize, usize>,
}

impl TimerWheels {
    fn new() -> Self {
        Self {
            wheels: BTreeMap::new(),
            owners: BTreeMap::new(),
        }
    }

    fn ensure_cpu(&mut self, cpu_id: usize) -> &mut TimerList<VmTimerEvent> {
        self.wheels.entry(cpu_id).or_default()
    }

    fn register(
        &mut self,
        owner_cpu: usize,
        token: usize,
        deadline: TimeValue,
        event: VmTimerEvent,
    ) -> Option<TimeValue> {
        self.owners.insert(token, owner_cpu);
        let wheel = self.ensure_cpu(owner_cpu);
        wheel.set(deadline, event);
        wheel.next_deadline()
    }

    fn cancel(&mut self, token: usize) -> Option<(usize, Option<TimeValue>)> {
        let owner_cpu = self.owners.remove(&token)?;
        let next_deadline = self.wheels.get_mut(&owner_cpu).map(|wheel| {
            wheel.cancel(|event| event.token == token);
            wheel.next_deadline()
        });
        Some((owner_cpu, next_deadline.flatten()))
    }

    fn expire_one(
        &mut self,
        owner_cpu: usize,
        now: TimeValue,
    ) -> Option<(TimeValue, VmTimerEvent)> {
        let expired = self
            .wheels
            .get_mut(&owner_cpu)
            .and_then(|wheel| wheel.expire_one(now));
        if let Some((_, event)) = &expired {
            self.owners.remove(&event.token);
        }
        expired
    }

    fn next_deadline(&self, owner_cpu: usize) -> Option<TimeValue> {
        self.wheels
            .get(&owner_cpu)
            .and_then(TimerList::next_deadline)
    }
}

static TIMER_WHEELS: LazyInit<SpinNoIrq<TimerWheels>> = LazyInit::new();

pub(crate) fn register_timer(
    deadline_ns: u64,
    callback: Box<dyn FnOnce(Duration) + Send + 'static>,
) -> usize {
    let token = TOKEN.fetch_add(1, Ordering::Relaxed);
    with_current_timer_wheels(|cpu_id, timer_wheels| {
        timer_wheels.register(
            cpu_id,
            token,
            TimeValue::from_nanos(deadline_ns),
            VmTimerEvent::new(token, callback),
        )
    });
    request_current_cpu_broker_recompute();
    token
}

pub(crate) fn cancel_timer(token: usize) {
    let _guard = NoPreempt::new();
    let current_cpu = current_cpu_id();
    let canceled = with_timer_wheels(|timer_wheels| timer_wheels.cancel(token));
    if let Some((owner_cpu, _)) = canceled {
        request_owner_cpu_broker_recompute(owner_cpu, current_cpu);
    }
}

pub(crate) fn check_events() {
    loop {
        let now = current_host_time();
        let expired =
            with_current_timer_wheels(|cpu_id, timer_wheels| timer_wheels.expire_one(cpu_id, now));
        if let Some((deadline, event)) = expired {
            request_current_cpu_broker_recompute();
            trace!("handle VM timer event scheduled at {deadline:#?}");
            event.callback(now);
        } else {
            break;
        }
    }
}

pub(crate) fn current_cpu_deadline_nanos() -> Option<u64> {
    let deadline_nanos = with_current_timer_wheels(|cpu_id, timer_wheels| {
        timer_wheels.next_deadline(cpu_id).map(deadline_to_nanos)
    });
    crate::rt_trace::axvm_deadline_publish(deadline_nanos);
    deadline_nanos
}

fn deadline_to_nanos(deadline: TimeValue) -> u64 {
    deadline.as_nanos().min(u64::MAX as u128) as u64
}

#[allow(
    dead_code,
    reason = "used by AArch64 production and portable host tests"
)]
pub(crate) trait TimerCallbackRegistrar {
    fn register<F>(self, callback: F)
    where
        F: Fn(TimeValue) + Send + Sync + 'static;
}

#[allow(
    dead_code,
    reason = "used by AArch64 production and portable host tests"
)]
pub(crate) fn register_timer_wheel_callback(
    registrar: impl TimerCallbackRegistrar,
    drain_timer_wheel: fn(),
) {
    registrar.register(move |_| drain_timer_wheel());
}

#[cfg(not(test))]
fn current_host_time() -> TimeValue {
    default_host().monotonic_time()
}

#[cfg(test)]
fn current_host_time() -> TimeValue {
    TimeValue::from_nanos(TEST_NOW_NS.load(Ordering::Acquire))
}

fn request_owner_cpu_broker_recompute(owner_cpu: usize, current_cpu: usize) {
    if owner_cpu == current_cpu {
        request_current_cpu_broker_recompute();
    } else {
        request_remote_owner_cpu_broker_recompute(owner_cpu);
    }
}

#[cfg(not(test))]
fn request_current_cpu_broker_recompute() {
    ax_std::os::arceos::modules::ax_task::reprogram_current_cpu_timer();
}

#[cfg(not(test))]
unsafe fn request_current_cpu_broker_recompute_thunk(_arg: *mut ()) {
    request_current_cpu_broker_recompute();
}

#[cfg(not(test))]
fn request_remote_owner_cpu_broker_recompute(owner_cpu: usize) {
    let result = task::run_on_cpu_sync(
        owner_cpu,
        request_current_cpu_broker_recompute_thunk,
        core::ptr::null_mut(),
    );
    if let Err(error) = result {
        // The previously programmed, possibly early deadline remains armed, so
        // cancellation cannot make the owner miss a later surviving deadline.
        warn!(
            "failed to reconcile AxVM timer on owner CPU {owner_cpu}: {error:?}; retaining the \
             early host deadline and sending IPI"
        );
        task::send_ipi(owner_cpu);
    }
}

pub(crate) fn init_percpu() {
    info!("Initializing AxVM timer wheel...");
    with_current_timer_wheels(|cpu_id, timer_wheels| {
        timer_wheels.ensure_cpu(cpu_id);
    });
    crate::arch::register_timer_callback();
    ax_std::os::arceos::modules::ax_task::register_current_cpu_timer_deadline_provider(
        current_cpu_deadline_nanos,
    );
}

fn with_timer_wheels<R>(operation: impl FnOnce(&mut TimerWheels) -> R) -> R {
    let timer_wheels = TIMER_WHEELS.get_or_init(|| SpinNoIrq::new(TimerWheels::new()));
    operation(&mut timer_wheels.lock())
}

fn with_current_timer_wheels<R>(operation: impl FnOnce(usize, &mut TimerWheels) -> R) -> R {
    let _guard = NoPreempt::new();
    let cpu_id = current_cpu_id();
    with_timer_wheels(|timer_wheels| operation(cpu_id, timer_wheels))
}

#[cfg(not(test))]
fn current_cpu_id() -> usize {
    use crate::host::HostCpu;

    default_host().this_cpu_id()
}

#[cfg(test)]
static TEST_CURRENT_CPU: AtomicUsize = AtomicUsize::new(0);
#[cfg(test)]
static TEST_BROKER_RECOMPUTES: Mutex<Vec<usize>> = Mutex::new(Vec::new());
#[cfg(test)]
static TEST_DIRECT_HOST_TIMER_WRITES: Mutex<Vec<(usize, Option<TimeValue>)>> =
    Mutex::new(Vec::new());
#[cfg(test)]
static TEST_REMOTE_RECOMPUTES: Mutex<Vec<usize>> = Mutex::new(Vec::new());
#[cfg(test)]
static TEST_NOW_NS: AtomicU64 = AtomicU64::new(0);

#[cfg(test)]
fn current_cpu_id() -> usize {
    TEST_CURRENT_CPU.load(Ordering::Acquire)
}

#[cfg(test)]
fn lock_test_mutex<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().expect("AxVM timer test mutex poisoned")
}

#[cfg(test)]
fn request_current_cpu_broker_recompute() {
    lock_test_mutex(&TEST_BROKER_RECOMPUTES).push(current_cpu_id());
}

#[cfg(test)]
fn request_remote_owner_cpu_broker_recompute(owner_cpu: usize) {
    lock_test_mutex(&TEST_REMOTE_RECOMPUTES).push(owner_cpu);
    let previous_cpu = TEST_CURRENT_CPU.swap(owner_cpu, Ordering::AcqRel);
    request_current_cpu_broker_recompute();
    TEST_CURRENT_CPU.store(previous_cpu, Ordering::Release);
}

#[cfg(test)]
mod tests {
    use super::*;

    static TEST_LOCK: Mutex<()> = Mutex::new(());

    type RecordedTimerCallback = Box<dyn Fn(TimeValue) + Send + Sync + 'static>;

    struct RecordingTimerCallbackRegistrar<'a>(&'a mut Option<RecordedTimerCallback>);

    impl TimerCallbackRegistrar for RecordingTimerCallbackRegistrar<'_> {
        fn register<F>(self, callback: F)
        where
            F: Fn(TimeValue) + Send + Sync + 'static,
        {
            *self.0 = Some(Box::new(callback));
        }
    }

    fn reset_global_timer_state() {
        with_timer_wheels(|timer_wheels| *timer_wheels = TimerWheels::new());
        lock_test_mutex(&TEST_BROKER_RECOMPUTES).clear();
        lock_test_mutex(&TEST_DIRECT_HOST_TIMER_WRITES).clear();
        lock_test_mutex(&TEST_REMOTE_RECOMPUTES).clear();
        TEST_CURRENT_CPU.store(0, Ordering::Release);
        TEST_NOW_NS.store(0, Ordering::Release);
    }

    fn set_current_cpu_for_test(cpu_id: usize) {
        TEST_CURRENT_CPU.store(cpu_id, Ordering::Release);
    }

    static TEST_CALLBACK_NOW_NS: AtomicU64 = AtomicU64::new(0);

    fn event(token: usize) -> VmTimerEvent {
        VmTimerEvent::new(token, |_| {})
    }

    #[test]
    fn host_timer_callback_path_dispatches_registered_event_once() {
        let _guard = lock_test_mutex(&TEST_LOCK);
        reset_global_timer_state();
        TEST_CALLBACK_NOW_NS.store(0, Ordering::Release);

        set_current_cpu_for_test(0);
        TEST_NOW_NS.store(1_000_000, Ordering::Release);
        let token = register_timer(
            10_000_000,
            Box::new(|now| {
                TEST_CALLBACK_NOW_NS.store(now.as_nanos() as u64, Ordering::Release);
            }),
        );

        check_events();
        assert_eq!(TEST_CALLBACK_NOW_NS.load(Ordering::Acquire), 0);

        lock_test_mutex(&TEST_BROKER_RECOMPUTES).clear();
        lock_test_mutex(&TEST_DIRECT_HOST_TIMER_WRITES).clear();
        TEST_NOW_NS.store(10_000_000, Ordering::Release);
        check_events();
        assert_eq!(TEST_CALLBACK_NOW_NS.load(Ordering::Acquire), 10_000_000);
        assert_eq!(lock_test_mutex(&TEST_BROKER_RECOMPUTES).as_slice(), &[0]);
        assert!(lock_test_mutex(&TEST_DIRECT_HOST_TIMER_WRITES).is_empty());
        assert_eq!(
            with_timer_wheels(|timer_wheels| timer_wheels.cancel(token)),
            None
        );
    }

    #[test]
    fn local_registration_and_cancellation_request_broker_recompute() {
        let _guard = lock_test_mutex(&TEST_LOCK);
        reset_global_timer_state();

        let early_token = register_timer(10_000_000, Box::new(|_| {}));
        let _late_token = register_timer(20_000_000, Box::new(|_| {}));

        assert_eq!(lock_test_mutex(&TEST_BROKER_RECOMPUTES).as_slice(), &[0, 0]);
        assert!(lock_test_mutex(&TEST_DIRECT_HOST_TIMER_WRITES).is_empty());

        lock_test_mutex(&TEST_BROKER_RECOMPUTES).clear();
        cancel_timer(early_token);

        assert_eq!(lock_test_mutex(&TEST_BROKER_RECOMPUTES).as_slice(), &[0]);
        assert!(lock_test_mutex(&TEST_DIRECT_HOST_TIMER_WRITES).is_empty());
    }

    #[test]
    fn unknown_timer_token_requests_no_recompute() {
        let _guard = lock_test_mutex(&TEST_LOCK);
        reset_global_timer_state();

        cancel_timer(usize::MAX);

        assert!(lock_test_mutex(&TEST_BROKER_RECOMPUTES).is_empty());
        assert!(lock_test_mutex(&TEST_REMOTE_RECOMPUTES).is_empty());
        assert!(lock_test_mutex(&TEST_DIRECT_HOST_TIMER_WRITES).is_empty());
    }

    #[test]
    fn portable_registration_invokes_the_real_timer_wheel_drain() {
        let _guard = lock_test_mutex(&TEST_LOCK);
        reset_global_timer_state();
        let mut registered = None;
        let dispatch_count = alloc::sync::Arc::new(AtomicUsize::new(0));
        let event_dispatch_count = dispatch_count.clone();

        register_timer_wheel_callback(
            RecordingTimerCallbackRegistrar(&mut registered),
            crate::check_timer_events,
        );
        TEST_NOW_NS.store(5_000_000, Ordering::Release);
        register_timer(
            5_000_000,
            Box::new(move |_| {
                event_dispatch_count.fetch_add(1, Ordering::AcqRel);
            }),
        );

        let callback = registered.expect("host timer callback must be registered");
        callback(Duration::from_nanos(5_000_000));
        callback(Duration::from_nanos(5_000_000));

        assert_eq!(dispatch_count.load(Ordering::Acquire), 1);
    }

    #[test]
    fn cancel_removes_event_from_original_cpu_wheel() {
        let mut timer_wheels = TimerWheels::new();
        let deadline = Duration::from_secs(60);

        assert_eq!(
            timer_wheels.register(0, 7, deadline, event(7)),
            Some(deadline)
        );
        assert_eq!(timer_wheels.next_deadline(0), Some(deadline));
        assert_eq!(timer_wheels.next_deadline(1), None);

        assert_eq!(timer_wheels.cancel(7), Some((0, None)));
        assert_eq!(timer_wheels.next_deadline(0), None);
        assert_eq!(timer_wheels.cancel(7), None);
    }

    #[test]
    fn deadline_provider_reads_only_current_cpu_and_saturates_to_u64() {
        let _guard = lock_test_mutex(&TEST_LOCK);
        reset_global_timer_state();

        assert_eq!(current_cpu_deadline_nanos(), None);
        with_timer_wheels(|timer_wheels| {
            timer_wheels.register(0, 41, Duration::MAX, event(41));
            timer_wheels.ensure_cpu(1);
        });

        assert_eq!(current_cpu_deadline_nanos(), Some(u64::MAX));
        set_current_cpu_for_test(1);
        assert_eq!(current_cpu_deadline_nanos(), None);
    }

    #[test]
    fn cancel_exposes_remaining_owner_deadline() {
        let mut timer_wheels = TimerWheels::new();
        let early = Duration::from_secs(10);
        let late = Duration::from_secs(20);

        timer_wheels.register(1, 11, early, event(11));
        timer_wheels.register(1, 12, late, event(12));

        assert_eq!(timer_wheels.cancel(11), Some((1, Some(late))));
        assert_eq!(timer_wheels.next_deadline(1), Some(late));
    }

    #[test]
    fn migration_removes_stale_original_cpu_deadline() {
        let mut timer_wheels = TimerWheels::new();
        let stale_deadline = Duration::from_secs(60);
        let migrated_deadline = Duration::from_millis(10);

        assert_eq!(
            timer_wheels.register(0, 31, stale_deadline, event(31)),
            Some(stale_deadline)
        );
        assert_eq!(timer_wheels.cancel(31), Some((0, None)));
        assert_eq!(
            timer_wheels.register(1, 32, migrated_deadline, event(32)),
            Some(migrated_deadline)
        );

        assert!(timer_wheels.expire_one(0, stale_deadline).is_none());
        let (deadline, migrated_event) = timer_wheels
            .expire_one(1, migrated_deadline)
            .expect("migrated timer event should expire on the new owner CPU");
        assert_eq!(deadline, migrated_deadline);
        assert_eq!(migrated_event.token, 32);
        assert_eq!(timer_wheels.cancel(32), None);
    }

    #[test]
    fn expiring_event_forgets_owner_token() {
        let mut timer_wheels = TimerWheels::new();
        let deadline = Duration::from_millis(5);

        timer_wheels.register(2, 21, deadline, event(21));
        let expired = timer_wheels.expire_one(2, deadline);

        assert!(expired.is_some());
        assert_eq!(timer_wheels.cancel(21), None);
    }

    #[test]
    fn remote_cancel_requests_owner_cpu_broker_recompute() {
        let _guard = lock_test_mutex(&TEST_LOCK);
        reset_global_timer_state();

        set_current_cpu_for_test(0);
        let early_token = register_timer(10_000_000, Box::new(|_| {}));
        let late_token = register_timer(20_000_000, Box::new(|_| {}));

        lock_test_mutex(&TEST_BROKER_RECOMPUTES).clear();
        lock_test_mutex(&TEST_DIRECT_HOST_TIMER_WRITES).clear();
        set_current_cpu_for_test(1);
        cancel_timer(early_token);

        assert_eq!(lock_test_mutex(&TEST_REMOTE_RECOMPUTES).as_slice(), &[0]);
        assert_eq!(lock_test_mutex(&TEST_BROKER_RECOMPUTES).as_slice(), &[0]);
        assert!(lock_test_mutex(&TEST_DIRECT_HOST_TIMER_WRITES).is_empty());

        lock_test_mutex(&TEST_BROKER_RECOMPUTES).clear();
        cancel_timer(late_token);

        assert_eq!(lock_test_mutex(&TEST_REMOTE_RECOMPUTES).as_slice(), &[0, 0]);
        assert_eq!(lock_test_mutex(&TEST_BROKER_RECOMPUTES).as_slice(), &[0]);
        assert!(lock_test_mutex(&TEST_DIRECT_HOST_TIMER_WRITES).is_empty());
    }
}
