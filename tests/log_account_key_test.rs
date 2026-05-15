//! SVM-level integration test for account-key pubkey logging.
//!
//! The setup step compiles `examples/log_account_key.ml` to
//! `build/log_account_key.so` with the local `omlz` binary, then loads that
//! artifact into Mollusk and verifies that `Account.key` is logged through the
//! public pubkey logging surface without byte-swapping or truncation.

use mollusk_svm::Mollusk;
use solana_account::Account;
use solana_instruction::{AccountMeta, Instruction};
use solana_pubkey::Pubkey;
use solana_svm_log_collector::LogCollector;
use std::fs;

const PROGRAM_ID_BYTES: [u8; 32] = [56u8; 32];

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

mod bpf_test_support;

fn setup_mollusk() -> Mollusk {
    let elf_path = bpf_test_support::compile_program("log_account_key");
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
fn log_account_key_matches_fixture_pubkey() {
    let mut mollusk = setup_mollusk();
    let log_collector = LogCollector::new_ref();
    mollusk.logger = Some(log_collector.clone());

    let logged_key = Pubkey::new_unique();
    let expected_base58 = logged_key.to_string();
    let ix = Instruction {
        program_id: program_id(),
        accounts: vec![AccountMeta::new_readonly(logged_key, false)],
        data: vec![],
    };
    let logged_account = Account {
        lamports: 123,
        owner: program_id(),
        ..Account::default()
    };

    let result = mollusk.process_instruction(&ix, &[(logged_key, logged_account)]);
    assert!(
        !result.program_result.is_err(),
        "log_account_key should succeed: {:?}",
        result.program_result
    );

    let logs = log_collector.borrow();
    let messages = logs.get_recorded_content();
    assert!(
        !messages
            .iter()
            .any(|message| message.contains("Program log: ZxCaml entrypoint")),
        "log_account_key should not emit default entrypoint noise; captured logs: {messages:?}"
    );
    let matching_logs = messages
        .iter()
        .filter(|message| message.contains(expected_base58.as_str()))
        .count();
    assert_eq!(
        matching_logs, 1,
        "log_account_key should log the fixture base58 key exactly once; expected {expected_base58}, logs: {messages:?}"
    );
}
