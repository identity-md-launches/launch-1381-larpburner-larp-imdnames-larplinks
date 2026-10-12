// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LARP} from "../src/LARP.sol";
import {ILARP} from "../src/ILARP.sol";
import {MockNFT} from "./Mocks.sol";
import {Mock1155} from "./Base.sol";

/// @dev Three wallets trade four identities, six ERC-721s (two collections) and ERC-1155 copies, and put them on and
/// take them off every slot at random.
contract LarpHandler is Test {
    LARP public larp;
    MockNFT public identity;
    MockNFT[2] public masks;
    Mock1155 public potions;
    address[3] public wallets = [address(0xA11CE), address(0xB0B), address(0xCA401)];

    constructor(LARP larp_, MockNFT identity_, MockNFT[2] memory masks_, Mock1155 potions_) {
        larp = larp_;
        identity = identity_;
        masks = masks_;
        potions = potions_;
    }

    function setFace(uint256 who, uint256 imdId, uint256 which, uint256 tokenId) external {
        vm.prank(wallets[who % 3]);
        try larp.setFace(imdId % 4, address(masks[which % 2]), tokenId % 3) {} catch {}
    }

    function equip721(uint256 who, uint256 imdId, uint256 slot, uint256 which, uint256 tokenId) external {
        vm.prank(wallets[who % 3]);
        try larp.equip(imdId % 4, 1 + slot % 8, address(masks[which % 2]), tokenId % 3, ILARP.Kind.ERC721) {} catch {}
    }

    function equip1155(uint256 who, uint256 imdId, uint256 slot, uint256 id) external {
        vm.prank(wallets[who % 3]);
        try larp.equip(imdId % 4, 1 + slot % 8, address(potions), id % 2, ILARP.Kind.ERC1155) {} catch {}
    }

    function takeOff(uint256 who, uint256 imdId, uint256 slot) external {
        vm.prank(wallets[who % 3]);
        slot %= 9;
        if (slot == 0) {
            try larp.clearFace(imdId % 4) {} catch {}
        } else {
            try larp.unequip(imdId % 4, slot) {} catch {}
        }
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

    function giveCopy(uint256 from, uint256 to, uint256 id) external {
        address f = wallets[from % 3];
        id %= 2;
        if (potions.balanceOf(f, id) == 0) return;
        vm.prank(f);
        potions.safeTransferFrom(f, wallets[to % 3], id, 1, "");
    }
}

contract LARPInvariantTest is Test {
    LARP larp;
    MockNFT identity;
    MockNFT[2] masks;
    Mock1155 potions;
    LarpHandler handler;

    function setUp() public {
        identity = new MockNFT("identity://");
        masks = [new MockNFT("a://"), new MockNFT("b://")];
        potions = new Mock1155();
        larp = new LARP(address(identity));
        handler = new LarpHandler(larp, identity, masks, potions);
        for (uint256 i; i < 4; ++i) {
            identity.mint(handler.wallets(i % 3), i);
        }
        for (uint256 i; i < 3; ++i) {
            masks[0].mint(handler.wallets(i), i);
            masks[1].mint(handler.wallets((i + 1) % 3), i);
            potions.mint(handler.wallets(i), i % 2, 2);
        }
        targetContract(address(handler));
    }

    function _spot(uint256 imdId, uint256 slot)
        internal
        view
        returns (address holder, address collection, uint256 tokenId, ILARP.Kind kind, bool live)
    {
        if (slot == 0) {
            (holder, collection, tokenId, live) = larp.faceOf(imdId);
            kind = ILARP.Kind.ERC721;
        } else {
            (holder, collection, tokenId, kind, live) = larp.itemOf(imdId, slot);
        }
    }

    /// @dev How many spots hold a copy of potion `id` placed by `holder`.
    function _placedCopies(address holder, uint256 id) internal view returns (uint256 n) {
        for (uint256 imdId; imdId < 4; ++imdId) {
            for (uint256 slot = 1; slot <= 8; ++slot) {
                (address h, address c, uint256 t, ILARP.Kind k,) = larp.itemOf(imdId, slot);
                if (h == holder && c == address(potions) && t == id && k == ILARP.Kind.ERC1155) ++n;
            }
        }
    }

    /// @dev Live is exactly: the placer owns the identity, and owns the ERC-721 or holds at least as many copies as it
    /// has placed. An ERC-721's spot is named by wearerOf.
    function invariant_LiveMeansThePlacerHoldsIt() public view {
        for (uint256 imdId; imdId < 4; ++imdId) {
            for (uint256 slot; slot <= 8; ++slot) {
                (address holder, address collection, uint256 tokenId, ILARP.Kind kind, bool live) = _spot(imdId, slot);
                if (holder == address(0)) {
                    assertFalse(live);
                    continue;
                }
                bool holds = kind == ILARP.Kind.ERC721
                    ? MockNFT(collection).ownerOf(tokenId) == holder
                    : potions.balanceOf(holder, tokenId) >= _placedCopies(holder, tokenId);
                assertEq(live, identity.ownerOf(imdId) == holder && holds, "live iff the placer holds both");
                if (kind == ILARP.Kind.ERC721) {
                    (uint256 i, uint256 s, bool worn) = larp.wearerOf(collection, tokenId);
                    assertEq(i, imdId, "wearerOf names the identity");
                    assertEq(s, slot, "and the slot");
                    assertEq(worn, live);
                }
            }
        }
    }

    /// @dev An ERC-721 sits in at most one spot, and wearerOf points at it.
    function invariant_OneTokenOneSpot() public view {
        for (uint256 m; m < 2; ++m) {
            for (uint256 tokenId; tokenId < 3; ++tokenId) {
                (uint256 wearer, uint256 wearerSlot, bool worn) = larp.wearerOf(address(masks[m]), tokenId);
                uint256 spots;
                for (uint256 imdId; imdId < 4; ++imdId) {
                    for (uint256 slot; slot <= 8; ++slot) {
                        (address h, address c, uint256 t, ILARP.Kind k,) = _spot(imdId, slot);
                        if (h != address(0) && c == address(masks[m]) && t == tokenId && k == ILARP.Kind.ERC721) {
                            ++spots;
                            assertEq(wearer, imdId);
                            assertEq(wearerSlot, slot);
                        }
                    }
                }
                assertLe(spots, 1, "one spot per token");
                if (spots == 0) assertFalse(worn, "an unplaced token has no live spot");
            }
        }
    }

    /// @dev A holder never has more copies live than it holds.
    function invariant_NoMoreLiveCopiesThanHeld() public view {
        for (uint256 w; w < 3; ++w) {
            address holder = handler.wallets(w);
            for (uint256 id; id < 2; ++id) {
                uint256 live;
                for (uint256 imdId; imdId < 4; ++imdId) {
                    for (uint256 slot = 1; slot <= 8; ++slot) {
                        (address h, address c, uint256 t, ILARP.Kind k, bool l) = larp.itemOf(imdId, slot);
                        if (l && h == holder && c == address(potions) && t == id && k == ILARP.Kind.ERC1155) ++live;
                    }
                }
                assertLe(live, potions.balanceOf(holder, id));
            }
        }
    }
}
