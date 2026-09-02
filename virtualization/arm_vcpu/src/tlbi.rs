//! AArch64 EL1 TLBI system-instruction classification.

/// Classification of the system-register encoding reported for a trapped
/// AArch64 TLBI instruction.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TlbiClassification {
    /// The encoding is not in the EL1 TLBI namespace.
    NotTlbi,
    /// The encoding names an architected EL1 stage-1 TLBI operation.
    Supported,
    /// The encoding is in the EL1 TLBI namespace but is reserved.
    Unsupported,
}

/// Classifies an ISS-derived AArch64 system-register encoding.
///
/// The encoding layout follows `sys_insn(op0, op1, CRn, CRm, op2)` from the
/// Arm architecture and Linux's `asm/sysreg.h`. Only EL1 stage-1 TLBI forms
/// are accepted; EL2, stage-2 and reserved forms remain outside the trap
/// emulation contract.
pub const fn classify_tlbi(addr: usize) -> TlbiClassification {
    let op0 = (addr >> 20) & 0x3;
    let op1 = (addr >> 14) & 0x7;
    let crn = (addr >> 10) & 0xf;
    let crm = (addr >> 1) & 0xf;
    let op2 = (addr >> 17) & 0x7;

    if op0 != 1 || op1 != 0 || (crn != 8 && crn != 9) {
        return TlbiClassification::NotTlbi;
    }

    let valid = match crm {
        // Outer-shareable and non-XS forms.
        1 | 3 | 7 => matches!(op2, 0 | 1 | 2 | 3 | 5 | 7),
        // Range forms.
        2 | 5 | 6 => matches!(op2, 1 | 3 | 5 | 7),
        _ => false,
    };

    if valid {
        TlbiClassification::Supported
    } else {
        TlbiClassification::Unsupported
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const fn sys_insn(op0: usize, op1: usize, crn: usize, crm: usize, op2: usize) -> usize {
        (op0 << 20) | (op2 << 17) | (op1 << 14) | (crn << 10) | (crm << 1)
    }

    #[test]
    fn classification_is_pure() {
        assert_eq!(
            classify_tlbi(sys_insn(1, 0, 8, 7, 0)),
            TlbiClassification::Supported
        );
        assert_eq!(
            classify_tlbi(sys_insn(1, 0, 8, 2, 0)),
            TlbiClassification::Unsupported
        );
        assert_eq!(
            classify_tlbi(sys_insn(1, 4, 8, 3, 0)),
            TlbiClassification::NotTlbi
        );
    }
}
