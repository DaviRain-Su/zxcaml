//! SVM-level integration test for the ZxCaml spl_close_account program.
//!
//! The setup step compiles `examples/spl_close_account.ml` to
//! `build/spl_close_account.so` with the local `omlz` binary.  This test
//! follows the program-owned mocked SPL Token account fixture convention: the
//! token account is owned by the example program, not Tokenkeg, and the BPF
//! helper transfers lamports and zeroes packed SPL Token account data directly.

use mollusk_svm::Mollusk;
use solana_account::Account;
use solana_instruction::{AccountMeta, Instruction};
use solana_pubkey::Pubkey;
use std::fs;

const PROGRAM_ID_BYTES: [u8; 32] = [32u8; 32];
const TOKEN_ACCOUNT_LEN: usize = 165;
const ATA_LAMPORTS: u64 = 2_039_280;
const TOKEN_PROGRAM_ID: Pubkey =
    solana_pubkey::pubkey!("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
const NATIVE_LOADER_ID: Pubkey =
    solana_pubkey::pubkey!("NativeLoader1111111111111111111111111111111");

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

mod bpf_test_support;

fn setup_mollusk() -> Mollusk {
    let elf_path = bpf_test_support::compile_program("spl_close_account");
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

fn executable_program_account() -> Account {
    Account {
        executable: true,
        owner: NATIVE_LOADER_ID,
        ..Account::default()
    }
}

fn signer_account(lamports: u64) -> Account {
    Account {
        lamports,
        ..Account::default()
    }
}

fn token_account_data(mint: &Pubkey, owner: &Pubkey, amount: u64) -> Vec<u8> {
    let mut data = vec![0u8; TOKEN_ACCOUNT_LEN];
    data[0..32].copy_from_slice(mint.as_ref());
    data[32..64].copy_from_slice(owner.as_ref());
    data[64..72].copy_from_slice(&amount.to_le_bytes());
    data[108] = 1;
    data
}

fn close_account_data() -> Vec<u8> {
    vec![0x00]
}

#[test]
fn spl_close_account_refunds_rent_and_zeroes_account_data() {
    let mollusk = setup_mollusk();
    let account_to_close = Pubkey::new_unique();
    let destination = Pubkey::new_unique();
    let authority = Pubkey::new_unique();
    let mint = Pubkey::new_unique();
    let destination_initial_lamports = 5_000u64;

    let ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(account_to_close, false),
            AccountMeta::new(destination, false),
            AccountMeta::new_readonly(authority, true),
            AccountMeta::new_readonly(TOKEN_PROGRAM_ID, false),
        ],
        data: close_account_data(),
    };

    let result = mollusk.process_instruction(
        &ix,
        &[
            (
                account_to_close,
                Account {
                    lamports: ATA_LAMPORTS,
                    data: token_account_data(&mint, &authority, 0),
                    owner: program_id(),
                    ..Account::default()
                },
            ),
            (destination, signer_account(destination_initial_lamports)),
            (authority, signer_account(1)),
            (TOKEN_PROGRAM_ID, executable_program_account()),
        ],
    );
    assert!(
        !result.program_result.is_err(),
        "spl_close_account should succeed for a zero-balance mocked token account: {:?}",
        result.program_result
    );

    let closed_account = &result.resulting_accounts[0].1;
    let destination_account = &result.resulting_accounts[1].1;
    assert_eq!(closed_account.lamports, 0);
    assert_eq!(
        destination_account.lamports,
        destination_initial_lamports + ATA_LAMPORTS
    );
    assert_eq!(closed_account.data, vec![0u8; TOKEN_ACCOUNT_LEN]);
}

#[test]
fn spl_close_account_rejects_non_zero_token_balance() {
    let mollusk = setup_mollusk();
    let account_to_close = Pubkey::new_unique();
    let destination = Pubkey::new_unique();
    let authority = Pubkey::new_unique();
    let mint = Pubkey::new_unique();

    let ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(account_to_close, false),
            AccountMeta::new(destination, false),
            AccountMeta::new_readonly(authority, true),
            AccountMeta::new_readonly(TOKEN_PROGRAM_ID, false),
        ],
        data: close_account_data(),
    };

    let result = mollusk.process_instruction(
        &ix,
        &[
            (
                account_to_close,
                Account {
                    lamports: ATA_LAMPORTS,
                    data: token_account_data(&mint, &authority, 1),
                    owner: program_id(),
                    ..Account::default()
                },
            ),
            (destination, signer_account(5_000)),
            (authority, signer_account(1)),
            (TOKEN_PROGRAM_ID, executable_program_account()),
        ],
    );
    assert!(
        result.program_result.is_err(),
        "spl_close_account should reject a non-zero mocked token balance: {:?}",
        result.program_result
    );
}
