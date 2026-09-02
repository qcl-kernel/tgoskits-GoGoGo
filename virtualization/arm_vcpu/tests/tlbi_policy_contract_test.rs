use arm_vcpu::{TlbiClassification, classify_tlbi};

const fn sys_insn(op0: usize, op1: usize, crn: usize, crm: usize, op2: usize) -> usize {
    (op0 << 20) | (op2 << 17) | (op1 << 14) | (crn << 10) | (crm << 1)
}

#[test]
fn recognizes_el1_tlbi_local_shareable_range_and_nxs_forms() {
    for addr in [
        sys_insn(1, 0, 8, 7, 0),
        sys_insn(1, 0, 8, 3, 1),
        sys_insn(1, 0, 8, 1, 0),
        sys_insn(1, 0, 8, 2, 1),
        sys_insn(1, 0, 9, 7, 7),
    ] {
        assert_eq!(classify_tlbi(addr), TlbiClassification::Supported);
    }
}

#[test]
fn rejects_reserved_el1_tlbi_encodings_without_confusing_other_sysregs() {
    assert_eq!(
        classify_tlbi(sys_insn(1, 0, 8, 2, 0)),
        TlbiClassification::Unsupported
    );
    assert_eq!(
        classify_tlbi(sys_insn(1, 0, 8, 4, 1)),
        TlbiClassification::Unsupported
    );
    assert_eq!(
        classify_tlbi(sys_insn(1, 4, 8, 3, 0)),
        TlbiClassification::NotTlbi
    );
    assert_eq!(
        classify_tlbi(sys_insn(0, 0, 8, 7, 0)),
        TlbiClassification::NotTlbi
    );
}
