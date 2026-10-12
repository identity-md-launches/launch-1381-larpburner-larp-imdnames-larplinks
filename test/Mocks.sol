// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev The least of an ERC-721 a face needs: ownerOf and tokenURI, plus a free mint and transfer.
contract MockNFT {
    mapping(uint256 => address) public ownerOf;
    string public base;

    constructor(string memory base_) {
        base = base_;
    }

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from && msg.sender == from, "not yours");
        ownerOf[id] = to;
    }

    function tokenURI(uint256 id) external view returns (string memory) {
        return string.concat(base, _decimal(id));
    }

    function _decimal(uint256 v) internal pure returns (string memory s) {
        if (v == 0) return "0";
        while (v != 0) {
            s = string.concat(string(abi.encodePacked(bytes1(uint8(48 + v % 10)))), s);
            v /= 10;
        }
    }
}

/// @dev ownerOf reverts, as for a token that doesn't exist.
contract RevertingNFT {
    function ownerOf(uint256) external pure returns (address) {
        revert("nonexistent");
    }
}

/// @dev ownerOf answers a word whose upper bits are set over `owner`.
contract DirtyNFT {
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    fallback() external {
        bytes32 word = bytes32(uint256(uint160(owner)) | (uint256(1) << 200));
        assembly {
            mstore(0, word)
            return(0, 0x20)
        }
    }
}

/// @dev ownerOf answers fewer than 32 bytes.
contract ShortNFT {
    fallback() external {
        assembly {
            mstore(0, 0)
            return(0, 0x10)
        }
    }
}

/// @dev A real owner, and a tokenURI whose return data is `raw`, whatever it is.
contract RawURINFT {
    address public immutable holder;
    bytes public raw;

    constructor(address holder_, bytes memory raw_) {
        holder = holder_;
        raw = raw_;
    }

    function ownerOf(uint256) external view returns (address) {
        return holder;
    }

    function tokenURI(uint256) external view returns (string memory) {
        bytes memory r = raw;
        assembly {
            return(add(r, 0x20), mload(r))
        }
    }
}
