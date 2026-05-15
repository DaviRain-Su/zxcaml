//! SVM-level integration tests for the R13 account guard helper example.
//!
//! The program validates signer/writable/owner preconditions and returns stable
//! custom status codes instead of panicking before mutation.

use mollusk_svm::Mollusk;
use solana_account::Account;
use solana_instruction::{AccountMeta, Instruction};
use solana_pubkey::Pubkey;
use std::fs;

const PROGRAM_ID_BYTES: [u8; 32] = [43u8; 32];
const MISSING_SIGNER: &str = "Failure(Custom(1))";
const MISSING_WRITABLE: &str = "Failure(Custom(2))";
const WRONG_OWNER: &str = "Failure(Custom(3))";

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

mod bpf_test_support;

fn setup_mollusk() -> Mollusk {
    let elf_path = bpf_test_support::compile_program("account_guard");
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

fn process_guard(
    authority_is_signer: bool,
    vault_is_writable: bool,
    vault_owner_matches_authority: bool,
) -> String {
    let mollusk = setup_mollusk();
    let authority = Pubkey::new_unique();
    let vault = Pubkey::new_unique();
    let wrong_owner = Pubkey::new_unique();

    let ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new_readonly(authority, authority_is_signer),
            AccountMeta {
                pubkey: vault,
                is_signer: false,
                is_writable: vault_is_writable,
            },
        ],
        data: vec![],
    };

    let authority_account = Account {
        lamports: 10,
        owner: program_id(),
        ..Account::default()
    };
    let vault_account = Account {
        lamports: 20,
        owner: if vault_owner_matches_authority {
            authority
        } else {
            wrong_owner
        },
        ..Account::default()
    };

    let result = mollusk.process_instruction(
        &ix,
        &[(authority, authority_account), (vault, vault_account)],
    );
    format!("{:?}", result.program_result)
}

#[test]
fn account_guard_accepts_valid_accounts() {
    assert_eq!(process_guard(true, true, true), "Success");
}

#[test]
fn account_guard_rejects_missing_signer() {
    assert_eq!(process_guard(false, true, true), MISSING_SIGNER);
}

#[test]
fn account_guard_rejects_missing_writable() {
    assert_eq!(process_guard(true, false, true), MISSING_WRITABLE);
}

#[test]
fn account_guard_rejects_wrong_owner() {
    assert_eq!(process_guard(true, true, false), WRONG_OWNER);
}
