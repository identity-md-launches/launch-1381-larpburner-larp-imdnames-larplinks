// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title LARP names: name.imd, by the IMD6900 frens
/// @notice ENS-style names as ERC-721 NFTs, traded like any NFT. Anyone can register a free name for its price; the
/// owner links it to an identity.md it holds, and the identity shows it while the owner holds both. Every fee buys
/// $IMD and burns it: the registration, a 6.9% royalty on secondary sales (ERC-2981, paid to the burner by markets
/// that honour royalties), and the toll every new owner pays once to link the name, which no market can skip.
/// @dev A name's token id is its label (a bytes32, left-aligned) as a uint256.
interface ILARPNames {
    event NameRegistered(uint256 indexed tokenId, bytes32 indexed label, address indexed to, uint256 paid);
    event NameLinked(uint256 indexed tokenId, uint256 indexed imdId, address indexed holder, uint256 toll);
    event NameUnlinked(uint256 indexed tokenId, uint256 indexed imdId);
    event PrimarySet(address indexed wallet, uint256 indexed imdId);
    event TextSet(uint256 indexed imdId, address indexed holder, string key, string value);
    event RendererSet(address renderer);
    event ArtistSet(address artist);
    event RendererLocked();

    /// @notice The caller controls no such identity (its owner or agent).
    error NotYourIdentity();
    /// @notice A label is 1 to 32 of a-z, 0-9 and '-', not starting or ending with '-'.
    error BadName();
    /// @notice The ETH sent is not the price (or toll) due.
    error WrongPrice();
    /// @notice No such name.
    error NoSuchName();
    /// @notice The identity's owner doesn't own this name.
    error NotYourName();
    /// @notice Only the identity's controller or the name's owner can unlink.
    error NotYours();
    /// @notice Only the artist can change the renderer.
    error NotArtist();
    /// @notice The renderer is locked for good.
    error Locked();

    /// @notice ".imd"
    function TLD() external view returns (string memory);
    /// @notice The royalty on secondary sales, in basis points (690 = 6.9%), paid to the burner.
    function ROYALTY_BPS() external view returns (uint256);
    /// @notice identity.md.
    function IDENTITY() external view returns (address);
    /// @notice The burner every fee goes to.
    function BURNER() external view returns (address);

    /// @notice A label's price in ETH: 0.069 for 1 to 3 characters, 0.0169 for 4, 0.0069 for 5 or more.
    function priceOf(bytes32 label) external pure returns (uint256);
    /// @notice What linking name `tokenId` costs its owner now: 0 if the owner registered it or already paid, else
    /// the name's price.
    function tollOf(uint256 tokenId) external view returns (uint256);
    /// @notice Registers `label`.imd as an NFT to `to`, paying exactly its price, which buys at least `minImd` $IMD to
    /// burn (0: no minimum; the burn may also wait in the burner). Anyone can register any free name.
    function register(bytes32 label, address to, uint256 minImd) external payable returns (uint256 tokenId);
    /// @notice Links name `tokenId` to identity `imdId`: the caller controls the identity, whose owner owns the name.
    /// A new owner's first link pays the toll (tollOf), burned like a fee. The identity's old name and the name's old
    /// identity are unlinked.
    function link(uint256 tokenId, uint256 imdId, uint256 minImd) external payable;
    /// @notice Unlinks identity `imdId`'s name: its controller or the name's owner can.
    function unlink(uint256 imdId) external;
    /// @notice The caller's primary identity (the reverse record of its wallet), live while it holds it.
    function setPrimary(uint256 imdId) external;
    /// @notice Sets the text record `key` of identity `imdId` (x, url, agent, ...) for its owner; its owner or agent
    /// can. A new owner starts with none.
    function setText(uint256 imdId, string calldata key, string calldata value) external;

    /// @notice The label of name `tokenId` and the name with ".imd".
    function nameOfToken(uint256 tokenId) external pure returns (string memory);
    /// @notice Identity `imdId`'s live name ("kek.imd"), or "".
    function nameOf(uint256 imdId) external view returns (string memory);
    /// @notice The identity name `tokenId` is linked to, live while its owner holds both.
    function identityOf(uint256 tokenId) external view returns (uint256 imdId, bool live);
    /// @notice `label`: whether it is registered, its owner, and the identity it shows on (`linked`).
    function resolve(bytes32 label) external view returns (bool exists, address owner, uint256 imdId, bool linked);
    /// @notice `resolve` for "kek" or "kek.imd".
    function resolveName(string calldata full)
        external
        view
        returns (bool exists, address owner, uint256 imdId, bool linked);
    /// @notice `wallet`'s primary identity and its name; `live` while the wallet holds it.
    function primaryOf(address wallet) external view returns (uint256 imdId, string memory full, bool live);
    /// @notice Identity `imdId`'s text record `key`, as its owner now set it.
    function text(uint256 imdId, string calldata key) external view returns (string memory);

    /// @notice Who may change the renderer (until it is locked).
    function artist() external view returns (address);
    /// @notice The renderer drawing the names (address(0): the built-in one).
    function renderer() external view returns (address);
    /// @notice Whether the renderer is locked for good.
    function rendererLocked() external view returns (bool);
    /// @notice The artist points tokenURI at a new renderer. The only thing in LARP anyone can change, and only the
    /// art: a renderer that fails or answers nothing falls back to the built-in one.
    function setRenderer(address renderer_) external;
    /// @notice The artist hands the role on (address(0) renounces it).
    function setArtist(address artist_) external;
    /// @notice The artist locks the renderer forever.
    function lockRenderer() external;
}

/// @notice A name renderer: draws name `tokenId` (`name` = "kek.imd"), linked to identity `imdIdPlusOne - 1` (0: none).
interface ILARPNameRenderer {
    function render(uint256 tokenId, string calldata full, uint256 imdIdPlusOne) external view returns (string memory);
}
