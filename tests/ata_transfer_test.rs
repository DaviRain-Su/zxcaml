//! SVM-level integration test for the ZxCaml ata_transfer program.
//!
//! The setup step compiles `examples/ata_transfer.ml` to
//! `build/ata_transfer.so` with the local `omlz` binary.  This test follows
//! the program-owned mocked SPL Token account fixture convention: source and
//! destination token accounts are owned by the example program, not Tokenkeg,
//! and the BPF helper mutates the packed SPL Token `amount` field directly.

use mollusk_svm::Mollusk;
use solana_account::Account;
use solana_instruction::{AccountMeta, Instruction};
use solana_pubkey::Pubkey;
use std::fs;

const PROGRAM_ID_BYTES: [u8; 32] = [22u8; 32];
const TOKEN_ACCOUNT_LEN: usize = 165;
const MINT_LEN: usize = 82;
const ATA_LAMPORTS: u64 = 2_039_280;
const SYSTEM_PROGRAM_ID: Pubkey = solana_pubkey::pubkey!("11111111111111111111111111111111");
const TOKEN_PROGRAM_ID: Pubkey =
    solana_pubkey::pubkey!("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
const NATIVE_LOADER_ID: Pubkey =
    solana_pubkey::pubkey!("NativeLoader1111111111111111111111111111111");

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

mod bpf_test_support;

fn setup_mollusk() -> Mollusk {
    let elf_path = bpf_test_support::compile_program("ata_transfer");
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

fn mint_account() -> Account {
    Account {
        lamports: 1,
        data: vec![0; MINT_LEN],
        owner: TOKEN_PROGRAM_ID,
        ..Account::default()
    }
}

fn empty_mock_token_account() -> Account {
    Account {
        lamports: ATA_LAMPORTS,
        data: vec![0; TOKEN_ACCOUNT_LEN],
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

fn transfer_data(amount: u64) -> Vec<u8> {
    let mut data = vec![0x01];
    data.extend_from_slice(&amount.to_le_bytes());
    data
}

#[test]
fn ata_transfer_initializes_destination_ata_then_transfers_mocked_tokens() {
    let mollusk = setup_mollusk();
    let funding = Pubkey::new_unique();
    let destination_ata = Pubkey::new_unique();
    let destination_owner = Pubkey::new_unique();
    let mint = Pubkey::new_unique();

    let initialize_ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(funding, true),
            AccountMeta::new(destination_ata, false),
            AccountMeta::new_readonly(destination_owner, false),
            AccountMeta::new_readonly(mint, false),
            AccountMeta::new_readonly(SYSTEM_PROGRAM_ID, false),
            AccountMeta::new_readonly(TOKEN_PROGRAM_ID, false),
        ],
        data: vec![0x00],
    };

    let initialize_result = mollusk.process_instruction(
        &initialize_ix,
        &[
            (funding, signer_account(10_000_000)),
            (destination_ata, empty_mock_token_account()),
            (destination_owner, signer_account(1)),
            (mint, mint_account()),
            (SYSTEM_PROGRAM_ID, executable_program_account()),
            (TOKEN_PROGRAM_ID, executable_program_account()),
        ],
    );
    assert!(
        !initialize_result.program_result.is_err(),
        "ata_transfer initialize should succeed: {:?}",
        initialize_result.program_result
    );

    let destination_after_initialize = &initialize_result.resulting_accounts[1].1;
    assert_eq!(destination_after_initialize.owner, program_id());
    assert_eq!(&destination_after_initialize.data[0..32], mint.as_ref());
    assert_eq!(
        &destination_after_initialize.data[32..64],
        destination_owner.as_ref()
    );
    assert_eq!(token_amount(&destination_after_initialize.data), 0);
    assert_eq!(destination_after_initialize.data[108], 1);

    let source_ata = Pubkey::new_unique();
    let authority = Pubkey::new_unique();
    let initial_source_amount = 500u64;
    let transfer_amount = 125u64;
    let source_account = Account {
        lamports: ATA_LAMPORTS,
        data: token_account_data(&mint, &authority, initial_source_amount),
        owner: program_id(),
        ..Account::default()
    };

    let transfer_ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(source_ata, false),
            AccountMeta::new(destination_ata, false),
            AccountMeta::new_readonly(authority, true),
            AccountMeta::new_readonly(mint, false),
            AccountMeta::new_readonly(SYSTEM_PROGRAM_ID, false),
            AccountMeta::new_readonly(TOKEN_PROGRAM_ID, false),
        ],
        data: transfer_data(transfer_amount),
    };

    let transfer_result = mollusk.process_instruction(
        &transfer_ix,
        &[
            (source_ata, source_account),
            (destination_ata, destination_after_initialize.clone()),
            (authority, signer_account(1)),
            (mint, mint_account()),
            (SYSTEM_PROGRAM_ID, executable_program_account()),
            (TOKEN_PROGRAM_ID, executable_program_account()),
        ],
    );
    assert!(
        !transfer_result.program_result.is_err(),
        "ata_transfer transfer should succeed: {:?}",
        transfer_result.program_result
    );

    let source_after_transfer = &transfer_result.resulting_accounts[0].1;
    let destination_after_transfer = &transfer_result.resulting_accounts[1].1;
    assert_eq!(
        token_amount(&source_after_transfer.data),
        initial_source_amount - transfer_amount
    );
    assert_eq!(
        token_amount(&destination_after_transfer.data),
        transfer_amount
    );
    assert_eq!(&destination_after_transfer.data[0..32], mint.as_ref());
    assert_eq!(
        &destination_after_transfer.data[32..64],
        destination_owner.as_ref()
    );
}
