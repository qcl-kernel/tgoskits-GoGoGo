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

use crate::*;

const MINIMAL_CONFIG: &str = r#"
[base]
id = 12
name = "test-guest"
guest_type = "passthrough"
cpu_num = 2
phys_cpu_sets = [3, 4]
phys_cpu_ids = [0x500, 0x501]

[kernel]
entry_point = 0xdeadbeef
image_location = "memory"
kernel_path = "guest.bin"
kernel_load_addr = 0xdeadbeef
memory_regions = [
    [0x8000_0000, 0x8000_0000, 0x7, 1],
]

[devices]
passthrough = [
    { path = "/soc/ethernet@1000" },
]
disabled = [
    { path = "/soc/gpio@2000" },
]
"#;

#[test]
fn parses_structured_guest_config() {
    let config = GuestConfig::from_toml(MINIMAL_CONFIG).unwrap();

    assert_eq!(config.base.id, 12);
    assert_eq!(config.base.name, "test-guest");
    assert_eq!(config.base.guest_type, GuestType::Passthrough);
    assert_eq!(config.base.cpu_num, 2);
    assert_eq!(config.base.phys_cpu_ids, Some(vec![0x500, 0x501]));
    assert_eq!(config.base.phys_cpu_sets, Some(vec![3, 4]));

    assert_eq!(config.kernel.entry_point, 0xdeadbeef);
    assert_eq!(config.kernel.configured_memory_region_count, 1);
    assert_eq!(
        config.kernel.memory_regions[0].map_type,
        VmMemMappingType::MapIdentical
    );

    assert_eq!(
        config.devices.passthrough,
        vec![PhysicalDeviceRef {
            path: "/soc/ethernet@1000".into(),
        }]
    );
    assert_eq!(
        config.devices.disabled,
        vec![PhysicalDeviceRef {
            path: "/soc/gpio@2000".into(),
        }]
    );
}

#[test]
fn parses_open_virtual_device_options() {
    let config = GuestConfig::from_toml(
        r#"
[devices]
[[devices.virtual]]
id = "data0"
model = "virtio-blk-like"
capacity = "20GiB"
backend = { type = "file", path = "/images/data.raw" }
"#,
    )
    .unwrap();
    let [request] = config.devices.virtual_devices.as_slice() else {
        panic!("expected one virtual device request");
    };
    assert_eq!(request.id, "data0");
    assert_eq!(request.model, "virtio-blk-like");
    assert_eq!(request.options["capacity"].as_str(), Some("20GiB"));
}

#[test]
fn rejects_duplicate_ids_and_numeric_resource_options() {
    let duplicate = GuestConfig::from_toml(
        r#"
[devices]
[[devices.virtual]]
id = "data0"
model = "demo"
[[devices.virtual]]
id = "data0"
model = "demo"
"#,
    )
    .unwrap_err();
    assert_eq!(
        duplicate,
        AxVmConfigError::DuplicateVirtualDeviceId { id: "data0".into() }
    );

    let raw_irq = GuestConfig::from_toml(
        r#"
[devices]
[[devices.virtual]]
id = "data0"
model = "demo"
irq_id = 32
"#,
    )
    .unwrap_err();
    assert_eq!(
        raw_irq,
        AxVmConfigError::ForbiddenVirtualDeviceResourceOption {
            id: "data0".into(),
            option: "irq_id".into(),
        }
    );
}

#[test]
fn guest_type_owns_address_space_policy() {
    assert_eq!(
        GuestType::Virtualized.address_space_policy(),
        AddressSpacePolicy::Virtualized
    );
    assert_eq!(
        GuestType::Passthrough.address_space_policy(),
        AddressSpacePolicy::Passthrough
    );

    let devices = GuestDevices {
        passthrough: vec![PhysicalDeviceRef {
            path: "/soc/net@1000".into(),
        }],
        disabled: Vec::new(),
        virtual_devices: Vec::new(),
    };
    let unresolved = devices.unresolved_host_devices();
    assert_eq!(unresolved.len(), 1);
    assert_eq!(unresolved[0].name, "/soc/net@1000");
    assert!(
        unresolved.iter().all(|device| device.name != "/"),
        "the config layer must not invent an unresolved root selector"
    );
}

#[test]
fn rejects_removed_configuration_fields() {
    let removed_fields = [
        ("[base]\n", "vm_type = 1\n"),
        ("", "version = 1\n"),
        ("[devices]\n", "serial = {}\n"),
        ("[devices]\n", "emu_devices = []\n"),
        ("[devices]\n", "interrupt_mode = \"passthrough\"\n"),
        ("[devices]\n", "passthrough_devices = []\n"),
        ("[devices]\n", "passthrough_addresses = []\n"),
        ("[devices]\n", "passthrough_ports = []\n"),
        ("[kernel]\n", "disk_path = \"disk.img\"\n"),
    ];

    for (table, field) in removed_fields {
        let raw = format!("{table}{field}");
        let error = GuestConfig::from_toml(&raw).unwrap_err();
        assert!(
            matches!(error, AxVmConfigError::TomlParse { .. }),
            "removed field unexpectedly parsed: {field}"
        );
    }
}

#[test]
fn rejects_unknown_nested_fields() {
    let error = GuestConfig::from_toml(
        r#"
[devices]
passthrough = [{ path = "/soc/net@1000", irq = 4 }]
"#,
    )
    .unwrap_err();
    assert!(matches!(error, AxVmConfigError::TomlParse { .. }));
}

#[test]
fn validates_physical_device_selectors() {
    let relative = GuestConfig::from_toml(
        r#"
[devices]
passthrough = [{ path = "soc/net@1000" }]
"#,
    )
    .unwrap_err();
    assert_eq!(
        relative,
        AxVmConfigError::InvalidPhysicalDevicePath {
            path: "soc/net@1000".into(),
        }
    );

    let root = GuestConfig::from_toml(
        r#"
[devices]
passthrough = [{ path = "/" }]
"#,
    )
    .unwrap_err();
    assert_eq!(
        root,
        AxVmConfigError::InvalidPhysicalDevicePath { path: "/".into() }
    );

    let conflict = GuestConfig::from_toml(
        r#"
[devices]
passthrough = [{ path = "/soc/net@1000" }]
disabled = [{ path = "/soc/net@1000" }]
"#,
    )
    .unwrap_err();
    assert_eq!(
        conflict,
        AxVmConfigError::ConflictingPhysicalDeviceSelection {
            path: "/soc/net@1000".into(),
        }
    );
}

#[test]
fn serialization_has_no_serial_or_raw_device_fields() {
    let encoded = toml::to_string(&GuestConfig::default()).unwrap();
    for removed in [
        "serial",
        "emu_devices",
        "cfg_list",
        "interrupt_mode",
        "passthrough_addresses",
        "passthrough_ports",
        "vm_type",
        "version",
    ] {
        assert!(!encoded.contains(removed), "{removed} leaked into schema");
    }
    assert!(encoded.contains("guest_type = \"virtualized\""));
    assert!(encoded.contains("passthrough = []"));
    assert!(encoded.contains("disabled = []"));
}

#[test]
fn menuconfig_schema_exposes_only_structured_device_selectors() {
    let schema = schemars::schema_for!(GuestConfig);
    let definitions = schema
        .as_value()
        .get("$defs")
        .and_then(|value| value.as_object())
        .unwrap();
    let device_properties = definitions["GuestDevices"]
        .get("properties")
        .and_then(|value| value.as_object())
        .unwrap();
    assert_eq!(device_properties.len(), 3);
    assert!(device_properties.contains_key("disabled"));
    assert!(device_properties.contains_key("passthrough"));
    assert!(device_properties.contains_key("virtual"));

    let base_properties = definitions["VMBaseConfig"]
        .get("properties")
        .and_then(|value| value.as_object())
        .unwrap();
    assert!(base_properties.contains_key("guest_type"));
    assert!(!base_properties.contains_key("vm_type"));

    let root_properties = schema
        .as_value()
        .get("properties")
        .and_then(|value| value.as_object())
        .unwrap();
    assert_eq!(root_properties.len(), 3);
    assert!(root_properties.contains_key("base"));
    assert!(root_properties.contains_key("devices"));
    assert!(root_properties.contains_key("kernel"));
}

#[test]
fn boot_config_validation_preserves_typed_errors() {
    let direct_with_bios = VMKernelConfig {
        enable_bios: true,
        boot_protocol: Some(VMBootProtocol::Direct),
        ..Default::default()
    };
    assert_eq!(
        direct_with_bios.validate_boot_config(),
        Err(AxVmConfigError::BootProtocolConflict {
            protocol: VMBootProtocol::Direct,
            enable_bios: true,
        })
    );

    let uefi_without_firmware = VMKernelConfig {
        enable_bios: true,
        boot_protocol: Some(VMBootProtocol::Uefi),
        bios_load_addr: Some(0xffc0_0000),
        ..Default::default()
    };
    assert_eq!(
        uefi_without_firmware.validate_boot_config_for_arch("x86_64"),
        Err(AxVmConfigError::MissingFirmwarePath {
            protocol: VMBootProtocol::Uefi,
        })
    );
}

#[test]
fn rejects_invalid_toml_with_public_error() {
    let result = GuestConfig::from_toml("[base");
    assert!(matches!(result, Err(AxVmConfigError::TomlParse { .. })));
}

#[test]
fn test_default_implementations() {
    use crate::*;

    assert_eq!(VMType::default(), VMType::VMTRTOS);
    assert_eq!(VmMemMappingType::default(), VmMemMappingType::MapAlloc);
    assert_eq!(EmulatedDeviceType::default(), EmulatedDeviceType::Dummy);
    assert_eq!(VMInterruptMode::default(), VMInterruptMode::NoIrq);

    let vm_mem_config = VmMemConfig::default();
    assert_eq!(vm_mem_config.gpa, 0);
    assert_eq!(vm_mem_config.size, 0);
    assert_eq!(vm_mem_config.flags, 0);
    assert_eq!(vm_mem_config.map_type, VmMemMappingType::MapAlloc);

    let emu_device_config = EmulatedDeviceConfig::default();
    assert_eq!(emu_device_config.name, "");
    assert_eq!(emu_device_config.base_gpa, 0);
    assert_eq!(emu_device_config.length, 0);
    assert_eq!(emu_device_config.irq_id, 0);
    assert_eq!(emu_device_config.emu_type, EmulatedDeviceType::Dummy);
    assert!(emu_device_config.cfg_list.is_empty());

    let passthrough_device_config = PassThroughDeviceConfig::default();
    assert_eq!(passthrough_device_config.name, "");
    assert_eq!(passthrough_device_config.base_gpa, 0);
    assert_eq!(passthrough_device_config.base_hpa, 0);
    assert_eq!(passthrough_device_config.length, 0);
    assert_eq!(passthrough_device_config.irq_id, 0);

    let vm_base_config = VMBaseConfig::default();
    assert_eq!(vm_base_config.id, 0);
    assert_eq!(vm_base_config.name, "");
    assert_eq!(vm_base_config.vm_type, 0);
    assert_eq!(vm_base_config.cpu_num, 0);
    assert!(vm_base_config.phys_cpu_ids.is_none());
    assert!(vm_base_config.phys_cpu_sets.is_none());

    let vm_kernel_config = VMKernelConfig::default();
    assert_eq!(vm_kernel_config.entry_point, 0);
    assert_eq!(vm_kernel_config.kernel_path, "");
    assert_eq!(vm_kernel_config.kernel_load_addr, 0);
    assert!(!vm_kernel_config.enable_bios);
    assert!(vm_kernel_config.boot_protocol.is_none());
    assert_eq!(
        vm_kernel_config.effective_boot_protocol(),
        VMBootProtocol::Direct
    );
    assert!(vm_kernel_config.bios_path.is_none());
    assert!(vm_kernel_config.uefi_firmware_path.is_none());
    assert!(vm_kernel_config.bios_load_addr.is_none());
    assert!(vm_kernel_config.dtb_path.is_none());
    assert!(vm_kernel_config.dtb_load_addr.is_none());
    assert!(vm_kernel_config.ramdisk_path.is_none());
    assert!(vm_kernel_config.ramdisk_load_addr.is_none());
    assert!(vm_kernel_config.image_location.is_none());
    assert!(vm_kernel_config.cmdline.is_none());
    assert!(vm_kernel_config.disk_path.is_none());
    assert!(vm_kernel_config.memory_regions.is_empty());

    let vm_devices_config = VMDevicesConfig::default();
    assert_eq!(
        vm_devices_config.address_space_policy,
        AddressSpacePolicy::Virtualized
    );
    assert!(vm_devices_config.emu_devices.is_empty());
    assert!(vm_devices_config.passthrough_devices.is_empty());
    assert_eq!(vm_devices_config.interrupt_mode, VMInterruptMode::NoIrq);

    let axvm_crate_config = AxVMCrateConfig::default();
    assert_eq!(axvm_crate_config.base.id, 0);
    assert_eq!(axvm_crate_config.kernel.entry_point, 0);
    assert!(axvm_crate_config.devices.emu_devices.is_empty());
}

#[test]
fn rt_scheduling_toml_parses_fixed_priority_policy() {
    let raw = r#"
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
        enabled = true
        base_timeslice_us = 500

        [[scheduling.vcpu_configs]]
        policy = "fixed_priority"
        priority = 0
        max_timeslice_us = 200

        [[scheduling.vcpu_configs]]
        policy = "fixed_priority"
        priority = 10
        max_timeslice_us = 1000
    "#;
    let config = AxVMCrateConfig::from_toml(raw).unwrap();
    let sched = config.scheduling.unwrap();
    assert!(sched.enabled);
    assert_eq!(sched.base_timeslice_us, Some(500));
    assert_eq!(sched.vcpu_configs.len(), 2);
    assert_eq!(
        sched.vcpu_configs[0].policy,
        crate::RtSchedPolicySerde::FixedPriority
    );
    assert_eq!(sched.vcpu_configs[0].priority, Some(0));
    assert_eq!(sched.vcpu_configs[0].max_timeslice_us, Some(200));
    assert_eq!(sched.vcpu_configs[1].priority, Some(10));
}

#[test]
fn rt_scheduling_toml_parses_budget_policy() {
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
    let config = AxVMCrateConfig::from_toml(raw).unwrap();
    let sched = config.scheduling.unwrap();
    assert_eq!(sched.vcpu_configs.len(), 1);
    assert_eq!(sched.vcpu_configs[0].policy, crate::RtSchedPolicySerde::Budget);
    assert_eq!(sched.vcpu_configs[0].budget_us, Some(500));
    assert_eq!(sched.vcpu_configs[0].period_us, Some(5000));
}

#[test]
fn rt_scheduling_toml_parses_deadline_policy() {
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
    let config = AxVMCrateConfig::from_toml(raw).unwrap();
    let sched = config.scheduling.unwrap();
    assert_eq!(sched.vcpu_configs.len(), 1);
    assert_eq!(sched.vcpu_configs[0].policy, crate::RtSchedPolicySerde::Deadline);
    assert_eq!(sched.vcpu_configs[0].deadline_us, Some(10000));
    assert_eq!(sched.vcpu_configs[0].wcet_us, Some(2000));
    assert_eq!(sched.vcpu_configs[0].period_us, Some(20000));
    assert!(sched.vcpu_configs[0].preemptive);
}

#[test]
fn rt_scheduling_toml_defaults_disabled_when_absent() {
    let raw = r#"
        [base]
        id = 1
        name = "no-scheduling"
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
    let config = AxVMCrateConfig::from_toml(raw).unwrap();
    assert!(config.scheduling.is_none());
}

#[test]
fn rt_scheduling_toml_reserved_cpus_parsed() {
    let raw = r#"
        [base]
        id = 4
        name = "isolated"
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
        reserved_cpus = [2, 3, 5]
        disable_housekeeping = true

        [[scheduling.vcpu_configs]]
        policy = "fixed_priority"
        priority = 0
    "#;
    let config = AxVMCrateConfig::from_toml(raw).unwrap();
    let sched = config.scheduling.unwrap();
    assert_eq!(sched.reserved_cpus, Some(vec![2, 3, 5]));
    assert!(sched.disable_housekeeping);
}
