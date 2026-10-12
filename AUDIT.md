# LARP audit (2026-10-12, before the swarm launch)

Scope: `src/` at this commit: `LARP`, `ILARP`, `LARPNames`, `ILARPNames`, `LARPLinks`, `BuysIMD`, `SafeReads`,
`Labels`. Three ownerless contracts on Ethereum: no admin, no upgrade path, no funds held between calls.

**Result: no critical, high or medium findings.** Two low findings fixed, each held by a test that fails without the
fix. The rest acknowledged and documented.

## Fixed

### L-01 A fee could be pushed to the fallback by starving the swap of gas (BuysIMD)

`_buyAndBurn` wraps `PoolManager.unlock` in try/catch, and the catch sends the fee to `FALLBACK` (the IMD6900 pot) and
skips `minImd`. A call that runs out of gas inside the try keeps 1/64 of its gas, so a caller who could make the swap
eat its 63/64 would route its own fee to the pot instead of the $IMD burn. With POOL4's swap costing ~100-150k gas this
needs an unrealistically expensive swap, but a heavier hook would make it real.

**Fix:** the catch reverts `TooLittleGas` when no more than 1/63 of the gas before the call is left.
**Test:** `test_ASwapOutOfGasRevertsInsteadOfPayingThePot` (a PoolManager that burns all gas): passes with the fix,
fails without it. `test_TooLittleGasNeverReachesThePot` sweeps gas limits 60k-400k on a real local POOL4.

### L-02 The jeet board's reads grow without bound (LARPLinks)

`jeetOf` / `rankOf` / `cardOf` read every launch proven for a wallet (about three reads each). The IMD6900 treasury
already has 80 Ethereum swarm launches and the swarm launches daily, so a busy wallet will eventually not fit an
`eth_call`.

**Fix:** `jeetOfRange(wallet, start, count)` reads a page. `jeetOf` is the whole range.
**Test:** `test_JeetsInPages`.

## Acknowledged

- **L-03 Name sniping.** A pending `register` can be front-run by anyone holding an identity. There is no commit-reveal
  (ENS has one). What limits it: one name per identity (2,000 identities), and the sniper pays the full fee, which is
  burned. The site should send registrations through a private mempool (Flashbots Protect / MEV Blocker).
- **L-04 Fee swaps can be sandwiched when `minImd` is 0.** The fees are tiny (0.0069 to 0.069 ETH) against POOL4's 2%
  round trip, so this is barely worth the gas. The site should still pass a quoted `minImd`.
- **L-05 The rank reads live balances.** Inside one transaction, borrowing a launch token (a v4 flash swap) makes a
  wallet look like it holds. `rankOf` is for display: a contract that pays out on rank must snapshot it, not read it.
- **I-01 Fake collections.** LARP proves only what a collection's own `ownerOf` / `balanceOf` answers, as ENS avatars
  do. Apps show the collection's address or keep an allowlist.
- **I-02 Hybrid tokens.** A contract that answers both `ownerOf` and `balanceOf(account, id)` can be placed once as an
  ERC-721 and again as an ERC-1155.
- **I-03 Views forward all gas to collections the holder chose.** A holder can make reads of its own identity
  expensive. On-chain consumers that loop over identities should call with try/catch and a gas cap.
  `SafeReads` never reverts and copies at most one word for `ownerOf` / `balanceOf`.
- **I-04 Fixed prices.** Name and crew prices are in ETH, forever: there is no owner to change them.
- **I-05 Hook launches can't be proven.** 16 of the 79 Ethereum launches paying the treasury come from IMD's v4-hook
  launcher (`0x12C6…A96F`), which has no `distributorOf`. Only distributors that IMD's launcher (`0xfF03…7120`) names
  are accepted.
- **I-06 What counts as a jeet.** Claimed tokens moved to another wallet count as sold, and buying back counts as
  holding. Unclaimed allocations count as not sold. Two launches sharing a token would each count the same balance.
- **I-07** ETH force-sent to a contract (no `receive`) stays there.
- **I-08** If a captain's identity were burned, its crew could not be disbanded (its members can still leave).

## Checked and holding

- **Reentrancy.** Every payable path is under a transient-storage lock (`nonReentrant`). State is written before the
  swap. `unlockCallback` answers only the PoolManager, and only this contract can start its own unlock. Reads use
  STATICCALL, so nothing read can change state (`test_NoReentryThroughThePot`).
- **ETH accounting.** Each fee is spent in full in the same call: exactly `msg.value` to POOL4, or all of it to the
  fallback. A partial fill reverts inside the callback and falls to the pot. No ETH is left behind
  (`test_RegisterBurnsIMDThroughPool4`, `test_FoundingACrewBurnsIMD`; on the fork, `test_TheRealPotTakesAFeePool4Cant`).
- **Merkle proofs.** Leaves are hashed twice, as in OpenZeppelin's standard tree. The amount is capped at 2^128 and
  the wallet is an address. The root comes from the distributor IMD's launcher names
  (`test_AnInnerNodeIsNotALeaf`, `test_RealProofsRefuseTampering`; real proofs in `test_TheRealJeetBoard`).
- **Placement bookkeeping.** The ERC-721 two-way map and the ERC-1155 copy counts stay consistent under random trading
  and placing (`test/LARP.invariant.t.sol`: three invariants, 128 runs x 64 calls each).
- **Launch constraints.** The constructors call nothing, and no CALLCODE / DELEGATECALL / SELFDESTRUCT appears in any
  creation code (with its arguments) or runtime code. All three fit one transaction (`test/Launch.t.sol`).
