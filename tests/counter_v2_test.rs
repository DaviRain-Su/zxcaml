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
use std::fs;

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

mod bpf_test_support;

fn setup_mollusk() -> Mollusk {
    let elf_path = bpf_test_support::compile_program("counter_v2");
    let elf = fs::read(&elf_path).unwrap_or_else(|error| {
        panic!(
            "failed to read sBPF artifact at {}: {}",
            elf_path.display(),
            error
        )
    });
    let pid = program_id();
    let loader_v3 = solana_pubkey::pubkey!("BPFLoaderUpgradeab1e11111111111111111111111");
    let mut mollusk = bpf_test_support::new_mollusk();
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
