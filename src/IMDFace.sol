// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IIMDFace} from "./IIMDFace.sol";

/// @title IMD Face: the face registry of the identity.md ecosystem
/// @notice Every identity.md can wear one NFT of any ERC-721 collection as its face. The holder of both sets it; it
/// stays live while that wallet holds both, so a sale of either takes the face down without anyone acting, and the new
/// owner chooses again. One mask, one identity: putting a mask on takes it off whatever identity wore it.
/// @dev No owner, no roles, no upgrades, no funds. It calls other contracts only with STATICCALL (`ownerOf`,
/// `tokenURI`), so nothing it calls can change state or re-enter. Trust in a collection is the reader's call: the
/// registry proves only what the collection's own `ownerOf` answers, as ENS avatars do.
contract IMDFace is IIMDFace {
    struct Face {
        address holder;
        address collection;
        uint256 tokenId;
    }

    /// @inheritdoc IIMDFace
    address public immutable IDENTITY;

    mapping(uint256 imdId => Face) internal _faces;
    /// @dev The identity wearing each mask, plus one (identity #0 exists). Kept two-way with `_faces`: an entry is
    /// imdId + 1 exactly when `_faces[imdId]` points at that mask.
    mapping(address collection => mapping(uint256 tokenId => uint256)) internal _wearers;

    error ZeroIdentity();

    /// @param identity the identity.md collection (Ethereum: 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D)
    constructor(address identity) {
        if (identity == address(0)) revert ZeroIdentity();
        IDENTITY = identity;
    }

    /// @inheritdoc IIMDFace
    function setFace(uint256 imdId, address collection, uint256 tokenId) external {
        if (_ownerOf(IDENTITY, imdId) != msg.sender) revert NotYourIdentity();
        if (collection == IDENTITY) revert NotAMask();
        if (_ownerOf(collection, tokenId) != msg.sender) revert NotYourMask();

        uint256 wearer = _wearers[collection][tokenId];
        if (wearer != 0 && wearer - 1 != imdId) {
            // the mask comes off the identity that wore it
            uint256 other = wearer - 1;
            emit FaceCleared(other, _faces[other].holder);
            delete _faces[other];
        }
        Face storage face = _faces[imdId];
        if (face.holder != address(0)) delete _wearers[face.collection][face.tokenId];

        face.holder = msg.sender;
        face.collection = collection;
        face.tokenId = tokenId;
        _wearers[collection][tokenId] = imdId + 1;
        emit FaceSet(imdId, msg.sender, collection, tokenId);
    }

    /// @inheritdoc IIMDFace
    function clearFace(uint256 imdId) external {
        if (_ownerOf(IDENTITY, imdId) != msg.sender) revert NotYourIdentity();
        Face storage face = _faces[imdId];
        address holder = face.holder;
        if (holder == address(0)) return;
        delete _wearers[face.collection][face.tokenId];
        delete _faces[imdId];
        emit FaceCleared(imdId, holder);
    }

    /// @inheritdoc IIMDFace
    function faceOf(uint256 imdId)
        public
        view
        returns (address holder, address collection, uint256 tokenId, bool live)
    {
        Face storage face = _faces[imdId];
        holder = face.holder;
        collection = face.collection;
        tokenId = face.tokenId;
        live = holder != address(0) && _ownerOf(IDENTITY, imdId) == holder && _ownerOf(collection, tokenId) == holder;
    }

    /// @inheritdoc IIMDFace
    function wearerOf(address collection, uint256 tokenId) external view returns (uint256 imdId, bool live) {
        uint256 wearer = _wearers[collection][tokenId];
        if (wearer == 0) return (0, false);
        imdId = wearer - 1;
        (,,, live) = faceOf(imdId);
    }

    /// @inheritdoc IIMDFace
    function faceURI(uint256 imdId) external view returns (string memory uri) {
        (, address collection, uint256 tokenId, bool live) = faceOf(imdId);
        if (live) uri = _tokenURI(collection, tokenId);
        if (bytes(uri).length == 0) uri = _tokenURI(IDENTITY, imdId);
    }

    /// @inheritdoc IIMDFace
    function avatarOf(uint256 imdId) external view returns (string memory) {
        (, address collection, uint256 tokenId, bool live) = faceOf(imdId);
        if (!live) return "";
        return string.concat("eip155:", _decimal(block.chainid), "/erc721:", _hex(collection), "/", _decimal(tokenId));
    }

    /// @notice ERC-165: IIMDFace and ERC-165 itself.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IIMDFace).interfaceId || interfaceId == 0x01ffc9a7;
    }

    /// @dev `collection.ownerOf(tokenId)`, or address(0) when the call fails, returns less than a word or returns a
    /// word that is not an address. Copies one word of return data at most.
    function _ownerOf(address collection, uint256 tokenId) internal view returns (address owner) {
        assembly ("memory-safe") {
            mstore(0x00, 0x6352211e) // ownerOf(uint256)
            mstore(0x20, tokenId)
            let ok := staticcall(gas(), collection, 0x1c, 0x24, 0x00, 0x20)
            let word := mload(0x00)
            if and(and(ok, gt(returndatasize(), 0x1f)), iszero(shr(160, word))) { owner := word }
        }
    }

    /// @dev `collection.tokenURI(tokenId)`, or "" when the call fails or its return data is not a well-formed string.
    function _tokenURI(address collection, uint256 tokenId) internal view returns (string memory uri) {
        (bool ok, bytes memory data) = collection.staticcall(abi.encodeWithSelector(0xc87b56dd, tokenId));
        if (!ok || data.length < 0x40) return "";
        uint256 at;
        assembly ("memory-safe") {
            at := mload(add(data, 0x20))
        }
        if (at > data.length - 0x20) return "";
        uint256 length;
        assembly ("memory-safe") {
            length := mload(add(add(data, 0x20), at))
        }
        if (length > data.length - 0x20 - at) return "";
        // the string already sits inside `data`: its length word, then its bytes
        assembly ("memory-safe") {
            uri := add(add(data, 0x20), at)
        }
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
