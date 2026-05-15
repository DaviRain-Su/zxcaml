//! SVM-level integration test for failed OCaml assert expressions.
//!
//! The setup step writes a tiny `assert false` program, compiles it to BPF,
//! verifies the generated Zig uses the assert panic path, then confirms Mollusk
//! reports a program failure instead of a successful return.

use mollusk_svm::Mollusk;
use solana_instruction::Instruction;
use solana_pubkey::Pubkey;
use std::{fs, path::PathBuf};

mod bpf_test_support;
const PROGRAM_ID_BYTES: [u8; 32] = [12u8; 32];

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

struct ScratchSource {
    path: PathBuf,
}

impl Drop for ScratchSource {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

struct CompiledProgram {
    elf_path: PathBuf,
    generated_source: String,
    _scratch_source: ScratchSource,
}

fn write_assert_source() -> (ScratchSource, PathBuf) {
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system clock should be after Unix epoch")
        .as_nanos();

    let root = bpf_test_support::repo_root();
    let source_name = format!("assert_false-{}-{stamp}.ml", std::process::id());
    let output_name = format!("assert_false-{}-{stamp}.so", std::process::id());
    let source_path = root.join("examples").join(&source_name);
    let output_path = root.join("build").join(&output_name);

    fs::write(&source_path, "let entrypoint _ =\n  assert false;\n  0\n").unwrap_or_else(|error| {
        panic!(
            "failed to write assert source at {}: {error}",
            source_path.display()
        )
    });

    let source_file = ScratchSource { path: source_path };

    (source_file, output_path)
}

fn compile_program() -> CompiledProgram {
    let root = bpf_test_support::repo_root();
    let (scratch_source, output_path) = write_assert_source();

    bpf_test_support::compile_program_from_path(&scratch_source.path, &output_path);

    let generated_path = root.join("out").join("program.zig");
    let generated_source = fs::read_to_string(&generated_path).unwrap_or_else(|error| {
        panic!(
            "failed to read generated Zig source at {}: {error}",
            generated_path.display()
        )
    });

    CompiledProgram {
        elf_path: output_path,
        generated_source,
        _scratch_source: scratch_source,
    }
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
fn test_assert_false_aborts_bpf() {
    let (mollusk, generated_source) = setup_mollusk();

    assert!(
        generated_source.contains("runtime_panic.assertFailure()"),
        "generated source should call the assert panic helper:\n{generated_source}"
    );

    let ix = Instruction {
        program_id: program_id(),
        accounts: vec![],
        data: vec![],
    };

    let result = mollusk.process_instruction(&ix, &[]);
    assert!(
        result.program_result.is_err(),
        "assert false should abort on BPF, got {:?}",
        result.program_result
    );
}
