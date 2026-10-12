// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LARP} from "../src/LARP.sol";
import {LARPNames} from "../src/LARPNames.sol";
import {LARPLinks} from "../src/LARPLinks.sol";

/// @dev What IMD's `evm_contracts` launch needs: three contracts created in one transaction, constructor arguments
/// only, nothing called.
contract LaunchTest is Test {
    address constant IDENTITY = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant POOL4_HOOK = 0xc6C965Bd164c483e87d0B550671798e9A3602840;
    address constant IMD_BURN = 0xe29386719C155B6847aD5a4E97C6674f10ffc750;
    address constant IMD6900_POT = 0xA16026A28aA581AA96713d20C608Da7F8db86444;
    address constant LAUNCHER = 0xfF03410d0Fe5fa8f7F59F743de35E333D9857120;

    function _launch() internal returns (LARP larp, LARPNames names, LARPLinks links) {
        larp = new LARP(IDENTITY);
        names = new LARPNames(IDENTITY, POOL_MANAGER, IMD, POOL4_HOOK, IMD_BURN, IMD6900_POT);
        links = new LARPLinks(IDENTITY, LAUNCHER, larp, names);
    }

    function test_DeploysOnAFreshChain() public {
        // nothing exists at any of these addresses here: the constructors call nothing
        assertEq(IDENTITY.code.length + POOL_MANAGER.code.length + LAUNCHER.code.length, 0);
        (LARP larp, LARPNames names, LARPLinks links) = _launch();
        assertEq(larp.IDENTITY(), IDENTITY);
        assertEq(names.IDENTITY(), IDENTITY);
        assertEq(address(names.POOL_MANAGER()), POOL_MANAGER);
        assertEq(names.IMD(), IMD);
        assertEq(names.POOL4_HOOK(), POOL4_HOOK);
        assertEq(names.IMD_BURN(), IMD_BURN);
        assertEq(names.FALLBACK(), IMD6900_POT);
        assertEq(links.IDENTITY(), IDENTITY);
        assertEq(links.LAUNCHER(), LAUNCHER);
        assertEq(address(links.LARP()), address(larp));
        assertEq(address(links.NAMES()), address(names));
    }

    function test_FitsOneTransaction() public {
        uint256 g = gasleft();
        _launch();
        uint256 used = g - gasleft();
        emit log_named_uint("launch gas, three creations", used);
        // IMD's launcher adds about 0.8M, and the creation code is calldata: 2^24 is the cap
        assertLt(used + 800_000 + 4 * 10 * _initcodeBytes(), 12_000_000);
    }

    function _initcodeBytes() internal pure returns (uint256) {
        return
            type(LARP).creationCode.length + type(LARPNames).creationCode.length + type(LARPLinks).creationCode.length;
    }

    function test_PassesTheAdmissionScan() public {
        (LARP larp, LARPNames names, LARPLinks links) = _launch();
        _scan(bytes.concat(type(LARP).creationCode, abi.encode(IDENTITY)), "LARP creation code");
        _scan(
            bytes.concat(
                type(LARPNames).creationCode, abi.encode(IDENTITY, POOL_MANAGER, IMD, POOL4_HOOK, IMD_BURN, IMD6900_POT)
            ),
            "LARPNames creation code"
        );
        _scan(
            bytes.concat(type(LARPLinks).creationCode, abi.encode(IDENTITY, LAUNCHER, larp, names)),
            "LARPLinks creation code"
        );
        _scan(address(larp).code, "LARP");
        _scan(address(names).code, "LARPNames");
        _scan(address(links).code, "LARPLinks");
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

    function test_UnderTheCodeSizeLimit() public {
        (LARP larp, LARPNames names, LARPLinks links) = _launch();
        assertLt(address(larp).code.length, 24_576);
        assertLt(address(names).code.length, 24_576);
        assertLt(address(links).code.length, 24_576);
    }
}
