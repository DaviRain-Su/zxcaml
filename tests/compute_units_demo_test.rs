//! SVM-level integration test for remaining compute-unit observation.
//!
//! The setup step compiles `examples/compute_units_demo.ml` to
//! `build/compute_units_demo.so` with the local `omlz` binary, then verifies
//! that reading remaining compute units before and after a known syscall
//! produces a positive, strictly decreasing pair.

use mollusk_svm::Mollusk;
use solana_instruction::Instruction;
use solana_pubkey::Pubkey;
use solana_svm_log_collector::LogCollector;
use std::fs;

const PROGRAM_ID_BYTES: [u8; 32] = [53u8; 32];

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

mod bpf_test_support;

fn setup_mollusk() -> Mollusk {
    let elf_path = bpf_test_support::compile_program("compute_units_demo");
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
fn compute_units_demo_reports_positive_decreasing_remaining_units() {
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
        "compute units demo should succeed: {:?}",
        result.program_result
    );

    let logs = log_collector.borrow();
    let messages = logs.get_recorded_content();
    let values = messages
        .iter()
        .find_map(|message| parse_sol_log_64(message))
        .unwrap_or_else(|| panic!("expected a sol_log_64 line in logs: {messages:?}"));

    assert!(
        values[0] > values[1],
        "remaining units should strictly decrease after logging; captured values: {values:?}, logs: {messages:?}"
    );
    assert!(
        values[1] > 0,
        "remaining units after the syscall should stay positive; captured values: {values:?}, logs: {messages:?}"
    );
}
