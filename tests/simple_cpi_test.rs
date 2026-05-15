//! SVM-level integration test for the ZxCaml simple CPI program.
//!
//! The setup step compiles `examples/simple_cpi.ml` to `build/simple_cpi.so`
//! with the local `omlz` binary, then installs the native System Program
//! builtin and verifies the transfer path inside Mollusk.

use mollusk_svm::Mollusk;
use solana_account::Account;
use solana_instruction::{AccountMeta, Instruction};
use solana_pubkey::Pubkey;
use std::fs;

const PROGRAM_ID_BYTES: [u8; 32] = [3u8; 32];
const SYSTEM_PROGRAM_ID: Pubkey = solana_pubkey::pubkey!("11111111111111111111111111111111");

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

mod bpf_test_support;

fn setup_mollusk() -> Mollusk {
    let elf_path = bpf_test_support::compile_program("simple_cpi");
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
        .program_cache
        .add_builtin(mollusk_svm::program::Builtin {
            program_id: SYSTEM_PROGRAM_ID,
            name: "system_program",
            entrypoint: solana_system_program::system_processor::Entrypoint::vm,
        });
    mollusk
}

#[test]
fn test_simple_cpi_transfers_one_lamport() {
    let mollusk = setup_mollusk();
    let from = Pubkey::new_unique();
    let to = Pubkey::new_unique();
    let initial_from_lamports = 1_000_000_000;
    let initial_to_lamports = 10;

    let mut transfer_data = vec![2, 0, 0, 0];
    transfer_data.extend_from_slice(&1u64.to_le_bytes());

    let ix = Instruction {
        program_id: SYSTEM_PROGRAM_ID,
        accounts: vec![AccountMeta::new(from, true), AccountMeta::new(to, false)],
        data: transfer_data,
    };

    let from_acc = Account {
        lamports: initial_from_lamports,
        ..Account::default()
    };
    let to_acc = Account {
        lamports: initial_to_lamports,
        ..Account::default()
    };

    let result = mollusk.process_instruction(&ix, &[(from, from_acc), (to, to_acc)]);

    assert!(
        !result.program_result.is_err(),
        "simple CPI transfer should succeed: {:?}",
        result.program_result
    );

    let from_post = &result.resulting_accounts[0].1;
    let to_post = &result.resulting_accounts[1].1;
    assert_eq!(from_post.lamports, initial_from_lamports - 1);
    assert_eq!(to_post.lamports, initial_to_lamports + 1);
}
