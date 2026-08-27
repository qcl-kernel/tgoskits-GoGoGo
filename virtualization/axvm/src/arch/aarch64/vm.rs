//! AArch64 VM resource creation and initialization.

#[cfg(target_arch = "aarch64")]
use std::{sync::Arc, vec::Vec};

#[cfg(target_arch = "aarch64")]
use arm_vcpu::{ArmTimerVmConfig, ArmVcpuCreateConfig, ArmVcpuSetupConfig, ArmVcpuTlbiPolicy};
#[cfg(target_arch = "aarch64")]
use axvm_types::NestedPagingConfig;

#[cfg(target_arch = "aarch64")]
use super::*;
#[cfg(target_arch = "aarch64")]
use crate::{
    AxVmError, AxVmResult, ax_err,
    config::*,
    machine::*,
    vm::{
        prepare::{devices::*, vcpus::*, *},
        *,
    },
};

#[cfg(target_arch = "aarch64")]
impl Aarch64Arch {
    pub(crate) fn create_vm_resources(
        config: &mut AxVMConfig,
        _fw_cfg_payload: Arc<axdevice::FwCfgPayloadSlot>,
    ) -> AxVmResult<AxVMResources> {
        let device_plan = Aarch64VmPlan::new(config)?;
        let placements = config.phys_cpu_ls.get_vcpu_affinities_pcpu_ids();
        let levels = guest_page_table_levels(&placements)?;
        let page_table = npt::NestedPageTable::new(levels)?;
        AxVMResources::from_page_table(config.id(), page_table, device_plan, |root_paddr| {
            nested_paging_config(root_paddr, levels, &placements)
        })
    }

    pub(crate) fn init_vm(vm: &AxVM) -> AxVmResult {
        vm.prepare_resources_with(|resources, config| {
            let vcpu_mappings = config.phys_cpu_ls.get_vcpu_affinities_pcpu_ids();
            let placements = resources.vcpu_placements(config);
            let timer_profile = config.timer_profile().cloned().ok_or_else(|| {
                AxVmError::invalid_config("AArch64 machine profile has no architectural timer")
            })?;
            let timer_config = timer_vm_config(&timer_profile, &vcpu_mappings)?;
            let guest_tlbi_policy = config.guest_tlbi_policy();
            // The busy idle policy currently only feeds the WFI fastpath,
            // which is disabled above; keep reading the policy so config
            // mistakes (e.g. `busy` on unsupported arches) still surface.
            #[allow(clippy::let_underscore_untyped)]
            let _busy_wfi_fastpath =
                config.host_vcpu_idle_policy() == HostVcpuIdlePolicy::Busy;
            if guest_tlbi_policy == GuestTlbiPolicy::VmScoped {
                super::tlbi::vm_pcpu_mask(&vcpu_mappings).map_err(|error| {
                    AxVmError::invalid_config(std::format!(
                        "VM-scoped AArch64 TLBI requires bounded vCPU affinity: {error:?}"
                    ))
                })?;
            }
            let vcpu_tlbi_policy = arm_tlbi_policy(guest_tlbi_policy);
            let host_irq_config = super::gic::host_irq_config()
                .map_err(|error| AxVmError::interrupt("discover host IRQ CPU interface", error))?;
            let dtb_addr = config.image_config().dtb_load_gpa.unwrap_or_default();
            let vcpus = PreparedVcpus::create(vm.id(), &placements, |placement| {
                Ok(ArmVcpuCreateConfig {
                    mpidr_el1: placement.phys_cpu_id as _,
                    dtb_addr: dtb_addr.as_usize(),
                })
            })?;
            let devices = PreparedDevices::build_planned(resources, vm.device_access_ports())?;
            let vgic_runtime = devices
                .devices()
                .services()
                .require::<Aarch64VgicRuntimeKey>()?;
            for vcpu in &vcpus {
                let binding = vgic_runtime
                    .attach_vcpu(vcpu.id(), &timer_profile)
                    .map_err(|error| {
                        crate::AxVmError::interrupt("attach vCPU to virtual GIC", error)
                    })?;
                vcpu.get_arch_vcpu().attach_vgic(
                    vgic_runtime.core().clone(),
                    binding,
                    timer_config,
                )?;
            }

            resources.prepare_guest_address_space(vm.id(), config, &[])?;
            vcpus.setup(resources, config, move |_config, _memory_regions| {
                Ok(ArmVcpuSetupConfig::with_runtime_policies(
                    timer_config,
                    host_irq_config,
                    vcpu_tlbi_policy,
                    // The busy WFI fastpath skips the EL2 exit entirely, so a
                    // guest that goes idle never re-enters the inject loop and
                    // its timer PPI stays pending on hardware GICv2 boards.
                    // Take the regular WFI exit (host waits for the timer
                    // event) until the fastpath learns to keep the guest
                    // timer directly loaded under the unified host-timer
                    // ownership model.
                    false,
                ))
            })?;

            let interrupt_controller: Arc<dyn axdevice_base::VirtualInterruptController> =
                vgic_runtime.core().clone();
            Ok(PreparedVm::new(vcpus, devices, interrupt_controller))
        })
    }
}

#[cfg(target_arch = "aarch64")]
const fn arm_tlbi_policy(policy: GuestTlbiPolicy) -> ArmVcpuTlbiPolicy {
    match policy {
        GuestTlbiPolicy::Native => ArmVcpuTlbiPolicy::Native,
        GuestTlbiPolicy::VmScoped => ArmVcpuTlbiPolicy::TrapEl1,
    }
}

#[cfg(target_arch = "aarch64")]
fn guest_page_table_levels(vcpu_mappings: &[(usize, Option<usize>, usize)]) -> AxVmResult<usize> {
    let selected = crate::architecture::minimum_recorded_target_cpu_capability(
        "AArch64 stage-2 page-table levels",
        vcpu_mappings,
        |cpu_id| {
            crate::percpu::select_cpu_virtualization_capability(cpu_id, |levels, _, _| {
                levels as u64
            })
        },
    )
    .map_err(|error| {
        crate::architecture::unsupported_target_cpu_capability(
            "select AArch64 target CPU capability",
            error,
        )
    })? as usize;
    match selected {
        0 => ax_err!(
            Unsupported,
            "AArch64 nested paging is not enabled on target CPU"
        ),
        3 | 4 => Ok(selected),
        _ => ax_err!(Unsupported, "unsupported AArch64 stage-2 page-table levels"),
    }
}

#[cfg(target_arch = "aarch64")]
fn nested_paging_config(
    root_paddr: ax_memory_addr::PhysAddr,
    levels: usize,
    vcpu_mappings: &[(usize, Option<usize>, usize)],
) -> AxVmResult<NestedPagingConfig> {
    let pa_bits = crate::architecture::minimum_recorded_target_cpu_capability(
        "AArch64 physical-address width",
        vcpu_mappings,
        |cpu_id| {
            crate::percpu::select_cpu_virtualization_capability(cpu_id, |_, pa_bits, _| {
                pa_bits as u64
            })
        },
    )
    .map_err(|error| {
        crate::architecture::unsupported_target_cpu_capability(
            "select AArch64 target CPU capability",
            error,
        )
    })? as usize;

    let gpa_bits = match levels {
        3 => 39,
        4 => 48,
        _ => return ax_err!(InvalidInput, "unsupported AArch64 stage-2 levels"),
    };
    Ok(NestedPagingConfig::new(
        root_paddr, levels, gpa_bits, pa_bits,
    ))
}

#[cfg(target_arch = "aarch64")]
fn timer_vm_config(
    profile: &GuestTimerProfile,
    vcpu_mappings: &[(usize, Option<usize>, usize)],
) -> AxVmResult<ArmTimerVmConfig> {
    let target_frequencies = crate::architecture::capabilities::recorded_target_cpu_capabilities(
        "AArch64 architectural counter frequency",
        vcpu_mappings,
        |cpu_id| {
            crate::percpu::select_cpu_virtualization_capability(cpu_id, |_, _, frequency| frequency)
                .flatten()
        },
    )
    .map_err(|error| {
        crate::architecture::unsupported_target_cpu_capability(
            "select AArch64 target CPU capability",
            error,
        )
    })?;
    let frequency_values = target_frequencies
        .iter()
        .map(|(_, frequency)| *frequency)
        .collect::<Vec<_>>();
    let hardware_frequency =
        ArmTimerVmConfig::uniform_frequency(&frequency_values).map_err(|_| {
            AxVmError::unsupported(
                "configure AArch64 architectural timers",
                std::format!(
                    "target CPUs report different counter frequencies: {target_frequencies:?}"
                ),
            )
        })?;
    let guest_frequency = profile
        .clock_frequency_hz
        .map(u64::from)
        .unwrap_or(hardware_frequency);
    ArmTimerVmConfig::new(guest_frequency, super::vtimer::physical_counter(), 0).map_err(|error| {
        AxVmError::unsupported(
            "configure AArch64 architectural timers",
            std::format!("{error:?}"),
        )
    })
}

#[cfg(all(test, target_arch = "aarch64"))]
mod tests {
    use arm_vcpu::ArmVcpuTlbiPolicy;
    use axvmconfig::GuestTlbiPolicy;

    use super::arm_tlbi_policy;

    #[test]
    fn vm_scoped_is_the_only_policy_that_traps_el1_tlbi() {
        assert_eq!(
            arm_tlbi_policy(GuestTlbiPolicy::Native),
            ArmVcpuTlbiPolicy::Native
        );
        assert_eq!(
            arm_tlbi_policy(GuestTlbiPolicy::VmScoped),
            ArmVcpuTlbiPolicy::TrapEl1
        );
    }
}
