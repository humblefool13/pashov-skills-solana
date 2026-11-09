//! Shared test environment: LiteSVM bootstrap, program loading, token helpers,
//! transaction sending and balance reads. Keep program-specific instruction
//! builders in `tests/ix.rs` (see TODO in properties.rs).
#![allow(dead_code)]

use litesvm::LiteSVM;
use litesvm_token::{CreateAssociatedTokenAccount, CreateMint, MintTo};
use solana_sdk::{
    instruction::Instruction,
    pubkey::Pubkey,
    signature::{Keypair, Signer},
    transaction::Transaction,
};

pub struct Env {
    pub svm: LiteSVM,
    pub payer: Keypair,
}

impl Env {
    /// Fresh in-process SVM with a funded payer. Programs are loaded separately.
    pub fn new() -> Self {
        let mut svm = LiteSVM::new();
        let payer = Keypair::new();
        svm.airdrop(&payer.pubkey(), 1_000_000_000_000).unwrap();
        Self { svm, payer }
    }

    /// Load a compiled `.so` (from `anchor build` / `cargo build-sbf`) at `program_id`.
    /// Build with the SAME toolchain the chain runs (for example the same SBF version and Agave line).
    pub fn load_program(&mut self, program_id: Pubkey, so_path: &str) {
        self.svm
            .add_program_from_file(program_id, so_path)
            .unwrap_or_else(|e| panic!("cannot load {so_path}: {e:?}"));
    }

    pub fn fund(&mut self, who: &Pubkey, lamports: u64) {
        self.svm.airdrop(who, lamports).unwrap();
    }

    /// Send one transaction signed by `payer` plus `extra` signers.
    /// Returns Ok(logs) or Err(error string + logs). A new blockhash is used each time
    /// so identical transactions are not rejected as duplicates.
    pub fn send(&mut self, ixs: &[Instruction], extra: &[&Keypair]) -> Result<Vec<String>, String> {
        self.svm.expire_blockhash();
        let mut signers: Vec<&Keypair> = vec![&self.payer];
        signers.extend_from_slice(extra);
        let tx = Transaction::new_signed_with_payer(
            ixs,
            Some(&self.payer.pubkey()),
            &signers,
            self.svm.latest_blockhash(),
        );
        match self.svm.send_transaction(tx) {
            Ok(meta) => Ok(meta.logs),
            Err(f) => Err(format!("{:?}\n{}", f.err, f.meta.logs.join("\n"))),
        }
    }

    pub fn new_mint(&mut self, decimals: u8) -> Pubkey {
        CreateMint::new(&mut self.svm, &self.payer)
            .decimals(decimals)
            .authority(&self.payer.pubkey())
            .send()
            .unwrap()
    }

    pub fn new_ata(&mut self, owner: &Pubkey, mint: &Pubkey) -> Pubkey {
        CreateAssociatedTokenAccount::new(&mut self.svm, &self.payer, mint)
            .owner(owner)
            .send()
            .unwrap()
    }

    pub fn mint_to(&mut self, mint: &Pubkey, dest: &Pubkey, amount: u64) {
        MintTo::new(&mut self.svm, &self.payer, mint, dest, amount)
            .send()
            .unwrap();
    }

    /// SPL token account balance (amount field at bytes 64..72 of a token account).
    pub fn token_balance(&self, ata: &Pubkey) -> u64 {
        let acc = self.svm.get_account(ata).expect("token account missing");
        u64::from_le_bytes(acc.data[64..72].try_into().unwrap())
    }

    pub fn lamports(&self, who: &Pubkey) -> u64 {
        self.svm.get_balance(who).unwrap_or(0)
    }
}
