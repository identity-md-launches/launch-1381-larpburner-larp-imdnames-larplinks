// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Labels: names as one word
/// @notice A label is 1 to 32 bytes of a-z, 0-9 and '-', not starting or ending with '-', left-aligned in a bytes32
/// and zero-padded. One spelling per name: no capitals, no look-alike characters.
library Labels {
    /// @dev The label's length, or 0 when it is not a valid label.
    function length(bytes32 label) internal pure returns (uint256 n) {
        for (; n < 32; ++n) {
            uint8 c = uint8(label[n]);
            if (c == 0) break;
            if (!((c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39) || c == 0x2d)) return 0;
        }
        if (n == 0 || label[0] == "-" || label[n - 1] == "-") return 0;
        // nothing after the padding starts
        if (n < 32 && uint256(label) << (8 * n) != 0) return 0;
    }

    /// @dev The label as a string (for a valid label: its bytes up to the padding).
    function toString(bytes32 label) internal pure returns (string memory s) {
        uint256 n;
        while (n < 32 && label[n] != 0) ++n;
        if (n == 0) return "";
        s = new string(n);
        assembly ("memory-safe") {
            mstore(add(s, 0x20), label)
        }
    }

    /// @dev "kek" or "kek.imd" as the label "kek"; bytes32(0) when it is neither.
    function fromName(string memory name, string memory tld) internal pure returns (bytes32 label) {
        bytes memory b = bytes(name);
        bytes memory t = bytes(tld);
        uint256 n = b.length;
        if (n > t.length) {
            bool suffixed = true;
            for (uint256 i; i < t.length; ++i) {
                if (b[n - t.length + i] != t[i]) {
                    suffixed = false;
                    break;
                }
            }
            if (suffixed) n -= t.length;
        }
        if (n == 0 || n > 32) return bytes32(0);
        assembly ("memory-safe") {
            label := mload(add(b, 0x20))
        }
        if (n < 32) label &= ~bytes32(type(uint256).max >> (8 * n));
        if (length(label) != n) return bytes32(0);
    }
}
