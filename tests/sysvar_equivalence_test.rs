//! Direct syscall vs account-reader equivalence harness for Clock/Rent fixtures.

mod bpf_test_support;
mod equivalence_test_support;

use equivalence_test_support::{
    compile_sysvar_example, read_u64_le, run_sysvar_example, CLOCK_EPOCH, CLOCK_SLOT,
    CLOCK_UNIX_TIMESTAMP, RENT_LAMPORTS_PER_BYTE_YEAR, SYSVAR_DIRECT_CLOCK_EPOCH_OFFSET,
    SYSVAR_DIRECT_CLOCK_SLOT_OFFSET, SYSVAR_DIRECT_CLOCK_UNIX_OFFSET,
    SYSVAR_DIRECT_RENT_LAMPORTS_OFFSET, SYSVAR_OUTPUT_LEN, SYSVAR_READER_CLOCK_EPOCH_OFFSET,
    SYSVAR_READER_CLOCK_SLOT_OFFSET, SYSVAR_READER_CLOCK_UNIX_OFFSET,
    SYSVAR_READER_RENT_LAMPORTS_OFFSET,
};

#[test]
fn sysvar_equivalence_direct_and_account_reader_paths_agree_for_same_fixture() {
    let elf_path = compile_sysvar_example();
    let bpf_output = run_sysvar_example(&elf_path);

    assert_eq!(
        bpf_output.len(),
        SYSVAR_OUTPUT_LEN,
        "BPF program should write the full normalized payload"
    );

    assert_eq!(
        read_u64_le(&bpf_output, SYSVAR_READER_CLOCK_SLOT_OFFSET),
        CLOCK_SLOT
    );
    assert_eq!(
        read_u64_le(&bpf_output, SYSVAR_READER_CLOCK_EPOCH_OFFSET),
        CLOCK_EPOCH
    );
    assert_eq!(
        read_u64_le(&bpf_output, SYSVAR_READER_CLOCK_UNIX_OFFSET),
        CLOCK_UNIX_TIMESTAMP as u64
    );
    assert_eq!(
        read_u64_le(&bpf_output, SYSVAR_READER_RENT_LAMPORTS_OFFSET),
        RENT_LAMPORTS_PER_BYTE_YEAR
    );

    assert_eq!(
        read_u64_le(&bpf_output, SYSVAR_DIRECT_CLOCK_SLOT_OFFSET),
        read_u64_le(&bpf_output, SYSVAR_READER_CLOCK_SLOT_OFFSET),
        "Clock.slot should match between direct syscall and account-reader paths"
    );
    assert_eq!(
        read_u64_le(&bpf_output, SYSVAR_DIRECT_CLOCK_EPOCH_OFFSET),
        read_u64_le(&bpf_output, SYSVAR_READER_CLOCK_EPOCH_OFFSET),
        "Clock.epoch should match between direct syscall and account-reader paths"
    );
    assert_eq!(
        read_u64_le(&bpf_output, SYSVAR_DIRECT_CLOCK_UNIX_OFFSET),
        read_u64_le(&bpf_output, SYSVAR_READER_CLOCK_UNIX_OFFSET),
        "Clock.unix_timestamp should match between direct syscall and account-reader paths"
    );
    assert_eq!(
        read_u64_le(&bpf_output, SYSVAR_DIRECT_RENT_LAMPORTS_OFFSET),
        read_u64_le(&bpf_output, SYSVAR_READER_RENT_LAMPORTS_OFFSET),
        "Rent.lamports_per_byte_year should match between direct syscall and account-reader paths"
    );
}
