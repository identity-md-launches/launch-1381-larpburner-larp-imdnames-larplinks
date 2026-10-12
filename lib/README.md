# Vendored libraries

Only what this repository uses, so it builds offline.

- `solady/`: `tokens/ERC721.sol` and `utils/Base64.sol`, compiled into `LARPNames` (MIT, github.com/Vectorized/solady).
- `forge-std/`: tests only (MIT / Apache-2.0).
- `v4-core/`: Uniswap v4 core, for the tests' local PoolManager, POOL4 and backup pool. Interfaces, types and libraries
  are MIT; `PoolManager.sol` and its base contracts are BUSL-1.1 (see `v4-core/licenses/`) and are never deployed by
  this repository.
- `solmate/src/auth/Owned.sol`: not solmate's. v4-core's PoolManager imports solmate's `Owned`, which is AGPL; this is a
  minimal stand-in with the same interface (MIT).
