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

//! Public AArch64 WFI trap policy contract.

use arm_vcpu::{Aarch64VCpuSetupConfig, HcrEl2Twi, TrappedWfxDisposition, trapped_wfx_disposition};

#[test]
fn setup_config_exposes_an_opt_in_wfi_trap_policy() {
    let default_config = Aarch64VCpuSetupConfig::default();
    let trapping_config = Aarch64VCpuSetupConfig {
        passthrough_interrupt: false,
        passthrough_timer: false,
        trap_wfi: true,
    };

    assert!(!default_config.trap_wfi);
    assert!(trapping_config.trap_wfi);
    assert_eq!(default_config.hcr_el2_twi(), HcrEl2Twi::Clear);
    assert_eq!(trapping_config.hcr_el2_twi(), HcrEl2Twi::Set);
}

#[test]
fn trapped_wfi_and_wfe_decode_to_distinct_typed_dispositions() {
    assert_eq!(
        trapped_wfx_disposition(0),
        TrappedWfxDisposition::WaitForInterrupt
    );
    assert_eq!(
        trapped_wfx_disposition(1),
        TrappedWfxDisposition::UnsupportedWaitForEvent
    );
}
