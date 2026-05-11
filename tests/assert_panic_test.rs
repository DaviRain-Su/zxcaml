//! SVM-level integration test for failed OCaml assert expressions.
//!
//! The setup step writes a tiny `assert false` program, compiles it to BPF,
//! verifies the generated Zig uses the assert panic path, then confirms Mollusk
//! reports a program failure instead of a successful return.

use mollusk_svm::Mollusk;
use solana_instruction::Instruction;
use solana_pubkey::Pubkey;
use std::{
    ffi::OsString,
    fs::{self, OpenOptions},
    path::{Path, PathBuf},
    process::Command,
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

const PROGRAM_ID_BYTES: [u8; 32] = [12u8; 32];

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

struct BuildLock {
    path: PathBuf,
}

impl Drop for BuildLock {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

struct ScratchDir {
    path: PathBuf,
}

impl Drop for ScratchDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

struct CompiledProgram {
    elf_path: PathBuf,
    generated_source: String,
    _scratch_dir: ScratchDir,
}

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("tests/ must live under the repository root")
        .to_path_buf()
}

fn acquire_build_lock(root: &Path) -> BuildLock {
    let build_dir = root.join("build");
    fs::create_dir_all(&build_dir).expect("failed to create build/ output directory");
    let path = build_dir.join(".omlz-build.lock");

    for _ in 0..600 {
        match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(_) => return BuildLock { path },
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                thread::sleep(Duration::from_millis(100));
            }
            Err(error) => panic!("failed to create build lock at {}: {error}", path.display()),
        }
    }

    panic!("timed out waiting for build lock at {}", path.display());
}

fn create_scratch_dir() -> ScratchDir {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock should be after Unix epoch")
        .as_nanos();
    let path = std::env::temp_dir().join(format!(
        "zxcaml-assert-panic-{}-{stamp}",
        std::process::id()
    ));
    fs::create_dir(&path).unwrap_or_else(|error| {
        panic!(
            "failed to create scratch dir at {}: {error}",
            path.display()
        )
    });
    ScratchDir { path }
}

fn llvm20_lib_dir() -> Option<PathBuf> {
    let llvm_roots = ["/opt/homebrew/opt", "/usr/local/opt"];
    for root in llvm_roots {
        if let Ok(entries) = fs::read_dir(root) {
            for entry in entries.flatten() {
                let name = entry.file_name();
                let name = name.to_string_lossy();
                if !name.starts_with("llvm") {
                    continue;
                }

                let candidate = entry.path().join("lib");
                if candidate.join("libLLVM.dylib").exists() {
                    return Some(candidate);
                }
            }
        }
    }

    None
}


fn apply_platform_env(command: &mut Command) {
    if !cfg!(target_os = "macos") {
        return;
    }

    if !std::env::var("SOLANA_ZIG").is_ok_and(|value| value == "0") {
        return;
    }

    if let Some(lib) = llvm20_lib_dir() {
        let mut value = OsString::from(lib);
        if let Some(existing) = std::env::var_os("DYLD_FALLBACK_LIBRARY_PATH") {
            value.push(":");
            value.push(existing);
        }
        command.env("DYLD_FALLBACK_LIBRARY_PATH", value);
    }
}

fn compile_program() -> CompiledProgram {
    let root = repo_root();
    let _lock = acquire_build_lock(&root);
    let scratch_dir = create_scratch_dir();
    let source_path = scratch_dir.path.join("assert_false.ml");
    let output_path = scratch_dir.path.join("assert_false.so");

    fs::write(&source_path, "let entrypoint _ =\n  assert false;\n  0\n").unwrap_or_else(|error| {
        panic!(
            "failed to write assert source at {}: {error}",
            source_path.display()
        )
    });

    let mut command = Command::new(root.join("zig-out").join("bin").join("omlz"));
    command
        .current_dir(&root)
        .arg("build")
        .arg("--target=bpf")
        .arg(&source_path)
        .arg("-o")
        .arg(&output_path);
    apply_platform_env(&mut command);

    let result = command.output().unwrap_or_else(|error| {
        panic!(
            "failed to spawn `zig-out/bin/omlz build --target=bpf {} -o {}`: {error}",
            source_path.display(),
            output_path.display()
        )
    });
    assert!(
        result.status.success(),
        "`zig-out/bin/omlz build --target=bpf {} -o {}` failed\nstdout:\n{}\nstderr:\n{}",
        source_path.display(),
        output_path.display(),
        String::from_utf8_lossy(&result.stdout),
        String::from_utf8_lossy(&result.stderr)
    );
    assert!(
        output_path.exists(),
        "expected BPF artifact at {}",
        output_path.display()
    );

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
        _scratch_dir: scratch_dir,
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
    let mut mollusk = Mollusk::default();
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
