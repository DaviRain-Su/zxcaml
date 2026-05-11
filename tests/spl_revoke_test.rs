//! SVM-level integration test for the ZxCaml spl_revoke program.
//!
//! The setup step compiles `examples/spl_revoke.ml` to `build/spl_revoke.so`
//! with the local `omlz` binary.  This test follows the program-owned mocked
//! SPL Token account fixture convention: the token account is owned by the
//! example program, not Tokenkeg, and the BPF helper clears the packed SPL
//! Token delegate fields directly.

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

const PROGRAM_ID_BYTES: [u8; 32] = [33u8; 32];
const TOKEN_ACCOUNT_LEN: usize = 165;
const ATA_LAMPORTS: u64 = 2_039_280;
const AMOUNT_OFFSET: usize = 64;
const DELEGATE_OPTION_OFFSET: usize = 72;
const DELEGATE_OFFSET: usize = 76;
const DELEGATE_END: usize = 108;
const DELEGATED_AMOUNT_OFFSET: usize = 121;
const DELEGATED_AMOUNT_END: usize = 129;
const TOKEN_PROGRAM_ID: Pubkey =
    solana_pubkey::pubkey!("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
const NATIVE_LOADER_ID: Pubkey =
    solana_pubkey::pubkey!("NativeLoader1111111111111111111111111111111");

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
    let elf_path = compile_program("spl_revoke");
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

fn executable_program_account() -> Account {
    Account {
        executable: true,
        owner: NATIVE_LOADER_ID,
        ..Account::default()
    }
}

fn signer_account(lamports: u64) -> Account {
    Account {
        lamports,
        ..Account::default()
    }
}

fn token_account_data_with_delegate(
    mint: &Pubkey,
    owner: &Pubkey,
    amount: u64,
    delegate: &Pubkey,
    delegated_amount: u64,
) -> Vec<u8> {
    let mut data = vec![0u8; TOKEN_ACCOUNT_LEN];
    data[0..32].copy_from_slice(mint.as_ref());
    data[32..64].copy_from_slice(owner.as_ref());
    data[AMOUNT_OFFSET..AMOUNT_OFFSET + 8].copy_from_slice(&amount.to_le_bytes());
    data[DELEGATE_OPTION_OFFSET..DELEGATE_OFFSET].copy_from_slice(&1u32.to_le_bytes());
    data[DELEGATE_OFFSET..DELEGATE_END].copy_from_slice(delegate.as_ref());
    data[108] = 1;
    data[DELEGATED_AMOUNT_OFFSET..DELEGATED_AMOUNT_END]
        .copy_from_slice(&delegated_amount.to_le_bytes());
    data
}

fn token_amount(data: &[u8]) -> u64 {
    let mut amount = [0u8; 8];
    amount.copy_from_slice(&data[AMOUNT_OFFSET..AMOUNT_OFFSET + 8]);
    u64::from_le_bytes(amount)
}

fn delegated_amount(data: &[u8]) -> u64 {
    let mut amount = [0u8; 8];
    amount.copy_from_slice(&data[DELEGATED_AMOUNT_OFFSET..DELEGATED_AMOUNT_END]);
    u64::from_le_bytes(amount)
}

fn revoke_data() -> Vec<u8> {
    vec![0x00]
}

#[test]
fn spl_revoke_clears_delegate_fields_and_preserves_token_state() {
    let mollusk = setup_mollusk();
    let source_account = Pubkey::new_unique();
    let authority = Pubkey::new_unique();
    let mint = Pubkey::new_unique();
    let delegate = Pubkey::new_unique();
    let initial_amount = 500u64;
    let initial_delegated_amount = 200u64;

    let ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(source_account, false),
            AccountMeta::new_readonly(authority, true),
            AccountMeta::new_readonly(TOKEN_PROGRAM_ID, false),
        ],
        data: revoke_data(),
    };

    let result = mollusk.process_instruction(
        &ix,
        &[
            (
                source_account,
                Account {
                    lamports: ATA_LAMPORTS,
                    data: token_account_data_with_delegate(
                        &mint,
                        &authority,
                        initial_amount,
                        &delegate,
                        initial_delegated_amount,
                    ),
                    owner: program_id(),
                    ..Account::default()
                },
            ),
            (authority, signer_account(1)),
            (TOKEN_PROGRAM_ID, executable_program_account()),
        ],
    );
    assert!(
        !result.program_result.is_err(),
        "spl_revoke should succeed for the token owner authority: {:?}",
        result.program_result
    );

    let source_after_revoke = &result.resulting_accounts[0].1;
    assert_eq!(
        &source_after_revoke.data[DELEGATE_OPTION_OFFSET..DELEGATE_OFFSET],
        &[0u8; 4]
    );
    assert_eq!(
        &source_after_revoke.data[DELEGATE_OFFSET..DELEGATE_END],
        &[0u8; 32]
    );
    assert_eq!(delegated_amount(&source_after_revoke.data), 0);
    assert_eq!(&source_after_revoke.data[0..32], mint.as_ref());
    assert_eq!(&source_after_revoke.data[32..64], authority.as_ref());
    assert_eq!(token_amount(&source_after_revoke.data), initial_amount);
    assert_eq!(source_after_revoke.data[108], 1);
}

#[test]
fn spl_revoke_rejects_non_signer_authority_without_mutating_delegate() {
    let mollusk = setup_mollusk();
    let source_account = Pubkey::new_unique();
    let authority = Pubkey::new_unique();
    let mint = Pubkey::new_unique();
    let delegate = Pubkey::new_unique();
    let initial_amount = 500u64;
    let initial_delegated_amount = 200u64;
    let initial_data = token_account_data_with_delegate(
        &mint,
        &authority,
        initial_amount,
        &delegate,
        initial_delegated_amount,
    );

    let ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(source_account, false),
            AccountMeta::new_readonly(authority, false),
            AccountMeta::new_readonly(TOKEN_PROGRAM_ID, false),
        ],
        data: revoke_data(),
    };

    let result = mollusk.process_instruction(
        &ix,
        &[
            (
                source_account,
                Account {
                    lamports: ATA_LAMPORTS,
                    data: initial_data.clone(),
                    owner: program_id(),
                    ..Account::default()
                },
            ),
            (authority, signer_account(1)),
            (TOKEN_PROGRAM_ID, executable_program_account()),
        ],
    );
    assert!(
        result.program_result.is_err(),
        "spl_revoke should reject a non-signer authority: {:?}",
        result.program_result
    );

    let source_after_failure = &result.resulting_accounts[0].1;
    assert_eq!(source_after_failure.data, initial_data);
}
