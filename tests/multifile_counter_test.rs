//! SVM-level integration tests for the ADR-016 multi-file module trio.
//!
//! `examples/multifile_counter_init.ml` and `examples/multifile_counter_bump.ml`
//! both `open Multifile_counter_types`; the setup step compiles each entry
//! file with the local `omlz` binary, which resolves the shared
//! `examples/multifile_counter_types.ml` dependency through closure
//! resolution and joins the files into one program per artifact.

use mollusk_svm::Mollusk;
use solana_instruction::Instruction;
use solana_pubkey::Pubkey;
use std::fs;

const INIT_PROGRAM_ID_BYTES: [u8; 32] = [61u8; 32];
const BUMP_PROGRAM_ID_BYTES: [u8; 32] = [62u8; 32];

mod bpf_test_support;

fn setup_mollusk(example: &str, program_id: &Pubkey) -> Mollusk {
    let elf_path = bpf_test_support::compile_program(example);
    let elf = fs::read(&elf_path).unwrap_or_else(|error| {
        panic!(
            "failed to read sBPF artifact at {}: {}",
            elf_path.display(),
            error
        )
    });
    let loader_v3 = solana_pubkey::pubkey!("BPFLoaderUpgradeab1e11111111111111111111111");
    let mut mollusk = bpf_test_support::new_mollusk();
    mollusk.add_program_with_loader_and_elf(program_id, &loader_v3, &elf);
    mollusk
}

fn process(example: &str, program_id_bytes: [u8; 32]) -> String {
    let program_id = Pubkey::new_from_array(program_id_bytes);
    let mollusk = setup_mollusk(example, &program_id);

    let ix = Instruction {
        program_id,
        accounts: vec![],
        data: vec![],
    };

    let result = mollusk.process_instruction(&ix, &[]);
    format!("{:?}", result.program_result)
}

/// The init program decodes a canned Init instruction through the shared
/// `decode_op` / `op_code` helpers and returns 0.
#[test]
fn multifile_counter_init_returns_init_wire_code() {
    assert_eq!(
        process("multifile_counter_init", INIT_PROGRAM_ID_BYTES),
        "Success"
    );
}

/// The bump program decodes a canned `Bump 5` instruction through the same
/// shared types module, survives the clamp guard, and returns the amount 5.
#[test]
fn multifile_counter_bump_returns_clamped_amount() {
    assert_eq!(
        process("multifile_counter_bump", BUMP_PROGRAM_ID_BYTES),
        "Failure(Custom(5))"
    );
}
