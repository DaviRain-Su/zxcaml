//! SVM-level integration test for the ZxCaml order_book program.
//!
//! The setup step compiles `examples/order_book.ml` to `build/order_book.so`
//! with the local `omlz` binary.  This test follows the program-owned mocked
//! SPL Token account fixture convention: maker/taker token accounts are owned
//! by the example program, not Tokenkeg, and the BPF helper mutates the packed
//! SPL Token `amount` fields directly.  The Order PDA uses the repository's
//! canonical bump-255 fixture pattern for seeds
//! `["order", maker_pubkey, order_id_le]`.

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

const PROGRAM_ID_BYTES: [u8; 32] = [23u8; 32];
const ORDER_SPACE: usize = 49;
const TOKEN_ACCOUNT_LEN: usize = 165;
const RENT_EXEMPT_LAMPORTS: u64 = 1_000_000;
const TOKEN_ACCOUNT_LAMPORTS: u64 = 2_039_280;

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

fn order_pda_for(maker: &Pubkey, order_id: u64) -> (Pubkey, u8) {
    let order_id_seed = order_id.to_le_bytes();
    let (pda, bump) =
        Pubkey::find_program_address(&[b"order", maker.as_ref(), &order_id_seed], &program_id());
    let recreated = Pubkey::create_program_address(
        &[b"order", maker.as_ref(), &order_id_seed, &[bump]],
        &program_id(),
    )
    .expect("find_program_address must return a valid bump seed");
    assert_eq!(pda, recreated, "test fixture should use canonical PDA");
    (pda, bump)
}

fn maker_with_order_bump_255() -> (Pubkey, u64, Pubkey, u8) {
    for order_id in 0..10_000u64 {
        let maker = Pubkey::new_unique();
        let (order, bump) = order_pda_for(&maker, order_id);
        if bump == 255 {
            return (maker, order_id, order, bump);
        }
    }
    panic!("unable to find maker/order_id with canonical bump 255");
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
    let elf_path = compile_program("order_book");
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

fn signer_account(lamports: u64) -> Account {
    Account {
        lamports,
        ..Account::default()
    }
}

fn order_account() -> Account {
    Account {
        lamports: RENT_EXEMPT_LAMPORTS,
        data: vec![0; ORDER_SPACE],
        owner: program_id(),
        ..Account::default()
    }
}

fn token_account_data(mint: &Pubkey, owner: &Pubkey, amount: u64) -> Vec<u8> {
    let mut data = vec![0u8; TOKEN_ACCOUNT_LEN];
    data[0..32].copy_from_slice(mint.as_ref());
    data[32..64].copy_from_slice(owner.as_ref());
    data[64..72].copy_from_slice(&amount.to_le_bytes());
    data[108] = 1;
    data
}

fn token_account(mint: &Pubkey, owner: &Pubkey, amount: u64) -> Account {
    Account {
        lamports: TOKEN_ACCOUNT_LAMPORTS,
        data: token_account_data(mint, owner, amount),
        owner: program_id(),
        ..Account::default()
    }
}

fn token_amount(data: &[u8]) -> u64 {
    let mut amount = [0u8; 8];
    amount.copy_from_slice(&data[64..72]);
    u64::from_le_bytes(amount)
}

fn order_base_amount(data: &[u8]) -> u64 {
    let mut amount = [0u8; 8];
    amount.copy_from_slice(&data[33..41]);
    u64::from_le_bytes(amount)
}

fn post_order_data(order_id: u64, side: u8, base_amount: u64, price: u64) -> Vec<u8> {
    let mut data = vec![0x01];
    data.extend_from_slice(&order_id.to_le_bytes());
    data.push(side);
    data.extend_from_slice(&base_amount.to_le_bytes());
    data.extend_from_slice(&price.to_le_bytes());
    data
}

fn fill_data(quantity: u64) -> Vec<u8> {
    let mut data = vec![0x02];
    data.extend_from_slice(&quantity.to_le_bytes());
    data
}

fn post_accounts(order: Pubkey, maker: Pubkey) -> Vec<AccountMeta> {
    vec![AccountMeta::new(order, false), AccountMeta::new(maker, true)]
}

fn fill_accounts(
    order: Pubkey,
    maker_base_ata: Pubkey,
    taker_base_ata: Pubkey,
    taker_quote_ata: Pubkey,
    maker_quote_ata: Pubkey,
    maker: Pubkey,
    taker: Pubkey,
) -> Vec<AccountMeta> {
    vec![
        AccountMeta::new(order, false),
        AccountMeta::new(maker_base_ata, false),
        AccountMeta::new(taker_base_ata, false),
        AccountMeta::new(taker_quote_ata, false),
        AccountMeta::new(maker_quote_ata, false),
        AccountMeta::new(maker, false),
        AccountMeta::new_readonly(taker, true),
    ]
}

fn post_then_fill_full() {
    let mollusk = setup_mollusk();
    let (maker, order_id, order, _bump) = maker_with_order_bump_255();
    let taker = Pubkey::new_unique();
    let base_mint = Pubkey::new_unique();
    let quote_mint = Pubkey::new_unique();
    let maker_base_ata = Pubkey::new_unique();
    let taker_base_ata = Pubkey::new_unique();
    let taker_quote_ata = Pubkey::new_unique();
    let maker_quote_ata = Pubkey::new_unique();
    let base_amount = 10u64;
    let price = 4u64;
    let maker_lamports = 10_000_000u64;

    let post_ix = Instruction {
        program_id: program_id(),
        accounts: post_accounts(order, maker),
        data: post_order_data(order_id, 0, base_amount, price),
    };
    let post_result = mollusk.process_instruction(
        &post_ix,
        &[(order, order_account()), (maker, signer_account(maker_lamports))],
    );
    assert!(
        !post_result.program_result.is_err(),
        "order_book post should succeed: {:?}",
        post_result.program_result
    );
    let order_after_post = &post_result.resulting_accounts[0].1;
    assert_eq!(&order_after_post.data[0..32], maker.as_ref());
    assert_eq!(order_after_post.data[32], 0);
    assert_eq!(order_base_amount(&order_after_post.data), base_amount);

    let fill_ix = Instruction {
        program_id: program_id(),
        accounts: fill_accounts(
            order,
            maker_base_ata,
            taker_base_ata,
            taker_quote_ata,
            maker_quote_ata,
            maker,
            taker,
        ),
        data: fill_data(base_amount),
    };
    let fill_result = mollusk.process_instruction(
        &fill_ix,
        &[
            (order, order_after_post.clone()),
            (maker_base_ata, token_account(&base_mint, &maker, base_amount)),
            (taker_base_ata, token_account(&base_mint, &taker, 0)),
            (
                taker_quote_ata,
                token_account(&quote_mint, &taker, price * base_amount),
            ),
            (maker_quote_ata, token_account(&quote_mint, &maker, 0)),
            (maker, post_result.resulting_accounts[1].1.clone()),
            (taker, signer_account(1)),
        ],
    );
    assert!(
        !fill_result.program_result.is_err(),
        "order_book full fill should succeed: {:?}",
        fill_result.program_result
    );

    let order_after_fill = &fill_result.resulting_accounts[0].1;
    let maker_base_after = &fill_result.resulting_accounts[1].1;
    let taker_base_after = &fill_result.resulting_accounts[2].1;
    let taker_quote_after = &fill_result.resulting_accounts[3].1;
    let maker_quote_after = &fill_result.resulting_accounts[4].1;
    let maker_after_fill = &fill_result.resulting_accounts[5].1;
    assert_eq!(token_amount(&maker_base_after.data), 0);
    assert_eq!(token_amount(&taker_base_after.data), base_amount);
    assert_eq!(token_amount(&taker_quote_after.data), 0);
    assert_eq!(token_amount(&maker_quote_after.data), price * base_amount);
    assert_eq!(order_after_fill.lamports, 0);
    assert!(order_after_fill.data.iter().all(|byte| *byte == 0));
    assert_eq!(
        maker_after_fill.lamports,
        maker_lamports + RENT_EXEMPT_LAMPORTS
    );
}

fn partial_fill_decrements() {
    let mollusk = setup_mollusk();
    let (maker, order_id, order, _bump) = maker_with_order_bump_255();
    let taker = Pubkey::new_unique();
    let base_mint = Pubkey::new_unique();
    let quote_mint = Pubkey::new_unique();
    let maker_base_ata = Pubkey::new_unique();
    let taker_base_ata = Pubkey::new_unique();
    let taker_quote_ata = Pubkey::new_unique();
    let maker_quote_ata = Pubkey::new_unique();
    let base_amount = 10u64;
    let fill_amount = 4u64;
    let price = 3u64;

    let post_ix = Instruction {
        program_id: program_id(),
        accounts: post_accounts(order, maker),
        data: post_order_data(order_id, 0, base_amount, price),
    };
    let post_result = mollusk.process_instruction(
        &post_ix,
        &[
            (order, order_account()),
            (maker, signer_account(10_000_000)),
        ],
    );
    assert!(
        !post_result.program_result.is_err(),
        "order_book post should succeed: {:?}",
        post_result.program_result
    );

    let fill_ix = Instruction {
        program_id: program_id(),
        accounts: fill_accounts(
            order,
            maker_base_ata,
            taker_base_ata,
            taker_quote_ata,
            maker_quote_ata,
            maker,
            taker,
        ),
        data: fill_data(fill_amount),
    };
    let fill_result = mollusk.process_instruction(
        &fill_ix,
        &[
            (order, post_result.resulting_accounts[0].1.clone()),
            (maker_base_ata, token_account(&base_mint, &maker, base_amount)),
            (taker_base_ata, token_account(&base_mint, &taker, 0)),
            (
                taker_quote_ata,
                token_account(&quote_mint, &taker, price * base_amount),
            ),
            (maker_quote_ata, token_account(&quote_mint, &maker, 0)),
            (maker, post_result.resulting_accounts[1].1.clone()),
            (taker, signer_account(1)),
        ],
    );
    assert!(
        !fill_result.program_result.is_err(),
        "order_book partial fill should succeed: {:?}",
        fill_result.program_result
    );

    let order_after_fill = &fill_result.resulting_accounts[0].1;
    let maker_base_after = &fill_result.resulting_accounts[1].1;
    let taker_base_after = &fill_result.resulting_accounts[2].1;
    let taker_quote_after = &fill_result.resulting_accounts[3].1;
    let maker_quote_after = &fill_result.resulting_accounts[4].1;
    assert_eq!(order_after_fill.lamports, RENT_EXEMPT_LAMPORTS);
    assert_eq!(
        order_base_amount(&order_after_fill.data),
        base_amount - fill_amount
    );
    assert_eq!(token_amount(&maker_base_after.data), base_amount - fill_amount);
    assert_eq!(token_amount(&taker_base_after.data), fill_amount);
    assert_eq!(
        token_amount(&taker_quote_after.data),
        (base_amount - fill_amount) * price
    );
    assert_eq!(token_amount(&maker_quote_after.data), fill_amount * price);
}

#[test]
fn order_book_post_then_fill_full() {
    post_then_fill_full();
}

#[test]
fn order_book_partial_fill_decrements() {
    partial_fill_decrements();
}
