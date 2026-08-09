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

//! Per-vCPU scheduler statistics used for RT performance monitoring.

use core::time::Duration;

/// Aggregated runtime statistics for one vCPU.
#[derive(Debug, Default, Clone)]
pub struct VcpuSchedStats {
    /// Total nanoseconds the vCPU spent in the guest.
    pub total_guest_ns: u64,
    /// Total nanoseconds the vCPU spent idle (blocked/waiting).
    pub total_idle_ns: u64,
    /// Number of times this vCPU was preempted by the scheduler.
    pub preemption_count: u64,
    /// Number of VM exits since creation.
    pub exit_count: u64,
    /// Cumulative time (ns) between `queue_interrupt` and actual injection.
    /// Divide by `interrupt_count` for average latency.
    pub cumulative_interrupt_latency_ns: u64,
    /// Number of interrupts injected.
    pub interrupt_count: u64,
    /// Cumulative time (ns) from preemption decision to context switch.
    /// Divide by `sched_switch_count` for average scheduling latency.
    pub cumulative_sched_latency_ns: u64,
    /// Number of scheduling context switches.
    pub sched_switch_count: u64,
}

impl VcpuSchedStats {
    /// Returns the average interrupt injection latency, or `None` if no
    /// interrupts have been recorded.
    pub fn avg_interrupt_latency(&self) -> Option<Duration> {
        if self.interrupt_count == 0 {
            None
        } else {
            Some(Duration::from_nanos(
                self.cumulative_interrupt_latency_ns / self.interrupt_count,
            ))
        }
    }

    /// Returns the average scheduling latency, or `None` if no context
    /// switches have been recorded.
    pub fn avg_sched_latency(&self) -> Option<Duration> {
        if self.sched_switch_count == 0 {
            None
        } else {
            Some(Duration::from_nanos(
                self.cumulative_sched_latency_ns / self.sched_switch_count,
            ))
        }
    }

    /// Records one interrupt injection with the given latency.
    pub fn record_interrupt(&mut self, latency_ns: u64) {
        self.interrupt_count = self.interrupt_count.saturating_add(1);
        self.cumulative_interrupt_latency_ns =
            self.cumulative_interrupt_latency_ns.saturating_add(latency_ns);
    }

    /// Records one scheduling context switch with the given latency.
    pub fn record_sched_switch(&mut self, latency_ns: u64) {
        self.sched_switch_count = self.sched_switch_count.saturating_add(1);
        self.cumulative_sched_latency_ns =
            self.cumulative_sched_latency_ns.saturating_add(latency_ns);
    }
}
