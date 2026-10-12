// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDFace} from "../src/IMDFace.sol";

/// @dev What IMD's `evm_contracts` launch needs: one contract, constructor arguments only, nothing called.
contract IMDFaceLaunchTest is Test {
    address constant IDENTITY = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;

    function test_DeploysOnAFreshChain() public {
        // nothing exists at the identity.md address here: the constructor calls nothing
        assertEq(IDENTITY.code.length, 0);
        IMDFace face = new IMDFace(IDENTITY);
        assertEq(face.IDENTITY(), IDENTITY);
    }

    function test_FitsOneTransaction() public {
        uint256 g = gasleft();
        new IMDFace(IDENTITY);
        uint256 used = g - gasleft();
        emit log_named_uint("launch gas", used);
        assertLt(used, 1_000_000);
    }

    function test_PassesTheAdmissionScan() public {
        IMDFace face = new IMDFace(IDENTITY);
        _scan(bytes.concat(type(IMDFace).creationCode, abi.encode(IDENTITY)), "creation code with its argument");
        _scan(address(face).code, "runtime code");
    }

    /// @dev IMD reads code as instructions (PUSH data skipped) and refuses CALLCODE, DELEGATECALL and SELFDESTRUCT
    function _scan(bytes memory code, string memory what) internal pure {
        uint256 hits;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0xf2 || op == 0xf4 || op == 0xff) ++hits;
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
        }
        assertEq(hits, 0, what);
    }
}
