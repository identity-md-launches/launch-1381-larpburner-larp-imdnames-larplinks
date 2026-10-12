// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDFace} from "../src/IMDFace.sol";
import {IIMDFace} from "../src/IIMDFace.sol";
import {MockNFT, RevertingNFT, DirtyNFT, ShortNFT, RawURINFT} from "./Mocks.sol";

contract IMDFaceTest is Test {
    event FaceSet(uint256 indexed imdId, address indexed holder, address indexed collection, uint256 tokenId);
    event FaceCleared(uint256 indexed imdId, address indexed holder);

    MockNFT identity;
    MockNFT masks;
    MockNFT otherMasks;
    IMDFace face;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        identity = new MockNFT("identity://");
        masks = new MockNFT("mask://");
        otherMasks = new MockNFT("other://");
        face = new IMDFace(address(identity));
        identity.mint(alice, 0);
        identity.mint(alice, 1);
        identity.mint(bob, 2);
        masks.mint(alice, 7);
        masks.mint(alice, 8);
        masks.mint(bob, 9);
        otherMasks.mint(alice, 0);
    }

    function _live(uint256 imdId) internal view returns (bool live) {
        (,,, live) = face.faceOf(imdId);
    }

    // --- setting a face ---

    function test_SetFace() public {
        vm.expectEmit(address(face));
        emit FaceSet(0, alice, address(masks), 7);
        vm.prank(alice);
        face.setFace(0, address(masks), 7);

        (address holder, address collection, uint256 tokenId, bool live) = face.faceOf(0);
        assertEq(holder, alice);
        assertEq(collection, address(masks));
        assertEq(tokenId, 7);
        assertTrue(live);
        (uint256 imdId, bool worn) = face.wearerOf(address(masks), 7);
        assertEq(imdId, 0, "identity #0 wears it");
        assertTrue(worn);
        assertEq(face.faceURI(0), "mask://7");
        assertEq(
            face.avatarOf(0), string.concat("eip155:31337/erc721:", vm.toLowercase(vm.toString(address(masks))), "/7")
        );
    }

    function test_RefusesAnIdentityThatIsNotYours() public {
        vm.prank(alice);
        vm.expectRevert(IIMDFace.NotYourIdentity.selector);
        face.setFace(2, address(masks), 7);
    }

    function test_RefusesAnIdentityThatDoesNotExist() public {
        vm.prank(alice);
        vm.expectRevert(IIMDFace.NotYourIdentity.selector);
        face.setFace(5, address(masks), 7);
    }

    function test_RefusesAMaskThatIsNotYours() public {
        vm.prank(alice);
        vm.expectRevert(IIMDFace.NotYourMask.selector);
        face.setFace(0, address(masks), 9);
    }

    function test_RefusesAnIdentityAsAMask() public {
        vm.prank(alice);
        vm.expectRevert(IIMDFace.NotAMask.selector);
        face.setFace(0, address(identity), 1);
    }

    function test_RefusesWhatIsNotAnNFT() public {
        address eoa = makeAddr("eoa");
        address reverting = address(new RevertingNFT());
        address dirty = address(new DirtyNFT(alice));
        address short = address(new ShortNFT());
        address[5] memory bad = [eoa, address(0), reverting, dirty, short];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(alice);
            vm.expectRevert(IIMDFace.NotYourMask.selector);
            face.setFace(0, bad[i], 1);
        }
    }

    function test_ZeroIdentityRefused() public {
        vm.expectRevert(IMDFace.ZeroIdentity.selector);
        new IMDFace(address(0));
    }

    // --- a face is live only while its holder holds both ---

    function test_SellingTheIdentityTakesTheFaceDown() public {
        vm.prank(alice);
        face.setFace(0, address(masks), 7);
        vm.prank(alice);
        identity.transferFrom(alice, bob, 0);
        assertFalse(_live(0));
        (, bool worn) = face.wearerOf(address(masks), 7);
        assertFalse(worn);
        assertEq(face.faceURI(0), "identity://0", "the identity's own art");
        assertEq(face.avatarOf(0), "");
    }

    function test_SellingTheMaskTakesTheFaceDown() public {
        vm.prank(alice);
        face.setFace(0, address(masks), 7);
        vm.prank(alice);
        masks.transferFrom(alice, bob, 7);
        assertFalse(_live(0));
        assertEq(face.faceURI(0), "identity://0");
    }

    function test_TheNewOwnerMustChooseAgain() public {
        vm.prank(alice);
        face.setFace(0, address(masks), 7);
        // bob ends up with both the identity and the mask: the face alice set is still not his
        vm.startPrank(alice);
        identity.transferFrom(alice, bob, 0);
        masks.transferFrom(alice, bob, 7);
        vm.stopPrank();
        assertFalse(_live(0), "set by alice, not bob");

        vm.prank(bob);
        face.setFace(0, address(masks), 7);
        assertTrue(_live(0));
        (address holder,,,) = face.faceOf(0);
        assertEq(holder, bob);
    }

    function test_AFaceComesBackWithBothTokens() public {
        vm.prank(alice);
        face.setFace(0, address(masks), 7);
        vm.prank(alice);
        masks.transferFrom(alice, bob, 7);
        vm.prank(bob);
        masks.transferFrom(bob, alice, 7);
        assertTrue(_live(0), "the holder's choice stands while she holds both");
    }

    // --- one mask, one identity ---

    function test_AMaskMovesToTheIdentityThatPutsItOn() public {
        vm.prank(alice);
        face.setFace(0, address(masks), 7);

        vm.expectEmit(address(face));
        emit FaceCleared(0, alice);
        vm.expectEmit(address(face));
        emit FaceSet(1, alice, address(masks), 7);
        vm.prank(alice);
        face.setFace(1, address(masks), 7);

        (address holder,,, bool live) = face.faceOf(0);
        assertEq(holder, address(0), "identity #0 has no face");
        assertFalse(live);
        assertTrue(_live(1));
        (uint256 imdId, bool worn) = face.wearerOf(address(masks), 7);
        assertEq(imdId, 1);
        assertTrue(worn);
    }

    function test_TheNewHolderOfAMaskTakesItOff() public {
        vm.prank(alice);
        face.setFace(0, address(masks), 7);
        vm.prank(alice);
        masks.transferFrom(alice, bob, 7);

        vm.expectEmit(address(face));
        emit FaceCleared(0, alice);
        vm.prank(bob);
        face.setFace(2, address(masks), 7);

        (address holder,,,) = face.faceOf(0);
        assertEq(holder, address(0));
        assertTrue(_live(2));
    }

    function test_ChangingMasksFreesTheOldOne() public {
        vm.prank(alice);
        face.setFace(0, address(masks), 7);
        vm.prank(alice);
        face.setFace(0, address(otherMasks), 0);

        (uint256 imdId, bool worn) = face.wearerOf(address(masks), 7);
        assertEq(imdId, 0);
        assertFalse(worn, "mask #7 is free");
        (imdId, worn) = face.wearerOf(address(otherMasks), 0);
        assertEq(imdId, 0);
        assertTrue(worn);
        assertEq(face.faceURI(0), "other://0");
    }

    function test_PuttingTheSameMaskOnAgain() public {
        vm.prank(alice);
        face.setFace(0, address(masks), 7);
        vm.prank(alice);
        face.setFace(0, address(masks), 7);
        assertTrue(_live(0));
        (uint256 imdId, bool worn) = face.wearerOf(address(masks), 7);
        assertEq(imdId, 0);
        assertTrue(worn);
    }

    // --- taking it off ---

    function test_ClearFace() public {
        vm.prank(alice);
        face.setFace(0, address(masks), 7);
        vm.expectEmit(address(face));
        emit FaceCleared(0, alice);
        vm.prank(alice);
        face.clearFace(0);
        (address holder, address collection, uint256 tokenId, bool live) = face.faceOf(0);
        assertEq(holder, address(0));
        assertEq(collection, address(0));
        assertEq(tokenId, 0);
        assertFalse(live);
        (, bool worn) = face.wearerOf(address(masks), 7);
        assertFalse(worn);
    }

    function test_OnlyTheIdentitysOwnerClears() public {
        vm.prank(alice);
        face.setFace(0, address(masks), 7);
        vm.prank(bob);
        vm.expectRevert(IIMDFace.NotYourIdentity.selector);
        face.clearFace(0);
    }

    function test_TheIdentitysNewOwnerClearsTheOldFace() public {
        vm.prank(alice);
        face.setFace(0, address(masks), 7);
        vm.prank(alice);
        identity.transferFrom(alice, bob, 0);
        vm.expectEmit(address(face));
        emit FaceCleared(0, alice);
        vm.prank(bob);
        face.clearFace(0);
        (address holder,,,) = face.faceOf(0);
        assertEq(holder, address(0));
    }

    function test_ClearingNoFaceDoesNothing() public {
        vm.recordLogs();
        vm.prank(alice);
        face.clearFace(0);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    // --- reading ---

    function test_FaceURIFallsBackOnABrokenTokenURI() public {
        // offset past the end, length past the end, too short, and a revert
        bytes[4] memory raws = [
            abi.encode(uint256(0x1000), uint256(4), bytes32("mask")),
            abi.encode(uint256(0x20), uint256(0x1000), bytes32("mask")),
            abi.encodePacked(uint256(0x20)),
            bytes("")
        ];
        for (uint256 i; i < raws.length; ++i) {
            RawURINFT broken = new RawURINFT(alice, raws[i]);
            vm.prank(alice);
            face.setFace(0, address(broken), 1);
            assertTrue(_live(0));
            assertEq(face.faceURI(0), "identity://0");
        }
        RawURINFT good = new RawURINFT(alice, abi.encode("ipfs://mask"));
        vm.prank(alice);
        face.setFace(0, address(good), 1);
        assertEq(face.faceURI(0), "ipfs://mask");
    }

    function test_AvatarFormat() public {
        // a mask at a known address, with a big token id
        MockNFT at = MockNFT(0x00000000000000000000000000000000000aBCdE);
        vm.etch(address(at), address(masks).code);
        at.mint(alice, type(uint256).max);
        vm.chainId(1);
        vm.prank(alice);
        face.setFace(1, address(at), type(uint256).max);
        assertEq(
            face.avatarOf(1),
            "eip155:1/erc721:0x00000000000000000000000000000000000abcde/115792089237316195423570985008687907853269984665640564039457584007913129639935"
        );
    }

    function test_WearerOfAnUnwornMask() public view {
        (uint256 imdId, bool live) = face.wearerOf(address(masks), 9);
        assertEq(imdId, 0);
        assertFalse(live);
    }

    function test_SupportsInterface() public view {
        assertTrue(face.supportsInterface(type(IIMDFace).interfaceId));
        assertTrue(face.supportsInterface(0x01ffc9a7));
        assertFalse(face.supportsInterface(0xffffffff));
        assertFalse(face.supportsInterface(0x80ac58cd), "not an NFT itself");
    }

    // --- fuzz ---

    function testFuzz_OnlyTheHolderOfBothSetsAFace(address caller, uint256 imdId, uint256 tokenId) public {
        imdId = bound(imdId, 0, 3);
        tokenId = bound(tokenId, 6, 10);
        bool may = identity.ownerOf(imdId) == caller && masks.ownerOf(tokenId) == caller && caller != address(0);
        vm.prank(caller);
        if (!may) vm.expectRevert();
        face.setFace(imdId, address(masks), tokenId);
        if (may) assertTrue(_live(imdId));
    }
}
