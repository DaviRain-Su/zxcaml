//! SVM-level integration test for the ZxCaml counter_v2 program.
//!
//! The setup step compiles `examples/counter_v2.ml` to
//! `build/counter_v2.so` with the local `omlz` binary, then verifies a
//! PDA-backed counter account can be initialized and incremented using the
//! zignocchio-compatible one-byte instruction discriminator.

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

const PROGRAM_ID_BYTES: [u8; 32] = [17u8; 32];
const COUNTER_SPACE: usize = 8;
const RENT_EXEMPT_LAMPORTS: u64 = 1_000_000;

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

fn counter_pda_for_user(user: &Pubkey) -> (Pubkey, u8) {
    let (pda, bump) = Pubkey::find_program_address(&[b"counter", user.as_ref()], &program_id());
    let recreated =
        Pubkey::create_program_address(&[b"counter", user.as_ref(), &[bump]], &program_id())
            .expect("find_program_address must return a valid bump seed");
    assert_eq!(pda, recreated, "test fixture should use canonical PDA");
    (pda, bump)
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
    let elf_path = compile_program("counter_v2");
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

fn read_counter(data: &[u8]) -> u64 {
    let mut value_bytes = [0u8; 8];
    value_bytes.copy_from_slice(&data[0..8]);
    u64::from_le_bytes(value_bytes)
}

#[test]
fn counter_v2_test_initializes_pda_and_increments() {
    let mollusk = setup_mollusk();
    let user = Pubkey::new_unique();
    let (counter_pda, _bump) = counter_pda_for_user(&user);

    let init_ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(counter_pda, false),
            AccountMeta::new_readonly(user, true),
        ],
        data: vec![2],
    };

    let mut stale_value = vec![0u8; COUNTER_SPACE];
    stale_value.copy_from_slice(&99u64.to_le_bytes());
    let counter_account = Account {
        lamports: RENT_EXEMPT_LAMPORTS,
        data: stale_value,
        owner: program_id(),
        ..Account::default()
    };
    let user_account = Account {
        lamports: 1,
        ..Account::default()
    };

    let init_result = mollusk.process_instruction(
        &init_ix,
        &[(counter_pda, counter_account), (user, user_account)],
    );

    assert!(
        !init_result.program_result.is_err(),
        "counter_v2 initialize should succeed: {:?}",
        init_result.program_result
    );
    let counter_after_init = &init_result.resulting_accounts[0].1;
    assert_eq!(counter_after_init.owner, program_id());
    assert_eq!(counter_after_init.lamports, RENT_EXEMPT_LAMPORTS);
    assert_eq!(read_counter(&counter_after_init.data), 0);

    let increment_ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(counter_pda, false),
            AccountMeta::new_readonly(user, true),
        ],
        data: vec![0],
    };

    let first_increment_result = mollusk.process_instruction(
        &increment_ix,
        &[
            (counter_pda, counter_after_init.clone()),
            (user, init_result.resulting_accounts[1].1.clone()),
        ],
    );

    assert!(
        !first_increment_result.program_result.is_err(),
        "counter_v2 first increment should succeed: {:?}",
        first_increment_result.program_result
    );
    let counter_after_first_increment = &first_increment_result.resulting_accounts[0].1;
    assert_eq!(read_counter(&counter_after_first_increment.data), 1);

    let second_increment_result = mollusk.process_instruction(
        &increment_ix,
        &[
            (counter_pda, counter_after_first_increment.clone()),
            (user, first_increment_result.resulting_accounts[1].1.clone()),
        ],
    );

    assert!(
        !second_increment_result.program_result.is_err(),
        "counter_v2 second increment should succeed: {:?}",
        second_increment_result.program_result
    );
    let counter_after_second_increment = &second_increment_result.resulting_accounts[0].1;
    assert_eq!(read_counter(&counter_after_second_increment.data), 2);
}
