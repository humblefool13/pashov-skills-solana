//! Property / invariant harness skeleton.
//!
//! Two layers:
//!  1. `model_*` tests run a pure Rust reference model of the protocol's math under proptest.
//!     They pass out of the box and show the shape of each property. Replace the model with
//!     the real formulas (copy them from the program crate, or call its `curve` module).
//!  2. `onchain_*` tests drive the compiled program through LiteSVM with random action
//!     sequences and re-check the same properties against real account state.
//!     They are `#[ignore]` until you wire instruction builders and set PROGRAM_SO.
//!
//! Run:   cargo test --test properties                          (model layer)
//!        PROGRAM_SO=../target/deploy/amm.so cargo test --test properties -- --ignored
//! More cases:   PROPTEST_CASES=5000 cargo test ...
//! Reproduce:    proptest prints a seed and writes proptest-regressions/; commit that file.
mod common;

use proptest::prelude::*;

// ---------------------------------------------------------------------------
// Layer 1: pure model of a constant-product pool with fee, floor/ceil rounding
// ---------------------------------------------------------------------------

#[derive(Clone, Debug)]
struct Pool {
    x: u128,       // reserve of token 0
    y: u128,       // reserve of token 1
    lp: u128,      // LP supply (includes locked amount)
    fee_ppm: u128, // trade fee in parts per million, charged on input, rounded UP
}

const LOCKED_LP: u128 = 100;
const FEE_DEN: u128 = 1_000_000;

fn ceil_div(a: u128, b: u128) -> u128 {
    (a + b - 1) / b
}

impl Pool {
    fn new(x: u128, y: u128, fee_ppm: u128) -> Option<Self> {
        let lp = isqrt(x.checked_mul(y)?);
        if lp <= LOCKED_LP {
            return None;
        }
        Some(Self { x, y, lp, fee_ppm })
    }

    /// exact-in swap token0 -> token1. Output rounds DOWN, fee rounds UP.
    fn swap_0_for_1(&mut self, dx: u128) -> Option<u128> {
        if dx == 0 {
            return None;
        }
        let fee = ceil_div(dx * self.fee_ppm, FEE_DEN);
        let dx_net = dx.checked_sub(fee)?;
        let dy = self.y.checked_mul(dx_net)? / (self.x + dx_net);
        if dy == 0 || dy >= self.y {
            return None; // programs must reject zero output
        }
        self.x += dx; // fee stays in the pool (LP fee)
        self.y -= dy;
        Some(dy)
    }

    fn swap_1_for_0(&mut self, dy: u128) -> Option<u128> {
        let mut flipped = Pool { x: self.y, y: self.x, lp: self.lp, fee_ppm: self.fee_ppm };
        let out = flipped.swap_0_for_1(dy)?;
        self.x = flipped.y;
        self.y = flipped.x;
        Some(out)
    }

    fn k(&self) -> u128 {
        self.x * self.y
    }
}

fn isqrt(n: u128) -> u128 {
    if n < 2 {
        return n;
    }
    let mut x = n;
    let mut y = (x + 1) / 2;
    while y < x {
        x = y;
        y = (x + n / x) / 2;
    }
    x
}

// Strategies matter: a fee of 2.5% hides a 1-unit rounding gain, so draw fee = 0 and tiny fees
// often, mix small and large reserves, and use trade sizes where rounding is visible.
fn fee_strategy() -> impl Strategy<Value = u128> {
    prop_oneof![Just(0u128), 1u128..100, 100u128..50_000]
}
fn reserve_strategy() -> impl Strategy<Value = u128> {
    prop_oneof![1_000u128..100_000, 100_000u128..1_000_000_000_000]
}
fn amount_strategy() -> impl Strategy<Value = u128> {
    prop_oneof![1u128..100, 100u128..10_000, 10_000u128..1_000_000_000]
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 2048, .. ProptestConfig::default() })]

    /// k never decreases across a swap (fee included in reserves).
    #[test]
    fn model_k_never_decreases(
        x in reserve_strategy(), y in reserve_strategy(), fee in fee_strategy(), dx in amount_strategy()
    ) {
        if let Some(mut p) = Pool::new(x, y, fee) {
            let k0 = p.k();
            if p.swap_0_for_1(dx).is_some() {
                prop_assert!(p.k() >= k0, "k fell: {} -> {}", k0, p.k());
            }
        }
    }

    /// No profit from swapping out and back, at any size including dust.
    #[test]
    fn model_round_trip_never_profits(
        x in reserve_strategy(), y in reserve_strategy(), fee in fee_strategy(), dx in amount_strategy()
    ) {
        if let Some(mut p) = Pool::new(x, y, fee) {
            if let Some(dy) = p.swap_0_for_1(dx) {
                if let Some(back) = p.swap_1_for_0(dy) {
                    prop_assert!(back <= dx, "profit: put in {}, got {}", dx, back);
                }
            }
        }
    }

    /// Repeated small round trips (the rounding-loop attack) never end ahead.
    #[test]
    fn model_dust_loop_never_profits(
        x in reserve_strategy(), y in reserve_strategy(), fee in fee_strategy(),
        unit in 1u128..2_000, n in 1usize..60
    ) {
        if let Some(mut p) = Pool::new(x, y, fee) {
            let start: u128 = 1_000_000;
            let mut held0 = start;
            for _ in 0..n {
                if held0 < unit { break; }
                match p.swap_0_for_1(unit).and_then(|dy| p.swap_1_for_0(dy)) {
                    Some(back) => { held0 = held0 - unit + back; }
                    None => break,
                }
            }
            prop_assert!(held0 <= start, "dust loop profit: {} -> {}", start, held0);
        }
    }
}

// ---------------------------------------------------------------------------
// Layer 2: on-chain driver (ignored until wired)
// ---------------------------------------------------------------------------

#[allow(dead_code)]
/// One step of a random action sequence. Keep the enum small and meaningful: every variant
/// should be a user-reachable instruction with clamped, mostly-valid arguments, plus a few
/// "hostile" variants (wrong account, zero amount, dust).
#[derive(Clone, Debug)]
enum Action {
    Swap { actor: u8, zero_for_one: bool, amount: u64 },
    Deposit { actor: u8, lp_out: u64 },
    Withdraw { actor: u8, lp_in: u64 },
    DonateToVault { zero: bool, amount: u64 },
    // TODO: Buy/Sell/Graduate for a launchpad; admin instructions for "no admin fund path".
}

fn action_strategy() -> impl Strategy<Value = Action> {
    prop_oneof![
        (0u8..3, any::<bool>(), prop_oneof![1u64..10, 1u64..1_000_000, Just(u64::MAX / 4)])
            .prop_map(|(actor, z, amount)| Action::Swap { actor, zero_for_one: z, amount }),
        (0u8..3, 1u64..1_000_000).prop_map(|(actor, lp_out)| Action::Deposit { actor, lp_out }),
        (0u8..3, 1u64..1_000_000).prop_map(|(actor, lp_in)| Action::Withdraw { actor, lp_in }),
        (any::<bool>(), 1u64..1_000_000).prop_map(|(zero, amount)| Action::DonateToVault { zero, amount }),
    ]
}

#[test]
#[ignore = "wire instruction builders in tests/ix.rs and set PROGRAM_SO"]
fn onchain_invariants_hold_over_random_sequences() {
    let so = match std::env::var("PROGRAM_SO") {
        Ok(p) => p,
        Err(_) => return, // nothing to drive
    };
    let mut runner = proptest::test_runner::TestRunner::new(ProptestConfig { cases: 64, ..Default::default() });
    let strat = proptest::collection::vec(action_strategy(), 1..40);
    runner
        .run(&strat, |actions| {
            let mut env = common::Env::new();
            // let program_id = ...; env.load_program(program_id, &so);
            // let (mint0, mint1, vault0, vault1, actors, ...) = setup_pool(&mut env);
            let _ = (&so, &mut env);

            // Ghost state: track what each actor put in and took out, and the books.
            for (_i, a) in actions.iter().enumerate() {
                // let before = snapshot(&env);
                // let res = apply(&mut env, a);       // Ok or an expected-failure error
                // INVARIANTS after every step, success or failure:
                //   I1 vault_balance >= books.reserve + accrued_fees           (E5)
                //   I2 k_after >= k_before on swaps                            (I1)
                //   I3 sum(actor_value_after) <= sum(actor_value_before) + donations   (no profit)
                //   I4 failed transactions leave state unchanged               (atomicity)
                //   I5 no admin instruction changes any user vault             (default rule)
                let _ = a;
            }
            Ok(())
        })
        .unwrap();
}

// Smoke test: the environment works (system transfer through LiteSVM).
#[test]
#[allow(deprecated)] // solana_sdk::system_instruction -> solana_system_interface in newer SDKs
fn env_smoke_system_transfer() {
    use solana_sdk::{pubkey::Pubkey, system_instruction};
    let mut env = common::Env::new();
    let to = Pubkey::new_unique();
    let payer = env.payer.pubkey();
    env.send(&[system_instruction::transfer(&payer, &to, 1_000_000_000)], &[]).unwrap();
    assert_eq!(env.lamports(&to), 1_000_000_000);
}

// KNOWN GAP, pinned on purpose. On a real validator, moving 1 lamport to an empty account
// fails ("insufficient funds for rent"). LiteSVM 0.7.1 only runs its rent-state check on
// writable accounts that already hold data (`check_accounts_rent` skips empty ones), so this
// transfer SUCCEEDS here. Do not rely on LiteSVM to reproduce rent-exempt DoS against
// zero-data recipients (vector C6): assert the program's own minimum-balance logic, or
// confirm on solana-test-validator. If a newer LiteSVM fixes this, this test fails: update
// the docs (references/litesvm-proptest.md) and flip the assertion.
#[test]
#[allow(deprecated)]
fn known_gap_litesvm_skips_rent_check_for_empty_accounts() {
    use solana_sdk::{pubkey::Pubkey, system_instruction};
    let mut env = common::Env::new();
    let to = Pubkey::new_unique();
    let payer = env.payer.pubkey();
    let res = env.send(&[system_instruction::transfer(&payer, &to, 1)], &[]);
    assert!(res.is_ok(), "LiteSVM now enforces the rent rule for empty accounts: update the template and docs");
}
use solana_sdk::signature::Signer;
