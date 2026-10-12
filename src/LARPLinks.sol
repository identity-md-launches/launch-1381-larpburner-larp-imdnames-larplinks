// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILARP} from "./ILARP.sol";
import {ILARPNames} from "./ILARPNames.sol";
import {LARPBurner} from "./LARPBurner.sol";
import {Labels} from "./Labels.sol";
import {SafeReads} from "./SafeReads.sol";

/// @title LARP links: frens, crews and ranks, by the IMD6900 frens
/// @notice The links between identity.md: two identities become frens when both agree, identities band into crews
/// under a captain, and each identity carries a rank read from what its holder did with the IMD swarm's airdrops.
/// Every IMD launch pays the swarm through a Merkle distributor; anyone can prove a wallet's allocation here, and the
/// rank reads, live, how much of it the wallet still holds. The level is the number of swarm launches proven; the jeet
/// points are how much of them was sold (10,000 = one launch's allocation, all gone). A crew's founding fee buys $IMD
/// and burns it, through the LARP burner. An identity's owner or its agent (LARP.canAct) acts for it.
/// @dev No owner, no roles, no upgrades, no funds. Frens and crews belong to identities and pass with them on a sale;
/// the rank belongs to whichever wallet holds the identity now.
contract LARPLinks {
    using SafeReads for address;

    /// @dev Gas for each read of a contract a launch's requester may have written (its token), or IMD's.
    uint256 internal constant READ_GAS = 100_000;
    uint256 internal constant BPS = 10_000;

    struct Crew {
        uint256 captain;
        bytes32 name;
        uint64 members;
        bool open;
        bool alive;
    }

    struct Launch {
        address distributor;
        uint64 number;
    }

    /// @notice One launch's allocation to a wallet, read now.
    struct LaunchJeet {
        uint64 number;
        address distributor;
        address token;
        uint256 allocated;
        uint256 claimed;
        uint256 held;
        uint256 jeetBps;
    }

    /// @notice Everything about one identity, for a card.
    struct Card {
        address holder;
        string name;
        address faceCollection;
        uint256 faceTokenId;
        bool faceLive;
        uint256 crewId;
        bytes32 crewName;
        bool captain;
        uint256 frens;
        uint256 level;
        uint256 jeetPoints;
        uint8 tier;
        string title;
    }

    /// @notice What founding a crew costs, in ETH: it buys $IMD on POOL4 for IMD's burn.
    uint256 public constant CREW_PRICE = 0.0069 ether;

    /// @notice The identity.md collection.
    address public immutable IDENTITY;
    /// @notice IMD's launcher, whose `distributorOf(launch)` names every swarm airdrop this board accepts.
    address public immutable LAUNCHER;
    /// @notice The LARP registry the cards read faces from.
    ILARP public immutable LARP;
    /// @notice LARP names: the cards' names.
    ILARPNames public immutable NAMES;
    /// @notice The LARP burner crew fees go to.
    address public immutable BURNER;

    // --- frens ---
    /// @notice Whether two identities are frens (symmetric).
    mapping(uint256 => mapping(uint256 => bool)) public isFren;
    /// @notice Whether `from` asked `to` to be frens and `to` has not answered.
    mapping(uint256 from => mapping(uint256 to => bool)) public asked;
    /// @notice How many frens an identity has.
    mapping(uint256 => uint256) public frenCount;

    // --- crews ---
    /// @notice Crews ever founded; crew ids run from 1 and are never reused.
    uint256 public crewCount;
    mapping(uint256 crewId => Crew) internal _crews;
    /// @notice The live crew with this name, or 0.
    mapping(bytes32 name => uint256 crewId) public crewByName;
    mapping(uint256 imdId => uint256 crewId) internal _crewOf;
    /// @notice Whether a crew's captain invited this identity.
    mapping(uint256 crewId => mapping(uint256 imdId => bool)) public invited;

    // --- the jeet board ---
    mapping(address wallet => Launch[]) internal _launches;
    mapping(address wallet => mapping(address distributor => uint256[])) internal _rounds;
    /// @notice A proven allocation: wallet => distributor => round => amount (0 = not proven).
    mapping(address wallet => mapping(address distributor => mapping(uint256 round => uint256))) public allocOf;

    event FrenAsked(uint256 indexed from, uint256 indexed to);
    event FrenAskCleared(uint256 indexed from, uint256 indexed to);
    event Frens(uint256 indexed a, uint256 indexed b);
    event Unfrenned(uint256 indexed a, uint256 indexed b);
    event CrewFounded(uint256 indexed crewId, uint256 indexed captain, bytes32 name, bool open);
    event CrewInvited(uint256 indexed crewId, uint256 indexed imdId, bool invited);
    event CrewJoined(uint256 indexed crewId, uint256 indexed imdId);
    event CrewLeft(uint256 indexed crewId, uint256 indexed imdId);
    event CrewCaptain(uint256 indexed crewId, uint256 indexed captain);
    event CrewOpen(uint256 indexed crewId, bool open);
    event CrewDisbanded(uint256 indexed crewId);
    event AllocProven(address indexed wallet, uint64 indexed launch, uint256 round, uint256 amount);

    error ZeroAddress();
    error WrongPrice();
    error TooMuchImd();
    error NotYourIdentity();
    error NoSuchIdentity();
    error SelfFren();
    error AlreadyFrens();
    error AlreadyAsked();
    error BadName();
    error NameTaken();
    error InACrew();
    error NoSuchCrew();
    error NotCaptain();
    error NotInCrew();
    error NotInvited();
    error CaptainStays();
    error BadAlloc();
    error UnknownLaunch();
    error UnknownRound();
    error AlreadyProven();
    error BadProof();

    /// @param identity identity.md (Ethereum: 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D)
    /// @param launcher IMD's launcher (Ethereum: 0xfF03410d0Fe5fa8f7F59F743de35E333D9857120)
    /// @param larp the LARP registry
    /// @param names LARP names
    /// @param burner the LARP burner
    constructor(address identity, address launcher, ILARP larp, ILARPNames names, address burner) {
        if (
            identity == address(0) || launcher == address(0) || address(larp) == address(0)
                || address(names) == address(0) || burner == address(0)
        ) revert ZeroAddress();
        IDENTITY = identity;
        LAUNCHER = launcher;
        LARP = larp;
        NAMES = names;
        BURNER = burner;
    }

    // ------------------------------------------------------------------ frens

    /// @notice Identity `me` asks `them` to be frens, or, if `them` already asked `me`, says yes.
    function fren(uint256 me, uint256 them) external {
        _own(me);
        if (me == them) revert SelfFren();
        if (IDENTITY.ownerOf(them, gasleft()) == address(0)) revert NoSuchIdentity();
        if (isFren[me][them]) revert AlreadyFrens();
        if (asked[them][me]) {
            delete asked[them][me];
            isFren[me][them] = true;
            isFren[them][me] = true;
            ++frenCount[me];
            ++frenCount[them];
            emit Frens(them, me);
        } else {
            if (asked[me][them]) revert AlreadyAsked();
            asked[me][them] = true;
            emit FrenAsked(me, them);
        }
    }

    /// @notice Identity `me` unfrens `them`, or withdraws its ask to `them`, or turns down `them`'s ask.
    function unfren(uint256 me, uint256 them) external {
        _own(me);
        if (isFren[me][them]) {
            delete isFren[me][them];
            delete isFren[them][me];
            --frenCount[me];
            --frenCount[them];
            emit Unfrenned(me, them);
        }
        if (asked[me][them]) {
            delete asked[me][them];
            emit FrenAskCleared(me, them);
        }
        if (asked[them][me]) {
            delete asked[them][me];
            emit FrenAskCleared(them, me);
        }
    }

    // ------------------------------------------------------------------ crews

    /// @notice Identity `captain` founds a crew named `name` (a label: 1 to 32 of a-z, 0-9 and '-', unique among
    /// live crews), paying CREW_PRICE, which buys at least `minImd` $IMD on POOL4 for IMD's burn. `open` crews take
    /// anyone; closed ones only identities the captain invites.
    function foundCrew(uint256 captain, bytes32 name, bool open, uint256 minImd)
        external
        payable
        returns (uint256 crewId)
    {
        if (msg.value != CREW_PRICE) revert WrongPrice();
        crewId = _found(captain, name, open);
        LARPBurner(payable(BURNER)).burn{value: msg.value}(minImd);
    }

    /// @notice `foundCrew`, paid in $IMD: CREW_PRICE's worth at the burner's quote, at most `maxImd`, pulled from the
    /// caller (approve this contract first) and burned.
    function foundCrewWithImd(uint256 captain, bytes32 name, bool open, uint256 maxImd)
        external
        returns (uint256 crewId)
    {
        crewId = _found(captain, name, open);
        LARPBurner burner = LARPBurner(payable(BURNER));
        uint256 due = burner.quoteImd(CREW_PRICE);
        if (due > maxImd) revert TooMuchImd();
        (bool ok, bytes memory r) = burner.IMD().call(abi.encodeWithSelector(0x23b872dd, msg.sender, BURNER, due)); // transferFrom
        if (!ok || (r.length != 0 && !abi.decode(r, (bool)))) revert WrongPrice();
        burner.burnImd();
    }

    function _found(uint256 captain, bytes32 name, bool open) internal returns (uint256 crewId) {
        _own(captain);
        if (crewOf(captain) != 0) revert InACrew();
        if (Labels.length(name) == 0) revert BadName();
        if (crewByName[name] != 0) revert NameTaken();
        crewId = ++crewCount;
        _crews[crewId] = Crew(captain, name, 1, open, true);
        crewByName[name] = crewId;
        _crewOf[captain] = crewId;
        emit CrewFounded(crewId, captain, name, open);
        emit CrewJoined(crewId, captain);
    }

    /// @notice The captain invites identity `imdId` into crew `crewId`, or takes the invitation back.
    function invite(uint256 crewId, uint256 imdId, bool yes) external {
        _captain(crewId);
        if (IDENTITY.ownerOf(imdId, gasleft()) == address(0)) revert NoSuchIdentity();
        invited[crewId][imdId] = yes;
        emit CrewInvited(crewId, imdId, yes);
    }

    /// @notice The captain opens crew `crewId` to anyone, or closes it to invitations only.
    function setOpen(uint256 crewId, bool open) external {
        _captain(crewId);
        _crews[crewId].open = open;
        emit CrewOpen(crewId, open);
    }

    /// @notice Identity `imdId` joins crew `crewId`: open, or invited. One crew at a time.
    function join(uint256 imdId, uint256 crewId) external {
        _own(imdId);
        Crew storage c = _crews[crewId];
        if (!c.alive) revert NoSuchCrew();
        if (crewOf(imdId) != 0) revert InACrew();
        if (!c.open && !invited[crewId][imdId]) revert NotInvited();
        delete invited[crewId][imdId];
        _crewOf[imdId] = crewId;
        ++c.members;
        emit CrewJoined(crewId, imdId);
    }

    /// @notice Identity `imdId` leaves its crew. A captain passes the captaincy or disbands instead.
    function leave(uint256 imdId) external {
        _own(imdId);
        uint256 crewId = crewOf(imdId);
        if (crewId == 0) revert NotInCrew();
        if (_crews[crewId].captain == imdId) revert CaptainStays();
        _drop(crewId, imdId);
    }

    /// @notice The captain removes identity `imdId` from crew `crewId`.
    function kick(uint256 crewId, uint256 imdId) external {
        _captain(crewId);
        if (crewOf(imdId) != crewId) revert NotInCrew();
        if (_crews[crewId].captain == imdId) revert CaptainStays();
        _drop(crewId, imdId);
    }

    /// @notice The captain hands crew `crewId` to member `imdId`.
    function passCaptain(uint256 crewId, uint256 imdId) external {
        _captain(crewId);
        if (crewOf(imdId) != crewId) revert NotInCrew();
        _crews[crewId].captain = imdId;
        emit CrewCaptain(crewId, imdId);
    }

    /// @notice The captain ends crew `crewId`: every member is crewless and the name is free again.
    function disband(uint256 crewId) external {
        _captain(crewId);
        Crew storage c = _crews[crewId];
        c.alive = false;
        c.members = 0;
        delete crewByName[c.name];
        emit CrewDisbanded(crewId);
    }

    /// @notice The live crew identity `imdId` is in, or 0.
    function crewOf(uint256 imdId) public view returns (uint256 crewId) {
        crewId = _crewOf[imdId];
        if (crewId != 0 && !_crews[crewId].alive) crewId = 0;
    }

    /// @notice Crew `crewId`: its captain, name, members, whether it is open and whether it still exists.
    function crew(uint256 crewId)
        external
        view
        returns (uint256 captain, bytes32 name, uint256 members, bool open, bool alive)
    {
        Crew storage c = _crews[crewId];
        return (c.captain, c.name, c.members, c.open, c.alive);
    }

    function _drop(uint256 crewId, uint256 imdId) internal {
        delete _crewOf[imdId];
        --_crews[crewId].members;
        emit CrewLeft(crewId, imdId);
    }

    function _captain(uint256 crewId) internal view {
        Crew storage c = _crews[crewId];
        if (!c.alive) revert NoSuchCrew();
        (bool ok,) = LARP.canAct(c.captain, msg.sender);
        if (!ok) revert NotCaptain();
    }

    // ------------------------------------------------------------ the jeet board

    /// @notice Proves that IMD launch `launch` allotted `amount` of its token to `wallet` in round `round` of its swarm
    /// airdrop. Anyone can prove anyone's allocation (the proofs are public: GET api.imd.fun/launches/<id>?claims=1).
    /// The distributor must be the one IMD's launcher names for `launch`; the proof is checked against its root.
    function proveAlloc(uint64 launch, uint256 round, address wallet, uint256 amount, bytes32[] calldata proof)
        external
    {
        if (wallet == address(0) || amount == 0 || amount > type(uint128).max) revert BadAlloc();
        (bool ok, uint256 w) = LAUNCHER.word(abi.encodeWithSelector(0x6c637492, launch), READ_GAS); // distributorOf
        if (!ok || w == 0 || w >> 160 != 0) revert UnknownLaunch();
        address distributor = address(uint160(w));
        if (allocOf[wallet][distributor][round] != 0) revert AlreadyProven();
        (ok, w) = distributor.word(abi.encodeWithSelector(0xc7c38091, round), READ_GAS); // roundOf: the root first
        if (!ok || w == 0) revert UnknownRound();
        bytes32 node = keccak256(bytes.concat(keccak256(abi.encode(wallet, amount))));
        for (uint256 i; i < proof.length; ++i) {
            bytes32 p = proof[i];
            node = node < p ? keccak256(abi.encode(node, p)) : keccak256(abi.encode(p, node));
        }
        if (node != bytes32(w)) revert BadProof();

        if (_rounds[wallet][distributor].length == 0) _launches[wallet].push(Launch(distributor, launch));
        _rounds[wallet][distributor].push(round);
        allocOf[wallet][distributor][round] = amount;
        emit AllocProven(wallet, launch, round, amount);
    }

    /// @notice How many swarm launches have an allocation to `wallet` proven.
    function launchCount(address wallet) external view returns (uint256) {
        return _launches[wallet].length;
    }

    /// @notice The `i`th launch proven for `wallet`, read now. What the wallet claimed and no longer holds is jeeted;
    /// what it never claimed is not. A token that can't be read counts as held.
    function launchJeet(address wallet, uint256 i) public view returns (LaunchJeet memory j) {
        Launch storage l = _launches[wallet][i];
        (j.number, j.distributor) = (l.number, l.distributor);
        uint256[] storage rounds = _rounds[wallet][l.distributor];
        for (uint256 k; k < rounds.length; ++k) {
            uint256 amount = allocOf[wallet][l.distributor][rounds[k]];
            j.allocated += amount;
            (bool ok, uint256 c) = l.distributor.word(abi.encodeWithSelector(0x120aa877, rounds[k], wallet), READ_GAS); // claimed
            if (ok && c != 0) j.claimed += amount;
        }
        if (j.claimed == 0) return j;
        (bool tokenOk, uint256 t) = l.distributor.word(abi.encodeWithSelector(0xfc0c546a), READ_GAS); // token
        uint256 balance = j.claimed;
        if (tokenOk && t >> 160 == 0 && t != 0) {
            j.token = address(uint160(t));
            (bool ok, uint256 b) = j.token.word(abi.encodeWithSelector(0x70a08231, wallet), READ_GAS); // balanceOf
            if (ok) balance = b;
        }
        j.held = balance < j.claimed ? balance : j.claimed;
        j.jeetBps = (j.claimed - j.held) * BPS / j.allocated;
    }

    /// @notice `wallet`'s level (swarm launches proven) and jeet points (the sum of each launch's jeeted share, in
    /// basis points: 10,000 = one launch's allocation, all sold).
    function jeetOf(address wallet) public view returns (uint256 level, uint256 jeetPoints) {
        level = _launches[wallet].length;
        jeetPoints = jeetOfRange(wallet, 0, level);
    }

    /// @notice The jeet points of `wallet`'s launches `start` to `start + count` (past the end: to the end). Each
    /// launch costs a few reads; for a wallet with hundreds of launches, add up pages.
    function jeetOfRange(address wallet, uint256 start, uint256 count) public view returns (uint256 jeetPoints) {
        uint256 end = _launches[wallet].length;
        if (count < end - (start < end ? start : end)) end = start + count;
        for (uint256 i = start; i < end; ++i) {
            jeetPoints += launchJeet(wallet, i).jeetBps;
        }
    }

    /// @notice Identity `imdId`'s rank, from the wallet holding it now: its level, jeet points and tier.
    function rankOf(uint256 imdId) public view returns (address holder, uint256 level, uint256 jeetPoints, uint8 tier) {
        holder = IDENTITY.ownerOf(imdId, gasleft());
        if (holder == address(0)) return (holder, 0, 0, 0);
        (level, jeetPoints) = jeetOf(holder);
        tier = tierOf(level, jeetPoints);
    }

    /// @notice The tier for a level and jeet points, by the average share jeeted per launch: 0 Lurker (no launch
    /// proven), 1 Diamond Hands (under 10%), 2 Holder (under 35%), 3 Paper Hands (under 65%), 4 Jeet (under 90%),
    /// 5 Jeet Lord.
    function tierOf(uint256 level, uint256 jeetPoints) public pure returns (uint8) {
        if (level == 0) return 0;
        uint256 average = jeetPoints / level;
        if (average < 1_000) return 1;
        if (average < 3_500) return 2;
        if (average < 6_500) return 3;
        if (average < 9_000) return 4;
        return 5;
    }

    /// @notice A tier's title.
    function titleOf(uint8 tier) public pure returns (string memory) {
        if (tier == 1) return "Diamond Hands";
        if (tier == 2) return "Holder";
        if (tier == 3) return "Paper Hands";
        if (tier == 4) return "Jeet";
        if (tier == 5) return "Jeet Lord";
        return "Lurker";
    }

    // ------------------------------------------------------------------ cards

    /// @notice Everything about identity `imdId` in one read: its holder, name, face, crew, frens and rank.
    function cardOf(uint256 imdId) external view returns (Card memory c) {
        (c.holder, c.level, c.jeetPoints, c.tier) = rankOf(imdId);
        c.title = titleOf(c.tier);
        c.name = NAMES.nameOf(imdId);
        (, c.faceCollection, c.faceTokenId, c.faceLive) = LARP.faceOf(imdId);
        c.crewId = crewOf(imdId);
        if (c.crewId != 0) {
            c.crewName = _crews[c.crewId].name;
            c.captain = _crews[c.crewId].captain == imdId;
        }
        c.frens = frenCount[imdId];
    }

    /// @dev The caller is the identity's owner or its live agent.
    function _own(uint256 imdId) internal view {
        (bool ok,) = LARP.canAct(imdId, msg.sender);
        if (!ok) revert NotYourIdentity();
    }
}
