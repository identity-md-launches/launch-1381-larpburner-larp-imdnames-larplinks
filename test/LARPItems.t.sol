// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LARP} from "../src/LARP.sol";
import {ILARP} from "../src/ILARP.sol";
import {MockNFT} from "./Mocks.sol";
import {Mock1155} from "./Base.sol";

contract LARPItemsTest is Test {
    event FaceCleared(uint256 indexed imdId, address indexed holder);
    event ItemEquipped(
        uint256 indexed imdId,
        uint256 slot,
        address indexed holder,
        address indexed collection,
        uint256 tokenId,
        ILARP.Kind kind
    );
    event ItemUnequipped(uint256 indexed imdId, uint256 slot, address indexed holder);

    ILARP.Kind constant ERC721 = ILARP.Kind.ERC721;
    ILARP.Kind constant ERC1155 = ILARP.Kind.ERC1155;

    MockNFT identity;
    MockNFT swords;
    Mock1155 potions;
    LARP larp;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        identity = new MockNFT("identity://");
        swords = new MockNFT("sword://");
        potions = new Mock1155();
        larp = new LARP(address(identity));
        identity.mint(alice, 0);
        identity.mint(alice, 1);
        identity.mint(bob, 2);
        swords.mint(alice, 1);
        swords.mint(bob, 2);
        potions.mint(alice, 5, 1);
    }

    function _live(uint256 imdId, uint256 slot) internal view returns (bool live) {
        (,,,, live) = larp.itemOf(imdId, slot);
    }

    function test_EquipAnERC721() public {
        vm.expectEmit(address(larp));
        emit ItemEquipped(0, 3, alice, address(swords), 1, ERC721);
        vm.prank(alice);
        larp.equip(0, 3, address(swords), 1, ERC721);
        (address holder, address collection, uint256 tokenId, ILARP.Kind kind, bool live) = larp.itemOf(0, 3);
        assertEq(holder, alice);
        assertEq(collection, address(swords));
        assertEq(tokenId, 1);
        assertEq(uint8(kind), uint8(ERC721));
        assertTrue(live);
        (uint256 imdId, uint256 slot, bool worn) = larp.wearerOf(address(swords), 1);
        assertEq(imdId, 0);
        assertEq(slot, 3);
        assertTrue(worn);
        assertEq(larp.itemURI(0, 3), "sword://1");
    }

    function test_EquipAnERC1155Copy() public {
        vm.prank(alice);
        larp.equip(0, 1, address(potions), 5, ERC1155);
        assertTrue(_live(0, 1));
        assertEq(larp.itemURI(0, 1), "item://{id}", "the uri as the collection gives it");
    }

    function test_OneCopyOnePlacement() public {
        vm.prank(alice);
        larp.equip(0, 1, address(potions), 5, ERC1155);
        vm.prank(alice);
        vm.expectRevert(ILARP.NotYours.selector);
        larp.equip(1, 1, address(potions), 5, ERC1155);

        // a second copy covers a second placement
        potions.mint(alice, 5, 1);
        vm.prank(alice);
        larp.equip(1, 1, address(potions), 5, ERC1155);
        assertTrue(_live(0, 1));
        assertTrue(_live(1, 1));
    }

    function test_SellingACopyDarkensItsPlacementsUntilOneComesOff() public {
        potions.mint(alice, 5, 1);
        vm.startPrank(alice);
        larp.equip(0, 1, address(potions), 5, ERC1155);
        larp.equip(1, 1, address(potions), 5, ERC1155);
        potions.safeTransferFrom(alice, bob, 5, 1, "");
        vm.stopPrank();
        assertFalse(_live(0, 1), "two placed, one held");
        assertFalse(_live(1, 1));

        vm.prank(alice);
        larp.unequip(1, 1);
        assertTrue(_live(0, 1), "one placed, one held");
    }

    function test_ReequippingTheSameCopyInTheSameSlot() public {
        vm.startPrank(alice);
        larp.equip(0, 1, address(potions), 5, ERC1155);
        larp.equip(0, 1, address(potions), 5, ERC1155);
        vm.stopPrank();
        assertTrue(_live(0, 1), "the slot's own copy is counted once");
    }

    function test_SlotsAreOneToEight() public {
        vm.startPrank(alice);
        vm.expectRevert(ILARP.BadSlot.selector);
        larp.equip(0, 0, address(swords), 1, ERC721);
        vm.expectRevert(ILARP.BadSlot.selector);
        larp.equip(0, 9, address(swords), 1, ERC721);
        vm.expectRevert(ILARP.BadSlot.selector);
        larp.unequip(0, 0);
        vm.expectRevert(ILARP.BadSlot.selector);
        larp.itemOf(0, 0);
        larp.equip(0, 8, address(swords), 1, ERC721);
        vm.stopPrank();
        assertEq(larp.SLOTS(), 8);
    }

    function test_AFaceBecomesAnItem() public {
        vm.prank(alice);
        larp.setFace(0, address(swords), 1);

        vm.expectEmit(address(larp));
        emit FaceCleared(0, alice);
        vm.prank(alice);
        larp.equip(0, 2, address(swords), 1, ERC721);

        (address holder,,, bool live) = larp.faceOf(0);
        assertEq(holder, address(0));
        assertFalse(live);
        assertTrue(_live(0, 2));
        (uint256 imdId, uint256 slot,) = larp.wearerOf(address(swords), 1);
        assertEq(imdId, 0);
        assertEq(slot, 2);
    }

    function test_AnItemBecomesAnotherIdentitysFace() public {
        vm.prank(alice);
        larp.equip(0, 4, address(swords), 1, ERC721);
        vm.expectEmit(address(larp));
        emit ItemUnequipped(0, 4, alice);
        vm.prank(alice);
        larp.setFace(1, address(swords), 1);
        assertFalse(_live(0, 4));
        (address holder,,,,) = larp.itemOf(0, 4);
        assertEq(holder, address(0));
        (,,, bool live) = larp.faceOf(1);
        assertTrue(live);
    }

    function test_ReplacingAnItemFreesTheOldOne() public {
        swords.mint(alice, 3);
        vm.startPrank(alice);
        larp.equip(0, 1, address(swords), 1, ERC721);
        larp.equip(0, 1, address(swords), 3, ERC721);
        vm.stopPrank();
        (,, bool worn) = larp.wearerOf(address(swords), 1);
        assertFalse(worn);
        (uint256 imdId, uint256 slot, bool live) = larp.wearerOf(address(swords), 3);
        assertEq(imdId, 0);
        assertEq(slot, 1);
        assertTrue(live);
    }

    function test_SellingTheIdentityDarkensItsItems() public {
        vm.startPrank(alice);
        larp.equip(0, 1, address(swords), 1, ERC721);
        larp.equip(0, 2, address(potions), 5, ERC1155);
        identity.transferFrom(alice, bob, 0);
        vm.stopPrank();
        assertFalse(_live(0, 1));
        assertFalse(_live(0, 2));
        assertEq(larp.itemURI(0, 1), "");
    }

    function test_ThePlacerTakesItsCopyBackAfterSellingTheIdentity() public {
        vm.startPrank(alice);
        larp.equip(0, 2, address(potions), 5, ERC1155);
        identity.transferFrom(alice, bob, 0);
        // the copy is still counted against alice until she takes it off
        vm.expectRevert(ILARP.NotYours.selector);
        larp.equip(1, 2, address(potions), 5, ERC1155);
        larp.unequip(0, 2);
        larp.equip(1, 2, address(potions), 5, ERC1155);
        vm.stopPrank();
        assertTrue(_live(1, 2));
    }

    function test_TheNewOwnerClearsTheOldItems() public {
        vm.startPrank(alice);
        larp.equip(0, 2, address(potions), 5, ERC1155);
        identity.transferFrom(alice, bob, 0);
        vm.stopPrank();
        vm.expectEmit(address(larp));
        emit ItemUnequipped(0, 2, alice);
        vm.prank(bob);
        larp.unequip(0, 2);
        // and alice's copy is free again
        vm.prank(alice);
        larp.equip(1, 2, address(potions), 5, ERC1155);
    }

    function test_StrangersCantTakeItemsOff() public {
        vm.prank(alice);
        larp.equip(0, 1, address(swords), 1, ERC721);
        vm.prank(bob);
        vm.expectRevert(ILARP.NotYourPlacement.selector);
        larp.unequip(0, 1);
    }

    function test_RefusedItems() public {
        vm.startPrank(alice);
        vm.expectRevert(ILARP.NotAMask.selector);
        larp.equip(0, 1, address(identity), 1, ERC721);
        vm.expectRevert(ILARP.NotAMask.selector);
        larp.equip(0, 1, address(identity), 1, ERC1155);
        vm.expectRevert(ILARP.NotYours.selector);
        larp.equip(0, 1, address(swords), 2, ERC721); // bob's
        vm.expectRevert(ILARP.NotYours.selector);
        larp.equip(0, 1, address(swords), 1, ERC1155); // an ERC-721 has no balanceOf(account, id)
        vm.expectRevert(ILARP.NotYours.selector);
        larp.equip(0, 1, address(potions), 6, ERC1155); // no copy
        vm.expectRevert(ILARP.NotYourIdentity.selector);
        larp.equip(2, 1, address(swords), 1, ERC721);
        vm.stopPrank();
    }
}
