// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title LARP names: name.imd, by the IMD6900 frens
/// @notice ENS-style names for identity.md. Each identity can hold one name, `<label>.imd`, unique across all of them.
/// The name belongs to the identity and passes with it on a sale; its fee buys $IMD on POOL4 and burns it. A wallet
/// picks a primary identity (its reverse record), and each holder keeps text records on its identities (x, url,
/// agent, ...), which a new holder starts over.
interface ILARPNames {
    event NameRegistered(
        uint256 indexed imdId, bytes32 indexed label, address indexed holder, uint256 paid, uint256 imdBurned
    );
    event NameReleased(uint256 indexed imdId, bytes32 indexed label);
    event NameMoved(uint256 indexed from, uint256 indexed to, bytes32 indexed label);
    event PrimarySet(address indexed wallet, uint256 indexed imdId);
    event TextSet(uint256 indexed imdId, address indexed holder, string key, string value);

    /// @notice The caller does not own the identity.
    error NotYourIdentity();
    /// @notice A label is 1 to 32 of a-z, 0-9 and '-', not starting or ending with '-'.
    error BadName();
    /// @notice Another identity holds this name.
    error NameTaken();
    /// @notice The ETH sent is not the name's price.
    error WrongPrice();
    /// @notice The identity has no name to release or move.
    error NoName();
    /// @notice The identity receiving a name already has one.
    error HasName();

    /// @notice ".imd"
    function TLD() external view returns (string memory);
    /// @notice The identity.md collection.
    function IDENTITY() external view returns (address);

    /// @notice The price of a label in ETH: 0.069 for 1 to 3 characters, 0.0169 for 4, 0.0069 for 5 or more.
    function priceOf(bytes32 label) external pure returns (uint256);
    /// @notice Identity `imdId` takes the name `label`.imd, paying exactly its price, which buys at least `minImd`
    /// $IMD on POOL4 for IMD's burn (0 for no minimum). Any name it had is released.
    function register(uint256 imdId, bytes32 label, uint256 minImd) external payable;
    /// @notice Identity `imdId` gives up its name; anyone can take it.
    function release(uint256 imdId) external;
    /// @notice Moves identity `from`'s name to identity `to`, both the caller's; `to` must have none.
    function moveName(uint256 from, uint256 to) external;
    /// @notice The caller's primary identity, shown for its wallet (the reverse record). Live while it holds it.
    function setPrimary(uint256 imdId) external;
    /// @notice Sets the caller's text record `key` on identity `imdId` ("" deletes it).
    function setText(uint256 imdId, string calldata key, string calldata value) external;
    /// @notice Spends the ETH sent on $IMD on POOL4 for IMD's burn: anyone can add volume.
    function burn(uint256 minImd) external payable returns (uint256 imd);

    /// @notice Identity `imdId`'s label, or bytes32(0).
    function labelOf(uint256 imdId) external view returns (bytes32);
    /// @notice Identity `imdId`'s name with ".imd", or "".
    function nameOf(uint256 imdId) external view returns (string memory);
    /// @notice The identity holding `label` and the wallet holding that identity now.
    function resolve(bytes32 label) external view returns (bool exists, uint256 imdId, address holder);
    /// @notice `resolve` for "kek" or "kek.imd".
    function resolveName(string calldata name) external view returns (bool exists, uint256 imdId, address holder);
    /// @notice `wallet`'s primary identity and its name; `live` while the wallet still holds it.
    function primaryOf(address wallet) external view returns (uint256 imdId, string memory name, bool live);
    /// @notice The text record `key` of identity `imdId`, as set by the wallet holding it now.
    function text(uint256 imdId, string calldata key) external view returns (string memory);
}
