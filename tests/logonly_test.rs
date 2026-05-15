//! SVM-level integration test for the ZxCaml logonly program.
//!
//! The setup step compiles `examples/logonly.ml` to `build/logonly.so` with the
//! local `omlz` binary, then loads that artifact into Mollusk and captures logs.

use mollusk_svm::Mollusk;
use solana_instruction::Instruction;
use solana_pubkey::Pubkey;
use solana_svm_log_collector::LogCollector;
use std::fs;

const PROGRAM_ID_BYTES: [u8; 32] = [14u8; 32];

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

mod bpf_test_support;

fn setup_mollusk() -> Mollusk {
    let elf_path = bpf_test_support::compile_program("logonly");
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
fn test_logonly_emits_string_numeric_and_compute_logs() {
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
        "logonly should succeed: {:?}",
        result.program_result
    );

    let logs = log_collector.borrow();
    let messages = logs.get_recorded_content();
    assert!(
        messages
            .iter()
            .any(|message| message.contains("Program log: logonly: hello")),
        "logonly should emit its zignocchio string log; captured logs: {messages:?}"
    );
    assert!(
        messages
            .iter()
            .any(|message| message.contains("Program log: 0xb, 0x16, 0x21, 0x2c, 0x37")),
        "logonly should emit sol_log_64 values; captured logs: {messages:?}"
    );
    assert!(
        messages
            .iter()
            .any(|message| message.contains("Program consumption:")),
        "logonly should emit a compute-unit log; captured logs: {messages:?}"
    );
}
