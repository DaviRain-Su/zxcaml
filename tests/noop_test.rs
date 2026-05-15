//! SVM-level integration test for the ZxCaml noop program.
//!
//! The setup step compiles `examples/noop.ml` to `build/noop.so` with the
//! local `omlz` binary, then loads that artifact into Mollusk.

use mollusk_svm::Mollusk;
use solana_instruction::Instruction;
use solana_pubkey::Pubkey;
use std::fs;

const PROGRAM_ID_BYTES: [u8; 32] = [13u8; 32];

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

mod bpf_test_support;

fn setup_mollusk() -> Mollusk {
    let elf_path = bpf_test_support::compile_program("noop");
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
fn test_noop_executes_successfully_with_no_accounts() {
    let mollusk = setup_mollusk();

    let ix = Instruction {
        program_id: program_id(),
        accounts: vec![],
        data: vec![],
    };

    let result = mollusk.process_instruction(&ix, &[]);
    assert!(
        !result.program_result.is_err(),
        "noop should succeed with no accounts: {:?}",
        result.program_result
    );
    assert!(
        result.resulting_accounts.is_empty(),
        "noop should not create or modify accounts: {:?}",
        result.resulting_accounts
    );
}
