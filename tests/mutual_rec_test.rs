//! SVM-level integration test for a mutually recursive ZxCaml program.
//!
//! The setup step compiles `examples/mutual_rec.ml` to BPF, verifies generated
//! Zig contains both mutually recursive helpers, then executes it under Mollusk.

use mollusk_svm::Mollusk;
use solana_instruction::Instruction;
use solana_pubkey::Pubkey;
use std::fs;

const PROGRAM_ID_BYTES: [u8; 32] = [11u8; 32];

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

mod bpf_test_support;

fn compile_program() -> bpf_test_support::CompiledProgram {
    bpf_test_support::compile_program_with_source("mutual_rec")
}

fn setup_mollusk() -> (Mollusk, String) {
    let compiled = compile_program();
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
fn test_mutual_rec_executes_successfully() {
    let (mollusk, generated_source) = setup_mollusk();

    assert!(
        generated_source.contains("fn omlz_user_is_even")
            && generated_source.contains("fn omlz_user_is_odd"),
        "generated source should contain both mutually recursive helpers:\n{generated_source}"
    );
    assert!(
        generated_source.contains("omlz_user_is_odd(arena")
            && generated_source.contains("omlz_user_is_even(arena"),
        "generated source should contain direct calls between mutual helpers:\n{generated_source}"
    );

    let ix = Instruction {
        program_id: program_id(),
        accounts: vec![],
        data: vec![],
    };

    let result = mollusk.process_instruction(&ix, &[]);
    assert_eq!(
        format!("{:?}", result.program_result),
        "Failure(Custom(1))",
        "mutual_rec should return the computed even/odd result as custom status 1"
    );
}
