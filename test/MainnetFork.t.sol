// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDFace} from "../src/IMDFace.sol";

interface IERC721Like {
    function ownerOf(uint256) external view returns (address);
    function tokenURI(uint256) external view returns (string memory);
    function transferFrom(address, address, uint256) external;
}

/// @dev The real thing on an Ethereum fork: identity.md #806 wears Worker Fren #1, both held by the IMD6900
/// treasury. Runs when MAINNET_RPC_URL is set, skips otherwise (IMD's swarm builds without an RPC).
contract MainnetForkTest is Test {
    address constant IDENTITY = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    address constant WORKER_FRENS = 0x6900d042460d6bdbe68CE994F4dE36706797CCd4;
    address constant TREASURY = 0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F;

    IMDFace face;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        face = new IMDFace(IDENTITY);
    }

    function test_AnIdentityWearsAWorkerFren() public {
        if (address(face) == address(0)) vm.skip(true);
        assertEq(IERC721Like(IDENTITY).ownerOf(806), TREASURY);
        assertEq(IERC721Like(WORKER_FRENS).ownerOf(1), TREASURY);

        vm.prank(TREASURY);
        face.setFace(806, WORKER_FRENS, 1);

        (,,, bool live) = face.faceOf(806);
        assertTrue(live);
        assertEq(face.faceURI(806), IERC721Like(WORKER_FRENS).tokenURI(1), "the fren's own on-chain art");
        assertEq(face.avatarOf(806), "eip155:1/erc721:0x6900d042460d6bdbe68ce994f4de36706797ccd4/1");
        (uint256 wearer, bool worn) = face.wearerOf(WORKER_FRENS, 1);
        assertEq(wearer, 806);
        assertTrue(worn);

        // the identity leaves the treasury: the face goes down, its own art comes back
        address buyer = makeAddr("buyer");
        vm.prank(TREASURY);
        IERC721Like(IDENTITY).transferFrom(TREASURY, buyer, 806);
        (,,, live) = face.faceOf(806);
        assertFalse(live);
        assertEq(face.faceURI(806), IERC721Like(IDENTITY).tokenURI(806));
        assertEq(face.avatarOf(806), "");
    }

    function test_RefusesAnIdentityAsAMask() public {
        if (address(face) == address(0)) vm.skip(true);
        vm.prank(TREASURY);
        vm.expectRevert();
        face.setFace(806, IDENTITY, 1533);
    }

    function test_SomeoneElsesFrenRefused() public {
        if (address(face) == address(0)) vm.skip(true);
        address holder = IERC721Like(IDENTITY).ownerOf(0);
        vm.prank(holder);
        vm.expectRevert();
        face.setFace(0, WORKER_FRENS, 1);
    }
}
