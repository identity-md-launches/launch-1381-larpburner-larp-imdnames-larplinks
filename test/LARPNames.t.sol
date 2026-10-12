// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base, Pot} from "./Base.sol";
import {LARPNames} from "../src/LARPNames.sol";
import {ILARPNames} from "../src/ILARPNames.sol";
import {BuysIMD} from "../src/BuysIMD.sol";

/// @dev A PoolManager whose swap burns all the gas it is given, as a heavy hook could.
contract GasHogPoolManager {
    function unlock(bytes calldata) external pure returns (bytes memory) {
        while (true) {}
        return "";
    }
}

/// @dev A pot that tries to register a name again while it is being paid.
contract GreedyPot {
    LARPNames public names;

    function aim(LARPNames names_) external {
        names = names_;
    }

    receive() external payable {
        names.burn{value: msg.value}(0);
    }
}

contract LARPNamesTest is Base {
    event IMDBurned(uint256 eth, uint256 imd);
    event NameRegistered(
        uint256 indexed imdId, bytes32 indexed label, address indexed holder, uint256 paid, uint256 imdBurned
    );
    event NameReleased(uint256 indexed imdId, bytes32 indexed label);

    bytes32 kek;

    function setUp() public {
        _deploy();
        _fillPool4();
        identity.mint(alice, 0);
        identity.mint(alice, 1);
        identity.mint(bob, 2);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        kek = _label("kekmaster");
    }

    function _register(address who, uint256 imdId, bytes32 label) internal {
        uint256 price = names.priceOf(label);
        vm.prank(who);
        names.register{value: price}(imdId, label, 0);
    }

    // --- registering ---

    function test_RegisterBurnsIMDThroughPool4() public {
        uint256 before = imd.balanceOf(burnExecutor);
        vm.expectEmit(true, true, true, false, address(names));
        emit NameRegistered(0, kek, alice, 0.0069 ether, 0);
        vm.prank(alice);
        names.register{value: 0.0069 ether}(0, kek, 0);

        uint256 burned = imd.balanceOf(burnExecutor) - before;
        // 0.0069 ETH at ~2,000 IMD per ETH, less POOL4's 1%
        assertApproxEqRel(burned, 13.66 ether, 0.02e18, "the fee bought $IMD for IMD's burn");
        assertEq(address(names).balance, 0, "no ETH stays");
        assertEq(address(pot).balance, 0, "POOL4 took it");

        assertEq(names.nameOf(0), "kekmaster.imd");
        assertEq(names.labelOf(0), kek);
        (bool exists, uint256 imdId, address holder) = names.resolve(kek);
        assertTrue(exists);
        assertEq(imdId, 0);
        assertEq(holder, alice);
    }

    function test_ResolveName() public {
        _register(alice, 1, kek);
        (bool exists, uint256 imdId,) = names.resolveName("kekmaster.imd");
        assertTrue(exists);
        assertEq(imdId, 1);
        (exists, imdId,) = names.resolveName("kekmaster");
        assertTrue(exists);
        assertEq(imdId, 1);
        string[6] memory misses = ["KEKMASTER.imd", "kekmaster.eth", ".imd", "", "nobody.imd", "kek master"];
        for (uint256 i; i < misses.length; ++i) {
            (exists,,) = names.resolveName(misses[i]);
            assertFalse(exists, misses[i]);
        }
    }

    function test_Prices() public view {
        assertEq(names.priceOf(_label("a")), 0.069 ether);
        assertEq(names.priceOf(_label("kek")), 0.069 ether);
        assertEq(names.priceOf(_label("pepe")), 0.0169 ether);
        assertEq(names.priceOf(_label("frens")), 0.0069 ether);
        assertEq(names.priceOf(_label("0123456789abcdefghijklmnopqrstuv")), 0.0069 ether);
    }

    function test_BadNames() public {
        bytes32[7] memory bad = [
            bytes32(0),
            _label("Kek"),
            _label("-kek"),
            _label("kek-"),
            _label("ke k"),
            _label("ke.k"),
            bytes32(uint256(_label("kek")) | 1) // a byte after the padding
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(ILARPNames.BadName.selector);
            names.priceOf(bad[i]);
        }
        assertEq(names.priceOf(_label("k-e-k")), 0.0069 ether, "hyphens inside are fine");
    }

    function test_ExactPriceOnly() public {
        vm.startPrank(alice);
        vm.expectRevert(ILARPNames.WrongPrice.selector);
        names.register{value: 0.0068 ether}(0, kek, 0);
        vm.expectRevert(ILARPNames.WrongPrice.selector);
        names.register{value: 0.007 ether}(0, kek, 0);
        vm.stopPrank();
    }

    function test_OnlyTheIdentitysOwnerRegisters() public {
        vm.prank(bob);
        vm.expectRevert(ILARPNames.NotYourIdentity.selector);
        names.register{value: 0.0069 ether}(0, kek, 0);
    }

    function test_OneHolderPerName() public {
        _register(alice, 0, kek);
        vm.prank(bob);
        vm.expectRevert(ILARPNames.NameTaken.selector);
        names.register{value: 0.0069 ether}(2, kek, 0);
    }

    function test_ANewNameReleasesTheOld() public {
        _register(alice, 0, kek);
        bytes32 other = _label("otherone");
        vm.expectEmit(address(names));
        emit NameReleased(0, kek);
        _register(alice, 0, other);
        (bool exists,,) = names.resolve(kek);
        assertFalse(exists);
        assertEq(names.nameOf(0), "otherone.imd");
        _register(bob, 2, kek);
        assertEq(names.nameOf(2), "kekmaster.imd");
    }

    function test_TheNamePassesWithTheIdentity() public {
        _register(alice, 0, kek);
        vm.prank(alice);
        identity.transferFrom(alice, bob, 0);
        (bool exists, uint256 imdId, address holder) = names.resolve(kek);
        assertTrue(exists);
        assertEq(imdId, 0);
        assertEq(holder, bob, "resolves to whoever holds the identity");
    }

    function test_Release() public {
        _register(alice, 0, kek);
        vm.prank(alice);
        names.release(0);
        assertEq(names.nameOf(0), "");
        _register(bob, 2, kek);
        vm.prank(alice);
        vm.expectRevert(ILARPNames.NoName.selector);
        names.release(0);
    }

    function test_MoveName() public {
        _register(alice, 0, kek);
        vm.prank(alice);
        names.moveName(0, 1);
        assertEq(names.nameOf(0), "");
        assertEq(names.nameOf(1), "kekmaster.imd");
        (, uint256 imdId,) = names.resolve(kek);
        assertEq(imdId, 1);

        vm.startPrank(alice);
        vm.expectRevert(ILARPNames.NoName.selector);
        names.moveName(0, 1);
        vm.stopPrank();
        _register(alice, 0, _label("second"));
        vm.prank(alice);
        vm.expectRevert(ILARPNames.HasName.selector);
        names.moveName(0, 1);
        vm.prank(alice);
        vm.expectRevert(ILARPNames.NotYourIdentity.selector);
        names.moveName(1, 2);
    }

    // --- POOL4 ---

    function test_MinImdProtectsTheBuy() public {
        vm.prank(alice);
        vm.expectRevert(BuysIMD.TooLittleIMD.selector);
        names.register{value: 0.0069 ether}(0, kek, 20 ether);
        assertEq(names.nameOf(0), "", "nothing registered");
    }

    function test_AnEmptyPool4SendsTheFeeToThePot() public {
        // a fresh deployment whose POOL4 has no liquidity
        _deploy();
        identity.mint(alice, 0);
        vm.expectEmit(address(names));
        emit IMDBurned(0.0069 ether, 0);
        vm.prank(alice);
        names.register{value: 0.0069 ether}(0, kek, 0);
        assertEq(address(pot).balance, 0.0069 ether, "the IMD6900 pot got it");
        assertEq(names.nameOf(0), "kekmaster.imd", "the name is registered all the same");
    }

    /// @dev Audit fix: with any gas limit, the fee is burned through POOL4 or the call reverts. A caller can't make the
    /// swap run out of gas inside the try and push its fee to the pot.
    function test_TooLittleGasNeverReachesThePot() public {
        uint256 burnedTo;
        for (uint256 gas = 60_000; gas < 400_000; gas += 5_000) {
            vm.prank(alice);
            (bool ok,) = address(names).call{value: 0.0069 ether, gas: gas}(
                abi.encodeCall(names.register, (0, _label("gaslimited"), 0))
            );
            assertEq(address(pot).balance, 0, "the pot never gets a fee POOL4 could take");
            if (ok) {
                ++burnedTo;
                vm.prank(alice);
                names.release(0);
            }
        }
        assertGt(burnedTo, 0, "with enough gas it goes through");
    }

    /// @dev Audit fix, the case it guards: a swap that runs out of gas reverts the call; its fee is not pushed to the
    /// pot with the 1/64 of gas the try keeps back.
    function test_ASwapOutOfGasRevertsInsteadOfPayingThePot() public {
        LARPNames hogged = new LARPNames(
            address(identity), address(new GasHogPoolManager()), address(imd), address(0), burnExecutor, address(pot)
        );
        vm.prank(alice);
        (bool ok, bytes memory err) =
            address(hogged).call{value: 0.0069 ether, gas: 3_000_000}(abi.encodeCall(hogged.register, (0, kek, 0)));
        assertFalse(ok);
        assertEq(bytes4(err), BuysIMD.TooLittleGas.selector);
        assertEq(address(pot).balance, 0);
    }

    function test_AnyoneCanBurn() public {
        uint256 before = imd.balanceOf(burnExecutor);
        vm.prank(carol);
        vm.deal(carol, 1 ether);
        uint256 got = names.burn{value: 1 ether}(0);
        assertGt(got, 0);
        assertEq(imd.balanceOf(burnExecutor) - before, got);
    }

    function test_OnlyThePoolManagerCallsBack() public {
        vm.expectRevert(BuysIMD.NotPoolManager.selector);
        names.unlockCallback(abi.encode(uint256(1 ether)));
    }

    function test_NoReentryThroughThePot() public {
        GreedyPot greedy = new GreedyPot();
        LARPNames n2 =
            new LARPNames(address(identity), address(pm), address(imd), address(0x1234), burnExecutor, address(greedy));
        greedy.aim(n2);
        // POOL4 with hook 0x1234 doesn't exist, so the fee goes to the pot, which tries to come back in
        vm.prank(alice);
        vm.expectRevert(BuysIMD.FallbackRefused.selector);
        n2.register{value: 0.0069 ether}(0, kek, 0);
    }

    // --- reverse records and text ---

    function test_Primary() public {
        _register(alice, 1, kek);
        vm.prank(alice);
        names.setPrimary(1);
        (uint256 imdId, string memory name, bool live) = names.primaryOf(alice);
        assertEq(imdId, 1);
        assertEq(name, "kekmaster.imd");
        assertTrue(live);

        vm.prank(alice);
        identity.transferFrom(alice, bob, 1);
        (, name, live) = names.primaryOf(alice);
        assertFalse(live, "she no longer holds it");
        assertEq(name, "");

        vm.prank(alice);
        vm.expectRevert(ILARPNames.NotYourIdentity.selector);
        names.setPrimary(2);
    }

    function test_TextRecordsStartOverWithANewHolder() public {
        vm.prank(alice);
        names.setText(0, "x", "@kekmaster");
        assertEq(names.text(0, "x"), "@kekmaster");
        vm.prank(alice);
        identity.transferFrom(alice, bob, 0);
        assertEq(names.text(0, "x"), "", "bob starts over");
        vm.prank(bob);
        names.setText(0, "x", "@bob");
        assertEq(names.text(0, "x"), "@bob");
        vm.prank(bob);
        identity.transferFrom(bob, alice, 0);
        assertEq(names.text(0, "x"), "@kekmaster", "alice's record is hers");
    }

    function test_SupportsInterface() public view {
        assertTrue(names.supportsInterface(type(ILARPNames).interfaceId));
        assertTrue(names.supportsInterface(0x01ffc9a7));
        assertFalse(names.supportsInterface(0xffffffff));
    }

    function testFuzz_OneNamePerIdentityOneIdentityPerName(uint8 a, uint8 b) public {
        bytes32[3] memory labels = [_label("alpha"), _label("bravo"), _label("charlie")];
        _register(alice, 0, labels[a % 3]);
        uint256 price = names.priceOf(labels[b % 3]);
        vm.prank(bob);
        if (a % 3 == b % 3) vm.expectRevert(ILARPNames.NameTaken.selector);
        names.register{value: price}(2, labels[b % 3], 0);
        (, uint256 holderOfA,) = names.resolve(labels[a % 3]);
        assertEq(holderOfA, 0);
    }
}
