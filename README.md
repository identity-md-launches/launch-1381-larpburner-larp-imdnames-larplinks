# IMD Face: give your identity.md a face

identity.md's 2,000 identities are on-chain text artifacts: good identities, plain faces. IMD Face lets each one
wear an NFT from any ERC-721 collection as its face, its **mask**: a Milady, a Pepe, a Worker Fren. Apps across the
IMD ecosystem read one registry to know which face to draw for an identity, and which identity hides behind a mask.
It works the way an ENS avatar does, with one difference: here the chain checks that you own the mask.

One contract, `IMDFace`, deployed on Ethereum by the IMD swarm. No owner, no admin, no upgrades, no fees, no tokens
held, no approvals asked.

## The rules

1. **You need to hold both.** `setFace(imdId, collection, tokenId)` works only if the caller owns identity `imdId` and
   owns the mask, as the mask's collection answers `ownerOf`.
2. **A face is live while its holder holds both.** Nobody has to act when something is sold. If the identity or the
   mask leaves the wallet that set the face, the face goes dark and the identity shows its own art again. If both
   come back to that wallet, the face is live again.
3. **A new owner chooses again.** A face set by the previous owner never shows for the new one, even if they also
   end up with the mask. The new owner calls `setFace` or `clearFace`.
4. **One mask, one identity.** Putting a mask on takes it off whatever identity wore it, so a holder of three
   identities and one Milady can't show the same face three times. Only the mask's current owner can move it.
5. **An identity can't be a mask.** identity.md tokens are the wearers, never the face.

## The standard (`src/IIMDFace.sol`)

```solidity
interface IIMDFace {
    event FaceSet(uint256 indexed imdId, address indexed holder, address indexed collection, uint256 tokenId);
    event FaceCleared(uint256 indexed imdId, address indexed holder);

    function IDENTITY() external view returns (address);                     // identity.md
    function setFace(uint256 imdId, address collection, uint256 tokenId) external;
    function clearFace(uint256 imdId) external;
    function faceOf(uint256 imdId) external view
        returns (address holder, address collection, uint256 tokenId, bool live);
    function wearerOf(address collection, uint256 tokenId) external view returns (uint256 imdId, bool live);
    function faceURI(uint256 imdId) external view returns (string memory);  // what to draw
    function avatarOf(uint256 imdId) external view returns (string memory); // ENS-avatar form
}
```

ERC-165: `supportsInterface(type(IIMDFace).interfaceId)` is true.

### For apps: drawing an identity

- **`faceURI(imdId)`** is all most apps need. It returns the live mask's `tokenURI` (JSON metadata, often a
  `data:` URI), or the identity's own `tokenURI` when the identity wears no live mask or the mask's collection gives
  none. Render it like any NFT's metadata.
- **`avatarOf(imdId)`** returns the live mask as an ENS avatar string (ENSIP-12 / CAIP-22),
  `eip155:1/erc721:<collection>/<tokenId>`, or `""`. Any library that resolves ENS avatars (ethers, viem, the ENS
  metadata service) resolves it.
- **`faceOf(imdId)`** gives the record and whether it is live. A record that is not live must not be shown.
- **`wearerOf(collection, tokenId)`** is the reverse lookup: which identity wears this NFT. `imdId` means something
  only when `live` is true.
- **Indexers** follow `FaceSet` and `FaceCleared`. Liveness also changes with plain transfers of identity.md or of
  the mask, which this registry never sees. Re-check `faceOf` (Multicall3 for many at once) rather than trusting the
  last event.
- **Trust the collection, not just the registry.** The registry proves only what a collection's own `ownerOf`
  answers. Anyone can deploy a contract that claims they own its token #1 and serves a copy of someone else's art, as
  with ENS avatars. Show the collection's address or name next to a face, or keep an allowlist of collections you
  recognise.

### For holders: putting a mask on

From the wallet that holds both NFTs:

```sh
cast send <IMDFace> "setFace(uint256,address,uint256)" <your identity.md id> <collection> <token id> --account <you>
cast send <IMDFace> "clearFace(uint256)" <your identity.md id> --account <you>
```

`setFace` costs about 125k gas the first time; `clearFace` about 40k.

## The launch (`evm_contracts`, Ethereum, chain id 1)

One contract, `IMDFace` (`src/IMDFace.sol`), with one constructor argument:

| | | |
|---|---|---|
| `identity` | `0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D` | identity.md, the collection whose tokens wear the faces |

The constructor stores the address and calls nothing, so the launch deploys the same on a fresh chain
(`test_DeploysOnAFreshChain`). It needs about 545k gas (`test_FitsOneTransaction`). The code contains no CALLCODE,
DELEGATECALL or SELFDESTRUCT, in the creation code (with its argument) or the runtime code
(`test_PassesTheAdmissionScan`). Nothing needs doing after the launch: there is no owner to hand over and nothing to
wire.

## Tests

```sh
forge test --offline                                   # unit, fuzz, invariants, the launch's constraints
MAINNET_RPC_URL=<rpc> forge test --match-contract MainnetFork   # the real collections on an Ethereum fork
```

- `test/IMDFace.t.sol`: every rule above, collections that are not NFTs (an EOA, `ownerOf` reverting, returning a
  short or a dirty word), malformed `tokenURI` return data, the avatar format.
- `test/IMDFace.invariant.t.sol`: three wallets trade four identities and six masks and set and clear faces at random.
  A face is live exactly when its holder holds both, no mask is on two identities, and `faceOf` and `wearerOf` always
  agree.
- `test/MainnetFork.t.sol`: identity.md #806 wears Worker Fren #1 (both in the IMD6900 treasury) and shows the
  fren's on-chain art, then loses the face when #806 leaves the treasury.

## Not in this version

- **Vaults.** The wallet that holds the identity must hold the mask too. Delegation (a cold wallet's NFT worn by a
  hot wallet's identity, e.g. through delegate.xyz) can come in a second registry; this one never changes.
- **ERC-1155 and CryptoPunks.** Masks are ERC-721 (`ownerOf`). Punks can be worn wrapped.
- **Masks on other chains.** Ownership is checked on Ethereum, where identity.md lives.
- **Identities held by contracts** need that contract to call `setFace`. The IMD6900 treasury's identities
  (#806, #1533, #1643) can't, unless an upgrade gives it the call or it releases them to a wallet.
