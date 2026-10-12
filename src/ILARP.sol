// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title LARP: Linked Avatar Registry Protocol, by the IMD6900 frens
/// @notice An identity.md larps as NFTs its holder owns: one ERC-721 as its face, and up to eight items (ERC-721 or
/// ERC-1155) in numbered slots. A placement is a pointer: the registry holds no tokens and asks for no approvals. It
/// shows only while the wallet that made it still holds the identity and the NFT, and an NFT shows on one identity at
/// a time (an ERC-1155 copy counts as one).
/// @dev Slot 0 is the face, slots 1 to SLOTS are items. ERC-165 id: type(ILARP).interfaceId.
interface ILARP {
    /// @notice An ERC-721 token (ownerOf) or an ERC-1155 copy (balanceOf).
    enum Kind {
        ERC721,
        ERC1155
    }

    /// @notice `holder` put the face `collection` #`tokenId` on identity `imdId`.
    event FaceSet(uint256 indexed imdId, address indexed holder, address indexed collection, uint256 tokenId);
    /// @notice Identity `imdId`'s face, placed by `holder`, came off.
    event FaceCleared(uint256 indexed imdId, address indexed holder);
    /// @notice `holder` equipped `collection` #`tokenId` in identity `imdId`'s item slot `slot`.
    event ItemEquipped(
        uint256 indexed imdId,
        uint256 slot,
        address indexed holder,
        address indexed collection,
        uint256 tokenId,
        Kind kind
    );
    /// @notice The item `holder` placed in identity `imdId`'s slot `slot` came off.
    event ItemUnequipped(uint256 indexed imdId, uint256 slot, address indexed holder);

    /// @notice The caller does not own the identity.
    error NotYourIdentity();
    /// @notice The caller does not hold the NFT, or holds no copy of it not already placed.
    error NotYours();
    /// @notice identity.md tokens wear; they are never worn.
    error NotAMask();
    /// @notice Items go in slots 1 to SLOTS.
    error BadSlot();
    /// @notice Only the identity's owner or the wallet that placed the NFT can take it off.
    error NotYourPlacement();

    /// @notice The identity.md collection whose tokens larp.
    function IDENTITY() external view returns (address);
    /// @notice The number of item slots (numbered 1 to SLOTS).
    function SLOTS() external view returns (uint256);

    /// @notice Puts the ERC-721 `collection` #`tokenId` on identity `imdId` as its face, in place of any face it had.
    /// The caller must own both. The token comes off wherever else it was placed.
    function setFace(uint256 imdId, address collection, uint256 tokenId) external;
    /// @notice Takes identity `imdId`'s face off. The identity's owner or the face's placer can; nothing happens if
    /// there is none.
    function clearFace(uint256 imdId) external;
    /// @notice Equips `collection` #`tokenId` in identity `imdId`'s item slot `slot`, in place of what was there. The
    /// caller must own the identity and the token (ERC-721), or a copy not already placed (ERC-1155).
    function equip(uint256 imdId, uint256 slot, address collection, uint256 tokenId, Kind kind) external;
    /// @notice Takes the item in identity `imdId`'s slot `slot` off. The identity's owner or the item's placer can.
    function unequip(uint256 imdId, uint256 slot) external;

    /// @notice Identity `imdId`'s face on record. Show it only when `live`.
    function faceOf(uint256 imdId)
        external
        view
        returns (address holder, address collection, uint256 tokenId, bool live);
    /// @notice Identity `imdId`'s item in slot `slot` on record. Show it only when `live`.
    function itemOf(uint256 imdId, uint256 slot)
        external
        view
        returns (address holder, address collection, uint256 tokenId, Kind kind, bool live);
    /// @notice Where the ERC-721 `collection` #`tokenId` is placed: identity `imdId`, slot `slot` (0 = the face).
    /// Meaningful only when `live`.
    function wearerOf(address collection, uint256 tokenId)
        external
        view
        returns (uint256 imdId, uint256 slot, bool live);
    /// @notice What to draw for identity `imdId`: its live face's tokenURI, or the identity's own tokenURI.
    function faceURI(uint256 imdId) external view returns (string memory);
    /// @notice The live face as an ENS avatar (ENSIP-12): "eip155:<chain>/erc721:<collection>/<tokenId>", or "".
    function avatarOf(uint256 imdId) external view returns (string memory);
    /// @notice The live item's metadata URI (ERC-721 tokenURI, ERC-1155 uri, unsubstituted), or "".
    function itemURI(uint256 imdId, uint256 slot) external view returns (string memory);
}
