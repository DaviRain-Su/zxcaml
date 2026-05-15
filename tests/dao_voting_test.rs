//! SVM-level integration test for the ZxCaml dao_voting program.
//!
//! The setup step compiles `examples/dao_voting.ml` to `build/dao_voting.so`
//! with the local `omlz` binary.  The PDA fixtures follow the repository's
//! canonical bump-255 convention: tests choose a proposal id and voter key whose
//! PDAs can be recreated with bump 255, while the BPF helper verifies those
//! addresses directly instead of calling `try_find_program_address` in BPF.

use mollusk_svm::Mollusk;
use solana_account::Account;
use solana_instruction::{AccountMeta, Instruction};
use solana_pubkey::Pubkey;
use std::fs;

const PROGRAM_ID_BYTES: [u8; 32] = [21u8; 32];
const PROPOSAL_SPACE: usize = 56;
const VOTE_RECORD_SPACE: usize = 1;
const RENT_EXEMPT_LAMPORTS: u64 = 1_000_000;

fn program_id() -> Pubkey {
    Pubkey::new_from_array(PROGRAM_ID_BYTES)
}

fn proposal_pda_for_id(proposal_id: u64) -> (Pubkey, u8) {
    let proposal_id_seed = proposal_id.to_le_bytes();
    let (pda, bump) =
        Pubkey::find_program_address(&[b"proposal", &proposal_id_seed], &program_id());
    let recreated =
        Pubkey::create_program_address(&[b"proposal", &proposal_id_seed, &[bump]], &program_id())
            .expect("find_program_address must return a valid bump seed");
    assert_eq!(pda, recreated, "test fixture should use canonical PDA");
    (pda, bump)
}

fn proposal_id_with_bump_255() -> (u64, Pubkey, u8) {
    for proposal_id in 0..10_000u64 {
        let (proposal, bump) = proposal_pda_for_id(proposal_id);
        if bump == 255 {
            return (proposal_id, proposal, bump);
        }
    }
    panic!("unable to find proposal id with canonical bump 255");
}

fn vote_record_pda_for(proposal: &Pubkey, voter: &Pubkey) -> (Pubkey, u8) {
    let (pda, bump) =
        Pubkey::find_program_address(&[b"vote", proposal.as_ref(), voter.as_ref()], &program_id());
    let recreated = Pubkey::create_program_address(
        &[b"vote", proposal.as_ref(), voter.as_ref(), &[bump]],
        &program_id(),
    )
    .expect("find_program_address must return a valid bump seed");
    assert_eq!(pda, recreated, "test fixture should use canonical PDA");
    (pda, bump)
}

fn voter_with_vote_record_bump_255(proposal: &Pubkey) -> (Pubkey, Pubkey, u8) {
    loop {
        let voter = Pubkey::new_unique();
        let (vote_record, bump) = vote_record_pda_for(proposal, &voter);
        if bump == 255 {
            return (voter, vote_record, bump);
        }
    }
}

mod bpf_test_support;

fn setup_mollusk() -> Mollusk {
    let elf_path = bpf_test_support::compile_program("dao_voting");
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

fn title_bytes(title: &str) -> [u8; 32] {
    let mut out = [0u8; 32];
    let title_bytes = title.as_bytes();
    assert!(title_bytes.len() <= out.len());
    out[..title_bytes.len()].copy_from_slice(title_bytes);
    out
}

fn create_proposal_data(proposal_id: u64, deadline_slot: u64, title: [u8; 32]) -> Vec<u8> {
    let mut data = vec![0x01];
    data.extend_from_slice(&proposal_id.to_le_bytes());
    data.extend_from_slice(&deadline_slot.to_le_bytes());
    data.extend_from_slice(&title);
    data
}

fn vote_data(yes: bool) -> Vec<u8> {
    vec![0x02, u8::from(yes)]
}

fn read_proposal_yes(data: &[u8]) -> u64 {
    let mut value_bytes = [0u8; 8];
    value_bytes.copy_from_slice(&data[32..40]);
    u64::from_le_bytes(value_bytes)
}

fn read_proposal_no(data: &[u8]) -> u64 {
    let mut value_bytes = [0u8; 8];
    value_bytes.copy_from_slice(&data[40..48]);
    u64::from_le_bytes(value_bytes)
}

fn dao_accounts(proposal: Pubkey, vote_record: Pubkey, voter: Pubkey) -> Vec<AccountMeta> {
    vec![
        AccountMeta::new(proposal, false),
        AccountMeta::new(vote_record, false),
        AccountMeta::new_readonly(voter, true),
    ]
}

fn proposal_account() -> Account {
    Account {
        lamports: RENT_EXEMPT_LAMPORTS,
        data: vec![0; PROPOSAL_SPACE],
        owner: program_id(),
        ..Account::default()
    }
}

fn vote_record_account() -> Account {
    Account {
        lamports: RENT_EXEMPT_LAMPORTS,
        data: vec![0; VOTE_RECORD_SPACE],
        owner: program_id(),
        ..Account::default()
    }
}

fn voter_account() -> Account {
    Account {
        lamports: 1,
        ..Account::default()
    }
}

#[test]
fn dao_voting_yes_vote_increments() {
    let mollusk = setup_mollusk();
    let (proposal_id, proposal, _proposal_bump) = proposal_id_with_bump_255();
    let (voter, vote_record, _vote_bump) = voter_with_vote_record_bump_255(&proposal);

    let create_ix = Instruction {
        program_id: program_id(),
        accounts: dao_accounts(proposal, vote_record, voter),
        data: create_proposal_data(proposal_id, 99, title_bytes("budget proposal")),
    };

    let create_result = mollusk.process_instruction(
        &create_ix,
        &[
            (proposal, proposal_account()),
            (vote_record, vote_record_account()),
            (voter, voter_account()),
        ],
    );
    assert!(
        !create_result.program_result.is_err(),
        "dao_voting create should succeed: {:?}",
        create_result.program_result
    );

    let vote_ix = Instruction {
        program_id: program_id(),
        accounts: dao_accounts(proposal, vote_record, voter),
        data: vote_data(true),
    };
    let vote_result = mollusk.process_instruction(
        &vote_ix,
        &[
            (proposal, create_result.resulting_accounts[0].1.clone()),
            (vote_record, create_result.resulting_accounts[1].1.clone()),
            (voter, create_result.resulting_accounts[2].1.clone()),
        ],
    );
    assert!(
        !vote_result.program_result.is_err(),
        "dao_voting yes vote should succeed: {:?}",
        vote_result.program_result
    );

    let proposal_after_vote = &vote_result.resulting_accounts[0].1;
    let vote_record_after_vote = &vote_result.resulting_accounts[1].1;
    assert_eq!(read_proposal_yes(&proposal_after_vote.data), 1);
    assert_eq!(read_proposal_no(&proposal_after_vote.data), 0);
    assert_eq!(vote_record_after_vote.data[0], 1);
}

#[test]
fn dao_voting_double_vote_blocked() {
    let mollusk = setup_mollusk();
    let (proposal_id, proposal, _proposal_bump) = proposal_id_with_bump_255();
    let (voter, vote_record, _vote_bump) = voter_with_vote_record_bump_255(&proposal);

    let create_ix = Instruction {
        program_id: program_id(),
        accounts: dao_accounts(proposal, vote_record, voter),
        data: create_proposal_data(proposal_id, 123, title_bytes("double vote guard")),
    };
    let create_result = mollusk.process_instruction(
        &create_ix,
        &[
            (proposal, proposal_account()),
            (vote_record, vote_record_account()),
            (voter, voter_account()),
        ],
    );
    assert!(
        !create_result.program_result.is_err(),
        "dao_voting create should succeed: {:?}",
        create_result.program_result
    );

    let vote_ix = Instruction {
        program_id: program_id(),
        accounts: dao_accounts(proposal, vote_record, voter),
        data: vote_data(true),
    };
    let first_vote_result = mollusk.process_instruction(
        &vote_ix,
        &[
            (proposal, create_result.resulting_accounts[0].1.clone()),
            (vote_record, create_result.resulting_accounts[1].1.clone()),
            (voter, create_result.resulting_accounts[2].1.clone()),
        ],
    );
    assert!(
        !first_vote_result.program_result.is_err(),
        "dao_voting first vote should succeed: {:?}",
        first_vote_result.program_result
    );

    let second_vote_result = mollusk.process_instruction(
        &vote_ix,
        &[
            (proposal, first_vote_result.resulting_accounts[0].1.clone()),
            (
                vote_record,
                first_vote_result.resulting_accounts[1].1.clone(),
            ),
            (voter, first_vote_result.resulting_accounts[2].1.clone()),
        ],
    );
    assert!(
        second_vote_result.program_result.is_err(),
        "dao_voting second vote must fail: {:?}",
        second_vote_result.program_result
    );

    let proposal_after_second_vote = &second_vote_result.resulting_accounts[0].1;
    let vote_record_after_second_vote = &second_vote_result.resulting_accounts[1].1;
    assert_eq!(read_proposal_yes(&proposal_after_second_vote.data), 1);
    assert_eq!(read_proposal_no(&proposal_after_second_vote.data), 0);
    assert_eq!(vote_record_after_second_vote.data[0], 1);
}
