//! SVM-level integration test for the ZxCaml secp256k1 recovery demo.
//!
//! The setup step compiles `examples/secp_recover_demo.ml` to
//! `build/secp_recover_demo.so` with the local `omlz` binary, then verifies
//! that the BPF program parses `(hash, recovery_id, signature)` from
//! instruction data, runs `secp256k1_recover`, and writes the recovered
//! 64-byte uncompressed secp256k1 public key into account 0.

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

const PROGRAM_ID_BYTES: [u8; 32] = [42u8; 32];

// fixture from: https://github.com/bitcoin-core/secp256k1/blob/master/src/modules/recovery/tests_impl.h
// ECDSA test vector: `test_ecdsa_recovery_edge_cases` uses this 32-byte
// message/hash and compact 64-byte signature; only recovery_id=1 succeeds.
const HASH: [u8; 32] = *b"This is a very secret message...";
const RECOVERY_ID: u8 = 1;
const SIGNATURE: [u8; 64] = [
    0x67, 0xcb, 0x28, 0x5f, 0x9c, 0xd1, 0x94, 0xe8, 0x40, 0xd6, 0x29, 0x39, 0x7a, 0xf5, 0x56, 0x96,
    0x62, 0xfd, 0xe4, 0x46, 0x49, 0x99, 0x59, 0x63, 0x17, 0x9a, 0x7d, 0xd1, 0x7b, 0xd2, 0x35, 0x32,
    0x4b, 0x1b, 0x7d, 0xf3, 0x4c, 0xe1, 0xf6, 0x8e, 0x69, 0x4f, 0xf6, 0xf1, 0x1a, 0xc7, 0x51, 0xdd,
    0x7d, 0xd7, 0x3e, 0x38, 0x7e, 0xe4, 0xfc, 0x86, 0x6e, 0x1b, 0xe8, 0xec, 0xc7, 0xdd, 0x95, 0x57,
];
const EXPECTED_PUBKEY: [u8; 64] = [
    134, 135, 74, 107, 36, 167, 84, 98, 113, 22, 86, 14, 122, 225, 92, 214, 158, 179, 62, 115, 180,
    216, 200, 16, 51, 178, 124, 47, 169, 207, 93, 28, 225, 63, 25, 250, 141, 234, 13, 26, 227, 232,
    76, 145, 20, 108, 51, 134, 143, 135, 115, 14, 49, 187, 72, 110, 179, 112, 5, 209, 64, 204, 122,
    85,
];

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

fn llvm_lib_dir() -> Option<PathBuf> {
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

    if let Some(lib) = llvm_lib_dir() {
        let mut value = OsString::from(lib);
        if let Some(existing) = std::env::var_os("DYLD_FALLBACK_LIBRARY_PATH") {
            value.push(":");
            value.push(existing);
        }
        command.env("DYLD_FALLBACK_LIBRARY_PATH", value);
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
    let elf_path = compile_program("secp_recover_demo");
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

fn instruction_data() -> Vec<u8> {
    let mut data = Vec::with_capacity(32 + 1 + 64);
    data.extend_from_slice(&HASH);
    data.push(RECOVERY_ID);
    data.extend_from_slice(&SIGNATURE);
    data
}

#[test]
fn secp_recover_demo_writes_recovered_pubkey_to_account_zero() {
    let mollusk = setup_mollusk();
    let output_account = Pubkey::new_unique();

    let ix = Instruction {
        program_id: program_id(),
        accounts: vec![AccountMeta::new(output_account, false)],
        data: instruction_data(),
    };

    let result = mollusk.process_instruction(
        &ix,
        &[(
            output_account,
            Account {
                lamports: 1_000_000,
                data: vec![0u8; 64],
                owner: program_id(),
                ..Account::default()
            },
        )],
    );

    assert!(
        !result.program_result.is_err(),
        "secp recover demo should succeed: {:?}",
        result.program_result
    );

    let output = &result.resulting_accounts[0].1.data;
    assert_eq!(&output[0..64], EXPECTED_PUBKEY.as_slice());
}
