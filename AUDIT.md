# LARP audit (2026-10-12, before the swarm launch)

Scope: `src/` at this commit: `LARPBurner`, `LARP` / `ILARP`, `LARPNames` / `ILARPNames`, `LARPLinks`, `SafeReads`,
`Labels`. Four contracts on Ethereum.
- No owner, no admin, no upgrades.
- The one role is the names' **artist**, who can change only the art (tokenURI's renderer) and can lock it forever.

**Result: no critical, high or medium findings.** Two low findings fixed, each held by a test that fails without the
fix. The rest acknowledged and documented.

## Trust: what LARP depends on, and what happens if it fails

| dependency | who controls it | if it fails or turns hostile |
|---|---|---|
| identity.md `0x0000eC93…` | its contract | inherent: LARP is about these tokens |
| Uniswap v4 PoolManager | nobody (immutable) | — |
| POOL4 (ETH/$IMD 1%, hook `0xc6C9…`) | IMD's treasury owns the hook (it can `closeMarket`) | the burner falls to route 2 |
| hookless ETH/$IMD pool (1%, spacing 200) | nobody (no hook); its LPs can withdraw | the ETH waits in the burner; anyone burns it later |
| $IMD (LayerZero OFT, owner `0x047F…`) | IMD's treasury (peers) | $IMD at `0x…dEaD` can never move, whatever the token's owner does |
| IMD's launcher `distributorOf` | immutable contract; IMD writes the airdrop roots | jeet ranks are only as true as IMD's airdrops; nothing else depends on it |
| the names' renderer | the artist, until locked | art only; a failing renderer falls back to the built-in card |

**Not used, on purpose:** IMD's BurnExecutor (`0xe293…c750`). Its owner can `rescueToken`, `rescueETH` and redirect
the burn (`setBaseBurnReceiver`), so $IMD sent there isn't trustlessly burned. LARP sends to `0x…dEaD` instead. The
cost: IMD's dashboard won't count these burns as IMD's own.

## Fixed

### L-01 A fee could skip its route by starving the swap of gas (LARPBurner)

Each route's swap runs in a try. A swap that runs out of gas inside it keeps 1/64 of the gas, so a caller who could
make the swap eat its 63/64 could skip POOL4 for the backup, or park the fee.

**Fix:** a route that fails with no more than 1/63 of its gas left reverts the call (`TooLittleGas`).
**Tests:** `test_ASwapOutOfGasReverts` (a PoolManager that burns all gas) and `test_NoGasLimitSkipsPool4`
(gas limits 40k-400k: the backup pool's price never moves while POOL4 can take the trade).

### L-02 The jeet board's reads grow without bound (LARPLinks)

`jeetOf` reads every proven launch of a wallet. **Fix:** `jeetOfRange(wallet, start, count)` pages it.
**Test:** `test_JeetsInPages`.

## Acknowledged

- **L-03 Name sniping.** A pending `register` can be front-run. There is no commit-reveal, and the sniper pays the full
  price (burned). The site should send registrations through a private mempool.
- **L-04 Sandwiching a burn.** At most `MAX_BURN` (0.1 ETH) is spent per call, below POOL4's ~0.24 ETH sandwich
  break-even, and far below the hookless pool's (23x POOL4's liquidity). Callers can set `minImd`; the site should
  pass a quote.
- **L-05 The rank reads live balances.** A flash loan inside one transaction can make a wallet look like it holds.
  `rankOf` is for display; a contract that pays on rank must snapshot it.
- **L-06 Royalties are voluntary on markets.** ERC-2981's 6.9% reaches the burner only where markets pay royalties.
  What no market can skip is the toll: a name's new owner pays its price once to link it to an identity, and that is
  burned.
- **I-01 An agent has the identity's whole social hand.** It can place the owner's NFTs, link the owner's names, set
  texts, fren, and run (or disband) the owner's crews. It can't move any token or ETH. The owner revokes it, and a
  sale ends it.
- **I-02 A returning identity brings its agent back.** If the owner who named an agent sells the identity and buys it
  back, the agent is live again. So is any unused agent signature still before its deadline (`test_AnAgentLapsesOnASale`).
- **I-03 The toll counts every change of hands,** including moves between the owner's own wallets.
- **I-04 The artist's renderer can show anything** in a name's metadata (it is still only metadata). Lock it when the
  art is final.
- **I-05 Fake collections.** LARP proves what a collection's `ownerOf` / `balanceOf` answers, as ENS avatars do.
- **I-06 Hybrid tokens** (both `ownerOf` and `balanceOf(account, id)`) can be placed once each way.
- **I-07 Views forward all gas to collections the holder chose.** On-chain consumers should cap gas.
- **I-08 Fixed prices,** in ETH, forever.
- **I-09 Hook launches can't be proven.** IMD's v4-hook launcher has no `distributorOf`.
- **I-10** ETH force-sent to LARP, LARPNames or LARPLinks (no `receive`) stays there; the burner has one and burns it.

## Checked and holding

- **The burner's ETH leaves only as a swap.** The sale is exact or nothing; a partial fill reverts the route. $IMD
  goes only to `0x…dEaD`. Only the PoolManager calls back, and only for the burner's own unlock. A transient lock
  refuses a burn inside a burn (`test_NoReentry`).
- **Agent signatures** use EIP-712 over (identity, agent, holder, nonce, deadline), bound to the chain and contract.
  - Malleable (high-s) signatures are refused.
  - A per-holder nonce, bumped by every agent change, voids unused signatures.
  - Contract wallets sign through ERC-1271.
  - An EOA path is tried first, so EIP-7702 accounts work.
  (`test/LARPAgents.t.sol`: 14 tests.)
- **Names.**
  - Two-way links: one name per identity, one identity per name.
  - Live only while the linker owns both.
  - The toll is due whenever the owner isn't the one who last paid.
  - A broken, gas-hungry or code-less renderer falls back to the card.
  (`test/LARPNames.t.sol`: 24 tests.)
- **Merkle proofs** and **placement bookkeeping** as before (`test_AnInnerNodeIsNotALeaf`, three invariants).
- **Launch constraints.** The constructors call nothing, and no CALLCODE / DELEGATECALL / SELFDESTRUCT appears anywhere.
  The four contracts take about 6M gas together, in one transaction (`test/Launch.t.sol`).
