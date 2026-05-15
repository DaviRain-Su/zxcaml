//! SVM-level integration test for tail-recursive ZxCaml programs.
//!
//! The setup step compiles `examples/tail_rec.ml` to BPF, verifies generated
//! Zig uses a loop for the self tail call, then executes it under Mollusk.

use mollusk_svm::Mollusk;
use solana_instruction::Instruction;
use solana_pubkey::Pubkey;
use std::fs;

const PROGRAM_ID_BYTES: [u8; 32] = [10u8; 32];

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

mod bpf_test_support;

fn compile_program(example: &str) -> bpf_test_support::CompiledProgram {
    bpf_test_support::compile_program_with_source(example)
}

fn setup_mollusk() -> (Mollusk, String) {
    let compiled = compile_program("tail_rec");
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
fn test_tail_rec_executes_deep_recursion_without_stack_overflow() {
    let (mollusk, generated_source) = setup_mollusk();

    assert!(
        generated_source.contains("while (true)"),
        "tail-recursive helper should emit a loop; generated source:\n{generated_source}"
    );

    let fact_body = generated_source
        .split("fn omlz_user_fact_loop")
        .nth(1)
        .and_then(|tail| tail.split("\n}\n\n").next())
        .expect("generated source should contain fact_loop helper body");
    assert!(
        !fact_body.contains("omlz_user_fact_loop(arena"),
        "tail-recursive helper body should not recursively call itself; body:\n{fact_body}"
    );

    let ix = Instruction {
        program_id: program_id(),
        accounts: vec![],
        data: vec![],
    };

    let result = mollusk.process_instruction(&ix, &[]);
    assert!(
        !result.program_result.is_err(),
        "tail_rec should succeed without stack overflow: {:?}",
        result.program_result
    );
}
