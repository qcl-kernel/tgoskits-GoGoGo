// Copyright 2026 The Axvisor Team
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

//! AArch64 software-trapped physical timer policy contract.

#![cfg(target_arch = "aarch64")]

use arm_vcpu::{
    ArmHostIrqConfig, ArmHostOps, ArmTimerVmConfig, ArmVcpu, ArmVcpuCreateConfig, ArmVcpuResult,
    ArmVcpuSetupConfig, ArmVcpuTlbiPolicy,
};

const CNTHCTL_EL1PCTEN: u64 = 1 << 0;
const CNTHCTL_EL1PCEN: u64 = 1 << 1;
const HCR_TWI: u64 = 1 << 13;
const HCR_TTLB: u64 = 1 << 25;

struct TestHost;

impl ArmHostOps for TestHost {
    fn inject_virtual_interrupt(_vector: u32) -> ArmVcpuResult {
        Ok(())
    }

    fn finish_pending_host_irq(_raw_ack: u32) -> Option<usize> {
        None
    }

    fn handle_current_host_irq() {}
}

fn new_vcpu() -> ArmVcpu<TestHost> {
    ArmVcpu::new(1, 0, ArmVcpuCreateConfig::default()).unwrap()
}

#[test]
fn set_entry_installs_a_fallback_exception_vector() {
    let mut vcpu = new_vcpu();

    vcpu.set_entry(0x40_0000usize.into()).unwrap();

    let (_, _, vbar_el1) = vcpu.saved_setup_state_for_test();
    assert_eq!(vbar_el1, 0x40_0000);
}

#[test]
fn setup_saves_software_trapped_cntp_and_wfi_policy() {
    let mut vcpu = new_vcpu();
    let timer = ArmTimerVmConfig::new(1_000_000, 0, 0).unwrap();
    let setup = ArmVcpuSetupConfig::new(timer, ArmHostIrqConfig::gicv3_sysreg());

    vcpu.setup(setup).unwrap();

    let (cnthctl_el2, hcr_el2, _) = vcpu.saved_setup_state_for_test();
    assert_eq!(cnthctl_el2 & (CNTHCTL_EL1PCEN | CNTHCTL_EL1PCTEN), 0);
    assert_ne!(hcr_el2 & HCR_TWI, 0);
    assert_eq!(hcr_el2 & HCR_TTLB, 0);
}

#[test]
fn explicit_tlbi_trap_policy_sets_hcr_ttlb_without_changing_timer_or_wfi() {
    let mut vcpu = new_vcpu();
    let timer = ArmTimerVmConfig::new(1_000_000, 0, 0).unwrap();
    let setup = ArmVcpuSetupConfig::with_tlbi_policy(
        timer,
        ArmHostIrqConfig::gicv3_sysreg(),
        ArmVcpuTlbiPolicy::TrapEl1,
    );

    vcpu.setup(setup).unwrap();

    let (cnthctl_el2, hcr_el2, _) = vcpu.saved_setup_state_for_test();
    assert_eq!(cnthctl_el2 & (CNTHCTL_EL1PCEN | CNTHCTL_EL1PCTEN), 0);
    assert_ne!(hcr_el2 & HCR_TWI, 0);
    assert_ne!(hcr_el2 & HCR_TTLB, 0);
}
