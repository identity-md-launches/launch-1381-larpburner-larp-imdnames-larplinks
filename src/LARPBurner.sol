// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev The few Uniswap v4 PoolManager types and calls a buy needs (ABI-identical to v4-core's).
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManagerLike {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256);
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
}

/// @title LARP burner: every fee buys $IMD and burns it, by the IMD6900 frens
/// @notice Every fee and royalty of the LARP protocol ends here as ETH, and leaves only as $IMD bought on Uniswap v4
/// and sent to 0x…dEaD, where nobody can ever move it. First route: POOL4, IMD's ETH/$IMD pool, so every fee is volume
/// there. If POOL4 can't take the trade (closed, empty, a hook that refuses), the second route: the hookless ETH/$IMD
/// pool (1%, tick spacing 200), which nobody can close. If neither can, the ETH waits here until anyone calls `burn`.
/// @dev No owner, no roles, no upgrades. ETH never leaves except into a swap. At most MAX_BURN is spent per call: a
/// small trade isn't worth sandwiching against a 1% pool.
contract LARPBurner {
    /// @notice Where bought $IMD goes: nobody holds this key.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    /// @notice The most ETH one call spends (more waits for the next call).
    uint256 public constant MAX_BURN = 0.1 ether;
    /// @dev v4-core TickMath.MIN_SQRT_PRICE + 1: sell ETH as far down as the pool goes.
    uint160 internal constant MIN_PRICE_LIMIT = 4295128740;
    uint256 private constant _LOCK = uint256(keccak256("larp.burner.lock"));

    /// @notice Uniswap v4's PoolManager.
    IPoolManagerLike public immutable POOL_MANAGER;
    /// @notice $IMD.
    address public immutable IMD;
    /// @notice The first route, POOL4: fee, tick spacing and hook.
    uint24 public immutable POOL4_FEE;
    int24 public immutable POOL4_SPACING;
    address public immutable POOL4_HOOK;
    /// @notice The second route, the hookless pool: fee and tick spacing.
    uint24 public immutable BACKUP_FEE;
    int24 public immutable BACKUP_SPACING;

    /// @notice `eth` bought `imd` $IMD on route `route` (0 = POOL4, 1 = the hookless pool), sent to DEAD.
    event Burned(uint256 eth, uint256 imd, uint8 route);
    /// @notice No route could take `eth`: it waits here for the next `burn`.
    event Parked(uint256 eth);

    error ZeroAddress();
    error NotPoolManager();
    error TooLittleIMD();
    error TooLittleGas();
    error Reentered();
    error Unfilled();

    constructor(
        address poolManager,
        address imd,
        uint24 pool4Fee,
        int24 pool4Spacing,
        address pool4Hook,
        uint24 backupFee,
        int24 backupSpacing
    ) {
        if (poolManager == address(0) || imd == address(0)) revert ZeroAddress();
        POOL_MANAGER = IPoolManagerLike(poolManager);
        IMD = imd;
        POOL4_FEE = pool4Fee;
        POOL4_SPACING = pool4Spacing;
        POOL4_HOOK = pool4Hook;
        BACKUP_FEE = backupFee;
        BACKUP_SPACING = backupSpacing;
    }

    /// @notice Fees and royalties arrive here; anyone can send.
    receive() external payable {}

    /// @notice Spends what is here (with what is sent), up to MAX_BURN, on $IMD for DEAD: POOL4 first, then the
    /// hookless pool. If both refuse, the ETH stays for later and this returns 0, unless `minImd` is set, then it
    /// reverts. If a route buys less than `minImd`, it reverts.
    function burn(uint256 minImd) external payable returns (uint256 imd) {
        uint256 slot = _LOCK;
        bool locked;
        assembly {
            locked := tload(slot)
        }
        if (locked) revert Reentered();
        assembly {
            tstore(slot, 1)
        }

        uint256 eth = address(this).balance;
        if (eth > MAX_BURN) eth = MAX_BURN;
        if (eth != 0) {
            for (uint8 route; route < 2; ++route) {
                uint256 gasBefore = gasleft();
                try POOL_MANAGER.unlock(abi.encode(route, eth)) returns (bytes memory result) {
                    imd = abi.decode(result, (uint256));
                    emit Burned(eth, imd, route);
                    break;
                } catch {
                    // the call keeps at most 1/64 of the gas back: if that's all that's left, it ran out of gas, and
                    // a caller must not be able to skip a route by sending too little
                    if (gasleft() <= gasBefore / 63) revert TooLittleGas();
                }
            }
            if (imd == 0) emit Parked(eth);
        }
        if (imd < minImd) revert TooLittleIMD();

        assembly {
            tstore(slot, 0)
        }
    }

    /// @notice The PoolManager's callback: sells exactly `eth` on the route, all of it or nothing.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        (uint8 route, uint256 eth) = abi.decode(data, (uint8, uint256));
        PoolKey memory key = route == 0
            ? PoolKey(address(0), IMD, POOL4_FEE, POOL4_SPACING, POOL4_HOOK)
            : PoolKey(address(0), IMD, BACKUP_FEE, BACKUP_SPACING, address(0));
        int256 delta = POOL_MANAGER.swap(key, SwapParams(true, -int256(eth), MIN_PRICE_LIMIT), "");
        int128 ethDelta = int128(delta >> 128);
        int128 imdDelta = int128(delta);
        // a partial fill (the pool ran dry) or nothing bought: undo, and try the next route
        if (ethDelta != -int128(int256(eth)) || imdDelta <= 0) revert Unfilled();
        POOL_MANAGER.settle{value: eth}();
        POOL_MANAGER.take(IMD, DEAD, uint128(imdDelta));
        return abi.encode(uint256(uint128(imdDelta)));
    }
}
