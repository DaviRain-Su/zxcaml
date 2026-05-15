//! Hosted/native vs BPF equivalence harness for M2 syscall/crypto/sysvar paths.

use solana_account::Account;
use solana_instruction::{AccountMeta, Instruction};
use solana_pubkey::Pubkey;
use std::fs;

mod bpf_test_support;
mod equivalence_test_support;

use equivalence_test_support::{
    compile_host_runner, compile_sysvar_example, read_u64_le, run_host_runner, run_sysvar_example,
    BLAKE3_OFFSET, CLOCK_EPOCH, CLOCK_SLOT, CLOCK_UNIX_TIMESTAMP, CRYPTO_INPUT,
    HOST_DIRECT_CLOCK_EPOCH_OFFSET, HOST_DIRECT_CLOCK_SLOT_OFFSET, HOST_DIRECT_CLOCK_UNIX_OFFSET,
    HOST_DIRECT_RENT_LAMPORTS_OFFSET, HOST_OUTPUT_LEN, HOST_READER_CLOCK_EPOCH_OFFSET,
    HOST_READER_CLOCK_SLOT_OFFSET, HOST_READER_CLOCK_UNIX_OFFSET,
    HOST_READER_RENT_LAMPORTS_OFFSET, HOST_REMAINING_COMPUTE_UNITS_OFFSET,
    RENT_LAMPORTS_PER_BYTE_YEAR, SHA_OFFSET, SYSVAR_DIRECT_CLOCK_EPOCH_OFFSET,
    SYSVAR_DIRECT_CLOCK_SLOT_OFFSET, SYSVAR_DIRECT_CLOCK_UNIX_OFFSET,
    SYSVAR_DIRECT_RENT_LAMPORTS_OFFSET, SYSVAR_READER_CLOCK_EPOCH_OFFSET,
    SYSVAR_READER_CLOCK_SLOT_OFFSET, SYSVAR_READER_CLOCK_UNIX_OFFSET,
    SYSVAR_READER_RENT_LAMPORTS_OFFSET, SYSVAR_REMAINING_COMPUTE_UNITS_OFFSET,
};

const CRYPTO_PROGRAM_ID_BYTES: [u8; 32] = [58u8; 32];

fn crypto_program_id() -> Pubkey {
    Pubkey::new_from_array(CRYPTO_PROGRAM_ID_BYTES)
}

fn run_crypto_equivalence_bpf() -> Vec<u8> {
    let elf_path = bpf_test_support::compile_program("crypto_equivalence");
    let elf = fs::read(&elf_path).unwrap_or_else(|error| {
        panic!(
            "failed to read sBPF artifact at {}: {}",
            elf_path.display(),
            error
        )
    });

    let pid = crypto_program_id();
    let loader_v3 = solana_pubkey::pubkey!("BPFLoaderUpgradeab1e11111111111111111111111");
    let mut mollusk = bpf_test_support::new_mollusk();
    mollusk.add_program_with_loader_and_elf(&pid, &loader_v3, &elf);

    let output_account = Pubkey::new_unique();
    let result = mollusk.process_instruction(
        &Instruction {
            program_id: pid,
            accounts: vec![AccountMeta::new(output_account, false)],
            data: CRYPTO_INPUT.to_vec(),
        },
        &[(
            output_account,
            Account {
                lamports: 1_000_000,
                data: vec![0u8; 96],
                owner: pid,
                ..Account::default()
            },
        )],
    );

    assert!(
        !result.program_result.is_err(),
        "crypto equivalence program should succeed: {:?}",
        result.program_result
    );

    result.resulting_accounts[0].1.data.clone()
}

#[test]
fn syscall_equivalence_supported_outputs_match_and_hosted_unsupported_paths_stay_explicit() {
    let host_bin_path = compile_host_runner();
    let host_output = run_host_runner(&host_bin_path);
    let crypto_output = run_crypto_equivalence_bpf();
    let sysvar_elf_path = compile_sysvar_example();
    let sysvar_output = run_sysvar_example(&sysvar_elf_path);

    assert_eq!(
        host_output.len(),
        HOST_OUTPUT_LEN,
        "hosted runner should emit the full normalized payload"
    );
    assert_eq!(
        &host_output[SHA_OFFSET..BLAKE3_OFFSET + 32],
        crypto_output.as_slice(),
        "supported crypto outputs should normalize identically across hosted and BPF paths"
    );

    assert_eq!(
        read_u64_le(&host_output, HOST_READER_CLOCK_SLOT_OFFSET),
        read_u64_le(&sysvar_output, SYSVAR_READER_CLOCK_SLOT_OFFSET)
    );
    assert_eq!(
        read_u64_le(&host_output, HOST_READER_CLOCK_EPOCH_OFFSET),
        read_u64_le(&sysvar_output, SYSVAR_READER_CLOCK_EPOCH_OFFSET)
    );
    assert_eq!(
        read_u64_le(&host_output, HOST_READER_CLOCK_UNIX_OFFSET),
        read_u64_le(&sysvar_output, SYSVAR_READER_CLOCK_UNIX_OFFSET)
    );
    assert_eq!(
        read_u64_le(&host_output, HOST_READER_RENT_LAMPORTS_OFFSET),
        read_u64_le(&sysvar_output, SYSVAR_READER_RENT_LAMPORTS_OFFSET)
    );

    for &offset in &[
        HOST_DIRECT_CLOCK_SLOT_OFFSET,
        HOST_DIRECT_CLOCK_EPOCH_OFFSET,
        HOST_DIRECT_CLOCK_UNIX_OFFSET,
        HOST_DIRECT_RENT_LAMPORTS_OFFSET,
        HOST_REMAINING_COMPUTE_UNITS_OFFSET,
    ] {
        assert_eq!(
            read_u64_le(&host_output, offset),
            0,
            "hosted unsupported syscall sentinel should stay explicit at offset {offset}"
        );
    }

    assert_eq!(
        read_u64_le(&sysvar_output, SYSVAR_DIRECT_CLOCK_SLOT_OFFSET),
        CLOCK_SLOT
    );
    assert_eq!(
        read_u64_le(&sysvar_output, SYSVAR_DIRECT_CLOCK_EPOCH_OFFSET),
        CLOCK_EPOCH
    );
    assert_eq!(
        read_u64_le(&sysvar_output, SYSVAR_DIRECT_CLOCK_UNIX_OFFSET),
        CLOCK_UNIX_TIMESTAMP as u64
    );
    assert_eq!(
        read_u64_le(&sysvar_output, SYSVAR_DIRECT_RENT_LAMPORTS_OFFSET),
        RENT_LAMPORTS_PER_BYTE_YEAR
    );
    assert!(
        read_u64_le(&sysvar_output, SYSVAR_REMAINING_COMPUTE_UNITS_OFFSET) > 0,
        "remaining compute units should stay positive on BPF"
    );
}
