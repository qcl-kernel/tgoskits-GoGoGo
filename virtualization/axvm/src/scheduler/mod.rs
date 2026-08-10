// Copyright 2025 The Axvisor Team
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//! AxVM Real-Time vCPU Scheduler.
//!
//! This module implements preemptive scheduling policies for vCPUs running
//! under AxVM. It is integrated with the per-CPU timer wheel and the vCPU
//! run loop in [`crate::runtime::vcpus`].
//!
//! # Scheduling Policies
//!
//! | Policy | Description |
//! |---|---|
//! | [`RtSchedPolicy::None`] | No real-time scheduling (current default behaviour). |
//! | [`RtSchedPolicy::FixedPriority`] | Strict priority preemptive: a higher-priority vCPU always runs before a lower-priority one. |
//! | [`RtSchedPolicy::Budget`] | Constant Bandwidth Server (CBS): each vCPU receives a CPU budget that replenishes every period. |
//! | [`RtSchedPolicy::Deadline`] | Earliest Deadline First (EDF): vCPUs are ordered by their absolute deadline. |
//!
//! # Per-CPU Instance
//!
//! Each physical CPU owns one [`RtScheduler`] instance (stored in
//! [`VmRuntimeHandle`]). The scheduler is consulted before every guest entry
//! and after every guest exit.

extern crate alloc;

use alloc::collections::{BTreeMap, BinaryHeap};
use core::cmp::Ordering;

use axvm_types::{
    RtBudgetParams, RtDeadlineParams, RtPriorityParams, RtSchedConfig, RtSchedPolicy, RtVcpuConfig,
};

pub(crate) mod stats;

pub(crate) use self::sched_glue::{
    after_vcpu_exit, before_vcpu_enter, handle_sched_decision, register_vcpu, set_runnable,
};

// ---------------------------------------------------------------------------
// Per-vCPU Scheduling State
// ---------------------------------------------------------------------------

/// Runtime scheduling state for one vCPU.
#[derive(Debug, Clone)]
pub(crate) struct VcpuSchedState {
    /// vCPU logical identifier (0-indexed within its VM).
    pub vcpu_id: usize,
    /// Owner VM identifier.
    pub vm_id: usize,
    /// Static scheduling configuration.
    pub config: RtVcpuConfig,
    /// Remaining CPU budget in nanoseconds (used by `Budget` and `Deadline`).
    pub remaining_budget_ns: u64,
    /// Absolute deadline timestamp in nanoseconds (used by `Deadline`).
    pub deadline_ns: u64,
    /// Timestamp (monotonic ns) of the last scheduling event.
    pub last_scheduled_ns: Option<u64>,
    /// Total nanoseconds consumed during the current period.
    pub consumed_ns: u64,
    /// Whether this vCPU is currently runnable.
    pub runnable: bool,
    /// Count of times this vCPU was preempted.
    pub preemption_count: u64,
    /// Total nanoseconds spent in the guest since creation.
    pub total_guest_ns: u64,
}

impl VcpuSchedState {
    fn new(vm_id: usize, vcpu_id: usize, config: RtVcpuConfig) -> Self {
        let (initial_budget_ns, initial_deadline_ns) = match config.policy {
            RtSchedPolicy::Budget => {
                let budget = config.budget.unwrap_or_default();
                ((budget.budget_us as u64) * 1000, 0u64)
            }
            RtSchedPolicy::Deadline => {
                let deadline = config.deadline.unwrap_or_default();
                (
                    (deadline.wcet_us as u64) * 1000,
                    deadline.deadline_us * 1000,
                )
            }
            _ => (u64::MAX, 0),
        };
        Self {
            vcpu_id,
            vm_id,
            config,
            remaining_budget_ns: initial_budget_ns,
            deadline_ns: initial_deadline_ns,
            last_scheduled_ns: None,
            consumed_ns: 0,
            runnable: true,
            preemption_count: 0,
            total_guest_ns: 0,
        }
    }

    fn key(&self) -> (usize, usize) {
        (self.vm_id, self.vcpu_id)
    }
}

// ---------------------------------------------------------------------------
// EDF Ready Queue Entry
// ---------------------------------------------------------------------------

/// Entry in the EDF ready queue, ordered by absolute deadline (earliest first).
#[derive(Debug, Clone, Copy)]
struct EdFEntry {
    deadline_ns: u64,
    vm_id: usize,
    vcpu_id: usize,
}

impl PartialEq for EdFEntry {
    fn eq(&self, other: &Self) -> bool {
        self.deadline_ns == other.deadline_ns
    }
}

impl Eq for EdFEntry {}

impl PartialOrd for EdFEntry {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for EdFEntry {
    fn cmp(&self, other: &Self) -> Ordering {
        // Reverse: BinaryHeap is a max-heap; we want the *earliest* deadline on top.
        other
            .deadline_ns
            .cmp(&self.deadline_ns)
            .then_with(|| other.vm_id.cmp(&self.vm_id))
            .then_with(|| other.vcpu_id.cmp(&self.vcpu_id))
    }
}

// ---------------------------------------------------------------------------
// Scheduling Decision
// ---------------------------------------------------------------------------

/// Decision returned by the scheduler after evaluating a vCPU exit.
#[derive(Debug, Clone, Copy)]
pub(crate) enum SchedDecision {
    /// Continue running the same vCPU with the given timeslice.
    Continue { next_timeslice_ns: u64 },
    /// Preempt the current vCPU in favour of another runnable vCPU.
    Preempt {
        next_vm_id: usize,
        next_vcpu_id: usize,
        timeslice_ns: u64,
    },
    /// No runnable vCPU is available; the calling vCPU should block.
    Yield,
}

// ---------------------------------------------------------------------------
// RT Scheduler
// ---------------------------------------------------------------------------

/// Per-physical-CPU real-time vCPU scheduler.
pub(crate) struct RtScheduler {
    /// The scheduling policy in effect.
    policy: RtSchedPolicy,
    /// Per-vCPU runtime state, keyed by `(vm_id, vcpu_id)`.
    vcpu_states: BTreeMap<(usize, usize), VcpuSchedState>,
    /// Default timeslice in nanoseconds.
    default_timeslice_ns: u64,
    /// Whether the scheduler is enabled.
    enabled: bool,
    /// Currently active vCPU key, if any.
    current_vcpu: Option<(usize, usize)>,
    /// EDF ready queue (populated when `policy` is `Deadline`).
    ready_queue: BinaryHeap<EdFEntry>,
}

impl RtScheduler {
    /// Creates a new scheduler from the RT configuration.
    pub fn new(config: &RtSchedConfig) -> Self {
        let policy = if !config.enabled {
            RtSchedPolicy::None
        } else if let Some(first) = config.vcpu_configs.first() {
            first.policy
        } else {
            RtSchedPolicy::None
        };

        let mut vcpu_states = BTreeMap::new();
        let mut ready_queue = BinaryHeap::new();

        // For now, vCPU 0 of the current VM is the only vCPU registered.
        // Per-vCPU registration happens later in `register_vcpu()`.
        // When multi-vCPU VMs need RT, this should be called per vCPU.
        for (vcpu_id, vcpu_cfg) in config.vcpu_configs.iter().enumerate() {
            let state = VcpuSchedState::new(0, vcpu_id, vcpu_cfg.clone());
            if policy == RtSchedPolicy::Deadline && vcpu_cfg.deadline.is_some() {
                ready_queue.push(EdFEntry {
                    deadline_ns: state.deadline_ns,
                    vm_id: 0,
                    vcpu_id,
                });
            }
            vcpu_states.insert((0, vcpu_id), state);
        }

        Self {
            policy,
            vcpu_states,
            default_timeslice_ns: (config.base_timeslice_us as u64) * 1000,
            enabled: config.enabled,
            current_vcpu: None,
            ready_queue,
        }
    }

    /// Returns `true` when the scheduler is actively managing vCPU placement.
    pub fn enabled(&self) -> bool {
        self.enabled
    }

    /// Registers a vCPU with the scheduler.
    pub fn register_vcpu(&mut self, vm_id: usize, vcpu_id: usize, config: RtVcpuConfig) {
        let state = VcpuSchedState::new(vm_id, vcpu_id, config);
        let key = state.key();
        if self.policy == RtSchedPolicy::Deadline && state.config.deadline.is_some() {
            self.ready_queue.push(EdFEntry {
                deadline_ns: state.deadline_ns,
                vm_id,
                vcpu_id,
            });
        }
        self.vcpu_states.insert(key, state);
    }

    /// Marks a vCPU as runnable (`true`) or blocked (`false`).
    pub fn set_runnable(&mut self, vm_id: usize, vcpu_id: usize, runnable: bool) {
        if let Some(state) = self.vcpu_states.get_mut(&(vm_id, vcpu_id)) {
            state.runnable = runnable;
            if runnable && self.policy == RtSchedPolicy::Deadline && state.config.deadline.is_some()
            {
                self.ready_queue.push(EdFEntry {
                    deadline_ns: state.deadline_ns,
                    vm_id,
                    vcpu_id,
                });
            }
        }
    }

    /// Called by the vCPU run loop before entering the guest.
    ///
    /// Returns the timeslice to program as the preemption timer, or 0 to use
    /// the architecture default.
    pub fn before_vcpu_enter(&mut self, vm_id: usize, vcpu_id: usize, now_ns: u64) -> u64 {
        if !self.enabled {
            return 0;
        }

        self.current_vcpu = Some((vm_id, vcpu_id));

        let Some(state) = self.vcpu_states.get_mut(&(vm_id, vcpu_id)) else {
            return self.default_timeslice_ns;
        };

        state.last_scheduled_ns = Some(now_ns);

        match state.config.policy {
            RtSchedPolicy::None => 0,
            RtSchedPolicy::FixedPriority => {
                // Fixed priority: timeslice is bounded by max_timeslice_us.
                let priority = state.config.priority.unwrap_or_default();
                if priority.max_timeslice_us > 0 {
                    (priority.max_timeslice_us as u64) * 1000
                } else {
                    self.default_timeslice_ns
                }
            }
            RtSchedPolicy::Budget => {
                // CBS: timeslice is the remaining budget (capped at the default).
                state.remaining_budget_ns.min(self.default_timeslice_ns)
            }
            RtSchedPolicy::Deadline => {
                let deadline = state.config.deadline.unwrap_or_default();
                let wcet_ns = (deadline.wcet_us as u64) * 1000;
                state.remaining_budget_ns = state.remaining_budget_ns.min(wcet_ns);
                state.remaining_budget_ns.min(self.default_timeslice_ns)
            }
        }
    }

    /// Called by the vCPU run loop after the guest exits.
    ///
    /// Returns the scheduling decision.
    pub fn after_vcpu_exit(
        &mut self,
        vm_id: usize,
        vcpu_id: usize,
        consumed_ns: u64,
        now_ns: u64,
    ) -> SchedDecision {
        if !self.enabled {
            return SchedDecision::Continue {
                next_timeslice_ns: 0,
            };
        }

        let Some(state) = self.vcpu_states.get_mut(&(vm_id, vcpu_id)) else {
            return SchedDecision::Continue {
                next_timeslice_ns: self.default_timeslice_ns,
            };
        };

        // Debit consumed time.
        state.consumed_ns = state.consumed_ns.saturating_add(consumed_ns);
        state.total_guest_ns = state.total_guest_ns.saturating_add(consumed_ns);

        match state.config.policy {
            RtSchedPolicy::None => SchedDecision::Continue {
                next_timeslice_ns: 0,
            },
            RtSchedPolicy::FixedPriority => {
                let my_priority = state.config.priority.map(|p| p.priority).unwrap_or(255);

                // Check for a higher-priority runnable vCPU.
                if let Some(higher) = self
                    .vcpu_states
                    .iter()
                    .filter(|(k, s)| {
                        **k != (vm_id, vcpu_id)
                            && s.runnable
                            && s.config.priority.map(|p| p.priority).unwrap_or(255) < my_priority
                    })
                    .min_by_key(|(_, s)| s.config.priority.map(|p| p.priority).unwrap_or(255))
                {
                    let next_state = higher.1;
                    let timeslice = self.timeslice_for_state(next_state);
                    return SchedDecision::Preempt {
                        next_vm_id: next_state.vm_id,
                        next_vcpu_id: next_state.vcpu_id,
                        timeslice_ns: timeslice,
                    };
                }

                let timeslice = self.timeslice_for_state(state);
                SchedDecision::Continue {
                    next_timeslice_ns: timeslice,
                }
            }
            RtSchedPolicy::Budget => {
                state.remaining_budget_ns = state.remaining_budget_ns.saturating_sub(consumed_ns);

                if state.remaining_budget_ns == 0 {
                    // Budget exhausted: replenish and yield.
                    let budget = state.config.budget.unwrap_or_default();
                    state.remaining_budget_ns = (budget.budget_us as u64) * 1000;
                    SchedDecision::Yield
                } else {
                    SchedDecision::Continue {
                        next_timeslice_ns: state.remaining_budget_ns.min(self.default_timeslice_ns),
                    }
                }
            }
            RtSchedPolicy::Deadline => {
                state.remaining_budget_ns = state.remaining_budget_ns.saturating_sub(consumed_ns);

                if state.remaining_budget_ns == 0 {
                    // WCET budget exhausted. Replenish at next period.
                    let deadline = state.config.deadline.unwrap_or_default();
                    state.remaining_budget_ns = (deadline.wcet_us as u64) * 1000;
                    state.deadline_ns = state.deadline_ns.saturating_add(deadline.period_us * 1000);
                }

                // Pick the vCPU with the earliest deadline.
                if let Some(entry) = self.ready_queue.pop() {
                    if entry.vm_id != vm_id || entry.vcpu_id != vcpu_id {
                        // Re-push current vCPU.
                        self.ready_queue.push(EdFEntry {
                            deadline_ns: state.deadline_ns,
                            vm_id,
                            vcpu_id,
                        });
                        let next_state = self.vcpu_states.get(&(entry.vm_id, entry.vcpu_id));
                        let timeslice = next_state
                            .map(|s| s.remaining_budget_ns.min(self.default_timeslice_ns))
                            .unwrap_or(self.default_timeslice_ns);
                        return SchedDecision::Preempt {
                            next_vm_id: entry.vm_id,
                            next_vcpu_id: entry.vcpu_id,
                            timeslice_ns: timeslice,
                        };
                    }
                    // Still the earliest deadline — continue.
                    self.ready_queue.push(EdFEntry {
                        deadline_ns: state.deadline_ns,
                        vm_id,
                        vcpu_id,
                    });
                }

                let timeslice = state.remaining_budget_ns.min(self.default_timeslice_ns);
                SchedDecision::Continue {
                    next_timeslice_ns: timeslice,
                }
            }
        }
    }

    /// Returns the timeslice in nanoseconds for a vCPU state.
    fn timeslice_for_state(&self, state: &VcpuSchedState) -> u64 {
        match state.config.policy {
            RtSchedPolicy::FixedPriority => {
                let priority = state.config.priority.unwrap_or_default();
                if priority.max_timeslice_us > 0 {
                    (priority.max_timeslice_us as u64) * 1000
                } else {
                    self.default_timeslice_ns
                }
            }
            RtSchedPolicy::Budget => state.remaining_budget_ns.min(self.default_timeslice_ns),
            _ => self.default_timeslice_ns,
        }
    }

    /// Returns whether a preemption-worthy vCPU is waiting.
    pub fn has_pending_preemption(&self, current_vm_id: usize, current_vcpu_id: usize) -> bool {
        if !self.enabled || self.policy != RtSchedPolicy::FixedPriority {
            return false;
        }

        let my_priority = self
            .vcpu_states
            .get(&(current_vm_id, current_vcpu_id))
            .and_then(|s| s.config.priority)
            .map(|p| p.priority)
            .unwrap_or(255);

        self.vcpu_states.iter().any(|(k, s)| {
            *k != (current_vm_id, current_vcpu_id)
                && s.runnable
                && s.config.priority.map(|p| p.priority).unwrap_or(255) < my_priority
        })
    }

    #[cfg(test)]
    pub(crate) fn total_guest_ns(&self, vm_id: usize, vcpu_id: usize) -> u64 {
        self.vcpu_states
            .get(&(vm_id, vcpu_id))
            .map(|s| s.total_guest_ns)
            .unwrap_or(0)
    }
}

// ---------------------------------------------------------------------------
// Scheduler Glue: bridge between vCPU run loop and RtScheduler
// ---------------------------------------------------------------------------

pub(crate) mod sched_glue {
    use alloc::sync::Arc;

    use crate::{AxVmResult, runtime::VMRef, vm::VmRuntimeHandle};

    pub(crate) fn register_vcpu(
        runtime: &Arc<VmRuntimeHandle>,
        vcpu: &crate::vm::AxVCpuRef,
        vm: &crate::AxVMRef,
    ) {
        let Some(sched) = &runtime.rt_scheduler else {
            return;
        };
        let rt_config = vm
            .with_config(|cfg| {
                cfg.rt_sched_config()
                    .map(|rt| rt.vcpu_configs.get(vcpu.id()).cloned().unwrap_or_default())
            })
            .unwrap_or_default()
            .unwrap_or_default();
        sched.lock().register_vcpu(vm.id(), vcpu.id(), rt_config);
    }

    pub(crate) fn before_vcpu_enter(
        runtime: &Arc<VmRuntimeHandle>,
        vm_id: usize,
        vcpu_id: usize,
        now_ns: u64,
    ) {
        let Some(sched) = &runtime.rt_scheduler else {
            return;
        };
        let timeslice_ns = sched.lock().before_vcpu_enter(vm_id, vcpu_id, now_ns);
        if timeslice_ns > 0 {
            let rate_us = (timeslice_ns / 1000).max(1) as u32;
            crate::arch::CurrentArch::set_periodic_timer(rate_us).unwrap_or_else(|err| {
                warn!("failed to set periodic timer for RT preemption: {err:?}");
            });
        }
    }

    pub(crate) fn after_vcpu_exit(
        runtime: &Arc<VmRuntimeHandle>,
        vm_id: usize,
        vcpu_id: usize,
        consumed_ns: u64,
        now_ns: u64,
    ) -> Option<super::SchedDecision> {
        let sched = runtime.rt_scheduler.as_ref()?;
        Some(
            sched
                .lock()
                .after_vcpu_exit(vm_id, vcpu_id, consumed_ns, now_ns),
        )
    }

    pub(crate) fn set_runnable(
        runtime: &Arc<VmRuntimeHandle>,
        vm_id: usize,
        vcpu_id: usize,
        runnable: bool,
    ) {
        let Some(sched) = &runtime.rt_scheduler else {
            return;
        };
        sched.lock().set_runnable(vm_id, vcpu_id, runnable);
    }

    pub(crate) fn handle_sched_decision(
        runtime: &Arc<VmRuntimeHandle>,
        decision: super::SchedDecision,
    ) {
        match decision {
            super::SchedDecision::Continue { .. } => {
                // Nothing to do — the same vCPU continues.
            }
            super::SchedDecision::Preempt {
                next_vm_id,
                next_vcpu_id,
                ..
            } => {
                debug!("Scheduler: preempting to VM[{next_vm_id}] VCpu[{next_vcpu_id}]");
                // Wake the target vCPU so it can enter the guest.
                if let Some(vm) = crate::get_vm_by_id(next_vm_id) {
                    let _ = vm.with_runtime(|r| {
                        r.notify_one();
                        Ok(())
                    });
                }
            }
            super::SchedDecision::Yield => {
                // The current vCPU should block until another event wakes it.
                debug!("Scheduler: yielding current vCPU");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use alloc::vec;

    use super::*;

    fn fixed_priority_config(priority: u8, max_timeslice_us: u32) -> RtVcpuConfig {
        RtVcpuConfig {
            policy: RtSchedPolicy::FixedPriority,
            priority: Some(RtPriorityParams {
                priority,
                min_timeslice_us: 0,
                max_timeslice_us,
            }),
            budget: None,
            deadline: None,
            preemptive: true,
        }
    }

    fn budget_config(budget_us: u32, period_us: u32) -> RtVcpuConfig {
        RtVcpuConfig {
            policy: RtSchedPolicy::Budget,
            priority: None,
            budget: Some(RtBudgetParams {
                budget_us,
                period_us,
            }),
            deadline: None,
            preemptive: false,
        }
    }

    #[test]
    fn fixed_priority_higher_preempts_lower() {
        let cfg = RtSchedConfig {
            enabled: true,
            base_timeslice_us: 1000,
            vcpu_configs: vec![
                fixed_priority_config(10, 500), // vCPU 0: lower priority
                fixed_priority_config(0, 200),  // vCPU 1: higher priority
            ],
        };
        let mut sched = RtScheduler::new(&cfg);

        // vCPU 0 runs first.
        let _ts = sched.before_vcpu_enter(0, 0, 0);
        let decision = sched.after_vcpu_exit(0, 0, 300_000, 300_000);

        assert!(
            matches!(
                decision,
                SchedDecision::Preempt {
                    next_vm_id: 0,
                    next_vcpu_id: 1,
                    ..
                }
            ),
            "higher-priority vCPU 1 should preempt vCPU 0, got {decision:?}"
        );
    }

    #[test]
    fn fixed_priority_no_preempt_when_alone() {
        let cfg = RtSchedConfig {
            enabled: true,
            base_timeslice_us: 1000,
            vcpu_configs: vec![fixed_priority_config(0, 500)],
        };
        let mut sched = RtScheduler::new(&cfg);

        let _ts = sched.before_vcpu_enter(0, 0, 0);
        let decision = sched.after_vcpu_exit(0, 0, 300_000, 300_000);

        assert!(
            matches!(decision, SchedDecision::Continue { .. }),
            "single vCPU should continue, got {decision:?}"
        );
    }

    #[test]
    fn budget_exhausted_yields() {
        let cfg = RtSchedConfig {
            enabled: true,
            base_timeslice_us: 1000,
            vcpu_configs: vec![budget_config(500, 5000)],
        };
        let mut sched = RtScheduler::new(&cfg);

        // vCPU runs and consumes its full 500us budget.
        let _ts = sched.before_vcpu_enter(0, 0, 0);
        let decision = sched.after_vcpu_exit(0, 0, 500_000, 500_000);

        assert!(
            matches!(decision, SchedDecision::Yield),
            "budget-exhausted vCPU should yield, got {decision:?}"
        );
    }

    #[test]
    fn disabled_scheduler_returns_continue() {
        let cfg = RtSchedConfig {
            enabled: false,
            base_timeslice_us: 1000,
            vcpu_configs: vec![],
        };
        let mut sched = RtScheduler::new(&cfg);

        assert!(!sched.enabled());
        assert_eq!(sched.before_vcpu_enter(0, 0, 0), 0);

        let decision = sched.after_vcpu_exit(0, 0, 1_000_000, 1_000_000);
        assert!(matches!(decision, SchedDecision::Continue { .. }));
    }
}
