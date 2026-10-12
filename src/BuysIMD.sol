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

/// @title BuysIMD: every fee buys $IMD on POOL4 and burns it
/// @notice A registry fee is spent at once on $IMD in IMD's own ETH/$IMD Uniswap v4 pool (POOL4: 1% fee, tick spacing
/// 60), and the $IMD goes to IMD's BurnExecutor, which destroys it and counts it as IMD's burn. So every fee is volume
/// on POOL4 and $IMD burned. If POOL4 cannot take the trade (no liquidity, a broken hook), the ETH goes to the
/// fallback (the IMD6900 NFT pot) instead, so the registry never stops.
/// @dev Inherited, not called: the buy runs inside the inheriting contract. No funds stay here between calls.
abstract contract BuysIMD {
    /// @dev v4-core TickMath.MIN_SQRT_PRICE + 1: sell ETH as far down as the pool goes.
    uint160 internal constant MIN_PRICE_LIMIT = 4295128740;

    /// @notice Uniswap v4's PoolManager.
    IPoolManagerLike public immutable POOL_MANAGER;
    /// @notice $IMD.
    address public immutable IMD;
    /// @notice POOL4's hook.
    address public immutable POOL4_HOOK;
    /// @notice Where the $IMD goes: IMD's BurnExecutor.
    address public immutable IMD_BURN;
    /// @notice Where the ETH goes when POOL4 can't take it.
    address public immutable FALLBACK;

    uint256 private constant _LOCK = uint256(keccak256("larp.buysimd.lock"));

    /// @notice `eth` bought `imd` $IMD on POOL4, sent to IMD's BurnExecutor (`imd` = 0: the ETH went to FALLBACK).
    event IMDBurned(uint256 eth, uint256 imd);

    error ZeroAddress();
    error NotPoolManager();
    error TooLittleIMD();
    error FallbackRefused();
    error TooLittleGas();
    error Reentered();

    constructor(address poolManager, address imd, address pool4Hook, address imdBurn, address fallback_) {
        if (poolManager == address(0) || imd == address(0) || imdBurn == address(0) || fallback_ == address(0)) {
            revert ZeroAddress();
        }
        POOL_MANAGER = IPoolManagerLike(poolManager);
        IMD = imd;
        POOL4_HOOK = pool4Hook;
        IMD_BURN = imdBurn;
        FALLBACK = fallback_;
    }

    /// @dev One payable entry at a time: a fee can't be spent twice or re-entered mid-buy.
    modifier nonReentrant() {
        uint256 slot = _LOCK;
        bool locked;
        assembly {
            locked := tload(slot)
        }
        if (locked) revert Reentered();
        assembly {
            tstore(slot, 1)
        }
        _;
        assembly {
            tstore(slot, 0)
        }
    }

    /// @dev Spends `eth` on $IMD on POOL4 for IMD's BurnExecutor; reverts if that buys less than `minImd`. If POOL4
    /// can't take the trade at all, the ETH goes to FALLBACK and `minImd` is not checked. A buy that ran out of gas
    /// reverts instead: a caller can't push its fee to FALLBACK by sending too little gas.
    function _buyAndBurn(uint256 eth, uint256 minImd) internal returns (uint256 imd) {
        if (eth == 0) return 0;
        uint256 gasBefore = gasleft();
        try POOL_MANAGER.unlock(abi.encode(eth)) returns (bytes memory result) {
            imd = abi.decode(result, (uint256));
            if (imd < minImd) revert TooLittleIMD();
        } catch {
            // the call kept at most 1/64 of the gas back: if that's all that's left, it ran out
            if (gasleft() <= gasBefore / 63) revert TooLittleGas();
            (bool ok,) = FALLBACK.call{value: eth}("");
            if (!ok) revert FallbackRefused();
        }
        emit IMDBurned(eth, imd);
    }

    /// @notice The PoolManager's callback: sells exactly the ETH asked for, all of it or nothing.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        uint256 eth = abi.decode(data, (uint256));
        int256 delta = POOL_MANAGER.swap(
            PoolKey(address(0), IMD, 10_000, 60, POOL4_HOOK), SwapParams(true, -int256(eth), MIN_PRICE_LIMIT), ""
        );
        int128 ethDelta = int128(delta >> 128);
        int128 imdDelta = int128(delta);
        // a partial fill (the pool ran dry) or nothing bought: undo, and the fee goes to FALLBACK
        if (ethDelta != -int128(int256(eth)) || imdDelta <= 0) revert TooLittleIMD();
        POOL_MANAGER.settle{value: eth}();
        POOL_MANAGER.take(IMD, IMD_BURN, uint128(imdDelta));
        return abi.encode(uint256(uint128(imdDelta)));
    }
}
