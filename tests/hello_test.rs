//! SVM-level integration test for the ZxCaml hello program.
//!
//! The setup step compiles `examples/hello.ml` to `build/hello.so` with the
//! local `omlz` binary, then loads that artifact into Mollusk.

use mollusk_svm::Mollusk;
use solana_instruction::Instruction;
use solana_pubkey::Pubkey;

mod bpf_test_support;

use std::{fs, path::PathBuf};

const PROGRAM_ID_BYTES: [u8; 32] = [1u8; 32];

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

fn compile_program(example: &str) -> PathBuf {
    bpf_test_support::compile_program(example)
}

fn setup_mollusk() -> Mollusk {
    let elf_path = compile_program("hello");
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
fn test_hello_executes_successfully() {
    let mollusk = setup_mollusk();

    let ix = Instruction {
        program_id: program_id(),
        accounts: vec![],
        data: vec![],
    };

    let result = mollusk.process_instruction(&ix, &[]);
    assert!(
        !result.program_result.is_err(),
        "hello should succeed: {:?}",
        result.program_result
    );
}
