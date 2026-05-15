//! SVM-level integration test for the Crypto stdlib wrappers.
//!
//! The setup step compiles `examples/crypto_demo.ml` to `build/crypto_demo.so`
//! with the local `omlz` binary, then loads that artifact into Mollusk and
//! verifies the SHA-256 and Keccak-256 digests logged through `sol_log_pubkey`.

use mollusk_svm::Mollusk;
use solana_instruction::Instruction;
use solana_pubkey::Pubkey;
use solana_svm_log_collector::LogCollector;
use std::fs;

const PROGRAM_ID_BYTES: [u8; 32] = [7u8; 32];
const HASH_INPUT: &[u8] = b"zxcaml crypto demo";

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

mod bpf_test_support;

fn setup_mollusk() -> Mollusk {
    let elf_path = bpf_test_support::compile_program("crypto_demo");
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
fn test_crypto_demo_executes_successfully_and_logs_expected_hashes() {
    let mut mollusk = setup_mollusk();
    let log_collector = LogCollector::new_ref();
    mollusk.logger = Some(log_collector.clone());

    let ix = Instruction {
        program_id: program_id(),
        accounts: vec![],
        data: HASH_INPUT.to_vec(),
    };

    let result = mollusk.process_instruction(&ix, &[]);
    assert!(
        !result.program_result.is_err(),
        "crypto demo should succeed: {:?}",
        result.program_result
    );

    let expected_sha =
        Pubkey::new_from_array(solana_sha256_hasher::hash(HASH_INPUT).to_bytes()).to_string();
    let expected_keccak =
        Pubkey::new_from_array(solana_keccak_hasher::hash(HASH_INPUT).to_bytes()).to_string();

    assert_ne!(
        expected_sha, expected_keccak,
        "SHA-256 and Keccak-256 should produce different digests for the demo input"
    );

    let logs = log_collector.borrow();
    let messages = logs.get_recorded_content();
    assert!(
        messages
            .iter()
            .any(|message| message.contains("crypto demo sha256")),
        "crypto demo should label the SHA-256 digest; captured logs: {messages:?}"
    );
    assert!(
        messages
            .iter()
            .any(|message| message.contains(expected_sha.as_str())),
        "crypto demo should log expected SHA-256 pubkey {expected_sha}; captured logs: {messages:?}"
    );
    assert!(
        messages
            .iter()
            .any(|message| message.contains("crypto demo keccak256")),
        "crypto demo should label the Keccak-256 digest; captured logs: {messages:?}"
    );
    assert!(
        messages
            .iter()
            .any(|message| message.contains(expected_keccak.as_str())),
        "crypto demo should log expected Keccak-256 pubkey {expected_keccak}; captured logs: {messages:?}"
    );
}
