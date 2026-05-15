//! SVM-level integration test for the ZxCaml counter program.
//!
//! The setup step compiles `examples/counter.ml` to `build/counter.so` with
//! the local `omlz` binary, then verifies an increment instruction mutates the
//! counter account's little-endian u64 state inside Mollusk.

use mollusk_svm::Mollusk;
use solana_account::Account;
use solana_instruction::{AccountMeta, Instruction};
use solana_pubkey::Pubkey;
use std::fs;

const PROGRAM_ID_BYTES: [u8; 32] = [4u8; 32];

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

mod bpf_test_support;

fn setup_mollusk() -> Mollusk {
    let elf_path = bpf_test_support::compile_program("counter");
    let elf = fs::read(&elf_path).unwrap_or_else(|error| {
        panic!(
            "failed to read sBPF artifact at {}: {}",
            elf_path.display(),
            error
        )
    });
    let pid = program_id();
    let loader_v3 = solana_pubkey::pubkey!("BPFLoaderUpgradeab1e11111111111111111111111");
    let mut mollusk = bpf_test_support::new_mollusk();
    mollusk.add_program_with_loader_and_elf(&pid, &loader_v3, &elf);
    mollusk
}

#[test]
fn counter_test_increment_updates_account_data() {
    let mollusk = setup_mollusk();
    let counter_key = Pubkey::new_unique();
    let initial_value = 41u64;
    let mut account_data = vec![0u8; 8];
    account_data.copy_from_slice(&initial_value.to_le_bytes());

    let ix = Instruction {
        program_id: program_id(),
        accounts: vec![AccountMeta::new(counter_key, false)],
        data: vec![0],
    };

    let counter_account = Account {
        lamports: 1_000_000,
        data: account_data,
        owner: program_id(),
        ..Account::default()
    };

    let result = mollusk.process_instruction(&ix, &[(counter_key, counter_account)]);

    assert!(
        !result.program_result.is_err(),
        "counter increment should succeed: {:?}",
        result.program_result
    );

    let counter_post = &result.resulting_accounts[0].1;
    assert!(
        counter_post.data.len() >= 8,
        "counter account should retain at least 8 data bytes"
    );
    let mut value_bytes = [0u8; 8];
    value_bytes.copy_from_slice(&counter_post.data[0..8]);
    assert_eq!(u64::from_le_bytes(value_bytes), initial_value + 1);
}
