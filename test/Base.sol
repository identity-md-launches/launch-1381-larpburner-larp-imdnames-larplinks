// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "forge-std/mocks/MockERC20.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey as V4PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {LARP} from "../src/LARP.sol";
import {ILARP} from "../src/ILARP.sol";
import {LARPNames} from "../src/LARPNames.sol";
import {ILARPNames} from "../src/ILARPNames.sol";
import {LARPLinks} from "../src/LARPLinks.sol";
import {MockNFT} from "./Mocks.sol";

/// @dev An ERC-1155 with the one read LARP makes, a free mint and a transfer.
contract Mock1155 {
    mapping(address => mapping(uint256 => uint256)) public balanceOf;

    function mint(address to, uint256 id, uint256 amount) external {
        balanceOf[to][id] += amount;
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata) external {
        require(msg.sender == from, "not yours");
        balanceOf[from][id] -= amount;
        balanceOf[to][id] += amount;
    }

    function uri(uint256) external pure returns (string memory) {
        return "item://{id}";
    }
}

/// @dev $IMD for tests.
contract MockIMD is MockERC20 {
    constructor() {
        initialize("IMD", "IMD", 18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Adds full-range liquidity to a v4 pool of native ETH and an ERC-20.
contract LiquidityAdder {
    IPoolManager immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function add(V4PoolKey memory key, int256 liquidity) external payable {
        pm.unlock(abi.encode(key, liquidity, msg.sender));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (V4PoolKey memory key, int256 liquidity, address payer) = abi.decode(data, (V4PoolKey, int256, address));
        (BalanceDelta delta,) = pm.modifyLiquidity(
            key, ModifyLiquidityParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), liquidity, 0), ""
        );
        uint256 eth = uint256(uint128(-delta.amount0()));
        uint256 tokens = uint256(uint128(-delta.amount1()));
        pm.settle{value: eth}();
        pm.sync(key.currency1);
        MockIMD(Currency.unwrap(key.currency1)).transferFrom(payer, address(pm), tokens);
        pm.settle();
        if (address(this).balance > 0) payable(payer).transfer(address(this).balance);
        return "";
    }

    receive() external payable {}
}

/// @dev The NFT pot standing in for IMD6900's hook: takes ETH.
contract Pot {
    receive() external payable {}
}

/// @dev IMD's launcher, as far as LARP links reads it.
contract MockLauncher {
    mapping(uint64 => address) public distributorOf;

    function set(uint64 launch, address distributor) external {
        distributorOf[launch] = distributor;
    }
}

/// @dev A swarm airdrop, as far as LARP links reads it: roots per round, who claimed, the token. claim() pays out.
contract MockDistributor {
    address public immutable token;
    mapping(uint256 => bytes32) internal _roots;
    mapping(uint256 => mapping(address => bool)) public claimed;

    constructor(address token_) {
        token = token_;
    }

    function setRoot(uint256 round, bytes32 root) external {
        _roots[round] = root;
    }

    function roundOf(uint256 round) external view returns (bytes32, uint256, uint256, uint64) {
        require(_roots[round] != 0, "no round");
        return (_roots[round], 1e26, 0, 1);
    }

    function claim(uint256 round, address account, uint256 amount) external {
        claimed[round][account] = true;
        MockIMD(token).mint(account, amount);
    }
}

abstract contract Base is Test {
    // Uniswap v4's MIN_SQRT_PRICE + 1, as BuysIMD uses
    uint160 constant MIN_PRICE_LIMIT = 4295128740;

    MockNFT identity;
    MockIMD imd;
    PoolManager pm;
    LiquidityAdder adder;
    Pot pot;
    address burnExecutor = makeAddr("burn executor");
    V4PoolKey pool4;

    LARP larp;
    LARPNames names;
    LARPLinks links;
    MockLauncher launcher;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function _deploy() internal {
        identity = new MockNFT("identity://");
        imd = new MockIMD();
        pm = new PoolManager(address(this));
        adder = new LiquidityAdder(IPoolManager(address(pm)));
        pot = new Pot();
        launcher = new MockLauncher();
        pool4 = V4PoolKey(Currency.wrap(address(0)), Currency.wrap(address(imd)), 10_000, 60, IHooks(address(0)));
        // $IMD at about 0.0005 ETH, as on Ethereum: 1 ETH ~ 2,000 IMD (tick ~ ln(2000)/ln(1.0001) ~ 76,000)
        pm.initialize(pool4, TickMath.getSqrtPriceAtTick(76_020));

        larp = new LARP(address(identity));
        names = new LARPNames(address(identity), address(pm), address(imd), address(0), burnExecutor, address(pot));
        links = new LARPLinks(address(identity), address(launcher), larp, names);
    }

    function _fillPool4() internal {
        imd.mint(address(this), 1e30);
        imd.approve(address(adder), type(uint256).max);
        vm.deal(address(this), 1_000 ether);
        adder.add{value: 1_000 ether}(pool4, 1e21);
    }

    function _label(string memory s) internal pure returns (bytes32 label) {
        assembly {
            label := mload(add(s, 0x20))
        }
        uint256 n = bytes(s).length;
        if (n < 32) label &= ~bytes32(type(uint256).max >> (8 * n));
    }

    receive() external payable {}
}
