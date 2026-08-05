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

use alloc::format;

use crate::{
    AsVCpuTask, AxVmResult, GuestPhysAddr, StopReason, VCpuTask, VmStatus, VmVcpuState,
    arch::{ArchOps, CurrentArch, VcpuRunAction},
    ax_err_type,
    runtime::{VCpuRef, VMRef, sub_running_vm_count},
    vm::VmRuntimeHandle,
};

const KERNEL_STACK_SIZE: usize = 0x40000; // 256 KiB

/// Blocks the current thread until it is explicitly woken up, using the wait queue
/// associated with the VCpus of the specified VM.
///
/// # Arguments
///
/// * `vm_id` - The ID of the VM whose VCpu wait queue is used to block the current thread.
fn wait(vm_vcpus: &VmRuntimeHandle) {
    vm_vcpus.wait();
}

/// Blocks the current thread until the provided condition is met, using the wait queue
/// associated with the VCpus of the specified VM.
///
/// # Arguments
///
/// * `vm_id` - The ID of the VM whose VCpu wait queue is used to block the current thread.
/// * `condition` - A closure that returns a boolean value indicating whether the condition is met.
fn wait_for<F>(vm_vcpus: &VmRuntimeHandle, condition: F)
where
    F: Fn() -> bool,
{
    vm_vcpus.wait_until(condition);
}

/// Notifies the primary VCpu task associated with the specified VM to wake up and resume execution.
/// This function is used to notify the primary VCpu of a VM to start running after the VM has been booted.
///
/// # Arguments
///
/// * `vm_id` - The ID of the VM whose VCpus are to be notified.
pub(crate) fn notify_primary_vcpu(vm_id: usize) {
    // Generally, the primary VCpu is the first and **only** VCpu in the list.
    let Some(vm) = crate::get_vm_by_id(vm_id) else {
        warn!("VM[{vm_id}] not found while notifying primary vCPU");
        return;
    };
    if let Err(err) = vm.with_runtime(|runtime| {
        runtime.notify_one();
        Ok(())
    }) {
        warn!("VM[{vm_id}] vCPU runtime not found: {err:?}");
    }
}

/// Notifies all VCpu tasks associated with the specified VM to wake up.
/// This is useful when shutting down a VM to ensure all waiting vCPUs can check the shutdown flag.
///
/// # Arguments
///
/// * `vm_id` - The ID of the VM whose VCpus should be notified.
pub(crate) fn notify_all_vcpus(vm_id: usize) {
    if let Some(vm) = crate::get_vm_by_id(vm_id) {
        let _ = vm.with_runtime(|runtime| {
            runtime.notify_all();
            Ok(())
        });
    }
}

pub(crate) fn queue_interrupt(vm_id: usize, vcpu_id: usize, vector: usize) -> AxVmResult {
    let vm = crate::get_vm_by_id(vm_id)
        .ok_or_else(|| ax_err_type!(NotFound, format!("VM[{vm_id}] not found")))?;
    if !matches!(vm.status(), VmStatus::Running | VmStatus::Paused) {
        return Err(ax_err_type!(
            BadState,
            format!("VM[{vm_id}] is not accepting interrupts")
        ));
    }

    let cpu_id = vm.with_runtime(|runtime| runtime.queue_interrupt(vcpu_id, vector))?;
    vm.with_runtime(|runtime| {
        runtime.notify_all();
        Ok(())
    })?;
    crate::host::task::send_ipi(cpu_id);
    Ok(())
}

#[expect(
    dead_code,
    reason = "only the LoongArch IRQ backend queues physical interrupts"
)]
pub(crate) fn queue_external_interrupt(
    vm_id: usize,
    vcpu_id: usize,
    vector: usize,
    physical_irq: usize,
) -> AxVmResult {
    let vm = crate::get_vm_by_id(vm_id)
        .ok_or_else(|| ax_err_type!(NotFound, format!("VM[{vm_id}] not found")))?;
    if !matches!(vm.status(), VmStatus::Running | VmStatus::Paused) {
        return Err(ax_err_type!(
            BadState,
            format!("VM[{vm_id}] is not accepting interrupts")
        ));
    }

    let cpu_id =
        vm.with_runtime(|runtime| runtime.queue_external_interrupt(vcpu_id, vector, physical_irq))?;
    vm.with_runtime(|runtime| {
        runtime.notify_all();
        Ok(())
    })?;
    crate::host::task::send_ipi(cpu_id);
    Ok(())
}

pub(crate) fn inject_pending_interrupts<A: ArchOps>(
    vm_id: usize,
    vcpu_id: usize,
    vcpu: &crate::vm::AxVCpuRef<A::VCpu>,
) {
    let Some(vm) = crate::get_vm_by_id(vm_id) else {
        warn!("VM[{vm_id}] not found, cannot drain VCpu[{vcpu_id}] interrupts");
        return;
    };
    let Ok(interrupts) = vm.with_runtime(|runtime| Ok(runtime.drain_pending_interrupts(vcpu_id)))
    else {
        warn!("VM[{vm_id}] vCPU runtime not found, cannot drain VCpu[{vcpu_id}] interrupts");
        return;
    };

    for interrupt in interrupts {
        A::inject_pending_interrupt(&vm, vcpu, interrupt);
    }
}

/// Cleans up VCpu resources for a VM that is being deleted.
/// This removes the VM's entry from the global VCpu wait queue.
///
/// # Arguments
///
/// * `vm_id` - The ID of the VM whose VCpu resources should be cleaned up.
///
/// # Note
///
/// This should be called after all VCpu threads have exited to avoid resource leaks.
/// It will join all VCpu tasks to ensure they are fully cleaned up.
pub(crate) fn cleanup_vm_vcpus(vm_id: usize) {
    if let Some(vm) = crate::get_vm_by_id(vm_id)
        && let Err(err) = vm.with_runtime(|runtime| {
            runtime.join_all_vcpu_tasks(vm_id);
            Ok(())
        })
    {
        warn!("VM[{vm_id}] vCPU runtime cleanup skipped: {err:?}");
    }
}

/// Marks the VCpu of the specified VM as running.
fn mark_vcpu_running(vm: &VMRef) {
    let _ = vm.with_runtime(|runtime| {
        runtime.mark_vcpu_running();
        Ok(())
    });
}

/// Boot target VCpu on the specified VM.
/// This function is used to boot a secondary VCpu on a VM, setting the entry point and argument for the VCpu.
///
/// # Arguments
///
/// * `vm_id` - The ID of the VM on which the VCpu is to be booted.
/// * `vcpu_id` - The ID of the VCpu to be booted.
/// * `entry_point` - The entry point of the VCpu.
/// * `arg` - The argument to be passed to the VCpu.
#[expect(
    dead_code,
    reason = "only non-x86 guest firmware boots secondary vCPUs"
)]
pub(crate) fn vcpu_on(
    vm: VMRef,
    vcpu_id: usize,
    entry_point: GuestPhysAddr,
    arg: usize,
) -> AxVmResult {
    let vcpu = vm
        .vcpu_list()
        .get(vcpu_id)
        .cloned()
        .ok_or_else(|| ax_err_type!(NotFound, format!("vCPU {vcpu_id} not found")))?;
    if vcpu.state() != VmVcpuState::Free {
        return Err(ax_err_type!(
            BadState,
            format!("vCPU {} invalid state {:?}", vcpu.id(), vcpu.state())
        ));
    }

    vcpu.set_entry(entry_point)?;
    CurrentArch::set_vcpu_on_args(&vcpu, vcpu_id, arg);

    let vcpu_task = alloc_vcpu_task(&vm, vcpu);
    vm.with_runtime(|runtime| {
        runtime.add_vcpu_task(vcpu_id, vcpu_task);
        Ok(())
    })?;
    Ok(())
}

#[expect(
    dead_code,
    reason = "only non-x86 guest firmware boots secondary vCPUs"
)]
pub(crate) fn alloc_vcpu_task(vm: &VMRef, vcpu: VCpuRef) -> crate::AxTaskRef {
    crate::host::task::spawn_task(build_vcpu_task(vm, vcpu))
}

pub(crate) fn build_vcpu_task(vm: &VMRef, vcpu: VCpuRef) -> crate::TaskInner {
    info!("Spawning task for VM[{}] VCpu[{}]", vm.id(), vcpu.id());
    let mut vcpu_task = crate::TaskInner::new(
        vcpu_run,
        format!("VM[{}]-VCpu[{}]", vm.id(), vcpu.id()),
        KERNEL_STACK_SIZE,
    );

    if let Some(phys_cpu_set) = vcpu.phys_cpu_set() {
        vcpu_task.set_cpumask(crate::host::task::cpu_mask_from_raw_bits(
            vcpu_task_cpu_mask(vm.id(), vcpu.id(), phys_cpu_set),
        ));
    }

    // Use Weak reference in TaskExt to avoid keeping VM alive
    let inner = VCpuTask::new(vm, vcpu);
    *vcpu_task.task_ext_mut() = Some(crate::AxTaskExt::from_impl(inner));

    info!(
        "VCpu task {} created {:?}",
        vcpu_task.id_name(),
        vcpu_task.cpumask()
    );
    vcpu_task
}

fn vcpu_task_cpu_mask(vm_id: usize, vcpu_id: usize, requested_mask: usize) -> usize {
    let enabled_mask = crate::percpu::enabled_cpu_mask();
    if enabled_mask == 0 {
        warn!(
            "VM[{vm_id}] VCpu[{vcpu_id}] has no initialized host CPU mask; using requested mask \
             {requested_mask:#x}"
        );
        return requested_mask;
    }

    let initialized_requested_mask = requested_mask & enabled_mask;
    if initialized_requested_mask != 0 {
        if initialized_requested_mask != requested_mask {
            warn!(
                "VM[{vm_id}] VCpu[{vcpu_id}] requested host CPU mask {requested_mask:#x}, but \
                 only {initialized_requested_mask:#x} is initialized for AxVM"
            );
        }
        return initialized_requested_mask;
    }

    let fallback_mask = enabled_mask.isolate_lowest_one();
    warn!(
        "VM[{vm_id}] VCpu[{vcpu_id}] requested host CPU mask {requested_mask:#x}, but none of \
         those CPUs initialized AxVM; using initialized host CPU mask {fallback_mask:#x}"
    );
    fallback_mask
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum VcpuLoopControl {
    Continue,
    Break,
}

trait PostExitHostTask {
    fn wait_for_event(&mut self);
    fn suspend_if_requested(&mut self) -> bool;
    fn stop_if_requested(&mut self) -> bool;
    fn yield_now(&mut self);
}

fn dispatch_post_exit(
    waits_for_event: bool,
    host_vcpu_yield: bool,
    host_task: &mut impl PostExitHostTask,
) -> VcpuLoopControl {
    if waits_for_event {
        host_task.wait_for_event();
    }
    if host_task.suspend_if_requested() {
        return VcpuLoopControl::Continue;
    }
    if host_task.stop_if_requested() {
        return VcpuLoopControl::Break;
    }
    if host_vcpu_yield {
        host_task.yield_now();
    }
    VcpuLoopControl::Continue
}

struct AxVmPostExitHostTask<'a> {
    vm: &'a VMRef,
    runtime: &'a VmRuntimeHandle,
    vm_id: usize,
    vcpu_id: usize,
}

impl PostExitHostTask for AxVmPostExitHostTask<'_> {
    fn wait_for_event(&mut self) {
        wait(self.runtime);
    }

    fn suspend_if_requested(&mut self) -> bool {
        if !self.vm.suspending() {
            return false;
        }

        debug!(
            "VM[{}] VCpu[{}] is suspended, waiting for resume...",
            self.vm_id, self.vcpu_id
        );
        wait_for(self.runtime, || !self.vm.suspending());
        info!(
            "VM[{}] VCpu[{}] resumed from suspend",
            self.vm_id, self.vcpu_id
        );
        true
    }

    fn stop_if_requested(&mut self) -> bool {
        if !self.vm.stopping() {
            return false;
        }

        warn!(
            "VM[{}] VCpu[{}] stopping because of VM stopping",
            self.vm_id, self.vcpu_id
        );
        if self.runtime.mark_vcpu_exiting() {
            info!(
                "VM[{}] VCpu[{}] last VCpu exiting, decreasing running VM count",
                self.vm_id, self.vcpu_id
            );

            if let Err(err) = self.vm.finish_stop() {
                warn!("VM[{}] finish stop failed: {err:?}", self.vm_id);
            }
            info!("VM[{}] state changed to Stopped", self.vm_id);

            CurrentArch::on_last_vcpu_exit(self.vm);

            sub_running_vm_count(1);
            crate::host::task::wait_queue_wake(&super::VMM, 1);
        }
        true
    }

    fn yield_now(&mut self) {
        crate::host::task::yield_now();
    }
}

/// The main routine for VCpu task.
/// This function is the entry point for the VCpu tasks, which are spawned for each VCpu of a VM.
///
/// When the VCpu first starts running, it waits for the VM to be in the running state.
/// It then enters a loop where it runs the VCpu and handles the various exit reasons.
fn vcpu_run() {
    let curr = crate::host::task::current_task();

    let vm = curr.as_vcpu_task().vm();
    let vcpu = curr.as_vcpu_task().vcpu.clone();
    let vm_id = vm.id();
    let vcpu_id = vcpu.id();
    let Ok(runtime) = vm.with_runtime(|runtime| Ok(runtime.clone())) else {
        warn!("VM[{vm_id}] vCPU runtime not found, VCpu[{vcpu_id}] exiting");
        return;
    };

    info!("VM[{}] VCpu[{}] waiting for running", vm.id(), vcpu.id());
    wait_for(&runtime, || vm.running());

    info!("VM[{}] VCpu[{}] running...", vm.id(), vcpu.id());
    CurrentArch::before_first_run(&vm, &vcpu);
    mark_vcpu_running(&vm);

    loop {
        CurrentArch::before_vcpu_run(&vm, &vcpu);

        let run_result = crate::runtime::run_vcpu_with_host_timer_policy(&vm, || {
            CurrentArch::run_vcpu(&vm, &vcpu)
        });
        let waits_for_event = match run_result {
            Ok(VcpuRunAction {
                stop_reason: Some(reason),
                ..
            }) => {
                if let Err(err) = vm.stop(reason) {
                    warn!("VM[{vm_id}] shutdown failed: {err:?}");
                }
                notify_all_vcpus(vm_id);
                false
            }
            Ok(VcpuRunAction {
                waits_for_event: true,
                ..
            }) => true,
            Ok(VcpuRunAction { .. }) => false,
            Err(err) => {
                error!("VM[{vm_id}] run VCpu[{vcpu_id}] get error {err:?}");
                if let Err(err) = vm.stop(StopReason::Fault(format!("{err:?}"))) {
                    warn!("VM[{vm_id}] shutdown failed after vCPU error: {err:?}");
                }
                // Notify all vCPUs to wake up to check the shutdown flag
                notify_all_vcpus(vm_id);
                false
            }
        };

        let host_vcpu_yield = vm.with_config(|config| config.host_vcpu_yield());
        let mut host_task = AxVmPostExitHostTask {
            vm: &vm,
            runtime: &runtime,
            vm_id,
            vcpu_id,
        };
        match dispatch_post_exit(waits_for_event, host_vcpu_yield, &mut host_task) {
            VcpuLoopControl::Continue => {}
            VcpuLoopControl::Break => break,
        }
    }

    info!("VM[{}] VCpu[{}] exiting...", vm_id, vcpu_id);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct RecordingPostExitHostTask {
        suspending: bool,
        stopping: bool,
        yield_count: usize,
        events: alloc::vec::Vec<&'static str>,
    }

    impl PostExitHostTask for RecordingPostExitHostTask {
        fn wait_for_event(&mut self) {
            self.events.push("wait");
        }

        fn suspend_if_requested(&mut self) -> bool {
            self.events.push("suspend_check");
            if self.suspending {
                self.events.push("suspend");
            }
            self.suspending
        }

        fn stop_if_requested(&mut self) -> bool {
            self.events.push("stop_check");
            if self.stopping {
                self.events.push("stop");
            }
            self.stopping
        }

        fn yield_now(&mut self) {
            self.events.push("yield");
            self.yield_count += 1;
        }
    }

    #[test]
    fn post_exit_dispatch_continues_without_yield_when_disabled() {
        let mut host = RecordingPostExitHostTask::default();

        assert_eq!(
            dispatch_post_exit(false, false, &mut host),
            VcpuLoopControl::Continue
        );
        assert_eq!(host.events, ["suspend_check", "stop_check"]);
        assert_eq!(host.yield_count, 0);
    }

    #[test]
    fn post_exit_dispatch_yields_once_after_state_checks() {
        let mut host = RecordingPostExitHostTask::default();

        assert_eq!(
            dispatch_post_exit(false, true, &mut host),
            VcpuLoopControl::Continue
        );
        assert_eq!(host.events, ["suspend_check", "stop_check", "yield"]);
        assert_eq!(host.yield_count, 1);
    }

    #[test]
    fn post_exit_dispatch_waits_before_optional_yield() {
        let mut host = RecordingPostExitHostTask::default();

        assert_eq!(
            dispatch_post_exit(true, true, &mut host),
            VcpuLoopControl::Continue
        );
        assert_eq!(
            host.events,
            ["wait", "suspend_check", "stop_check", "yield"]
        );
        assert_eq!(host.yield_count, 1);
    }

    #[test]
    fn post_exit_dispatch_suspend_consumes_control_before_stop_and_yield() {
        let mut host = RecordingPostExitHostTask {
            suspending: true,
            ..Default::default()
        };

        assert_eq!(
            dispatch_post_exit(false, true, &mut host),
            VcpuLoopControl::Continue
        );
        assert_eq!(host.events, ["suspend_check", "suspend"]);
        assert_eq!(host.yield_count, 0);
    }

    #[test]
    fn post_exit_dispatch_stop_breaks_before_optional_yield() {
        let mut host = RecordingPostExitHostTask {
            stopping: true,
            ..Default::default()
        };

        assert_eq!(
            dispatch_post_exit(false, true, &mut host),
            VcpuLoopControl::Break
        );
        assert_eq!(host.events, ["suspend_check", "stop_check", "stop"]);
        assert_eq!(host.yield_count, 0);
    }
}
