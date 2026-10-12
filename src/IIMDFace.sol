// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IMD Face: the face standard of the identity.md ecosystem
/// @notice An identity.md wears one NFT of any ERC-721 collection as its face (its mask). A face is a pointer: the
/// registry holds no tokens and asks for no approvals. A face is live only while the wallet that set it still holds
/// both the identity and the mask, and a mask is worn by one identity at a time.
/// @dev ERC-165 id: type(IIMDFace).interfaceId.
interface IIMDFace {
    /// @notice `holder` put the mask `collection` #`tokenId` on identity `imdId`.
    event FaceSet(uint256 indexed imdId, address indexed holder, address indexed collection, uint256 tokenId);
    /// @notice Identity `imdId` no longer wears the mask `holder` gave it: its owner took it off, or the mask's holder
    /// put it on another identity.
    event FaceCleared(uint256 indexed imdId, address indexed holder);

    /// @notice The caller does not own the identity.
    error NotYourIdentity();
    /// @notice The caller does not own the mask, as the mask's collection answers `ownerOf`.
    error NotYourMask();
    /// @notice An identity.md cannot be another identity's mask.
    error NotAMask();

    /// @notice The identity.md collection whose tokens wear the faces.
    function IDENTITY() external view returns (address);

    /// @notice Puts the mask `collection` #`tokenId` on identity `imdId`, in place of any mask it wore. The caller must
    /// own both. The mask comes off any other identity that wore it.
    function setFace(uint256 imdId, address collection, uint256 tokenId) external;

    /// @notice Takes identity `imdId`'s mask off. Only the identity's owner can; nothing happens if it wears none.
    function clearFace(uint256 imdId) external;

    /// @notice The mask on record for identity `imdId` and who set it. `live` is true only while `holder` owns both the
    /// identity and the mask; a record that is not live shows no face.
    function faceOf(uint256 imdId)
        external
        view
        returns (address holder, address collection, uint256 tokenId, bool live);

    /// @notice The identity that wears the mask `collection` #`tokenId`. `imdId` means something only when `live`.
    function wearerOf(address collection, uint256 tokenId) external view returns (uint256 imdId, bool live);

    /// @notice What to draw for identity `imdId`: its live mask's tokenURI, or the identity's own tokenURI when it
    /// wears no live mask or the mask's collection gives none.
    function faceURI(uint256 imdId) external view returns (string memory);

    /// @notice The live mask as an ENS avatar (ENSIP-12 / CAIP-22): "eip155:<chain>/erc721:<collection>/<tokenId>",
    /// or "" when identity `imdId` wears no live mask.
    function avatarOf(uint256 imdId) external view returns (string memory);
}
