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

/// Configuration for setting up a new AArch64 vCPU.
#[derive(Clone, Debug, Default)]
pub struct ArmVcpuSetupConfig {
    /// Should the hypervisor passthrough interrupts to the guest?
    pub passthrough_interrupt: bool,
    /// Should the hypervisor passthrough timers to the guest?
    pub passthrough_timer: bool,
    /// Should guest WFI instructions trap to EL2?
    ///
    /// Defaults to `false`, preserving the guest's native WFI behavior.
    pub trap_wfi: bool,
}

impl ArmVcpuSetupConfig {
    /// Returns the `HCR_EL2.TWI` value selected by this setup policy.
    pub const fn hcr_el2_twi(&self) -> HcrEl2Twi {
        if self.trap_wfi {
            HcrEl2Twi::Set
        } else {
            HcrEl2Twi::Clear
        }
    }
}

/// Typed input for composing the `HCR_EL2.TWI` register field.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HcrEl2Twi {
    /// Leave WFI execution native to the guest.
    Clear,
    /// Trap guest WFI execution to EL2.
    Set,
}

/// Host-visible disposition of a trapped WFI or WFE instruction.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TrappedWfxDisposition {
    /// Advance past WFI and return a wait-for-interrupt VM exit.
    WaitForInterrupt,
    /// Reject WFE because event-register emulation is not implemented.
    UnsupportedWaitForEvent,
}

/// Decodes the WFx instruction bit from an AArch64 exception ISS value.
pub const fn trapped_wfx_disposition(iss: usize) -> TrappedWfxDisposition {
    const WFX_ISS_WFE: usize = 1 << 0;

    if iss & WFX_ISS_WFE == 0 {
        TrappedWfxDisposition::WaitForInterrupt
    } else {
        TrappedWfxDisposition::UnsupportedWaitForEvent
    }
}
