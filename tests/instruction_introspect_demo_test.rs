//! SVM-level integration test for the ZxCaml Instructions sysvar introspection demo.
//!
//! The setup step compiles `examples/instruction_introspect_demo.ml` to
//! `build/instruction_introspect_demo.so`.  The test then runs a two-instruction
//! transaction via Mollusk's `process_transaction_instructions` path so the
//! runtime constructs the Instructions sysvar account from the full transaction.
//! That construction is equivalent to `solana_instructions_sysvar::
//! construct_instructions_data`: a little-endian instruction count, u16 offsets,
//! serialized account metas / program ids / instruction data, plus the current
//! instruction index in the final two bytes.  Including the sysvar account in
//! each instruction lets Mollusk inject that serialized account automatically.

use mollusk_svm::Mollusk;
use solana_account::Account;
use solana_instruction::{AccountMeta, Instruction};
use solana_pubkey::Pubkey;
use std::{
    ffi::OsString,
    fs::{self, OpenOptions},
    path::{Path, PathBuf},
    process::Command,
    thread,
    time::Duration,
};

const PROGRAM_ID_BYTES: [u8; 32] = [49u8; 32];
const SYSTEM_PROGRAM_BYTES: [u8; 32] = [0u8; 32];
const INSTRUCTIONS_SYSVAR_ID: Pubkey =
    solana_pubkey::pubkey!("Sysvar1nstructions1111111111111111111111111");

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

fn system_program_id() -> Pubkey {
    Pubkey::new_from_array(SYSTEM_PROGRAM_BYTES)
}

struct BuildLock {
    path: PathBuf,
}

impl Drop for BuildLock {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
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
    if cfg!(target_os = "macos") {
        if let Some(lib) = llvm20_lib_dir() {
            let mut value = OsString::from(lib);
            if let Some(existing) = std::env::var_os("DYLD_FALLBACK_LIBRARY_PATH") {
                value.push(":");
                value.push(existing);
            }
            command.env("DYLD_FALLBACK_LIBRARY_PATH", value);
        }
    }
}

fn compile_program(example: &str) -> PathBuf {
    let root = repo_root();
    let _lock = acquire_build_lock(&root);
    let output_path = root.join("build").join(format!("{example}.so"));
    let source = format!("examples/{example}.ml");
    let output = format!("build/{example}.so");

    let mut command = Command::new(root.join("zig-out").join("bin").join("omlz"));
    command.current_dir(&root).args([
        "build",
        "--target=bpf",
        source.as_str(),
        "-o",
        output.as_str(),
    ]);
    apply_platform_env(&mut command);

    let result = command.output().unwrap_or_else(|error| {
        panic!(
            "failed to spawn `zig-out/bin/omlz build --target=bpf {source} -o {output}`: {error}"
        )
    });
    assert!(
        result.status.success(),
        "`zig-out/bin/omlz build --target=bpf {source} -o {output}` failed\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&result.stdout),
        String::from_utf8_lossy(&result.stderr)
    );
    assert!(
        output_path.exists(),
        "expected BPF artifact at {}",
        output_path.display()
    );
    output_path
}

fn setup_mollusk() -> Mollusk {
    let elf_path = compile_program("instruction_introspect_demo");
    let elf = fs::read(&elf_path).unwrap_or_else(|error| {
        panic!(
            "failed to read sBPF artifact at {}: {}",
            elf_path.display(),
            error
        )
    });
    let pid = program_id();
    let loader_v3 = solana_pubkey::pubkey!("BPFLoaderUpgradeab1e11111111111111111111111");
    let mut mollusk = Mollusk::default();
    mollusk.add_program_with_loader_and_elf(&pid, &loader_v3, &elf);
    mollusk
}

fn read_u64_le(data: &[u8], offset: usize) -> u64 {
    let mut bytes = [0u8; 8];
    bytes.copy_from_slice(&data[offset..offset + 8]);
    u64::from_le_bytes(bytes)
}

fn system_transfer_data(lamports: u64) -> Vec<u8> {
    let mut data = Vec::with_capacity(12);
    data.extend_from_slice(&2u32.to_le_bytes());
    data.extend_from_slice(&lamports.to_le_bytes());
    data
}

#[test]
fn instruction_introspect_demo_asserts_next_instruction_program_id() {
    let mollusk = setup_mollusk();
    let pid = program_id();
    let output_account = Pubkey::new_unique();
    let payer = Pubkey::new_unique();
    let receiver = Pubkey::new_unique();

    let account_metas = vec![
        AccountMeta::new(output_account, false),
        AccountMeta::new_readonly(INSTRUCTIONS_SYSVAR_ID, false),
    ];

    let first_ix = Instruction {
        program_id: pid,
        accounts: account_metas.clone(),
        data: SYSTEM_PROGRAM_BYTES.to_vec(),
    };
    let second_ix = Instruction {
        program_id: system_program_id(),
        accounts: vec![
            AccountMeta::new(payer, true),
            AccountMeta::new(receiver, false),
        ],
        data: system_transfer_data(1),
    };

    let result = mollusk.process_transaction_instructions(
        &[first_ix, second_ix],
        &[
            (
                output_account,
                Account {
                    lamports: 1_000_000,
                    data: vec![0u8; 32],
                    owner: pid,
                    ..Account::default()
                },
            ),
            (
                payer,
                Account {
                    lamports: 10,
                    owner: system_program_id(),
                    ..Account::default()
                },
            ),
            (
                receiver,
                Account {
                    lamports: 0,
                    owner: system_program_id(),
                    ..Account::default()
                },
            ),
        ],
    );

    assert!(
        result.raw_result.is_ok(),
        "introspection transaction should succeed: {:?}",
        result.raw_result
    );

    let output = &result
        .get_account(&output_account)
        .expect("output account should be present")
        .data;
    assert_eq!(read_u64_le(output, 0), 2, "instruction count");
    assert_eq!(read_u64_le(output, 8), 0, "current instruction index");
    assert_eq!(read_u64_le(output, 16), 1, "next instruction index");
    assert_eq!(
        read_u64_le(output, 24),
        u64::from(SYSTEM_PROGRAM_BYTES[0]),
        "first byte of the introspected next program id"
    );
    assert_eq!(
        result
            .get_account(&payer)
            .expect("payer account should be present")
            .lamports,
        9,
        "second instruction system transfer debits payer"
    );
    assert_eq!(
        result
            .get_account(&receiver)
            .expect("receiver account should be present")
            .lamports,
        1,
        "second instruction system transfer credits receiver"
    );
}
