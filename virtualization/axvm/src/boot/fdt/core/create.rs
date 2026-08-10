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

use alloc::{string::String, vec::Vec};
use core::ptr::NonNull;

use ax_memory_addr::MemoryAddr;
use axvmconfig::AxVMCrateConfig;
use fdt_edit::{Fdt, Node, NodeId};

use super::tree::{FdtTree, GuestMemorySpec};
use crate::{
    AxVMRef, AxVmResult, GuestPhysAddr, VMMemoryRegion, ax_err_type,
    boot::images::load_vm_image_from_memory,
};

pub fn create_guest_fdt(
    fdt: &Fdt,
    passthrough_device_names: &[String],
    crate_config: &AxVMCrateConfig,
) -> AxVmResult<Vec<u8>> {
    let phys_cpu_ids = crate_config
        .base
        .phys_cpu_ids
        .as_deref()
        .ok_or_else(|| ax_err_type!(InvalidInput, "phys_cpu_ids is missing"))?;

    let mut guest_tree = FdtTree::clone_filtered(fdt, |node_id, path, node| {
        should_keep_generated_node(
            fdt,
            node_id,
            path,
            node,
            passthrough_device_names,
            phys_cpu_ids,
        )
    })?;
    // Preserve dma-coherent on passthrough devices and root. In GPPT
    // identity-mapped mode, guest PA equals host PA, so DMA between the
    // guest and the passthrough device (e.g. QEMU virtio-mmio) is genuinely
    // coherent. Removing the property causes the guest to perform spurious
    // cache maintenance and breaks virtio-net DMA buffer management.
    Ok(guest_tree.finish())
}

fn should_keep_generated_node(
    fdt: &Fdt,
    node_id: NodeId,
    node_path: &str,
    node: &Node,
    passthrough_device_names: &[String],
    phys_cpu_ids: &[usize],
) -> bool {
    if node.name().starts_with("memory") {
        return false;
    }

    if node_path == "/cpus" || node_path.starts_with("/cpus/cpu-map") {
        return true;
    }

    // Boot arguments and the console path are supplied through /chosen.
    if matches!(node_path, "/chosen" | "/aliases") {
        return true;
    }

    if node_path.starts_with("/cpus/cpu@") {
        return need_cpu_node(phys_cpu_ids, fdt, node_id, node_path);
    }

    passthrough_device_names
        .iter()
        .any(|device_path| device_path == node_path)
        || is_descendant_of_passthrough_device(node_path, passthrough_device_names)
        || is_ancestor_of_passthrough_device(node_path, passthrough_device_names)
}

fn is_descendant_of_passthrough_device(
    node_path: &str,
    passthrough_device_names: &[String],
) -> bool {
    passthrough_device_names.iter().any(|passthrough_path| {
        node_path
            .strip_prefix(passthrough_path)
            .is_some_and(|suffix| suffix.starts_with('/'))
    })
}

fn is_ancestor_of_passthrough_device(node_path: &str, passthrough_device_names: &[String]) -> bool {
    passthrough_device_names.iter().any(|passthrough_path| {
        passthrough_path
            .strip_prefix(node_path)
            .is_some_and(|suffix| suffix.starts_with('/'))
            || node_path == "/"
    })
}

fn cpu_node_id(node_path: &str) -> Option<usize> {
    node_path
        .strip_prefix("/cpus/cpu@")
        .and_then(|rest| rest.split('/').next())
        .and_then(|id| usize::from_str_radix(id, 16).ok())
}

fn cpu_reg_address(fdt: &Fdt, node_id: NodeId) -> Option<usize> {
    fdt.view_typed(node_id)
        .and_then(|node| node.regs().first().map(|reg| reg.address as usize))
}

pub(crate) fn need_cpu_node(
    phys_cpu_ids: &[usize],
    fdt: &Fdt,
    node_id: NodeId,
    node_path: &str,
) -> bool {
    if !node_path.starts_with("/cpus/cpu@") {
        return true;
    }

    if let Some(cpu_id) = cpu_node_id(node_path) {
        return phys_cpu_ids.contains(&cpu_id);
    }

    cpu_reg_address(fdt, node_id).is_some_and(|cpu_address| {
        debug!("Checking CPU node {node_path} with address 0x{cpu_address:x}");
        phys_cpu_ids.contains(&cpu_address)
    })
}

fn guest_memory_specs(
    new_memory: &[VMMemoryRegion],
    crate_config: &AxVMCrateConfig,
) -> Vec<GuestMemorySpec> {
    let configured_region_count = if crate_config.kernel.configured_memory_region_count == 0 {
        crate_config.kernel.memory_regions.len()
    } else {
        crate_config
            .kernel
            .configured_memory_region_count
            .min(crate_config.kernel.memory_regions.len())
    };

    if new_memory.len() != crate_config.kernel.memory_regions.len() {
        warn!(
            "VM memory region count {} does not match config region count {}; filtering /memory \
             by zipped order",
            new_memory.len(),
            crate_config.kernel.memory_regions.len()
        );
    }

    new_memory
        .iter()
        .take(configured_region_count)
        .zip(
            crate_config
                .kernel
                .memory_regions
                .iter()
                .take(configured_region_count),
        )
        .map(|(mem, _cfg)| GuestMemorySpec::new(mem.gpa.as_usize() as u64, mem.size() as u64))
        .collect()
}

#[cfg(test)]
fn initrd_range_from_image_config(
    ramdisk: Option<&crate::config::RamdiskInfo>,
) -> Option<(u64, u64)> {
    let ramdisk = ramdisk?;
    let start = ramdisk.load_gpa.as_usize() as u64;
    let size = ramdisk.size? as u64;
    Some((start, start.saturating_add(size)))
}

fn configured_dtb_load_addr(
    configured: Option<GuestPhysAddr>,
    main_memory: &VMMemoryRegion,
    fdt_size: usize,
) -> Option<GuestPhysAddr> {
    let configured = configured?;
    let memory_end = main_memory.gpa.as_usize().checked_add(main_memory.size())?;
    let fdt_end = configured.as_usize().checked_add(fdt_size)?;
    (configured.as_usize() >= main_memory.gpa.as_usize() && fdt_end <= memory_end)
        .then_some(configured)
}

pub fn update_fdt(
    fdt_src: NonNull<u8>,
    dtb_size: usize,
    vm: AxVMRef,
    crate_config: &AxVMCrateConfig,
) -> AxVmResult {
    let patch_runtime = super::selected_guest_fdt_policy().patch_runtime;
    // SAFETY: `fdt_src` originates from `GuestDtbImage::as_bytes`, and the
    // caller supplies the exact slice length while the image remains borrowed.
    let fdt_bytes = unsafe { core::slice::from_raw_parts(fdt_src.as_ptr(), dtb_size) };
    let new_fdt_bytes = patch_runtime(fdt_bytes, &vm, crate_config)?;

    load_patched_fdt(vm, new_fdt_bytes)
}

fn load_patched_fdt(vm: AxVMRef, new_fdt_bytes: Vec<u8>) -> AxVmResult {
    let dest_addr = calculate_dtb_load_addr(vm.clone(), new_fdt_bytes.len())?;
    debug!(
        "New FDT will be loaded at {:x}, size: 0x{:x}",
        dest_addr,
        new_fdt_bytes.len()
    );
    load_vm_image_from_memory(&new_fdt_bytes, dest_addr, vm.clone())?;
    vm.set_guest_device_tree(dest_addr, new_fdt_bytes)
}

pub fn patch_guest_fdt_for_runtime(
    fdt_bytes: &[u8],
    memory_regions: &[VMMemoryRegion],
    crate_config: &AxVMCrateConfig,
    initrd_start_size: Option<(u64, u64)>,
    create_chosen: bool,
) -> AxVmResult<Vec<u8>> {
    let mut tree = FdtTree::from_bytes(fdt_bytes)?;
    let memory_specs = guest_memory_specs(memory_regions, crate_config);
    tree.rebuild_memory_nodes(&memory_specs)?;
    if create_chosen
        || initrd_start_size.is_some()
        || tree.inner().get_by_path_id("/chosen").is_some()
    {
        tree.patch_chosen(initrd_start_size)?;
    }
    Ok(tree.finish())
}

pub(crate) fn calculate_dtb_load_addr(vm: AxVMRef, fdt_size: usize) -> AxVmResult<GuestPhysAddr> {
    const MB: usize = 1024 * 1024;

    let main_memory =
        vm.memory_regions().first().cloned().ok_or_else(|| {
            ax_err_type!(InvalidInput, "VM has no memory region for DTB placement")
        })?;

    let dtb_addr = vm.with_config(|config| {
        // The configured address is also the AArch64 boot argument (x0); keep
        // it when the complete DTB fits in guest memory so loading and handoff
        // cannot diverge.
        let dtb_addr = if let Some(configured) =
            configured_dtb_load_addr(config.image_config.dtb_load_gpa, &main_memory, fdt_size)
        {
            configured
        } else {
            let main_memory_size = main_memory.size().min(512 * MB);
            let addr = (main_memory.gpa + main_memory_size - fdt_size).align_down(2 * MB);
            if fdt_size > main_memory_size {
                error!("DTB size is larger than available memory");
            }
            addr
        };
        config.image_config.dtb_load_gpa = Some(dtb_addr);
        dtb_addr
    });

    Ok(dtb_addr)
}

#[cfg(test)]
mod tests {
    use core::alloc::Layout;

    use axvmconfig::AxVMCrateConfig;
    use fdt_edit::{Fdt, Node, Property};
    use fdt_raw::RegInfo;

    use super::{
        super::tree::sanitize_bootargs, cpu_node_id, initrd_range_from_image_config, need_cpu_node,
    };
    use crate::{GuestPhysAddr, VMMemoryRegion, config::RamdiskInfo};

    fn prop_u32(name: &str, value: u32) -> Property {
        let mut prop = Property::new(name, alloc::vec![]);
        prop.set_u32_ls(&[value]);
        prop
    }

    fn prop_str(name: &str, value: &str) -> Property {
        let mut prop = Property::new(name, alloc::vec![]);
        prop.set_string(value);
        prop
    }

    fn test_fdt(dts: &str) -> Fdt {
        let mut fdt = Fdt::new();
        let root = fdt.root_id();
        let cpus = fdt.add_node(root, Node::new("cpus"));
        fdt.node_mut(cpus)
            .unwrap()
            .set_property(prop_u32("#address-cells", 2));
        fdt.node_mut(cpus)
            .unwrap()
            .set_property(prop_u32("#size-cells", 0));

        for line in dts.lines().map(str::trim).filter(|line| !line.is_empty()) {
            let (name, reg) = line.split_once('=').unwrap();
            let node = fdt.add_node(cpus, Node::new(name));
            let reg = usize::from_str_radix(reg, 16).unwrap();
            fdt.view_typed_mut(node)
                .unwrap()
                .set_regs(&[RegInfo::new(reg as u64, None)]);
        }

        fdt
    }

    #[test]
    fn cpu_node_selection_uses_node_id_when_reg_differs() {
        let fdt = test_fdt("cpu@0=200\ncpu@100=0\ncpu@101=100");
        let selected: alloc::vec::Vec<_> = fdt
            .iter_node_ids()
            .map(|id| (id, fdt.path_of(id)))
            .filter(|(_, path)| path.starts_with("/cpus/cpu@"))
            .filter_map(|(id, path)| need_cpu_node(&[0x100], &fdt, id, &path).then_some(path))
            .collect();

        assert_eq!(selected, ["/cpus/cpu@100"]);
    }

    #[test]
    fn cpu_node_id_parses_hex_unit_address() {
        assert_eq!(cpu_node_id("/cpus/cpu@100"), Some(0x100));
    }

    #[test]
    fn initrd_range_requires_both_address_and_size() {
        assert_eq!(
            initrd_range_from_image_config(Some(&RamdiskInfo {
                load_gpa: GuestPhysAddr::from(0xa000_0000usize),
                size: None,
            })),
            None
        );
        assert_eq!(
            initrd_range_from_image_config(Some(&RamdiskInfo {
                load_gpa: GuestPhysAddr::from(0xa000_0000usize),
                size: Some(0x1234),
            })),
            Some((0xa000_0000, 0xa000_1234))
        );
    }

    #[test]
    fn sanitize_bootargs_enables_auto_repair_for_block_roots() {
        let bootargs = "root=/dev/mmcblk0p2 rw console=ttyS2,1500000 rootwait rootfstype=ext4";

        assert_eq!(
            sanitize_bootargs(bootargs),
            "root=/dev/mmcblk0p2 rw console=ttyS2,1500000 rootwait rootfstype=ext4 fsck.repair=yes"
        );
    }

    #[test]
    fn sanitize_bootargs_preserves_existing_fsck_policy() {
        let bootargs =
            "root=/dev/mmcblk0p2 ro rootwait rootfstype=ext4 fsckfix rdinit=/init root=/dev/ram0";

        assert_eq!(
            sanitize_bootargs(bootargs),
            "root=/dev/mmcblk0p2 rw rootwait rootfstype=ext4 fsckfix"
        );
    }

    #[test]
    fn runtime_patch_can_leave_missing_chosen_for_host_copy() {
        let fdt = Fdt::new();
        let dtb = fdt.encode().as_ref().to_vec();
        let cfg = AxVMCrateConfig::default();

        let patched = super::patch_guest_fdt_for_runtime(&dtb, &[], &cfg, None, false).unwrap();
        let reparsed = Fdt::from_bytes(&patched).unwrap();

        assert!(reparsed.get_by_path_id("/chosen").is_none());

        let patched = super::patch_guest_fdt_for_runtime(&dtb, &[], &cfg, None, true).unwrap();
        let reparsed = Fdt::from_bytes(&patched).unwrap();

        assert!(reparsed.get_by_path_id("/chosen").is_some());
    }

    #[test]
    fn generated_fdt_filters_cpu_nodes_by_unit_address() {
        let fdt = test_fdt("cpu@0=200\ncpu@100=0\ncpu@101=100");
        let cfg = AxVMCrateConfig {
            base: axvmconfig::VMBaseConfig {
                phys_cpu_ids: Some(alloc::vec![0x100]),
                ..Default::default()
            },
            ..Default::default()
        };
        let dtb = super::create_guest_fdt(&fdt, &[], &cfg).unwrap();
        let reparsed = Fdt::from_bytes(&dtb).unwrap();

        assert!(reparsed.get_by_path_id("/cpus/cpu@100").is_some());
        assert!(reparsed.get_by_path_id("/cpus/cpu@0").is_none());
        assert!(reparsed.get_by_path_id("/cpus/cpu@101").is_none());
    }

    #[test]
    fn generated_fdt_keeps_chosen_boot_metadata() {
        let mut fdt = Fdt::new();
        let root = fdt.root_id();
        let cpus = fdt.add_node(root, Node::new("cpus"));
        fdt.node_mut(cpus)
            .unwrap()
            .set_property(prop_u32("#address-cells", 1));
        let cpu = fdt.add_node(cpus, Node::new("cpu@0"));
        fdt.view_typed_mut(cpu)
            .unwrap()
            .set_regs(&[RegInfo::new(0, None)]);

        let mut chosen = Node::new("chosen");
        let mut bootargs = Property::new("bootargs", alloc::vec![]);
        bootargs.set_string("console=ttyAMA0");
        chosen.set_property(bootargs);
        fdt.add_node(root, chosen);

        let cfg = AxVMCrateConfig {
            base: axvmconfig::VMBaseConfig {
                phys_cpu_ids: Some(alloc::vec![0]),
                ..Default::default()
            },
            ..Default::default()
        };
        let dtb = super::create_guest_fdt(&fdt, &["/pl011@9000000".into()], &cfg).unwrap();
        let reparsed = Fdt::from_bytes(&dtb).unwrap();

        let chosen = reparsed.get_by_path("/chosen").unwrap();
        assert_eq!(
            chosen.as_node().get_property("bootargs").unwrap().as_str(),
            Some("console=ttyAMA0")
        );
    }

    #[test]
    fn generated_fdt_keeps_console_alias_for_zephyr_boot() {
        let mut fdt = Fdt::new();
        let root = fdt.root_id();
        let cpus = fdt.add_node(root, Node::new("cpus"));
        fdt.node_mut(cpus)
            .unwrap()
            .set_property(prop_u32("#address-cells", 1));
        let cpu = fdt.add_node(cpus, Node::new("cpu@0"));
        fdt.view_typed_mut(cpu)
            .unwrap()
            .set_regs(&[RegInfo::new(0, None)]);

        let mut aliases = Node::new("aliases");
        let mut serial0 = Property::new("serial0", alloc::vec![]);
        serial0.set_string("/pl011@9000000");
        aliases.set_property(serial0);
        fdt.add_node(root, aliases);

        let mut chosen = Node::new("chosen");
        let mut stdout_path = Property::new("stdout-path", alloc::vec![]);
        stdout_path.set_string("/pl011@9000000");
        chosen.set_property(stdout_path);
        fdt.add_node(root, chosen);

        let cfg = AxVMCrateConfig {
            base: axvmconfig::VMBaseConfig {
                phys_cpu_ids: Some(alloc::vec![0]),
                ..Default::default()
            },
            ..Default::default()
        };
        let dtb = super::create_guest_fdt(&fdt, &["/pl011@9000000".into()], &cfg).unwrap();
        let reparsed = Fdt::from_bytes(&dtb).unwrap();

        assert_eq!(
            reparsed
                .get_by_path("/aliases")
                .unwrap()
                .as_node()
                .get_property("serial0")
                .unwrap()
                .as_str(),
            Some("/pl011@9000000")
        );
    }

    #[test]
    fn generated_and_runtime_fdt_keep_zephyr_boot_nodes_and_memory() {
        let mut host = Fdt::new();
        let root = host.root_id();
        host.node_mut(root)
            .unwrap()
            .set_property(prop_u32("#address-cells", 2));
        host.node_mut(root)
            .unwrap()
            .set_property(prop_u32("#size-cells", 2));

        let cpus = host.add_node(root, Node::new("cpus"));
        host.node_mut(cpus)
            .unwrap()
            .set_property(prop_u32("#address-cells", 1));
        let cpu = host.add_node(cpus, Node::new("cpu@0"));
        host.view_typed_mut(cpu)
            .unwrap()
            .set_regs(&[RegInfo::new(0, None)]);

        let gic = host.add_node(root, Node::new("intc@8000000"));
        host.node_mut(gic)
            .unwrap()
            .set_property(prop_str("compatible", "arm,gic-v3"));
        host.view_typed_mut(gic).unwrap().set_regs(&[
            RegInfo::new(0x0800_0000, Some(0x1_0000)),
            RegInfo::new(0x080a_0000, Some(0xf6_0000)),
        ]);

        let timer = host.add_node(root, Node::new("timer"));
        host.node_mut(timer)
            .unwrap()
            .set_property(prop_str("compatible", "arm,armv8-timer"));

        let psci = host.add_node(root, Node::new("psci"));
        host.node_mut(psci)
            .unwrap()
            .set_property(prop_str("compatible", "arm,psci-0.2"));

        let console = host.add_node(root, Node::new("pl011@9000000"));
        host.node_mut(console)
            .unwrap()
            .set_property(prop_str("compatible", "arm,pl011"));
        host.view_typed_mut(console)
            .unwrap()
            .set_regs(&[RegInfo::new(0x0900_0000, Some(0x1000))]);

        let mut aliases = Node::new("aliases");
        let mut serial0 = Property::new("serial0", alloc::vec![]);
        serial0.set_string("/pl011@9000000");
        aliases.set_property(serial0);
        host.add_node(root, aliases);

        let mut chosen = Node::new("chosen");
        let mut stdout_path = Property::new("stdout-path", alloc::vec![]);
        stdout_path.set_string("/pl011@9000000");
        chosen.set_property(stdout_path);
        host.add_node(root, chosen);

        let host_memory = host.add_node(root, Node::new("memory@40000000"));
        host.node_mut(host_memory)
            .unwrap()
            .set_property(prop_str("device_type", "memory"));
        host.view_typed_mut(host_memory)
            .unwrap()
            .set_regs(&[RegInfo::new(0x4000_0000, Some(0x2_0000_0000))]);

        let cfg = AxVMCrateConfig {
            base: axvmconfig::VMBaseConfig {
                phys_cpu_ids: Some(alloc::vec![0]),
                ..Default::default()
            },
            kernel: axvmconfig::VMKernelConfig {
                memory_regions: alloc::vec![axvmconfig::VmMemConfig {
                    gpa: 0xa000_0000,
                    size: 0x1000_0000,
                    flags: 0x7,
                    map_type: axvmconfig::VmMemMappingType::MapIdentical,
                }],
                ..Default::default()
            },
            ..Default::default()
        };
        let passthrough = alloc::vec![
            "/intc@8000000".into(),
            "/timer".into(),
            "/psci".into(),
            "/pl011@9000000".into(),
        ];
        let generated = super::create_guest_fdt(&host, &passthrough, &cfg).unwrap();
        let generated_fdt = Fdt::from_bytes(&generated).unwrap();
        for path in [
            "/chosen",
            "/aliases",
            "/pl011@9000000",
            "/timer",
            "/intc@8000000",
            "/psci",
        ] {
            assert!(
                generated_fdt.get_by_path_id(path).is_some(),
                "generated FDT lost {path}"
            );
        }
        assert!(generated_fdt.get_by_path_id("/memory@40000000").is_none());

        let memory = VMMemoryRegion {
            gpa: GuestPhysAddr::from(0xa000_0000),
            hva: 0.into(),
            layout: Layout::from_size_align(0x1000_0000, 0x2000_0000).unwrap(),
            needs_dealloc: false,
        };
        let runtime =
            super::patch_guest_fdt_for_runtime(&generated, &[memory], &cfg, None, true).unwrap();
        let runtime_fdt = Fdt::from_bytes(&runtime).unwrap();
        let runtime_memory = runtime_fdt.get_by_path("/memory@a0000000").unwrap();
        assert_eq!(runtime_memory.regs()[0].address, 0xa000_0000);
        assert_eq!(runtime_memory.regs()[0].size, Some(0x1000_0000));
        assert_eq!(
            runtime_fdt
                .get_by_path("/chosen")
                .unwrap()
                .as_node()
                .get_property("stdout-path")
                .unwrap()
                .as_str(),
            Some("/pl011@9000000")
        );
    }

    #[test]
    fn identity_guest_keeps_configured_dtb_address_for_vcpu_boot_arg() {
        let memory = VMMemoryRegion {
            gpa: GuestPhysAddr::from(0xa000_0000),
            hva: 0.into(),
            layout: Layout::from_size_align(0x1000_0000, 0x2000_0000).unwrap(),
            needs_dealloc: false,
        };
        let configured = GuestPhysAddr::from(0xaf00_0000);

        assert_eq!(
            super::configured_dtb_load_addr(Some(configured), &memory, 0x4000),
            Some(configured)
        );
    }

   #[test]
    fn generated_fdt_preserves_dma_coherent_on_passthrough_virtio_mmio() {
       let mut fdt = Fdt::new();
       let root = fdt.root_id();
       fdt.node_mut(root)
           .unwrap()
           .set_property(Property::new("dma-coherent", alloc::vec![]));

        let passthrough = fdt.add_node(root, Node::new("virtio_mmio@a000000"));
        fdt.node_mut(passthrough)
            .unwrap()
            .set_property(Property::new("dma-coherent", alloc::vec![]));

        let cfg = AxVMCrateConfig {
            base: axvmconfig::VMBaseConfig {
                phys_cpu_ids: Some(alloc::vec![0]),
                ..Default::default()
            },
            ..Default::default()
        };
        let dtb = super::create_guest_fdt(&fdt, &["/virtio_mmio@a000000".into()], &cfg).unwrap();
        let reparsed = Fdt::from_bytes(&dtb).unwrap();

       let passthrough = reparsed.get_by_path("/virtio_mmio@a000000").unwrap();
        assert!(passthrough.as_node().get_property("dma-coherent").is_some());
        assert!(
            reparsed
                .node(reparsed.root_id())
                .unwrap()
                .get_property("dma-coherent")
                .is_some()
        );
   }
}
