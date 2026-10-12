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
    /// @notice `holder` made `agent` identity `imdId`'s agent (address(0): no agent).
    event AgentSet(uint256 indexed imdId, address indexed holder, address indexed agent);

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
    /// @notice No such identity.
    error NoSuchIdentity();
    /// @notice The signature's deadline has passed.
    error Expired();
    /// @notice The signature isn't the identity owner's (or was already used).
    error BadSignature();
    /// @notice Only the identity's agent can resign.
    error NotTheAgent();

    // --- agents ---
    // An identity's owner can name one agent: a key its agent (an IMD worker, a bot, a hot wallet) holds, that acts
    // for the identity everywhere in LARP: faces and items (with the owner's NFTs), names' links and text records,
    // frens and crews. An agent can't move any token or ETH of the owner's. It is the owner's, so it lapses the moment
    // the identity changes hands; the owner can replace or remove it any time, and the agent can resign.

    /// @notice Identity `imdId`'s owner makes `agent` its agent (address(0) removes it). Voids the owner's unused
    /// agent signatures.
    function setAgent(uint256 imdId, address agent) external;
    /// @notice Sets identity `imdId`'s agent with its owner's EIP-712 signature (an EOA's, or an ERC-1271 contract
    /// wallet's) of SetAgent(imdId, agent, holder, nonce, deadline): the owner signs, anyone (the agent) sends.
    function setAgentBySig(uint256 imdId, address agent, uint256 deadline, bytes calldata signature) external;
    /// @notice The agent of identity `imdId` steps down.
    function resignAgent(uint256 imdId) external;
    /// @notice Identity `imdId`'s agent, live while the owner who named it still holds the identity.
    function agentOf(uint256 imdId) external view returns (address agent, bool live);
    /// @notice The identity `agent` was last made the agent of; `live` while it still is.
    function identityOfAgent(address agent) external view returns (uint256 imdId, bool live);
    /// @notice Whether `who` controls identity `imdId` (its owner, or its live agent), and its owner.
    function canAct(uint256 imdId, address who) external view returns (bool ok, address holder);
    /// @notice The next agent-signature nonce of `holder`.
    function nonces(address holder) external view returns (uint256);
    /// @notice EIP-712 domain separator (name "LARP", version "1").
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    /// @notice The identity.md collection whose tokens larp.
    function IDENTITY() external view returns (address);
    /// @notice The number of item slots (numbered 1 to SLOTS).
    function SLOTS() external view returns (uint256);

    /// @notice Puts the ERC-721 `collection` #`tokenId` on identity `imdId` as its face, in place of any face it had.
    /// The caller must control the identity (its owner or agent), and the owner must own the token. The token comes off
    /// wherever else it was placed.
    function setFace(uint256 imdId, address collection, uint256 tokenId) external;
    /// @notice Takes identity `imdId`'s face off. The identity's owner or agent, or the face's placer, can; nothing
    /// happens if there is none.
    function clearFace(uint256 imdId) external;
    /// @notice Equips `collection` #`tokenId` in identity `imdId`'s item slot `slot`, in place of what was there. The
    /// caller must control the identity; its owner must own the token (ERC-721) or a copy not already placed (ERC-1155).
    function equip(uint256 imdId, uint256 slot, address collection, uint256 tokenId, Kind kind) external;
    /// @notice Takes the item in identity `imdId`'s slot `slot` off. The identity's owner or agent, or the item's
    /// placer, can.
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
