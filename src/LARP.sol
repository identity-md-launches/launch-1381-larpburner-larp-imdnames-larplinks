// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILARP} from "./ILARP.sol";
import {SafeReads} from "./SafeReads.sol";

/// @title LARP: Linked Avatar Registry Protocol, by the IMD6900 frens
/// @notice Every identity.md can larp as NFTs its holder owns: a face (an ERC-721) and eight items (ERC-721 or
/// ERC-1155). A placement shows while the wallet that made it holds both the identity and the NFT, so a sale of
/// either takes it down with nobody acting, and a new owner chooses again. An ERC-721 shows on one identity at a time;
/// a wallet's ERC-1155 copies show on as many slots as it holds copies.
/// Each identity's owner can name an agent, a key its IMD agent holds, that acts for the identity across LARP without
/// the owner's wallet sending anything: one EIP-712 signature (or one call) connects it, a sale disconnects it.
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

    struct Agent {
        address holder;
        address agent;
    }

    bytes32 internal constant SET_AGENT_TYPEHASH =
        keccak256("SetAgent(uint256 imdId,address agent,address holder,uint256 nonce,uint256 deadline)");
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    /// @dev secp256k1n / 2: higher s values are the malleable twin of a signature
    uint256 internal constant HALF_N = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

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

    /// @dev identity => its agent and the owner who named it
    mapping(uint256 imdId => Agent) internal _agents;
    /// @dev agent => the identity it was last named the agent of, plus one
    mapping(address agent => uint256) internal _agentIdentity;
    /// @inheritdoc ILARP
    mapping(address holder => uint256) public nonces;

    error ZeroIdentity();

    /// @param identity the identity.md collection (Ethereum: 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D)
    constructor(address identity) {
        if (identity == address(0)) revert ZeroIdentity();
        IDENTITY = identity;
    }

    // --- agents ---

    /// @inheritdoc ILARP
    function setAgent(uint256 imdId, address agent) external {
        if (IDENTITY.ownerOf(imdId, gasleft()) != msg.sender) revert NotYourIdentity();
        ++nonces[msg.sender];
        _setAgent(imdId, msg.sender, agent);
    }

    /// @inheritdoc ILARP
    function setAgentBySig(uint256 imdId, address agent, uint256 deadline, bytes calldata signature) external {
        if (block.timestamp > deadline) revert Expired();
        address holder = IDENTITY.ownerOf(imdId, gasleft());
        if (holder == address(0)) revert NoSuchIdentity();
        uint256 nonce = nonces[holder]++;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                keccak256(abi.encode(SET_AGENT_TYPEHASH, imdId, agent, holder, nonce, deadline))
            )
        );
        if (!_signedBy(holder, digest, signature)) revert BadSignature();
        _setAgent(imdId, holder, agent);
    }

    /// @inheritdoc ILARP
    function resignAgent(uint256 imdId) external {
        Agent storage a = _agents[imdId];
        if (a.agent != msg.sender || msg.sender == address(0)) revert NotTheAgent();
        emit AgentSet(imdId, a.holder, address(0));
        delete _agents[imdId];
    }

    /// @inheritdoc ILARP
    function agentOf(uint256 imdId) public view returns (address agent, bool live) {
        Agent storage a = _agents[imdId];
        agent = a.agent;
        live = agent != address(0) && IDENTITY.ownerOf(imdId, gasleft()) == a.holder;
    }

    /// @inheritdoc ILARP
    function identityOfAgent(address agent) external view returns (uint256 imdId, bool live) {
        uint256 at = _agentIdentity[agent];
        if (at == 0) return (0, false);
        imdId = at - 1;
        (address current, bool l) = agentOf(imdId);
        live = l && current == agent;
    }

    /// @inheritdoc ILARP
    function canAct(uint256 imdId, address who) public view returns (bool ok, address holder) {
        holder = IDENTITY.ownerOf(imdId, gasleft());
        if (holder == address(0) || who == address(0)) return (false, holder);
        if (who == holder) return (true, holder);
        Agent storage a = _agents[imdId];
        ok = a.agent == who && a.holder == holder;
    }

    /// @inheritdoc ILARP
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("LARP"), keccak256("1"), block.chainid, address(this)));
    }

    function _setAgent(uint256 imdId, address holder, address agent) internal {
        if (agent == address(0)) {
            delete _agents[imdId];
        } else {
            _agents[imdId] = Agent(holder, agent);
            _agentIdentity[agent] = imdId + 1;
        }
        emit AgentSet(imdId, holder, agent);
    }

    /// @dev An EOA's 65-byte signature (low s, v 27 or 28), or a contract wallet's ERC-1271 approval.
    function _signedBy(address signer, bytes32 digest, bytes calldata signature) internal view returns (bool) {
        if (signature.length == 65) {
            bytes32 r;
            bytes32 s;
            uint8 v;
            assembly {
                r := calldataload(signature.offset)
                s := calldataload(add(signature.offset, 0x20))
                v := byte(0, calldataload(add(signature.offset, 0x40)))
            }
            if (uint256(s) <= HALF_N && (v == 27 || v == 28)) {
                address recovered = ecrecover(digest, v, r, s);
                if (recovered != address(0) && recovered == signer) return true;
            }
        }
        if (signer.code.length == 0) return false;
        (bool ok, bytes memory answer) = signer.staticcall(abi.encodeWithSelector(0x1626ba7e, digest, signature));
        return ok && answer.length >= 32 && bytes4(abi.decode(answer, (bytes32))) == 0x1626ba7e;
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

    /// @dev The caller is the identity's owner or agent; the placement is the owner's, with the owner's NFT.
    function _place(uint256 imdId, uint256 slot, address collection, uint256 tokenId, Kind kind) internal {
        (bool ok, address holder) = canAct(imdId, msg.sender);
        if (!ok) revert NotYourIdentity();
        if (collection == IDENTITY) revert NotAMask();

        // whatever was in this slot comes off first (no event: the new placement replaces it)
        _remove(imdId, slot, false);
        if (kind == Kind.ERC721) {
            if (collection.ownerOf(tokenId, gasleft()) != holder) revert NotYours();
            uint256 at = _placed[collection][tokenId];
            // the token comes off wherever else it was
            if (at != 0) _remove((at - 1) >> 4, (at - 1) & 15, true);
            _placed[collection][tokenId] = 1 + imdId * 16 + slot;
        } else {
            uint256 used = _copies[holder][collection][tokenId] + 1;
            if (collection.balanceOf(holder, tokenId, gasleft()) < used) revert NotYours();
            _copies[holder][collection][tokenId] = used;
        }
        _spots[imdId][slot] = Spot(holder, kind, collection, tokenId);
        if (slot == 0) emit FaceSet(imdId, holder, collection, tokenId);
        else emit ItemEquipped(imdId, slot, holder, collection, tokenId, kind);
    }

    function _takeOff(uint256 imdId, uint256 slot) internal {
        address placer = _spots[imdId][slot].holder;
        if (placer == address(0)) return;
        if (msg.sender != placer) {
            (bool ok,) = canAct(imdId, msg.sender);
            if (!ok) revert NotYourPlacement();
        }
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
