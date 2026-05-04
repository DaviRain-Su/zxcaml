//! SVM-level integration test for the ZxCaml pda_storage program.
//!
//! The setup step compiles `examples/pda_storage.ml` to
//! `build/pda_storage.so` with the local `omlz` binary, then verifies the
//! program derives the zignocchio-compatible storage PDA, initializes its
//! account data, and persists an updated u64 value.

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

const PROGRAM_ID_BYTES: [u8; 32] = [16u8; 32];
const SYSTEM_PROGRAM_ID: Pubkey = solana_pubkey::pubkey!("11111111111111111111111111111111");
const NATIVE_LOADER_ID: Pubkey =
    solana_pubkey::pubkey!("NativeLoader1111111111111111111111111111111");
const STORAGE_SPACE: usize = 40;
const RENT_EXEMPT_LAMPORTS: u64 = 1_200_000;

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

fn storage_pda_for_user(user: &Pubkey) -> (Pubkey, u8) {
    let (pda, bump) = Pubkey::find_program_address(&[b"storage", user.as_ref()], &program_id());
    let recreated =
        Pubkey::create_program_address(&[b"storage", user.as_ref(), &[bump]], &program_id())
            .expect("find_program_address must return a valid bump seed");
    assert_eq!(pda, recreated, "test fixture should use canonical PDA");
    (pda, bump)
}

fn user_with_storage_pda_bump_255() -> (Pubkey, Pubkey, u8) {
    loop {
        let user = Pubkey::new_unique();
        let (pda, bump) = storage_pda_for_user(&user);
        if bump == 255 {
            return (user, pda, bump);
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
    let elf_path = compile_program("pda_storage");
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

fn instruction_data(discriminator: u8, value: u64) -> Vec<u8> {
    let mut data = vec![discriminator];
    data.extend_from_slice(&value.to_le_bytes());
    data
}

fn read_storage_value(data: &[u8]) -> u64 {
    let mut value_bytes = [0u8; 8];
    value_bytes.copy_from_slice(&data[32..40]);
    u64::from_le_bytes(value_bytes)
}

#[test]
fn pda_storage_test_initializes_and_updates_pda_state() {
    let mollusk = setup_mollusk();
    let payer = Pubkey::new_unique();
    let (user, storage_pda, _bump) = user_with_storage_pda_bump_255();
    let initial_value = 41u64;
    let updated_value = 9001u64;

    let init_ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(payer, true),
            AccountMeta::new(storage_pda, false),
            AccountMeta::new_readonly(user, true),
            AccountMeta::new_readonly(SYSTEM_PROGRAM_ID, false),
        ],
        data: instruction_data(0, initial_value),
    };

    let payer_account = Account {
        lamports: 10_000_000,
        owner: SYSTEM_PROGRAM_ID,
        ..Account::default()
    };
    let storage_account = Account {
        lamports: RENT_EXEMPT_LAMPORTS,
        data: vec![0; STORAGE_SPACE],
        owner: program_id(),
        ..Account::default()
    };
    let user_account = Account {
        lamports: 1,
        owner: SYSTEM_PROGRAM_ID,
        ..Account::default()
    };
    let system_account = Account {
        executable: true,
        owner: NATIVE_LOADER_ID,
        ..Account::default()
    };

    let init_result = mollusk.process_instruction(
        &init_ix,
        &[
            (payer, payer_account),
            (storage_pda, storage_account),
            (user, user_account),
            (SYSTEM_PROGRAM_ID, system_account),
        ],
    );

    assert!(
        !init_result.program_result.is_err(),
        "pda_storage init should succeed: {:?}",
        init_result.program_result
    );

    let storage_after_init = &init_result.resulting_accounts[1].1;
    assert_eq!(storage_after_init.lamports, RENT_EXEMPT_LAMPORTS);
    assert_eq!(storage_after_init.owner, program_id());
    assert!(
        storage_after_init.data.len() >= STORAGE_SPACE,
        "storage PDA should be allocated with at least {STORAGE_SPACE} bytes"
    );
    assert_eq!(&storage_after_init.data[0..32], user.as_ref());
    assert_eq!(read_storage_value(&storage_after_init.data), initial_value);

    let update_ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(storage_pda, false),
            AccountMeta::new_readonly(user, true),
        ],
        data: instruction_data(1, updated_value),
    };

    let update_result = mollusk.process_instruction(
        &update_ix,
        &[
            (storage_pda, storage_after_init.clone()),
            (user, init_result.resulting_accounts[2].1.clone()),
        ],
    );

    assert!(
        !update_result.program_result.is_err(),
        "pda_storage update should succeed: {:?}",
        update_result.program_result
    );

    let storage_after_update = &update_result.resulting_accounts[0].1;
    assert_eq!(storage_after_update.owner, program_id());
    assert_eq!(&storage_after_update.data[0..32], user.as_ref());
    assert_eq!(read_storage_value(&storage_after_update.data), updated_value);
}
