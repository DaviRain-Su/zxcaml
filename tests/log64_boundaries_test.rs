//! SVM-level integration test for exact `sol_log_64` boundary values.
//!
//! The setup step compiles `examples/log64_boundaries.ml` to
//! `build/log64_boundaries.so` with the local `omlz` binary, then loads that
//! artifact into Mollusk and verifies that the logged values preserve the exact
//! u64 bit patterns emitted by the OCaml syscall surface.

use mollusk_svm::Mollusk;
use solana_instruction::Instruction;
use solana_pubkey::Pubkey;
use solana_svm_log_collector::LogCollector;
use std::fs;

const PROGRAM_ID_BYTES: [u8; 32] = [55u8; 32];
const EXPECTED_MAX_INT: i64 = i64::MAX;
const EXPECTED_MIN_INT: i64 = i64::MIN;

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

mod bpf_test_support;

fn setup_mollusk() -> Mollusk {
    let elf_path = bpf_test_support::compile_program("log64_boundaries");
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

fn parse_sol_log_64(message: &str) -> Option<[u64; 5]> {
    let payload = message.strip_prefix("Program log: ").unwrap_or(message);
    let mut values = [0u64; 5];
    let mut count = 0usize;

    for part in payload.split(", ") {
        let hex = part.trim().strip_prefix("0x")?;
        if count >= values.len() {
            return None;
        }
        values[count] = u64::from_str_radix(hex, 16).ok()?;
        count += 1;
    }

    (count == values.len()).then_some(values)
}

#[test]
fn log64_boundaries_preserve_exact_bit_patterns() {
    let mut mollusk = setup_mollusk();
    let log_collector = LogCollector::new_ref();
    mollusk.logger = Some(log_collector.clone());

    let ix = Instruction {
        program_id: program_id(),
        accounts: vec![],
        data: vec![],
    };

    let result = mollusk.process_instruction(&ix, &[]);
    assert!(
        !result.program_result.is_err(),
        "log64 boundaries should succeed: {:?}",
        result.program_result
    );

    let logs = log_collector.borrow();
    let messages = logs.get_recorded_content();
    assert!(
        !messages
            .iter()
            .any(|message| message.contains("Program log: ZxCaml entrypoint")),
        "log64 boundaries should not emit default entrypoint noise; captured logs: {messages:?}"
    );
    assert!(
        messages
            .iter()
            .any(|message| message.contains("Program log: log64 boundaries")),
        "log64 boundaries should label the fixture; captured logs: {messages:?}"
    );

    let values = messages
        .iter()
        .find_map(|message| parse_sol_log_64(message))
        .unwrap_or_else(|| panic!("expected a sol_log_64 line in logs: {messages:?}"));
    let expected = [
        0,
        1,
        EXPECTED_MAX_INT as u64,
        EXPECTED_MIN_INT as u64,
        (-1i64) as u64,
    ];

    assert_eq!(
        values, expected,
        "sol_log_64 should preserve exact boundary-value bit patterns; logs: {messages:?}"
    );
}
