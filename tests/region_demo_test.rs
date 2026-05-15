//! SVM-level integration test for the ZxCaml region inference demo.
//!
//! The setup step compiles `examples/region_demo.ml` to
//! `build/region_demo.so`, verifies the generated Zig contains both stack
//! locals and arena-backed lets, then loads the artifact into Mollusk.

use mollusk_svm::Mollusk;
use solana_instruction::Instruction;
use solana_pubkey::Pubkey;
use solana_svm_log_collector::LogCollector;
use std::fs;

const PROGRAM_ID_BYTES: [u8; 32] = [8u8; 32];

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

mod bpf_test_support;

fn compile_program(example: &str) -> bpf_test_support::CompiledProgram {
    bpf_test_support::compile_program_with_source(example)
}

fn setup_mollusk() -> (Mollusk, String) {
    let compiled = compile_program("region_demo");
    let elf = fs::read(&compiled.elf_path).unwrap_or_else(|error| {
        panic!(
            "failed to read sBPF artifact at {}: {}",
            compiled.elf_path.display(),
            error
        )
    });
    let pid = program_id();
    let loader_v3 = solana_pubkey::pubkey!("BPFLoaderUpgradeab1e11111111111111111111111");
    let mut mollusk = bpf_test_support::new_mollusk();
    mollusk.add_program_with_loader_and_elf(&pid, &loader_v3, &elf);
    (mollusk, compiled.generated_source)
}

#[test]
fn test_region_demo_executes_and_shows_region_storage() {
    let (mut mollusk, generated_source) = setup_mollusk();
    let log_collector = LogCollector::new_ref();
    mollusk.logger = Some(log_collector.clone());

    assert!(
        generated_source.contains("var stack_left: i64 ="),
        "region demo should emit stack_left as a Zig stack local; generated source:\n{generated_source}"
    );
    assert!(
        generated_source.contains("var stack_right: i64 ="),
        "region demo should emit stack_right as a Zig stack local; generated source:\n{generated_source}"
    );
    assert!(
        generated_source.contains("var stack_mix: i64 ="),
        "region demo should emit stack_mix as a Zig stack local; generated source:\n{generated_source}"
    );
    assert!(
        generated_source.contains("const arena_value = arena.allocOneOrTrap(i64);"),
        "region demo should keep function-argument lets arena-backed; generated source:\n{generated_source}"
    );

    let ix = Instruction {
        program_id: program_id(),
        accounts: vec![],
        data: vec![],
    };

    let result = mollusk.process_instruction(&ix, &[]);
    assert!(
        !result.program_result.is_err(),
        "region demo should succeed: {:?}",
        result.program_result
    );

    let logs = log_collector.borrow();
    let messages = logs.get_recorded_content();
    assert!(
        messages
            .iter()
            .any(|message| message.contains("region demo")),
        "region demo should emit its string log; captured logs: {messages:?}"
    );
    assert!(
        messages.len() >= 2,
        "region demo should emit both string and numeric logs; captured logs: {messages:?}"
    );
}
