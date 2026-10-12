// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILARPNames} from "./ILARPNames.sol";
import {BuysIMD} from "./BuysIMD.sol";
import {Labels} from "./Labels.sol";
import {SafeReads} from "./SafeReads.sol";

/// @title LARP names: name.imd, by the IMD6900 frens
/// @notice ENS-style names for identity.md: one `<label>.imd` per identity, unique, paid once, kept while the
/// identity keeps it (it passes with the identity on a sale). Every fee buys $IMD on POOL4 and burns it.
/// @dev No owner, no roles, no upgrades. ETH never stays here: each fee is spent in the same call.
contract LARPNames is ILARPNames, BuysIMD {
    using SafeReads for address;

    /// @inheritdoc ILARPNames
    string public constant TLD = ".imd";
    /// @inheritdoc ILARPNames
    address public immutable IDENTITY;

    mapping(bytes32 label => uint256 imdIdPlusOne) internal _holderOf;
    mapping(uint256 imdId => bytes32 label) internal _labelOf;
    mapping(address wallet => uint256 imdIdPlusOne) internal _primary;
    mapping(uint256 imdId => mapping(address holder => mapping(bytes32 keyHash => string))) internal _texts;

    /// @param identity identity.md
    /// @param poolManager Uniswap v4's PoolManager
    /// @param imd $IMD
    /// @param pool4Hook POOL4's hook
    /// @param imdBurn IMD's BurnExecutor
    /// @param fallback_ where a fee goes if POOL4 can't take it (the IMD6900 NFT pot)
    constructor(
        address identity,
        address poolManager,
        address imd,
        address pool4Hook,
        address imdBurn,
        address fallback_
    ) BuysIMD(poolManager, imd, pool4Hook, imdBurn, fallback_) {
        if (identity == address(0)) revert ZeroAddress();
        IDENTITY = identity;
    }

    /// @inheritdoc ILARPNames
    function priceOf(bytes32 label) public pure returns (uint256) {
        uint256 n = Labels.length(label);
        if (n == 0) revert BadName();
        if (n <= 3) return 0.069 ether;
        if (n == 4) return 0.0169 ether;
        return 0.0069 ether;
    }

    /// @inheritdoc ILARPNames
    function register(uint256 imdId, bytes32 label, uint256 minImd) external payable nonReentrant {
        _own(imdId);
        uint256 price = priceOf(label);
        if (msg.value != price) revert WrongPrice();
        if (_holderOf[label] != 0) revert NameTaken();
        bytes32 old = _labelOf[imdId];
        if (old != 0) {
            delete _holderOf[old];
            emit NameReleased(imdId, old);
        }
        _holderOf[label] = imdId + 1;
        _labelOf[imdId] = label;
        uint256 imd = _buyAndBurn(price, minImd);
        emit NameRegistered(imdId, label, msg.sender, price, imd);
    }

    /// @inheritdoc ILARPNames
    function release(uint256 imdId) external {
        _own(imdId);
        bytes32 label = _labelOf[imdId];
        if (label == 0) revert NoName();
        delete _holderOf[label];
        delete _labelOf[imdId];
        emit NameReleased(imdId, label);
    }

    /// @inheritdoc ILARPNames
    function moveName(uint256 from, uint256 to) external {
        _own(from);
        _own(to);
        bytes32 label = _labelOf[from];
        if (label == 0) revert NoName();
        if (_labelOf[to] != 0) revert HasName();
        delete _labelOf[from];
        _labelOf[to] = label;
        _holderOf[label] = to + 1;
        emit NameMoved(from, to, label);
    }

    /// @inheritdoc ILARPNames
    function setPrimary(uint256 imdId) external {
        _own(imdId);
        _primary[msg.sender] = imdId + 1;
        emit PrimarySet(msg.sender, imdId);
    }

    /// @inheritdoc ILARPNames
    function setText(uint256 imdId, string calldata key, string calldata value) external {
        _own(imdId);
        _texts[imdId][msg.sender][keccak256(bytes(key))] = value;
        emit TextSet(imdId, msg.sender, key, value);
    }

    /// @inheritdoc ILARPNames
    function burn(uint256 minImd) external payable nonReentrant returns (uint256 imd) {
        imd = _buyAndBurn(msg.value, minImd);
    }

    // --- reading ---

    /// @inheritdoc ILARPNames
    function labelOf(uint256 imdId) external view returns (bytes32) {
        return _labelOf[imdId];
    }

    /// @inheritdoc ILARPNames
    function nameOf(uint256 imdId) public view returns (string memory) {
        bytes32 label = _labelOf[imdId];
        if (label == 0) return "";
        return string.concat(Labels.toString(label), TLD);
    }

    /// @inheritdoc ILARPNames
    function resolve(bytes32 label) public view returns (bool exists, uint256 imdId, address holder) {
        uint256 at = _holderOf[label];
        if (at == 0) return (false, 0, address(0));
        imdId = at - 1;
        return (true, imdId, IDENTITY.ownerOf(imdId, gasleft()));
    }

    /// @inheritdoc ILARPNames
    function resolveName(string calldata name) external view returns (bool exists, uint256 imdId, address holder) {
        bytes32 label = Labels.fromName(name, TLD);
        if (label == 0) return (false, 0, address(0));
        return resolve(label);
    }

    /// @inheritdoc ILARPNames
    function primaryOf(address wallet) external view returns (uint256 imdId, string memory name, bool live) {
        uint256 at = _primary[wallet];
        if (at == 0) return (0, "", false);
        imdId = at - 1;
        live = IDENTITY.ownerOf(imdId, gasleft()) == wallet;
        if (live) name = nameOf(imdId);
    }

    /// @inheritdoc ILARPNames
    function text(uint256 imdId, string calldata key) external view returns (string memory) {
        return _texts[imdId][IDENTITY.ownerOf(imdId, gasleft())][keccak256(bytes(key))];
    }

    /// @notice ERC-165: ILARPNames and ERC-165 itself.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ILARPNames).interfaceId || interfaceId == 0x01ffc9a7;
    }

    function _own(uint256 imdId) internal view {
        if (IDENTITY.ownerOf(imdId, gasleft()) != msg.sender) revert NotYourIdentity();
    }
}
