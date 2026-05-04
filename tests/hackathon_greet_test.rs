//! SVM-level integration test for the ZxCaml hackathon_greet program.
//!
//! The setup step compiles `examples/hackathon_greet.ml` to
//! `build/hackathon_greet.so` with the local `omlz` binary, then verifies the
//! Colosseum demo's canonical bump-255 PDA fixture.  The test preallocates the
//! PDA as a program-owned account because this repository's Mollusk/BPF fixture
//! pattern hardcodes bump 255 instead of calling `try_find_program_address`
//! inside BPF.

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

const PROGRAM_ID_BYTES: [u8; 32] = [21u8; 32];
const GREET_SPACE: usize = 40;
const RENT_EXEMPT_LAMPORTS: u64 = 1_000_000;

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

fn greet_pda_for_maker(maker: &Pubkey) -> (Pubkey, u8) {
    let (pda, bump) = Pubkey::find_program_address(&[b"greet", maker.as_ref()], &program_id());
    let recreated =
        Pubkey::create_program_address(&[b"greet", maker.as_ref(), &[bump]], &program_id())
            .expect("find_program_address must return a valid bump seed");
    assert_eq!(pda, recreated, "test fixture should use canonical PDA");
    (pda, bump)
}

fn maker_with_greet_pda_bump_255() -> (Pubkey, Pubkey, u8) {
    loop {
        let maker = Pubkey::new_unique();
        let (pda, bump) = greet_pda_for_maker(&maker);
        if bump == 255 {
            return (maker, pda, bump);
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
    let elf_path = compile_program("hackathon_greet");
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

fn read_greet_count(data: &[u8]) -> u64 {
    let mut value_bytes = [0u8; 8];
    value_bytes.copy_from_slice(&data[32..40]);
    u64::from_le_bytes(value_bytes)
}

#[test]
fn hackathon_greet_test_initializes_and_counts_two_greets() {
    let mollusk = setup_mollusk();
    let (maker, greet_pda, _bump) = maker_with_greet_pda_bump_255();

    let init_ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(greet_pda, false),
            AccountMeta::new_readonly(maker, true),
        ],
        data: vec![0],
    };

    let mut stale_data = vec![0xff; GREET_SPACE];
    stale_data[32..40].copy_from_slice(&99u64.to_le_bytes());
    let greet_account = Account {
        lamports: RENT_EXEMPT_LAMPORTS,
        data: stale_data,
        owner: program_id(),
        ..Account::default()
    };
    let maker_account = Account {
        lamports: 1,
        ..Account::default()
    };

    let init_result = mollusk.process_instruction(
        &init_ix,
        &[(greet_pda, greet_account), (maker, maker_account)],
    );

    assert!(
        !init_result.program_result.is_err(),
        "hackathon_greet init should succeed: {:?}",
        init_result.program_result
    );
    let greet_after_init = &init_result.resulting_accounts[0].1;
    assert_eq!(greet_after_init.owner, program_id());
    assert_eq!(greet_after_init.lamports, RENT_EXEMPT_LAMPORTS);
    assert_eq!(&greet_after_init.data[0..32], &[0u8; 32]);
    assert_eq!(read_greet_count(&greet_after_init.data), 0);

    let greet_ix = Instruction {
        program_id: program_id(),
        accounts: vec![
            AccountMeta::new(greet_pda, false),
            AccountMeta::new_readonly(maker, true),
        ],
        data: vec![1],
    };

    let first_greet_result = mollusk.process_instruction(
        &greet_ix,
        &[
            (greet_pda, greet_after_init.clone()),
            (maker, init_result.resulting_accounts[1].1.clone()),
        ],
    );

    assert!(
        !first_greet_result.program_result.is_err(),
        "hackathon_greet first greet should succeed: {:?}",
        first_greet_result.program_result
    );
    let greet_after_first = &first_greet_result.resulting_accounts[0].1;
    assert_eq!(&greet_after_first.data[0..32], maker.as_ref());
    assert_eq!(read_greet_count(&greet_after_first.data), 1);

    let second_greet_result = mollusk.process_instruction(
        &greet_ix,
        &[
            (greet_pda, greet_after_first.clone()),
            (maker, first_greet_result.resulting_accounts[1].1.clone()),
        ],
    );

    assert!(
        !second_greet_result.program_result.is_err(),
        "hackathon_greet second greet should succeed: {:?}",
        second_greet_result.program_result
    );
    let greet_after_second = &second_greet_result.resulting_accounts[0].1;
    assert_eq!(&greet_after_second.data[0..32], maker.as_ref());
    assert_eq!(read_greet_count(&greet_after_second.data), 2);
}
