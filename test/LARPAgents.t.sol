// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./Base.sol";
import {ILARP} from "../src/ILARP.sol";
import {LARPLinks} from "../src/LARPLinks.sol";
import {MockNFT} from "./Mocks.sol";

/// @dev A contract wallet (ERC-1271) whose signer is one EOA key, holding an identity.
contract SmartWallet {
    address public immutable signer;

    constructor(address signer_) {
        signer = signer_;
    }

    function isValidSignature(bytes32 digest, bytes calldata sig) external view returns (bytes4) {
        (bytes32 r, bytes32 s) = abi.decode(sig[:64], (bytes32, bytes32));
        return ecrecover(digest, uint8(sig[64]), r, s) == signer ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0x150b7a02;
    }
}

contract LARPAgentsTest is Base {
    event AgentSet(uint256 indexed imdId, address indexed holder, address indexed agent);

    uint256 ownerKey = 0xA11CE5;
    address owner;
    address agent = makeAddr("agent");
    MockNFT masks;

    function setUp() public {
        _deploy();
        _fillPool4();
        owner = vm.addr(ownerKey);
        identity.mint(owner, 7);
        identity.mint(bob, 8);
        masks = new MockNFT("mask://");
        masks.mint(owner, 1);
        masks.mint(agent, 2);
    }

    function _digest(uint256 imdId, address who, address holder, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("SetAgent(uint256 imdId,address agent,address holder,uint256 nonce,uint256 deadline)"),
                imdId,
                who,
                holder,
                nonce,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", larp.DOMAIN_SEPARATOR(), structHash));
    }

    function _sign(uint256 key, uint256 imdId, address who, address holder, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _digest(imdId, who, holder, nonce, deadline));
        return abi.encodePacked(r, s, v);
    }

    function _live(uint256 imdId) internal view returns (bool live) {
        (, live) = larp.agentOf(imdId);
    }

    // --- connecting ---

    function test_TheOwnerConnectsAnAgentInOneCall() public {
        vm.expectEmit(address(larp));
        emit AgentSet(7, owner, agent);
        vm.prank(owner);
        larp.setAgent(7, agent);
        (address a, bool live) = larp.agentOf(7);
        assertEq(a, agent);
        assertTrue(live);
        (uint256 imdId, bool l) = larp.identityOfAgent(agent);
        assertEq(imdId, 7);
        assertTrue(l);
        (bool ok, address holder) = larp.canAct(7, agent);
        assertTrue(ok);
        assertEq(holder, owner);
    }

    function test_TheOwnerSignsTheAgentSends() public {
        bytes memory sig = _sign(ownerKey, 7, agent, owner, 0, block.timestamp + 1 days);
        vm.prank(agent); // the owner's wallet never sends a transaction
        larp.setAgentBySig(7, agent, block.timestamp + 1 days, sig);
        assertTrue(_live(7));
        assertEq(larp.nonces(owner), 1);
    }

    function test_AContractWalletSignsWithERC1271() public {
        SmartWallet wallet = new SmartWallet(owner);
        identity.mint(address(wallet), 9);
        bytes memory sig = _sign(ownerKey, 9, agent, address(wallet), 0, block.timestamp + 1 days);
        larp.setAgentBySig(9, agent, block.timestamp + 1 days, sig);
        (address a, bool live) = larp.agentOf(9);
        assertEq(a, agent);
        assertTrue(live);
    }

    function test_BadSignatures() public {
        uint256 deadline = block.timestamp + 1 days;
        // a stranger's key
        bytes memory sig = _sign(0xBAD, 7, agent, owner, 0, deadline);
        vm.expectRevert(ILARP.BadSignature.selector);
        larp.setAgentBySig(7, agent, deadline, sig);
        // the owner's, for another agent
        sig = _sign(ownerKey, 7, bob, owner, 0, deadline);
        vm.expectRevert(ILARP.BadSignature.selector);
        larp.setAgentBySig(7, agent, deadline, sig);
        // the owner's, for another identity
        sig = _sign(ownerKey, 8, agent, owner, 0, deadline);
        vm.expectRevert(ILARP.BadSignature.selector);
        larp.setAgentBySig(7, agent, deadline, sig);
        // the owner's, made malleable: the same signature with the high s (and the other v) recovers the same key,
        // and is refused
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, _digest(7, agent, owner, 0, deadline));
        bytes32 highS = bytes32(0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141 - uint256(s));
        vm.expectRevert(ILARP.BadSignature.selector);
        larp.setAgentBySig(7, agent, deadline, abi.encodePacked(r, highS, v == 27 ? uint8(28) : uint8(27)));
        // too short
        vm.expectRevert(ILARP.BadSignature.selector);
        larp.setAgentBySig(7, agent, deadline, hex"1234");
    }

    function test_SignaturesExpire() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(ownerKey, 7, agent, owner, 0, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(ILARP.Expired.selector);
        larp.setAgentBySig(7, agent, deadline, sig);
    }

    function test_ASignatureWorksOnce() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _sign(ownerKey, 7, agent, owner, 0, deadline);
        larp.setAgentBySig(7, agent, deadline, sig);
        vm.prank(owner);
        larp.setAgent(7, address(0));
        // the same signature can't bring the removed agent back
        vm.expectRevert(ILARP.BadSignature.selector);
        larp.setAgentBySig(7, agent, deadline, sig);
    }

    function test_AnyAgentChangeVoidsOutstandingSignatures() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _sign(ownerKey, 7, agent, owner, 0, deadline);
        vm.prank(owner);
        larp.setAgent(7, bob); // nonce 0 -> 1
        vm.expectRevert(ILARP.BadSignature.selector);
        larp.setAgentBySig(7, agent, deadline, sig);
    }

    // --- what an agent can and can't do ---

    function test_AnAgentDressesTheIdentityWithTheOwnersNFTs() public {
        vm.prank(owner);
        larp.setAgent(7, agent);
        vm.prank(agent);
        larp.setFace(7, address(masks), 1);
        (address holder,,, bool live) = larp.faceOf(7);
        assertEq(holder, owner, "the placement is the owner's");
        assertTrue(live);

        // the agent's own NFT is not the owner's
        vm.prank(agent);
        vm.expectRevert(ILARP.NotYours.selector);
        larp.equip(7, 1, address(masks), 2, ILARP.Kind.ERC721);

        vm.prank(agent);
        larp.clearFace(7);
        (holder,,,) = larp.faceOf(7);
        assertEq(holder, address(0));
    }

    function test_AnAgentRunsFrensAndCrews() public {
        vm.prank(owner);
        larp.setAgent(7, agent);
        vm.prank(agent);
        links.fren(7, 8);
        vm.prank(bob);
        links.fren(8, 7);
        assertTrue(links.isFren(7, 8));

        vm.deal(agent, 1 ether);
        vm.prank(agent);
        uint256 crewId = links.foundCrew{value: 0.00069 ether}(7, _label("agents"), true, 0);
        vm.prank(agent);
        links.setOpen(crewId, false);
        vm.prank(agent);
        links.invite(crewId, 8, true);
        vm.prank(bob);
        links.join(8, crewId);
        assertEq(links.crewOf(8), crewId);
    }

    function test_AnAgentLinksTheOwnersNameAndSetsTexts() public {
        uint256 tokenId = _register(owner, "agent-zero");
        vm.prank(owner);
        larp.setAgent(7, agent);
        vm.prank(agent);
        names.link(tokenId, 7, 0);
        assertEq(names.nameOf(7), "agent-zero.imd");
        vm.prank(agent);
        names.setText(7, "agent", "erc8004:52015");
        assertEq(names.text(7, "agent"), "erc8004:52015");
    }

    function test_AnAgentCantNameAgentsOrTheWallet() public {
        vm.prank(owner);
        larp.setAgent(7, agent);
        vm.startPrank(agent);
        vm.expectRevert(ILARP.NotYourIdentity.selector);
        larp.setAgent(7, carol);
        vm.expectRevert(); // the reverse record is the wallet's own
        names.setPrimary(7);
        vm.stopPrank();
    }

    function test_AnAgentLapsesOnASale() public {
        vm.prank(owner);
        larp.setAgent(7, agent);
        vm.prank(owner);
        identity.transferFrom(owner, carol, 7);
        assertFalse(_live(7));
        (bool ok,) = larp.canAct(7, agent);
        assertFalse(ok);
        vm.prank(agent);
        vm.expectRevert(LARPLinks.NotYourIdentity.selector);
        links.fren(7, 8);
        (, bool l) = larp.identityOfAgent(agent);
        assertFalse(l);

        // and doesn't come back if the identity does
        vm.prank(carol);
        identity.transferFrom(carol, owner, 7);
        assertTrue(_live(7), "the owner's own choice stands again");
    }

    function test_AnAgentResigns() public {
        vm.prank(owner);
        larp.setAgent(7, agent);
        vm.prank(bob);
        vm.expectRevert(ILARP.NotTheAgent.selector);
        larp.resignAgent(7);
        vm.prank(agent);
        larp.resignAgent(7);
        (address a,) = larp.agentOf(7);
        assertEq(a, address(0));
    }

    function test_OnlyTheOwnerSetsTheAgent() public {
        vm.prank(bob);
        vm.expectRevert(ILARP.NotYourIdentity.selector);
        larp.setAgent(7, agent);
    }
}
