//! SVM-level integration test for the ZxCaml spl_burn program.
//!
//! The setup step compiles `examples/spl_burn.ml` to `build/spl_burn.so`
//! with the local `omlz` binary.  This test follows the program-owned mocked
//! SPL Token account fixture convention: the token account is owned by the
//! example program, not Tokenkeg, and the BPF helper mutates the packed SPL
//! Token `amount` field directly.

use mollusk_svm::Mollusk;
use solana_account::Account;
use solana_instruction::{AccountMeta, Instruction};
use solana_pubkey::Pubkey;
use solana_svm_log_collector::LogCollector;
use std::fs;

const PROGRAM_ID_BYTES: [u8; 32] = [31u8; 32];
const TOKEN_ACCOUNT_LEN: usize = 165;
const MINT_LEN: usize = 82;
const ATA_LAMPORTS: u64 = 2_039_280;
const MINT_SUPPLY_OFFSET: usize = 36;
const TOKEN_PROGRAM_ID: Pubkey =
    solana_pubkey::pubkey!("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
const TOKEN_2022_PROGRAM_ID: Pubkey =
    solana_pubkey::pubkey!("TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb");
const NATIVE_LOADER_ID: Pubkey =
    solana_pubkey::pubkey!("NativeLoader1111111111111111111111111111111");

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

mod bpf_test_support;

fn setup_mollusk() -> Mollusk {
    let elf_path = bpf_test_support::compile_program("spl_burn");
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

fn mint_account(supply: u64) -> Account {
    let mut data = vec![0; MINT_LEN];
    data[MINT_SUPPLY_OFFSET..MINT_SUPPLY_OFFSET + 8].copy_from_slice(&supply.to_le_bytes());
    data[44] = 6;
    data[45] = 1;
    Account {
        lamports: 1,
        data,
        owner: program_id(),
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

fn token_amount(data: &[u8]) -> u64 {
    let mut amount = [0u8; 8];
    amount.copy_from_slice(&data[64..72]);
    u64::from_le_bytes(amount)
}

fn mint_supply(data: &[u8]) -> u64 {
    let mut supply = [0u8; 8];
    supply.copy_from_slice(&data[MINT_SUPPLY_OFFSET..MINT_SUPPLY_OFFSET + 8]);
    u64::from_le_bytes(supply)
}

fn burn_data(amount: u64) -> Vec<u8> {
    let mut data = vec![0x00];
    data.extend_from_slice(&amount.to_le_bytes());
    data
}

#[test]
fn spl_burn_decrements_mocked_token_balance() {
    let mollusk = setup_mollusk();
    let account_to_burn = Pubkey::new_unique();
    let mint = Pubkey::new_unique();
    let authority = Pubkey::new_unique();
    let initial_amount = 500u64;
    let initial_supply = 1_000u64;
    let burn_amount = 100u64;

    let ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(account_to_burn, false),
            AccountMeta::new(mint, false),
            AccountMeta::new_readonly(authority, true),
            AccountMeta::new_readonly(TOKEN_PROGRAM_ID, false),
        ],
        data: burn_data(burn_amount),
    };

    let result = mollusk.process_instruction(
        &ix,
        &[
            (
                account_to_burn,
                Account {
                    lamports: ATA_LAMPORTS,
                    data: token_account_data(&mint, &authority, initial_amount),
                    owner: program_id(),
                    ..Account::default()
                },
            ),
            (mint, mint_account(initial_supply)),
            (authority, signer_account(1)),
            (TOKEN_PROGRAM_ID, executable_program_account()),
        ],
    );
    assert!(
        !result.program_result.is_err(),
        "spl_burn should succeed: {:?}",
        result.program_result
    );

    let account_after_burn = &result.resulting_accounts[0].1;
    let mint_after_burn = &result.resulting_accounts[1].1;
    assert_eq!(
        token_amount(&account_after_burn.data),
        initial_amount - burn_amount
    );
    assert_eq!(&account_after_burn.data[0..32], mint.as_ref());
    assert_eq!(&account_after_burn.data[32..64], authority.as_ref());
    assert_eq!(account_after_burn.data[108], 1);
    assert_eq!(mint_supply(&mint_after_burn.data), initial_supply - burn_amount);
}

#[test]
fn spl_burn_rejects_insufficient_mocked_balance() {
    let mollusk = setup_mollusk();
    let account_to_burn = Pubkey::new_unique();
    let mint = Pubkey::new_unique();
    let authority = Pubkey::new_unique();

    let ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(account_to_burn, false),
            AccountMeta::new(mint, false),
            AccountMeta::new_readonly(authority, true),
            AccountMeta::new_readonly(TOKEN_PROGRAM_ID, false),
        ],
        data: burn_data(600),
    };

    let result = mollusk.process_instruction(
        &ix,
        &[
            (
                account_to_burn,
                Account {
                    lamports: ATA_LAMPORTS,
                    data: token_account_data(&mint, &authority, 500),
                    owner: program_id(),
                    ..Account::default()
                },
            ),
            (mint, mint_account(1_000)),
            (authority, signer_account(1)),
            (TOKEN_PROGRAM_ID, executable_program_account()),
        ],
    );
    assert!(
        result.program_result.is_err(),
        "spl_burn should reject an over-burn: {:?}",
        result.program_result
    );
    let account_after_failure = &result.resulting_accounts[0].1;
    let mint_after_failure = &result.resulting_accounts[1].1;
    assert_eq!(token_amount(&account_after_failure.data), 500);
    assert_eq!(mint_supply(&mint_after_failure.data), 1_000);
}

#[test]
fn spl_burn_rejects_non_signer_authority() {
    let mollusk = setup_mollusk();
    let account_to_burn = Pubkey::new_unique();
    let mint = Pubkey::new_unique();
    let authority = Pubkey::new_unique();

    let ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(account_to_burn, false),
            AccountMeta::new(mint, false),
            AccountMeta::new_readonly(authority, false),
            AccountMeta::new_readonly(TOKEN_PROGRAM_ID, false),
        ],
        data: burn_data(100),
    };

    let result = mollusk.process_instruction(
        &ix,
        &[
            (
                account_to_burn,
                Account {
                    lamports: ATA_LAMPORTS,
                    data: token_account_data(&mint, &authority, 500),
                    owner: program_id(),
                    ..Account::default()
                },
            ),
            (mint, mint_account(1_000)),
            (authority, signer_account(1)),
            (TOKEN_PROGRAM_ID, executable_program_account()),
        ],
    );
    assert!(
        result.program_result.is_err(),
        "spl_burn should reject a non-signer authority: {:?}",
        result.program_result
    );
    let account_after_failure = &result.resulting_accounts[0].1;
    let mint_after_failure = &result.resulting_accounts[1].1;
    assert_eq!(token_amount(&account_after_failure.data), 500);
    assert_eq!(mint_supply(&mint_after_failure.data), 1_000);
}

#[test]
fn spl_burn_rejects_token_2022_with_explicit_unsupported_diagnostic() {
    let mut mollusk = setup_mollusk();
    let log_collector = LogCollector::new_ref();
    mollusk.logger = Some(log_collector.clone());

    let account_to_burn = Pubkey::new_unique();
    let mint = Pubkey::new_unique();
    let authority = Pubkey::new_unique();

    let ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(account_to_burn, false),
            AccountMeta::new(mint, false),
            AccountMeta::new_readonly(authority, true),
            AccountMeta::new_readonly(TOKEN_2022_PROGRAM_ID, false),
        ],
        data: burn_data(100),
    };

    let result = mollusk.process_instruction(
        &ix,
        &[
            (
                account_to_burn,
                Account {
                    lamports: ATA_LAMPORTS,
                    data: token_account_data(&mint, &authority, 500),
                    owner: program_id(),
                    ..Account::default()
                },
            ),
            (mint, mint_account(1_000)),
            (authority, signer_account(1)),
            (TOKEN_2022_PROGRAM_ID, executable_program_account()),
        ],
    );
    assert!(
        result.program_result.is_err(),
        "spl_burn should reject Token-2022 for the current user surface: {:?}",
        result.program_result
    );

    let logs = log_collector.borrow();
    let messages = logs.get_recorded_content();
    assert!(
        messages.iter().any(|message| message.contains(
            "Program log: Token-2022 unsupported: spl_burn only supports classic Tokenkeg helpers"
        )),
        "spl_burn should emit an explicit Token-2022 unsupported diagnostic; captured logs: {messages:?}"
    );
}
