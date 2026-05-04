//! Reference-only Anchor counterpart for `examples/hackathon_greet.ml`.
//!
//! This program intentionally mirrors the ZxCaml demo's preallocated 40-byte
//! PDA layout instead of using Anchor's normal 8-byte account discriminator.
//! It exists for fair line-count and artifact-size comparison, not for
//! production deployment.

use anchor_lang::prelude::*;

declare_id!("5ZUTYaJjGZgzjMaaTyuamVstcsdhzVXJFHRKTi1QA1dB");

const GREET_SEED: &[u8] = b"greet";
const GREET_BUMP: u8 = 255;
const MAKER_LEN: usize = 32;
const COUNTER_OFFSET: usize = MAKER_LEN;
const STATE_LEN: usize = MAKER_LEN + 8;

#[program]
pub mod hackathon_greet_anchor {
    use super::*;

    pub fn init(ctx: Context<Init>) -> Result<()> {
        validate_greeting_account(&ctx.accounts.greeting_account, &ctx.accounts.maker)?;

        let mut data = ctx.accounts.greeting_account.try_borrow_mut_data()?;
        for byte in data[..STATE_LEN].iter_mut() {
            *byte = 0;
        }

        Ok(())
    }

    pub fn greet(ctx: Context<Greet>) -> Result<()> {
        validate_greeting_account(&ctx.accounts.greeting_account, &ctx.accounts.maker)?;

        let maker_key = ctx.accounts.maker.key();
        let maker_bytes = maker_key.to_bytes();
        let mut data = ctx.accounts.greeting_account.try_borrow_mut_data()?;
        let mut counter_bytes = [0u8; 8];
        counter_bytes.copy_from_slice(&data[COUNTER_OFFSET..STATE_LEN]);

        let counter = u64::from_le_bytes(counter_bytes);
        if counter == 0 {
            data[..MAKER_LEN].copy_from_slice(&maker_bytes);
        } else {
            require!(
                &data[..MAKER_LEN] == maker_bytes.as_slice(),
                GreetError::MakerMismatch
            );
        }

        let next = counter.checked_add(1).ok_or(GreetError::CounterOverflow)?;
        data[COUNTER_OFFSET..STATE_LEN].copy_from_slice(&next.to_le_bytes());

        Ok(())
    }
}

#[derive(Accounts)]
pub struct Init<'info> {
    /// CHECK: Preallocated program-owned PDA with manual ZxCaml-compatible data.
    #[account(mut)]
    pub greeting_account: AccountInfo<'info>,
    pub maker: Signer<'info>,
}

#[derive(Accounts)]
pub struct Greet<'info> {
    /// CHECK: Preallocated program-owned PDA with manual ZxCaml-compatible data.
    #[account(mut)]
    pub greeting_account: AccountInfo<'info>,
    pub maker: Signer<'info>,
}

fn validate_greeting_account(greeting_account: &AccountInfo, maker: &Signer) -> Result<()> {
    let maker_key = maker.key();
    let expected_pda = Pubkey::create_program_address(
        &[GREET_SEED, maker_key.as_ref(), &[GREET_BUMP]],
        &crate::ID,
    )
    .map_err(|_| error!(GreetError::InvalidPda))?;

    require_keys_eq!(*greeting_account.key, expected_pda, GreetError::InvalidPda);
    require_keys_eq!(*greeting_account.owner, crate::ID, GreetError::WrongOwner);
    require!(
        greeting_account.data_len() >= STATE_LEN,
        GreetError::StateTooSmall
    );

    Ok(())
}

#[error_code]
pub enum GreetError {
    #[msg("greeting account is not the bump-255 PDA for [greet, maker]")]
    InvalidPda,
    #[msg("greeting account must be owned by this program")]
    WrongOwner,
    #[msg("greeting account data must be at least 40 bytes")]
    StateTooSmall,
    #[msg("stored maker does not match the signing maker")]
    MakerMismatch,
    #[msg("greeting counter overflowed u64")]
    CounterOverflow,
}
