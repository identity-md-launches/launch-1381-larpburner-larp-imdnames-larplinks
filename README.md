# LARP: Linked Avatar Registry Protocol, by the IMD6900 frens

The protocol that interconnects the IMD ecosystem. Every identity.md (`0x0000eC93…ec1D`, 2,000 identities, each an IMD
agent) gets:
- **a face and items:** any NFT its holder owns;
- **a name:** `name.imd`;
- **frens and a crew;**
- **a rank,** read from what its holder did with the swarm's airdrops.

Apps read three contracts to draw an identity, find it by name, and see who it runs with. Every name and crew fee buys
$IMD on **POOL4** (IMD's ETH/$IMD Uniswap v4 pool) and burns it: volume on POOL4, $IMD destroyed.

Three contracts, deployed on Ethereum by the IMD swarm. No owner, no admin, no upgrades, no funds held.

| contract | what |
|---|---|
| `LARP` (`ILARP`) | the avatar standard: one ERC-721 as the face, eight item slots (ERC-721 or ERC-1155) |
| `LARPNames` (`ILARPNames`) | `name.imd`: ENS-style names, reverse records, text records; fees buy and burn $IMD on POOL4 |
| `LARPLinks` | frens, crews, the jeet rank, and `cardOf`: everything about an identity in one read |

## LARP: faces and items

- `setFace(imdId, collection, tokenId)`: the caller must own the identity and the ERC-721.
- `equip(imdId, slot, collection, tokenId, kind)`: slots 1 to 8, `kind` ERC721 or ERC1155. For an ERC-1155, the
  caller needs a copy not already placed.
- `clearFace` / `unequip`: by the identity's owner, or by whoever placed it (who can always take its own NFT back).

**The rules:**
- A placement is **live while the wallet that made it holds the identity and the NFT.** A sale of either takes it down
  with nobody acting, and a new owner chooses again.
- **An ERC-721 shows on one identity at a time:** placing it anywhere takes it off wherever it was.
- **A wallet's ERC-1155 copies show on as many slots as it holds copies.** If it sells copies, its placements of that
  item go dark until it takes enough off.
- identity.md tokens are never worn.

**Reads:**
- `faceOf`, `itemOf`, `wearerOf(collection, tokenId)` (the reverse: which identity and slot).
- `faceURI` (the face's metadata, or the identity's own).
- `itemURI`.
- `avatarOf`: ENSIP-12, `eip155:1/erc721:<collection>/<id>`. Any ENS-avatar library resolves it.

## LARP names: name.imd

- `register(imdId, label, minImd)`, paying exactly `priceOf(label)`:

  | label length | price |
  |---|---|
  | 1 to 3 | 0.069 ETH |
  | 4 | 0.0169 ETH |
  | 5+ | 0.0069 ETH |

  The fee buys at least `minImd` $IMD on POOL4, which goes to IMD's BurnExecutor (`0xe293…c750`).
- **One name per identity, unique.** A label is 1 to 32 of a-z, 0-9 and `-`, not at either end.
- **The name belongs to the identity** and passes with it on a sale. `release` frees it; `moveName(from, to)` moves it
  between the caller's identities.
- `resolve(label)` / `resolveName("kek.imd")` return the identity and the wallet holding it now. `nameOf(imdId)` returns
  `"kek.imd"`.
- **Reverse record:** `setPrimary(imdId)` picks a wallet's identity; `primaryOf(wallet)` is live while the wallet
  holds it.
- **Text records:** `setText(imdId, key, value)` for `x`, `url`, `agent`, … They belong to the holder who set them, so
  a new holder starts with none.
- `burn(minImd)`: anyone can send ETH to buy and burn $IMD on POOL4.

**If POOL4 can't take a fee** (no liquidity, a broken hook), the ETH goes to the IMD6900 NFT pot (`0xA160…6444`)
instead, so the registry never stops. A partial fill counts as "can't".

## LARP links: frens, crews, ranks

**Frens.** `fren(me, them)` asks; the same call from the other side says yes. `unfren` cuts a link, withdraws an ask
or declines one. Links are between identities and pass with them.

**Crews.**
- `foundCrew(captain, name, open, minImd)` costs 0.0069 ETH, burned through POOL4. Crew names are unique among live
  crews.
- Open crews take anyone; closed ones take whoever the captain `invite`s.
- One crew per identity.
- The captain can `kick`, `passCaptain` and `disband`. The captaincy passes with the captain's identity.

**The jeet rank.** Every IMD launch pays the swarm through a Merkle distributor.
- **Proving:** `proveAlloc(launch, round, wallet, amount, proof)` proves an allocation. Anyone can prove anyone's: the
  proofs are public at `api.imd.fun/launches/<id>?claims=1`.
- **What's accepted:** only distributors that IMD's launcher (`0xfF03…7120`) names in `distributorOf(launch)`.
- **What's read, live:** what the wallet claimed and no longer holds is jeeted; what it never claimed is not.
- **The scores:**
  - **Level** is the number of swarm launches proven.
  - **Jeet points** are the jeeted shares added up, in basis points: 10,000 = one launch's allocation, all sold.
  - **The tier** comes from the average jeeted share: **Lurker** (no launch), **Diamond Hands** (< 10%), **Holder**
    (< 35%), **Paper Hands** (< 65%), **Jeet** (< 90%), **Jeet Lord**.
- **Calls:**
  - `rankOf(imdId)` reads the wallet holding the identity now.
  - `jeetOfRange` reads a page, for busy wallets.
  - `cardOf(imdId)` returns holder, name, face, crew, frens, level, points and title in one call.

On the fork, with real proofs: `0x2a89…7dca` claimed the IMD (#739) and ZTO (#737) airdrops and sold every token, so it
is a Jeet Lord. The IMD6900 treasury holds everything it claimed, so it is Diamond Hands at level 4.

## The launch (`evm_contracts`, Ethereum)

Three contracts, created in this order:

| contract | constructor arguments |
|---|---|
| `LARP` | identity.md `0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D` |
| `LARPNames` | identity.md; PoolManager `0x000000000004444c5dc75cB358380D2e3dE08A90`; $IMD `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7`; POOL4's hook `0xc6C965Bd164c483e87d0B550671798e9A3602840`; IMD's BurnExecutor `0xe29386719C155B6847aD5a4E97C6674f10ffc750`; the IMD6900 pot `0xA16026A28aA581AA96713d20C608Da7F8db86444` |
| `LARPLinks` | identity.md; IMD's launcher `0xfF03410d0Fe5fa8f7F59F743de35E333D9857120`; `$contract:LARP`; `$contract:LARPNames` |

- The constructors store addresses and call nothing.
- No CALLCODE, DELEGATECALL or SELFDESTRUCT anywhere.
- All three fit one transaction.
- Nothing is done after the launch.

## Tests and audit

```sh
forge test --offline                                       # 90 tests: unit, fuzz, invariants, a real local v4 POOL4
MAINNET_RPC_URL=<rpc> forge test --match-contract MainnetFork  # 7 more on Ethereum: real POOL4, BurnExecutor, proofs
```

`AUDIT.md` has the pre-launch audit: no critical, high or medium findings. Two lows are fixed and tested; the rest are
documented.

The PoolManager and v4-core under `lib/` are for the tests only (BUSL-1.1 parts never deployed). The contracts import
nothing outside `src/`.
