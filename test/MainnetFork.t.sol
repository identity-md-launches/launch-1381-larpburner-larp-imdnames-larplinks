// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LARP} from "../src/LARP.sol";
import {ILARP} from "../src/ILARP.sol";
import {LARPNames} from "../src/LARPNames.sol";
import {LARPLinks} from "../src/LARPLinks.sol";

interface IERC721Like {
    function ownerOf(uint256) external view returns (address);
    function tokenURI(uint256) external view returns (string memory);
    function transferFrom(address, address, uint256) external;
}

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
}

/// @dev The real thing on an Ethereum fork: identity.md, Worker Frens, POOL4, IMD's BurnExecutor and launcher, and
/// real swarm airdrop proofs (test/fixtures/allocs.json, from GET api.imd.fun/launches/<id>?claims=1). Runs when
/// MAINNET_RPC_URL is set, skips otherwise (IMD's swarm builds without an RPC).
contract MainnetForkTest is Test {
    address constant IDENTITY = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant POOL4_HOOK = 0xc6C965Bd164c483e87d0B550671798e9A3602840;
    address constant IMD_BURN = 0xe29386719C155B6847aD5a4E97C6674f10ffc750;
    address constant IMD6900_POT = 0xA16026A28aA581AA96713d20C608Da7F8db86444;
    address constant LAUNCHER = 0xfF03410d0Fe5fa8f7F59F743de35E333D9857120;
    address constant WORKER_FRENS = 0x6900d042460d6bdbe68CE994F4dE36706797CCd4;
    address constant TREASURY = 0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F;
    address constant FULL_JEETER = 0x2A89C680d9d96A51f8dD52bD20AabC4A320E7dCA;
    address constant HALF_JEETER = 0x7d5E92853599B792cCb65A6E9B1fC26c663F6563;

    LARP larp;
    LARPNames names;
    LARPLinks links;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        larp = new LARP(IDENTITY);
        names = new LARPNames(IDENTITY, POOL_MANAGER, IMD, POOL4_HOOK, IMD_BURN, IMD6900_POT);
        links = new LARPLinks(IDENTITY, LAUNCHER, larp, names);
    }

    modifier forked() {
        if (address(larp) == address(0)) vm.skip(true);
        _;
    }

    function _label(string memory s) internal pure returns (bytes32 label) {
        assembly {
            label := mload(add(s, 0x20))
        }
        uint256 n = bytes(s).length;
        if (n < 32) label &= ~bytes32(type(uint256).max >> (8 * n));
    }

    function test_AnIdentityWearsAWorkerFren() public forked {
        vm.prank(TREASURY);
        larp.setFace(806, WORKER_FRENS, 1);
        (,,, bool live) = larp.faceOf(806);
        assertTrue(live);
        assertEq(larp.faceURI(806), IERC721Like(WORKER_FRENS).tokenURI(1), "the fren's own on-chain art");
        assertEq(larp.avatarOf(806), "eip155:1/erc721:0x6900d042460d6bdbe68ce994f4de36706797ccd4/1");

        vm.prank(TREASURY);
        larp.equip(806, 1, WORKER_FRENS, 2, ILARP.Kind.ERC721);
        assertEq(larp.itemURI(806, 1), IERC721Like(WORKER_FRENS).tokenURI(2));

        address buyer = address(0xb0B0000000000000000000000000000000000B0B);
        vm.prank(TREASURY);
        IERC721Like(IDENTITY).transferFrom(TREASURY, buyer, 806);
        (,,, live) = larp.faceOf(806);
        assertFalse(live);
        assertEq(larp.faceURI(806), IERC721Like(IDENTITY).tokenURI(806));
    }

    function test_ANameBuysAndBurnsRealIMDOnPool4() public forked {
        uint256 before = IERC20Like(IMD).balanceOf(IMD_BURN);
        uint256 potBefore = IMD6900_POT.balance;
        uint256 dust = address(names).balance; // mainnet dust may sit at a fork-deployed address
        vm.deal(TREASURY, 1 ether);
        vm.prank(TREASURY);
        names.register{value: 0.0069 ether}(806, _label("imd6900"), 0);
        uint256 burned = IERC20Like(IMD).balanceOf(IMD_BURN) - before;
        emit log_named_decimal_uint("IMD bought on POOL4 and sent to the BurnExecutor for 0.0069 ETH", burned, 18);
        assertGt(burned, 0, "POOL4 took the trade");
        assertEq(IMD6900_POT.balance, potBefore, "no fallback");
        assertEq(address(names).balance, dust, "no ETH stays");
        assertEq(names.nameOf(806), "imd6900.imd");
        (bool exists, uint256 imdId, address holder) = names.resolveName("imd6900.imd");
        assertTrue(exists);
        assertEq(imdId, 806);
        assertEq(holder, TREASURY);
    }

    /// @dev If POOL4 can't take a fee, the real IMD6900 pot takes the ETH (here: a registry pointed at a pool that
    /// doesn't exist).
    function test_TheRealPotTakesAFeePool4Cant() public forked {
        LARPNames lost = new LARPNames(IDENTITY, POOL_MANAGER, IMD, address(0x1234), IMD_BURN, IMD6900_POT);
        uint256 potBefore = IMD6900_POT.balance;
        vm.deal(TREASURY, 1 ether);
        vm.prank(TREASURY);
        lost.register{value: 0.0069 ether}(806, _label("imd6900"), 0);
        assertEq(IMD6900_POT.balance - potBefore, 0.0069 ether, "the NFT pot took it");
        assertEq(lost.nameOf(806), "imd6900.imd");
    }

    function test_ACrewBuysAndBurnsRealIMDOnPool4() public forked {
        uint256 before = IERC20Like(IMD).balanceOf(IMD_BURN);
        vm.deal(TREASURY, 1 ether);
        vm.prank(TREASURY);
        links.foundCrew{value: 0.0069 ether}(806, _label("imd6900-frens"), true, 0);
        assertGt(IERC20Like(IMD).balanceOf(IMD_BURN), before);
        assertEq(links.crewOf(806), 1);
    }

    /// @dev Proves every allocation in the fixtures with its real proof against the real distributor.
    function _proveAll() internal {
        string memory json = vm.readFile("test/fixtures/allocs.json");
        for (uint256 i;; ++i) {
            string memory at = string.concat(".allocs[", vm.toString(i), "]");
            if (!vm.keyExistsJson(json, at)) break;
            links.proveAlloc(
                uint64(vm.parseJsonUint(json, string.concat(at, ".launch"))),
                vm.parseJsonUint(json, string.concat(at, ".round")),
                vm.parseJsonAddress(json, string.concat(at, ".wallet")),
                vm.parseUint(vm.parseJsonString(json, string.concat(at, ".amount"))),
                vm.parseJsonBytes32Array(json, string.concat(at, ".proof"))
            );
        }
    }

    function test_TheRealJeetBoard() public forked {
        _proveAll();

        // claimed both its airdrops (IMD #739, ZTO #737) and sold every token
        (uint256 level, uint256 points) = links.jeetOf(FULL_JEETER);
        assertEq(level, 2);
        assertEq(points, 20_000);
        assertEq(links.titleOf(links.tierOf(level, points)), "Jeet Lord");

        // sold half of its ZTO (49.9999%: basis points round down)
        (level, points) = links.jeetOf(HALF_JEETER);
        assertEq(level, 1);
        assertEq(points, 4_999);
        assertEq(links.titleOf(links.tierOf(level, points)), "Paper Hands");

        // the IMD6900 treasury holds what it claimed and never claimed VERDICT
        (address holder, uint256 lvl, uint256 pts, uint8 tier) = links.rankOf(806);
        assertEq(holder, TREASURY);
        assertEq(lvl, 4);
        assertEq(pts, 0);
        assertEq(links.titleOf(tier), "Diamond Hands");
        LARPLinks.LaunchJeet memory verdict = links.launchJeet(TREASURY, 3);
        assertEq(verdict.number, 1352);
        assertEq(verdict.claimed, 0, "VERDICT is unclaimed");
    }

    function test_RealProofsRefuseTampering() public forked {
        string memory json = vm.readFile("test/fixtures/allocs.json");
        bytes32[] memory proof = vm.parseJsonBytes32Array(json, ".allocs[1].proof");
        uint256 amount = vm.parseUint(vm.parseJsonString(json, ".allocs[1].amount"));
        vm.expectRevert(LARPLinks.BadProof.selector);
        links.proveAlloc(737, 0, FULL_JEETER, amount + 1, proof);
        vm.expectRevert(LARPLinks.BadProof.selector);
        links.proveAlloc(739, 0, FULL_JEETER, amount, proof);
        vm.expectRevert(LARPLinks.UnknownLaunch.selector);
        links.proveAlloc(1341, 0, FULL_JEETER, amount, proof); // a hook launch: not this launcher's
    }

    function test_TheTreasurysCard() public forked {
        _proveAll();
        vm.deal(TREASURY, 1 ether);
        vm.startPrank(TREASURY);
        names.register{value: 0.0069 ether}(806, _label("imd6900"), 0);
        larp.setFace(806, WORKER_FRENS, 1);
        links.foundCrew{value: 0.0069 ether}(806, _label("imd6900-frens"), true, 0);
        links.fren(806, 1533);
        links.fren(1533, 806);
        vm.stopPrank();

        LARPLinks.Card memory c = links.cardOf(806);
        assertEq(c.holder, TREASURY);
        assertEq(c.name, "imd6900.imd");
        assertEq(c.faceCollection, WORKER_FRENS);
        assertEq(c.faceTokenId, 1);
        assertTrue(c.faceLive);
        assertEq(c.crewName, _label("imd6900-frens"));
        assertTrue(c.captain);
        assertEq(c.frens, 1);
        assertEq(c.level, 4);
        assertEq(c.title, "Diamond Hands");
    }
}
