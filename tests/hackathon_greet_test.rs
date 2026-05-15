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
use std::fs;

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

mod bpf_test_support;

fn setup_mollusk() -> Mollusk {
    let elf_path = bpf_test_support::compile_program("hackathon_greet");
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
