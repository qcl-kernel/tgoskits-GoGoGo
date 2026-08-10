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

#[cfg(all(
    feature = "fs",
    any(
        target_arch = "aarch64",
        target_arch = "x86_64",
        target_arch = "loongarch64"
    )
))]
use core::sync::atomic::{AtomicBool, Ordering};

use anyhow::{Context, Result, bail};
#[cfg(feature = "fs")]
use axvm::{AxVmError, AxVmResult};
use axvm::{boot::*, config::*, *};
use axvm_types::CpuIsolationConfig;
use axvmconfig::{AxVMCrateConfig, GuestConfig, GuestType, HostDeviceAssignment, VMType};

#[cfg(all(
    feature = "fs",
    any(
        target_arch = "aarch64",
        target_arch = "x86_64",
        target_arch = "loongarch64"
    )
))]
static HOST_FILESYSTEM_RELEASE_REQUIRED: AtomicBool = AtomicBool::new(false);

#[allow(dead_code)]
pub mod vmcfg {
    use alloc::{string::String, vec, vec::Vec};

    /// Default static VM configs. Used when no VM config is provided.
    pub fn default_static_vm_configs() -> Vec<&'static str> {
        vec![]
    }

    /// Read VM configs from filesystem
    #[cfg(feature = "fs")]
    pub fn filesystem_vm_configs() -> Vec<String> {
        let config_dir = "/guest/vm_default";
        crate::manager::AxvmManager::filesystem_vm_configs(config_dir)
            .into_iter()
            .filter_map(
                |content| match axvmconfig::GuestConfig::from_toml(&content) {
                    Ok(_) => Some(content),
                    Err(e) => {
                        warn!("Filesystem VM config is invalid: {:?}", e);
                        None
                    }
                },
            )
            .collect()
    }

    /// Fallback function for when "fs" feature is not enabled
    #[cfg(not(feature = "fs"))]
    pub fn filesystem_vm_configs() -> Vec<String> {
        Vec::new()
    }

    include!(concat!(env!("OUT_DIR"), "/vm_configs.rs"));
}

pub fn init_guest_vms() {
    init_guest_boot_resources();

    // First try to get configs from filesystem if fs feature is enabled
    let mut gvm_raw_configs = vmcfg::filesystem_vm_configs();

    // If no filesystem configs found, fallback to static configs
    if gvm_raw_configs.is_empty() {
        let static_configs = vmcfg::static_vm_configs();
        if static_configs.is_empty() {
            info!("Static VM configs are empty.");
            info!("Now axvisor will entry the shell...");
        } else {
            info!("Using static VM configs.");
        }
        // Convert static configs to String type
        gvm_raw_configs.extend(static_configs.into_iter().map(|s| s.into()));
    }

    for raw_cfg_str in gvm_raw_configs {
        debug!("Initializing guest VM with config: {:#?}", raw_cfg_str);
        if let Err(e) = init_guest_vm(&raw_cfg_str) {
            error!("Failed to initialize guest VM: {e:#}");
        }
    }
}

pub fn init_guest_vm(raw_cfg: &str) -> Result<usize> {
    let image_provider = AxvisorBootImageProvider;
    let vm_create_config =
        GuestConfig::from_toml(raw_cfg).context("parse VM TOML configuration")?;
    let configured_vm_id = vm_create_config.base.id;

    #[cfg(all(
        feature = "fs",
        any(
            target_arch = "aarch64",
            target_arch = "x86_64",
            target_arch = "loongarch64"
        )
    ))]
    let release_host_filesystem = vm_config_needs_host_filesystem_release(&vm_create_config);

    if let Some(linux) = get_image_header(&vm_create_config, &image_provider) {
        debug!(
            "VM[{}] Linux header: {:#x?}",
            vm_create_config.base.id, linux
        );
    }

    let mut vm_config = build_axvm_config(&vm_create_config);
    let prepared_boot = prepare_guest_boot(&mut vm_config, vm_create_config, &image_provider)
        .with_context(|| format!("prepare boot resources for VM[{configured_vm_id}]"))?;
    let prepared_config = prepared_boot.config();

    sync_axvm_config_from_crate_config(&mut vm_config, prepared_config);

    vm_config.set_boot_policy(guest_boot_policy(prepared_config, &image_provider));

    // info!("after parse_vm_interrupt, crate VM[{}] with config: {:#?}", vm_config.id(), vm_config);
    info!("Creating VM[{}] {:?}", vm_config.id(), vm_config.name());

    // Create VM.
    let vm = AxVM::new(vm_config).with_context(|| format!("create VM[{configured_vm_id}]"))?;
    let vm_id = vm.id();

    let memory_layout = vm
        .prepare_memory_layout()
        .with_context(|| format!("prepare memory layout for VM[{vm_id}]"))?;
    let main_mem = memory_layout.main_memory().clone();

    // Load corresponding images for VM.
    info!("VM[{}] created success, loading images...", vm.id());

    prepared_boot
        .load_images(main_mem, vm.clone(), &image_provider)
        .with_context(|| format!("load boot images for VM[{vm_id}]"))?;

    vm.prepare()
        .with_context(|| format!("prepare devices and vCPUs for VM[{vm_id}]"))?;

    // Keep the local `Arc` for architecture-specific post-registration setup.
    if !axvm::register_vm(vm.clone()) {
        bail!("register VM[{vm_id}]: a VM with this ID already exists");
    }
    #[cfg(target_arch = "loongarch64")]
    crate::manager::register_loongarch_passthrough_irq_routes(vm_id);

    #[cfg(all(
        feature = "fs",
        any(
            target_arch = "aarch64",
            target_arch = "x86_64",
            target_arch = "loongarch64"
        )
    ))]
    if release_host_filesystem {
        #[cfg(target_arch = "x86_64")]
        axvm::host::x86::register_qemu_block_passthrough_irq(&vm)
            .context("register x86 QEMU block passthrough IRQ route")?;
        HOST_FILESYSTEM_RELEASE_REQUIRED.store(true, Ordering::Release);
    }

    Ok(vm_id)
}

pub(crate) fn build_axvm_config(cfg: &GuestConfig) -> AxVMConfig {
    let machine = axvm::machine::current_machine_profile(cfg.base.cpu_num);
    let serial_profile = machine.serial;
    let mut passthrough_devices = cfg.devices.unresolved_host_devices();
    if cfg.base.guest_type == GuestType::Passthrough
        && let Some(path) = machine.default_passthrough_device_path
    {
        passthrough_devices.insert(
            0,
            HostDeviceAssignment {
                name: path.into(),
                ..Default::default()
            },
        );
    }
    AxVMConfig::new(AxVMConfigParams {
        id: cfg.base.id,
        name: cfg.base.name.clone(),
        phys_cpu_ls: PhysCpuList::new(
            cfg.base.cpu_num,
            cfg.base.phys_cpu_ids.clone(),
            cfg.base.phys_cpu_sets.clone(),
        ),
        cpu_config: AxVCpuConfig {
            bsp_entry: GuestPhysAddr::from(cfg.kernel.entry_point),
            ap_entry: GuestPhysAddr::from(cfg.kernel.entry_point),
        },
        image_config: VMImageConfig {
            kernel_load_gpa: GuestPhysAddr::from(cfg.kernel.kernel_load_addr),
            loaded_from_filesystem: cfg.kernel.image_location.as_deref() == Some("fs"),
            bios_load_gpa: boot_firmware_load_gpa(cfg),
            dtb_load_gpa: cfg.kernel.dtb_load_addr.map(GuestPhysAddr::from),
            ramdisk: cfg.kernel.ramdisk_load_addr.map(|addr| RamdiskInfo {
                load_gpa: GuestPhysAddr::from(addr),
                size: None,
            }),
        },
        pass_through_devices: passthrough_devices,
        excluded_devices: cfg.devices.disabled_device_paths(),
        pass_through_addresses: Vec::new(),
        reserved_address_ranges: Vec::new(),
        pass_through_ports: Vec::new(),
        address_space_policy: cfg.base.guest_type.address_space_policy(),
        memory_regions: cfg.kernel.memory_regions.clone(),
        boot_policy: GuestBootPolicy::KeepConfigured,
        serial_profile: Some(serial_profile),
        serial_backend_factory: Some(crate::guest_console::serial_backend_factory(cfg.base.id)),
        virtual_device_requests: cfg.devices.virtual_devices.clone(),
        virtual_device_catalog: Some(alloc::sync::Arc::new(axvm::ConfiguredDeviceCatalog::new())),
        interrupt_mode: cfg.devices.interrupt_mode,
        rt_sched_config: cfg
            .scheduling
            .as_ref()
            .map(|sched| sched.clone().into()),
        cpu_isolation: cfg.scheduling.as_ref().and_then(|sched| {
            sched.reserved_cpus.as_ref().map(|cpus| {
                if sched.disable_housekeeping {
                    warn!(
                        "VM[{}] CPU isolation: disable_housekeeping is configured but not yet \
                         enforced; host housekeeping tasks may still run on reserved CPUs {:?}",
                        cfg.base.id, cpus
                    );
                }
                info!(
                    "VM[{}] CPU isolation active: reserved CPUs {:?}, housekeeping {}",
                    cfg.base.id,
                    cpus,
                    if sched.disable_housekeeping { "suppressed (not yet enforced)" } else { "permitted" }
                );
                CpuIsolationConfig {
                    reserved_cpus: cpus.clone(),
                    disable_housekeeping: sched.disable_housekeeping,
                }
            })
        }),
    })
}

fn sync_axvm_config_from_crate_config(vm_config: &mut AxVMConfig, cfg: &GuestConfig) {
    vm_config.set_memory_regions(cfg.kernel.memory_regions.clone());
}

#[cfg(all(
    feature = "fs",
    any(
        target_arch = "aarch64",
        target_arch = "x86_64",
        target_arch = "loongarch64"
    )
))]
fn vm_config_needs_host_filesystem_release(config: &GuestConfig) -> bool {
    config.kernel.image_location.as_deref() == Some("fs")
        && (config.base.guest_type == GuestType::Passthrough
            || !config.devices.passthrough.is_empty())
}

#[cfg(all(
    feature = "fs",
    any(
        target_arch = "aarch64",
        target_arch = "x86_64",
        target_arch = "loongarch64"
    )
))]
pub fn host_filesystem_release_required() -> bool {
    HOST_FILESYSTEM_RELEASE_REQUIRED.load(Ordering::Acquire)
}

struct AxvisorBootImageProvider;

impl BootImageProvider for AxvisorBootImageProvider {
    fn static_vm_images(&self) -> &'static [StaticVmImage] {
        vmcfg::get_memory_images()
    }

    #[cfg(target_arch = "loongarch64")]
    fn static_firmware_images(&self) -> &'static [StaticVmImage] {
        vmcfg::get_firmware_images()
    }

    #[cfg(feature = "fs")]
    fn read_file(&self, file_name: &str) -> AxVmResult<alloc::vec::Vec<u8>> {
        crate::manager::AxvmManager::read_file(file_name)
            .map_err(|error| boot_file_error("read guest image file", file_name, error))
    }

    #[cfg(feature = "fs")]
    fn read_file_exact(
        &self,
        file_name: &str,
        read_size: usize,
    ) -> AxVmResult<alloc::vec::Vec<u8>> {
        crate::manager::AxvmManager::read_file_exact(file_name, read_size)
            .map_err(|error| boot_file_error("read guest image file", file_name, error))
    }

    #[cfg(feature = "fs")]
    fn file_size(&self, file_name: &str) -> AxVmResult<usize> {
        crate::manager::AxvmManager::file_size(file_name)
            .map_err(|error| boot_file_error("inspect guest image file", file_name, error))
    }
}

#[cfg(feature = "fs")]
fn boot_file_error(operation: &'static str, file_name: &str, error: anyhow::Error) -> AxVmError {
    AxVmError::Boot {
        operation,
        detail: format!("`{file_name}`: {error:#}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axvmconfig::{VmMemConfig, VmMemMappingType};

    fn memory_region(gpa: usize, size: usize, map_type: VmMemMappingType) -> VmMemConfig {
        VmMemConfig {
            gpa,
            size,
            flags: 0x7,
            map_type,
        }
    }

    fn rt_sched_toml(enabled: bool, priority0: u8, priority1: u8) -> String {
        format!(
            r#"
            [base]
            id = 1
            name = "rt-test"
            vm_type = 1
            cpu_num = 2

            [kernel]
            entry_point = 0x80200000
            kernel_path = "kernel.bin"
            kernel_load_addr = 0x80200000
            image_location = "memory"
            memory_regions = [[0x80000000, 0x10000000, 0x7, 1]]

            [devices]
            interrupt_mode = "passthrough"

            [scheduling]
            enabled = {enabled}
            base_timeslice_us = 500
            reserved_cpus = [0, 1]

            [[scheduling.vcpu_configs]]
            policy = "fixed_priority"
            priority = {priority0}
            max_timeslice_us = 200

            [[scheduling.vcpu_configs]]
            policy = "fixed_priority"
            priority = {priority1}
            max_timeslice_us = 1000
            "#
        )
    }

    #[test]
    fn rt_scheduling_enabled_when_scheduling_section_present() {
        let raw = rt_sched_toml(true, 0, 10);
        let crate_config = AxVMCrateConfig::from_toml(&raw).unwrap();
        let vm_config = build_axvm_config(&crate_config);

        assert!(vm_config.rt_scheduling_enabled());
        let rt = vm_config.rt_sched_config().unwrap();
        assert!(rt.enabled);
        assert_eq!(rt.base_timeslice_us, 500);
        assert_eq!(rt.vcpu_configs.len(), 2);
        assert_eq!(rt.vcpu_configs[0].policy, axvm::RtSchedPolicy::FixedPriority);
        assert_eq!(
            rt.vcpu_configs[0].priority.as_ref().unwrap().priority,
            0
        );
        assert_eq!(
            rt.vcpu_configs[1].priority.as_ref().unwrap().priority,
            10
        );
    }

    #[test]
    fn rt_scheduling_disabled_when_scheduling_section_absent() {
        let raw = r#"
            [base]
            id = 1
            name = "no-rt"
            vm_type = 1
            cpu_num = 1

            [kernel]
            entry_point = 0x80200000
            kernel_path = "kernel.bin"
            kernel_load_addr = 0x80200000
            image_location = "memory"
            memory_regions = [[0x80000000, 0x10000000, 0x7, 1]]

            [devices]
            interrupt_mode = "passthrough"
        "#;
        let crate_config = AxVMCrateConfig::from_toml(raw).unwrap();
        let vm_config = build_axvm_config(&crate_config);

        assert!(!vm_config.rt_scheduling_enabled());
        assert!(vm_config.rt_sched_config().is_none());
    }

    #[test]
    fn rt_scheduling_disabled_explicitly() {
        let raw = rt_sched_toml(false, 0, 10);
        let crate_config = AxVMCrateConfig::from_toml(&raw).unwrap();
        let vm_config = build_axvm_config(&crate_config);

        assert!(!vm_config.rt_scheduling_enabled());
        let rt = vm_config.rt_sched_config().unwrap();
        assert!(!rt.enabled);
    }

    #[test]
    fn cpu_isolation_configured_when_reserved_cpus_present() {
        let raw = rt_sched_toml(true, 0, 10);
        let crate_config = AxVMCrateConfig::from_toml(&raw).unwrap();
        let vm_config = build_axvm_config(&crate_config);

        let iso = vm_config.cpu_isolation().unwrap();
        assert_eq!(iso.reserved_cpus, vec![0, 1]);
        assert_eq!(vm_config.reserved_cpu_mask(), 0b11);
    }

    #[test]
    fn cpu_isolation_absent_when_scheduling_absent() {
        let raw = r#"
            [base]
            id = 1
            name = "no-iso"
            vm_type = 1
            cpu_num = 1

            [kernel]
            entry_point = 0x80200000
            kernel_path = "kernel.bin"
            kernel_load_addr = 0x80200000
            image_location = "memory"
            memory_regions = [[0x80000000, 0x10000000, 0x7, 1]]

            [devices]
            interrupt_mode = "passthrough"
        "#;
        let crate_config = AxVMCrateConfig::from_toml(raw).unwrap();
        let vm_config = build_axvm_config(&crate_config);

        assert!(vm_config.cpu_isolation().is_none());
        assert_eq!(vm_config.reserved_cpu_mask(), 0);
    }

    #[test]
    fn budget_scheduling_config_parses() {
        let raw = r#"
            [base]
            id = 2
            name = "budget-test"
            vm_type = 1
            cpu_num = 1

            [kernel]
            entry_point = 0x80200000
            kernel_path = "kernel.bin"
            kernel_load_addr = 0x80200000
            image_location = "memory"
            memory_regions = [[0x80000000, 0x10000000, 0x7, 1]]

            [devices]
            interrupt_mode = "passthrough"

            [scheduling]
            enabled = true
            base_timeslice_us = 1000

            [[scheduling.vcpu_configs]]
            policy = "budget"
            budget_us = 500
            period_us = 5000
        "#;
        let crate_config = AxVMCrateConfig::from_toml(raw).unwrap();
        let vm_config = build_axvm_config(&crate_config);

        assert!(vm_config.rt_scheduling_enabled());
        let rt = vm_config.rt_sched_config().unwrap();
        assert_eq!(rt.vcpu_configs.len(), 1);
        assert_eq!(rt.vcpu_configs[0].policy, axvm::RtSchedPolicy::Budget);
        let budget = rt.vcpu_configs[0].budget.as_ref().unwrap();
        assert_eq!(budget.budget_us, 500);
        assert_eq!(budget.period_us, 5000);
    }

    #[test]
    fn deadline_scheduling_config_parses() {
        let raw = r#"
            [base]
            id = 3
            name = "deadline-test"
            vm_type = 1
            cpu_num = 1

            [kernel]
            entry_point = 0x80200000
            kernel_path = "kernel.bin"
            kernel_load_addr = 0x80200000
            image_location = "memory"
            memory_regions = [[0x80000000, 0x10000000, 0x7, 1]]

            [devices]
            interrupt_mode = "passthrough"

            [scheduling]
            enabled = true
            base_timeslice_us = 500

            [[scheduling.vcpu_configs]]
            policy = "deadline"
            deadline_us = 10000
            wcet_us = 2000
            period_us = 20000
            preemptive = true
        "#;
        let crate_config = AxVMCrateConfig::from_toml(raw).unwrap();
        let vm_config = build_axvm_config(&crate_config);

        assert!(vm_config.rt_scheduling_enabled());
        let rt = vm_config.rt_sched_config().unwrap();
        assert_eq!(rt.vcpu_configs.len(), 1);
        assert_eq!(rt.vcpu_configs[0].policy, axvm::RtSchedPolicy::Deadline);
        let deadline = rt.vcpu_configs[0].deadline.as_ref().unwrap();
        assert_eq!(deadline.deadline_us, 10000);
        assert_eq!(deadline.wcet_us, 2000);
        assert_eq!(deadline.period_us, 20000);
    }

    #[test]
    fn sync_axvm_config_keeps_fdt_reserved_memory_regions() {
        let mut crate_config = GuestConfig::default();
        crate_config.kernel.memory_regions.push(memory_region(
            0x8000_0000,
            0x200000,
            VmMemMappingType::MapIdentical,
        ));
        let mut vm_config = build_axvm_config(&crate_config);

        crate_config.kernel.memory_regions.push(memory_region(
            0x110000,
            0x10000,
            VmMemMappingType::MapReserved,
        ));
        assert_eq!(vm_config.memory_regions().len(), 1);

        sync_axvm_config_from_crate_config(&mut vm_config, &crate_config);

        let regions = vm_config.memory_regions();
        assert_eq!(regions.len(), 2);
        assert_eq!(regions[1].gpa, 0x110000);
        assert_eq!(regions[1].size, 0x10000);
        assert_eq!(regions[1].map_type, VmMemMappingType::MapReserved);
    }

    #[test]
    fn build_axvm_config_copies_explicit_passthrough_irqs() {
        let mut crate_config = AxVMCrateConfig::default();
        crate_config.devices.passthrough_irqs = vec![4, 4, 17];

        let vm_config = build_axvm_config(&crate_config);

        assert_eq!(vm_config.pass_through_irqs(), &vec![4, 17]);
    }
}
