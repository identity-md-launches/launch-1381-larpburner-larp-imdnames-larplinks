// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILARP} from "./ILARP.sol";
import {SafeReads} from "./SafeReads.sol";

/// @title LARP: Linked Avatar Registry Protocol, by the IMD6900 frens
/// @notice Every identity.md can larp as NFTs its holder owns: a face (an ERC-721) and eight items (ERC-721 or
/// ERC-1155). A placement shows while the wallet that made it holds both the identity and the NFT, so a sale of
/// either takes it down with nobody acting, and a new owner chooses again. An ERC-721 shows on one identity at a time;
/// a wallet's ERC-1155 copies show on as many slots as it holds copies.
/// @dev No owner, no roles, no upgrades, no funds. It calls other contracts by STATICCALL only, so nothing it calls can
/// change state or re-enter. Trust in a collection is the reader's call: the registry proves only what the
/// collection's own `ownerOf` / `balanceOf` answers, as ENS avatars do.
contract LARP is ILARP {
    using SafeReads for address;

    struct Spot {
        address holder;
        Kind kind;
        address collection;
        uint256 tokenId;
    }

    /// @inheritdoc ILARP
    address public immutable IDENTITY;
    /// @inheritdoc ILARP
    uint256 public constant SLOTS = 8;

    /// @dev identity => slot (0 = the face, 1..SLOTS = items) => what is placed there
    mapping(uint256 imdId => mapping(uint256 slot => Spot)) internal _spots;
    /// @dev Where each placed ERC-721 is: 1 + imdId * 16 + slot. Two-way with `_spots`: an entry names a spot exactly
    /// when that spot holds this ERC-721.
    mapping(address collection => mapping(uint256 tokenId => uint256)) internal _placed;
    /// @dev How many spots hold a copy of each ERC-1155 placed by each holder.
    mapping(address holder => mapping(address collection => mapping(uint256 id => uint256))) internal _copies;

    error ZeroIdentity();

    /// @param identity the identity.md collection (Ethereum: 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D)
    constructor(address identity) {
        if (identity == address(0)) revert ZeroIdentity();
        IDENTITY = identity;
    }

    // --- placing ---

    /// @inheritdoc ILARP
    function setFace(uint256 imdId, address collection, uint256 tokenId) external {
        _place(imdId, 0, collection, tokenId, Kind.ERC721);
    }

    /// @inheritdoc ILARP
    function equip(uint256 imdId, uint256 slot, address collection, uint256 tokenId, Kind kind) external {
        if (slot == 0 || slot > SLOTS) revert BadSlot();
        _place(imdId, slot, collection, tokenId, kind);
    }

    /// @inheritdoc ILARP
    function clearFace(uint256 imdId) external {
        _takeOff(imdId, 0);
    }

    /// @inheritdoc ILARP
    function unequip(uint256 imdId, uint256 slot) external {
        if (slot == 0 || slot > SLOTS) revert BadSlot();
        _takeOff(imdId, slot);
    }

    function _place(uint256 imdId, uint256 slot, address collection, uint256 tokenId, Kind kind) internal {
        if (IDENTITY.ownerOf(imdId, gasleft()) != msg.sender) revert NotYourIdentity();
        if (collection == IDENTITY) revert NotAMask();

        // whatever was in this slot comes off first (no event: the new placement replaces it)
        _remove(imdId, slot, false);
        if (kind == Kind.ERC721) {
            if (collection.ownerOf(tokenId, gasleft()) != msg.sender) revert NotYours();
            uint256 at = _placed[collection][tokenId];
            // the token comes off wherever else it was
            if (at != 0) _remove((at - 1) >> 4, (at - 1) & 15, true);
            _placed[collection][tokenId] = 1 + imdId * 16 + slot;
        } else {
            uint256 used = _copies[msg.sender][collection][tokenId] + 1;
            if (collection.balanceOf(msg.sender, tokenId, gasleft()) < used) revert NotYours();
            _copies[msg.sender][collection][tokenId] = used;
        }
        _spots[imdId][slot] = Spot(msg.sender, kind, collection, tokenId);
        if (slot == 0) emit FaceSet(imdId, msg.sender, collection, tokenId);
        else emit ItemEquipped(imdId, slot, msg.sender, collection, tokenId, kind);
    }

    function _takeOff(uint256 imdId, uint256 slot) internal {
        address holder = _spots[imdId][slot].holder;
        if (holder == address(0)) return;
        if (msg.sender != holder && IDENTITY.ownerOf(imdId, gasleft()) != msg.sender) revert NotYourPlacement();
        _remove(imdId, slot, true);
    }

    /// @dev Empties a spot and keeps `_placed` and `_copies` in step with it.
    function _remove(uint256 imdId, uint256 slot, bool announce) internal {
        Spot storage spot = _spots[imdId][slot];
        address holder = spot.holder;
        if (holder == address(0)) return;
        if (spot.kind == Kind.ERC721) delete _placed[spot.collection][spot.tokenId];
        else --_copies[holder][spot.collection][spot.tokenId];
        delete _spots[imdId][slot];
        if (!announce) return;
        if (slot == 0) emit FaceCleared(imdId, holder);
        else emit ItemUnequipped(imdId, slot, holder);
    }

    // --- reading ---

    /// @inheritdoc ILARP
    function faceOf(uint256 imdId)
        public
        view
        returns (address holder, address collection, uint256 tokenId, bool live)
    {
        Spot storage spot = _spots[imdId][0];
        (holder, collection, tokenId) = (spot.holder, spot.collection, spot.tokenId);
        live = _live(imdId, spot);
    }

    /// @inheritdoc ILARP
    function itemOf(uint256 imdId, uint256 slot)
        public
        view
        returns (address holder, address collection, uint256 tokenId, Kind kind, bool live)
    {
        if (slot == 0 || slot > SLOTS) revert BadSlot();
        Spot storage spot = _spots[imdId][slot];
        (holder, collection, tokenId, kind) = (spot.holder, spot.collection, spot.tokenId, spot.kind);
        live = _live(imdId, spot);
    }

    /// @inheritdoc ILARP
    function wearerOf(address collection, uint256 tokenId)
        external
        view
        returns (uint256 imdId, uint256 slot, bool live)
    {
        uint256 at = _placed[collection][tokenId];
        if (at == 0) return (0, 0, false);
        (imdId, slot) = ((at - 1) >> 4, (at - 1) & 15);
        live = _live(imdId, _spots[imdId][slot]);
    }

    /// @inheritdoc ILARP
    function faceURI(uint256 imdId) external view returns (string memory uri) {
        (, address collection, uint256 tokenId, bool live) = faceOf(imdId);
        if (live) uri = collection.text(0xc87b56dd, tokenId);
        if (bytes(uri).length == 0) uri = IDENTITY.text(0xc87b56dd, imdId);
    }

    /// @inheritdoc ILARP
    function avatarOf(uint256 imdId) external view returns (string memory) {
        (, address collection, uint256 tokenId, bool live) = faceOf(imdId);
        if (!live) return "";
        return string.concat("eip155:", _decimal(block.chainid), "/erc721:", _hex(collection), "/", _decimal(tokenId));
    }

    /// @inheritdoc ILARP
    function itemURI(uint256 imdId, uint256 slot) external view returns (string memory) {
        (, address collection, uint256 tokenId, Kind kind, bool live) = itemOf(imdId, slot);
        if (!live) return "";
        return collection.text(kind == Kind.ERC721 ? bytes4(0xc87b56dd) : bytes4(0x0e89341c), tokenId);
    }

    /// @notice ERC-165: ILARP and ERC-165 itself.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ILARP).interfaceId || interfaceId == 0x01ffc9a7;
    }

    /// @dev Live: its placer still owns the identity and still holds the NFT (for an ERC-1155, as many copies as it
    /// has placed).
    function _live(uint256 imdId, Spot storage spot) internal view returns (bool) {
        address holder = spot.holder;
        if (holder == address(0) || IDENTITY.ownerOf(imdId, gasleft()) != holder) return false;
        if (spot.kind == Kind.ERC721) return spot.collection.ownerOf(spot.tokenId, gasleft()) == holder;
        return
            spot.collection.balanceOf(holder, spot.tokenId, gasleft()) >= _copies[holder][spot.collection][spot.tokenId];
    }

    function _decimal(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 digits;
        for (uint256 v = value; v != 0; v /= 10) {
            ++digits;
        }
        bytes memory out = new bytes(digits);
        for (; value != 0; value /= 10) {
            out[--digits] = bytes1(uint8(48 + value % 10));
        }
        return string(out);
    }

    function _hex(address account) internal pure returns (string memory) {
        bytes memory out = new bytes(42);
        out[0] = "0";
        out[1] = "x";
        uint256 v = uint160(account);
        for (uint256 i = 41; i > 1; --i) {
            out[i] = bytes16("0123456789abcdef")[v & 15];
            v >>= 4;
        }
        return string(out);
    }
}
