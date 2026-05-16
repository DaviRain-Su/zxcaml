//! SVM-level integration tests for the account parser/view migration fixture.
//!
//! The program reports parsed account fields into a writable output account and
//! can also verify duplicate-account aliasing through a second account slot.

use mollusk_svm::Mollusk;
use solana_account::Account;
use solana_instruction::{AccountMeta, Instruction};
use solana_pubkey::Pubkey;
use std::fs;

const PROGRAM_ID_BYTES: [u8; 32] = [51u8; 32];

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

mod bpf_test_support;

fn setup_mollusk() -> Mollusk {
    let elf_path = bpf_test_support::compile_program("account_parser_view");
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

fn read_u64_le(data: &[u8], offset: usize) -> u64 {
    let mut bytes = [0u8; 8];
    bytes.copy_from_slice(&data[offset..offset + 8]);
    u64::from_le_bytes(bytes)
}

#[test]
fn account_parser_view_reports_key_owner_flags_lamports_and_data() {
    let mollusk = setup_mollusk();
    let subject = Pubkey::new_unique();
    let alias = Pubkey::new_unique();
    let output = Pubkey::new_unique();
    let subject_owner = Pubkey::new_unique();
    let subject_data = b"\x01\x02\x03\x04\x05\x06\x07\x08".to_vec();
    let subject_lamports = 42u64;

    let ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta {
                pubkey: subject,
                is_signer: true,
                is_writable: false,
            },
            AccountMeta::new_readonly(alias, false),
            AccountMeta::new(output, false),
        ],
        data: vec![0],
    };

    let subject_account = Account {
        lamports: subject_lamports,
        data: subject_data.clone(),
        owner: subject_owner,
        executable: true,
        rent_epoch: 777,
        ..Account::default()
    };
    let alias_account = Account {
        lamports: 9,
        owner: Pubkey::new_unique(),
        ..Account::default()
    };
    let output_account = Account {
        lamports: 1,
        data: vec![0u8; 91],
        owner: program_id(),
        ..Account::default()
    };

    let result = mollusk.process_instruction(
        &ix,
        &[
            (subject, subject_account),
            (alias, alias_account),
            (output, output_account),
        ],
    );

    assert!(
        !result.program_result.is_err(),
        "account parser view report should succeed: {:?}",
        result.program_result
    );

    let output_post = result
        .get_account(&output)
        .expect("output account should be present after report");
    assert_eq!(&output_post.data[0..32], subject.as_ref(), "subject key bytes");
    assert_eq!(
        &output_post.data[32..64],
        subject_owner.as_ref(),
        "subject owner bytes"
    );
    assert_eq!(
        read_u64_le(&output_post.data, 64),
        subject_lamports,
        "subject lamports"
    );
    assert_eq!(output_post.data[72], 1, "subject signer flag");
    assert_eq!(output_post.data[73], 0, "subject writable flag");
    assert_eq!(output_post.data[74], 1, "subject executable flag");
    assert_eq!(
        read_u64_le(&output_post.data, 75),
        subject_data.len() as u64,
        "subject data length"
    );
    assert_eq!(
        &output_post.data[83..91],
        subject_data.as_slice(),
        "subject data prefix"
    );
}

#[test]
fn account_parser_view_duplicate_account_slots_alias_shared_state() {
    let mollusk = setup_mollusk();
    let shared = Pubkey::new_unique();
    let output = Pubkey::new_unique();

    let ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(shared, false),
            AccountMeta::new(shared, false),
            AccountMeta::new(output, false),
        ],
        data: vec![1],
    };

    let shared_account = Account {
        lamports: 9,
        data: vec![0u8; 8],
        owner: program_id(),
        ..Account::default()
    };
    let output_account = Account {
        lamports: 1,
        data: vec![0u8; 8],
        owner: program_id(),
        ..Account::default()
    };

    let result =
        mollusk.process_instruction(&ix, &[(shared, shared_account), (output, output_account)]);

    assert!(
        !result.program_result.is_err(),
        "duplicate account alias check should succeed: {:?}",
        result.program_result
    );

    let shared_post = result
        .get_account(&shared)
        .expect("shared account should remain present");
    assert_eq!(shared_post.data, b"shared!!".to_vec(), "shared account data");

    let output_post = result
        .get_account(&output)
        .expect("output account should be present after duplicate check");
    assert_eq!(read_u64_le(&output_post.data, 0), 1, "duplicate alias marker");
}

#[test]
fn account_parser_view_missing_account_access_fails_safely() {
    let mollusk = setup_mollusk();
    let subject = Pubkey::new_unique();
    let alias = Pubkey::new_unique();

    let ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new_readonly(subject, false),
            AccountMeta::new_readonly(alias, false),
        ],
        data: vec![0],
    };

    let result = mollusk.process_instruction(
        &ix,
        &[
            (subject, Account::default()),
            (alias, Account::default()),
        ],
    );

    assert!(
        result.program_result.is_err(),
        "missing output account should fail safely: {:?}",
        result.program_result
    );
}

#[test]
fn account_parser_view_more_than_sixteen_accounts_is_explicit_failure() {
    let mollusk = setup_mollusk();
    let subject = Pubkey::new_unique();
    let alias = Pubkey::new_unique();
    let output = Pubkey::new_unique();

    let mut accounts = vec![
        AccountMeta::new_readonly(subject, false),
        AccountMeta::new_readonly(alias, false),
        AccountMeta::new(output, false),
    ];
    let mut backing = vec![
        (subject, Account::default()),
        (alias, Account::default()),
        (
            output,
            Account {
                data: vec![0u8; 91],
                owner: program_id(),
                ..Account::default()
            },
        ),
    ];
    for _ in 0..14 {
        let key = Pubkey::new_unique();
        accounts.push(AccountMeta::new_readonly(key, false));
        backing.push((key, Account::default()));
    }

    let ix = Instruction {
        program_id: program_id(),
        accounts,
        data: vec![0],
    };

    let result = mollusk.process_instruction(&ix, &backing);
    assert!(
        result.program_result.is_err(),
        "more than sixteen accounts should fail explicitly, not silently truncate: {:?}",
        result.program_result
    );
}
