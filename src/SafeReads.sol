// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title SafeReads: STATICCALL reads that never revert
/// @notice Every read here answers zero (or "") when the call fails, returns too little, or returns something that is
/// not the type asked for. Internal functions only, so it is inlined: no DELEGATECALL.
library SafeReads {
    /// @dev One word from a STATICCALL with at most `gasCap` gas: `ok` only if the call succeeded and returned at
    /// least a word. Copies one word of return data at most.
    function word(address target, bytes memory data, uint256 gasCap) internal view returns (bool ok, uint256 w) {
        assembly ("memory-safe") {
            ok := staticcall(gasCap, target, add(data, 0x20), mload(data), 0x00, 0x20)
            ok := and(ok, gt(returndatasize(), 0x1f))
            w := mul(mload(0x00), ok)
        }
    }

    /// @dev ERC-721 `ownerOf`, or address(0) if the answer is not an address.
    function ownerOf(address collection, uint256 tokenId, uint256 gasCap) internal view returns (address) {
        (bool ok, uint256 w) = word(collection, abi.encodeWithSelector(0x6352211e, tokenId), gasCap);
        return ok && w >> 160 == 0 ? address(uint160(w)) : address(0);
    }

    /// @dev ERC-1155 `balanceOf(account, id)`.
    function balanceOf(address collection, address account, uint256 id, uint256 gasCap)
        internal
        view
        returns (uint256 balance)
    {
        (, balance) = word(collection, abi.encodeWithSelector(0x00fdd58e, account, id), gasCap);
    }

    /// @dev ERC-20 `balanceOf(account)`.
    function balanceOf(address token, address account, uint256 gasCap) internal view returns (uint256 balance) {
        (, balance) = word(token, abi.encodeWithSelector(0x70a08231, account), gasCap);
    }

    /// @dev A string-returning view taking one uint256 (`tokenURI`, `uri`), or "" when the return data is not a
    /// well-formed ABI string.
    function text(address target, bytes4 selector, uint256 arg) internal view returns (string memory) {
        return textCall(target, abi.encodeWithSelector(selector, arg), gasleft());
    }

    /// @dev Any string-returning view, with at most `gasCap` gas, or "" when the return data is not a well-formed ABI
    /// string. The string is returned in place inside the copied return data.
    function textCall(address target, bytes memory call, uint256 gasCap) internal view returns (string memory s) {
        (bool ok, bytes memory data) = target.staticcall{gas: gasCap}(call);
        if (!ok || data.length < 0x40) return "";
        uint256 at;
        assembly ("memory-safe") {
            at := mload(add(data, 0x20))
        }
        if (at > data.length - 0x20) return "";
        uint256 length;
        assembly ("memory-safe") {
            length := mload(add(add(data, 0x20), at))
        }
        if (length > data.length - 0x20 - at) return "";
        assembly ("memory-safe") {
            s := add(add(data, 0x20), at)
        }
    }
}
