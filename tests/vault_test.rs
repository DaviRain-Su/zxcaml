//! SVM-level integration test for the ZxCaml vault program.
//!
//! The setup step compiles `examples/vault.ml` to `build/vault.so` with the
//! local `omlz` binary, then verifies deposit and withdraw instructions move
//! lamports between an owner and a PDA vault via the System Program.

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

const PROGRAM_ID_BYTES: [u8; 32] = [5u8; 32];
const SYSTEM_PROGRAM_ID: Pubkey = solana_pubkey::pubkey!("11111111111111111111111111111111");
const NATIVE_LOADER_ID: Pubkey =
    solana_pubkey::pubkey!("NativeLoader1111111111111111111111111111111");

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

fn owner_and_vault_pda() -> (Pubkey, Pubkey) {
    loop {
        let owner = Pubkey::new_unique();
        if let Ok(vault) =
            Pubkey::create_program_address(&[b"vault", owner.as_ref()], &program_id())
        {
            return (owner, vault);
        }
    }
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
    for candidate in [
        PathBuf::from("/opt/homebrew/opt/llvm@20/lib"),
        PathBuf::from("/usr/local/opt/llvm@20/lib"),
    ] {
        if candidate.join("libLLVM.dylib").exists() {
            return Some(candidate);
        }
    }

    let output = Command::new("brew")
        .args(["--prefix", "llvm@20"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }

    let prefix = String::from_utf8(output.stdout).ok()?;
    let lib = PathBuf::from(prefix.trim()).join("lib");
    lib.join("libLLVM.dylib").exists().then_some(lib)
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
    let elf_path = compile_program("vault");
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
        .program_cache
        .add_builtin(mollusk_svm::program::Builtin {
            program_id: SYSTEM_PROGRAM_ID,
            name: "system_program",
            entrypoint: solana_system_program::system_processor::Entrypoint::vm,
        });
    mollusk
}

#[test]
fn vault_test_deposit_increases_vault_and_withdraw_returns_funds() {
    let mollusk = setup_mollusk();
    let (owner, vault) = owner_and_vault_pda();
    let initial_owner_lamports = 1_000_000_000;
    let deposit_amount = 123_456u64;

    let mut deposit_data = vec![0];
    deposit_data.extend_from_slice(&deposit_amount.to_le_bytes());
    let deposit_ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(owner, true),
            AccountMeta::new(vault, false),
            AccountMeta::new_readonly(SYSTEM_PROGRAM_ID, false),
        ],
        data: deposit_data,
    };

    let owner_account = Account {
        lamports: initial_owner_lamports,
        owner: SYSTEM_PROGRAM_ID,
        ..Account::default()
    };
    let vault_account = Account {
        lamports: 0,
        owner: SYSTEM_PROGRAM_ID,
        ..Account::default()
    };
    let system_account = Account {
        executable: true,
        owner: NATIVE_LOADER_ID,
        ..Account::default()
    };

    let deposit_result = mollusk.process_instruction(
        &deposit_ix,
        &[
            (owner, owner_account),
            (vault, vault_account),
            (SYSTEM_PROGRAM_ID, system_account),
        ],
    );

    assert!(
        !deposit_result.program_result.is_err(),
        "vault deposit should succeed: {:?}",
        deposit_result.program_result
    );
    let owner_after_deposit = &deposit_result.resulting_accounts[0].1;
    let vault_after_deposit = &deposit_result.resulting_accounts[1].1;
    assert_eq!(
        owner_after_deposit.lamports,
        initial_owner_lamports - deposit_amount
    );
    assert_eq!(vault_after_deposit.lamports, deposit_amount);

    let withdraw_ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(owner, true),
            AccountMeta::new(vault, false),
            AccountMeta::new_readonly(SYSTEM_PROGRAM_ID, false),
        ],
        data: vec![1],
    };

    let withdraw_result = mollusk.process_instruction(
        &withdraw_ix,
        &[
            (owner, deposit_result.resulting_accounts[0].1.clone()),
            (vault, deposit_result.resulting_accounts[1].1.clone()),
            (
                SYSTEM_PROGRAM_ID,
                deposit_result.resulting_accounts[2].1.clone(),
            ),
        ],
    );

    assert!(
        !withdraw_result.program_result.is_err(),
        "vault withdraw should succeed: {:?}",
        withdraw_result.program_result
    );
    let owner_after_withdraw = &withdraw_result.resulting_accounts[0].1;
    let vault_after_withdraw = &withdraw_result.resulting_accounts[1].1;
    assert_eq!(owner_after_withdraw.lamports, initial_owner_lamports);
    assert_eq!(vault_after_withdraw.lamports, 0);
}
