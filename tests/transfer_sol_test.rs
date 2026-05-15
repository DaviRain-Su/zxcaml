//! SVM-level integration test for the ZxCaml transfer_sol program.
//!
//! The setup step compiles `examples/transfer_sol.ml` to
//! `build/transfer_sol.so` with the local `omlz` binary, then verifies the
//! program performs a System Program CPI using the amount encoded in the
//! zignocchio-compatible instruction payload.

use mollusk_svm::Mollusk;
use solana_account::Account;
use solana_instruction::{AccountMeta, Instruction};
use solana_pubkey::Pubkey;
use std::fs;

const PROGRAM_ID_BYTES: [u8; 32] = [15u8; 32];
const SYSTEM_PROGRAM_ID: Pubkey = solana_pubkey::pubkey!("11111111111111111111111111111111");
const NATIVE_LOADER_ID: Pubkey =
    solana_pubkey::pubkey!("NativeLoader1111111111111111111111111111111");

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

mod bpf_test_support;

fn setup_mollusk() -> Mollusk {
    let elf_path = bpf_test_support::compile_program("transfer_sol");
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
fn transfer_sol_test_moves_lamports_via_system_cpi() {
    let mollusk = setup_mollusk();
    let from = Pubkey::new_unique();
    let to = Pubkey::new_unique();
    let amount = 1_000_000u64;
    let initial_from_lamports = 10_000_000u64;
    let initial_to_lamports = 42u64;

    let ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(from, true),
            AccountMeta::new(to, false),
            AccountMeta::new_readonly(SYSTEM_PROGRAM_ID, false),
        ],
        data: amount.to_le_bytes().to_vec(),
    };

    let from_account = Account {
        lamports: initial_from_lamports,
        owner: SYSTEM_PROGRAM_ID,
        ..Account::default()
    };
    let to_account = Account {
        lamports: initial_to_lamports,
        owner: SYSTEM_PROGRAM_ID,
        ..Account::default()
    };
    let system_account = Account {
        executable: true,
        owner: NATIVE_LOADER_ID,
        ..Account::default()
    };

    let result = mollusk.process_instruction(
        &ix,
        &[
            (from, from_account),
            (to, to_account),
            (SYSTEM_PROGRAM_ID, system_account),
        ],
    );

    assert!(
        !result.program_result.is_err(),
        "transfer_sol should succeed: {:?}",
        result.program_result
    );

    let from_post = &result.resulting_accounts[0].1;
    let to_post = &result.resulting_accounts[1].1;
    assert_eq!(from_post.lamports, initial_from_lamports - amount);
    assert_eq!(to_post.lamports, initial_to_lamports + amount);
}
