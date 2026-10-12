// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDFace} from "../src/IMDFace.sol";
import {MockNFT} from "./Mocks.sol";

/// @dev Three wallets trade four identities and six masks (two collections) and put masks on and off at random.
contract FaceHandler is Test {
    IMDFace public face;
    MockNFT public identity;
    MockNFT[2] public masks;
    address[3] public wallets = [address(0xA11CE), address(0xB0B), address(0xCA401)];

    constructor(IMDFace face_, MockNFT identity_, MockNFT[2] memory masks_) {
        face = face_;
        identity = identity_;
        masks = masks_;
    }

    function setFace(uint256 who, uint256 imdId, uint256 which, uint256 tokenId) external {
        address w = wallets[who % 3];
        vm.prank(w);
        try face.setFace(imdId % 4, address(masks[which % 2]), tokenId % 3) {} catch {}
    }

    function clearFace(uint256 who, uint256 imdId) external {
        vm.prank(wallets[who % 3]);
        try face.clearFace(imdId % 4) {} catch {}
    }

    function giveIdentity(uint256 to, uint256 imdId) external {
        imdId %= 4;
        address from = identity.ownerOf(imdId);
        vm.prank(from);
        identity.transferFrom(from, wallets[to % 3], imdId);
    }

    function giveMask(uint256 to, uint256 which, uint256 tokenId) external {
        MockNFT m = masks[which % 2];
        tokenId %= 3;
        address from = m.ownerOf(tokenId);
        vm.prank(from);
        m.transferFrom(from, wallets[to % 3], tokenId);
    }
}

contract IMDFaceInvariantTest is Test {
    IMDFace face;
    MockNFT identity;
    MockNFT[2] masks;
    FaceHandler handler;

    function setUp() public {
        identity = new MockNFT("identity://");
        masks = [new MockNFT("a://"), new MockNFT("b://")];
        face = new IMDFace(address(identity));
        handler = new FaceHandler(face, identity, masks);
        for (uint256 i; i < 4; ++i) {
            identity.mint(handler.wallets(i % 3), i);
        }
        for (uint256 i; i < 3; ++i) {
            masks[0].mint(handler.wallets(i), i);
            masks[1].mint(handler.wallets((i + 1) % 3), i);
        }
        targetContract(address(handler));
    }

    /// @dev A live face is exactly: its holder owns the identity and the mask, and the mask names it as its wearer.
    function invariant_LiveMeansTheHolderHoldsBoth() public view {
        for (uint256 imdId; imdId < 4; ++imdId) {
            (address holder, address collection, uint256 tokenId, bool live) = face.faceOf(imdId);
            bool both = holder != address(0) && identity.ownerOf(imdId) == holder
                && MockNFT(collection).ownerOf(tokenId) == holder;
            assertEq(live, both, "live iff the holder holds both");
            if (holder != address(0)) {
                (uint256 wearer, bool worn) = face.wearerOf(collection, tokenId);
                assertEq(wearer, imdId, "the mask names its wearer");
                assertEq(worn, live);
            }
        }
    }

    /// @dev No mask is on two identities, and a mask's wearer points back at it.
    function invariant_OneMaskOneIdentity() public view {
        for (uint256 m; m < 2; ++m) {
            for (uint256 tokenId; tokenId < 3; ++tokenId) {
                (uint256 wearer, bool worn) = face.wearerOf(address(masks[m]), tokenId);
                uint256 wearing;
                for (uint256 imdId; imdId < 4; ++imdId) {
                    (address holder, address collection, uint256 t,) = face.faceOf(imdId);
                    if (holder != address(0) && collection == address(masks[m]) && t == tokenId) {
                        ++wearing;
                        assertEq(wearer, imdId, "the record and the reverse agree");
                    }
                }
                assertLe(wearing, 1, "one identity per mask");
                if (wearing == 0) assertFalse(worn, "an unworn mask has no live wearer");
            }
        }
    }
}
