// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./Base.sol";
import {LARPBurner} from "../src/LARPBurner.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary, PoolKey as V4PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @dev A PoolManager whose swap burns all the gas it is given, as a heavy hook could.
contract GasHogPoolManager {
    function unlock(bytes calldata) external pure returns (bytes memory) {
        while (true) {}
        return "";
    }
}

contract LARPBurnerTest is Base {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for V4PoolKey;
    event Burned(uint256 eth, uint256 imd, uint8 route);
    event Parked(uint256 eth);

    function setUp() public {
        _deploy();
    }

    function test_BurnsThroughPool4First() public {
        _fillPool4();
        _fillBackup();
        vm.expectEmit(true, false, true, false, address(burner));
        emit Burned(0.05 ether, 0, 0);
        uint256 got = burner.burn{value: 0.05 ether}(0);
        assertApproxEqRel(got, 99 ether, 0.02e18, "0.05 ETH at ~2,000 IMD per ETH, less 1%");
        assertEq(imd.balanceOf(DEAD), got, "to 0x..dEaD, where nobody can move it");
        assertEq(address(burner).balance, 0);
    }

    function test_TheHooklessPoolIfPool4CantTakeIt() public {
        _fillBackup(); // POOL4 stays empty
        vm.expectEmit(true, false, true, false, address(burner));
        emit Burned(0.05 ether, 0, 1);
        uint256 got = burner.burn{value: 0.05 ether}(0);
        assertGt(got, 0);
        assertEq(imd.balanceOf(DEAD), got);
    }

    function test_ParkedWhenNoPoolCanAndBurnedLater() public {
        vm.expectEmit(address(burner));
        emit Parked(0.05 ether);
        assertEq(burner.burn{value: 0.05 ether}(0), 0);
        assertEq(address(burner).balance, 0.05 ether, "it waits");

        _fillPool4();
        vm.prank(carol); // anyone
        uint256 got = burner.burn(0);
        assertGt(got, 0);
        assertEq(address(burner).balance, 0);
    }

    function test_MinImdWhenParkingIsNotWanted() public {
        vm.expectRevert(LARPBurner.TooLittleIMD.selector);
        burner.burn{value: 0.05 ether}(1);
    }

    function test_MinImdProtectsTheBuy() public {
        _fillPool4();
        vm.expectRevert(LARPBurner.TooLittleIMD.selector);
        burner.burn{value: 0.05 ether}(200 ether);
    }

    function test_RoyaltiesArriveByPlainTransfer() public {
        // markets pay royalties with transfer (2,300 gas) or call: both land
        payable(address(burner)).transfer(0.01 ether);
        (bool ok,) = address(burner).call{value: 0.02 ether}("");
        assertTrue(ok);
        assertEq(address(burner).balance, 0.03 ether);
    }

    function test_AtMostMaxBurnPerCall() public {
        _fillPool4();
        vm.deal(address(burner), 0.35 ether);
        burner.burn(0);
        assertEq(address(burner).balance, 0.25 ether);
        burner.burn(0);
        burner.burn(0);
        burner.burn(0);
        assertEq(address(burner).balance, 0);
        assertEq(burner.MAX_BURN(), 0.1 ether);
    }

    function test_EmptyBurnIsANoOp() public {
        assertEq(burner.burn(0), 0);
    }

    function test_OnlyThePoolManagerCallsBack() public {
        vm.expectRevert(LARPBurner.NotPoolManager.selector);
        burner.unlockCallback(abi.encode(uint8(0), uint256(1 ether)));
    }

    /// @dev A swap that runs out of gas reverts the call instead of skipping its route.
    function test_ASwapOutOfGasReverts() public {
        LARPBurner hogged =
            new LARPBurner(address(new GasHogPoolManager()), address(imd), 10_000, 60, address(0), 10_000, 200);
        (bool ok, bytes memory err) =
            address(hogged).call{value: 0.05 ether, gas: 3_000_000}(abi.encodeCall(hogged.burn, (0)));
        assertFalse(ok);
        assertEq(bytes4(err), LARPBurner.TooLittleGas.selector);
    }

    /// @dev With any gas limit, a burn goes through POOL4 or reverts: too little gas can't push it to the backup.
    function test_NoGasLimitSkipsPool4() public {
        _fillPool4();
        _fillBackup();
        (uint160 backupPrice,,,) = IPoolManager(address(pm)).getSlot0(backup.toId());
        uint256 burned;
        for (uint256 gas = 40_000; gas < 400_000; gas += 5_000) {
            (bool ok,) = address(burner).call{value: 0.001 ether, gas: gas}(abi.encodeCall(burner.burn, (0)));
            if (ok) ++burned;
            (uint160 now_,,,) = IPoolManager(address(pm)).getSlot0(backup.toId());
            assertEq(now_, backupPrice, "the backup is never used while POOL4 can take the trade");
        }
        assertGt(burned, 0);
        assertGt(imd.balanceOf(DEAD), 0);
    }

    /// @dev A burn can't run inside a burn: here the PoolManager itself tries, as a hook could.
    function test_NoReentry() public {
        ReenteringPoolManager evil = new ReenteringPoolManager();
        LARPBurner b = new LARPBurner(address(evil), address(imd), 10_000, 60, address(0), 10_000, 200);
        evil.aim(b);
        b.burn{value: 0.01 ether}(0);
        assertEq(bytes4(evil.lastError()), LARPBurner.Reentered.selector);
    }
}

/// @dev A PoolManager that calls the burner back during unlock.
contract ReenteringPoolManager {
    LARPBurner public burner;
    bytes public lastError;

    function aim(LARPBurner b) external {
        burner = b;
    }

    function unlock(bytes calldata) external returns (bytes memory) {
        try burner.burn(0) {}
        catch (bytes memory e) {
            lastError = e;
        }
        return abi.encode(uint256(0));
    }
}
