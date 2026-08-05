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

#![cfg(target_arch = "aarch64")]

use arm_vcpu::Aarch64VCpuSetupConfig;

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
}
