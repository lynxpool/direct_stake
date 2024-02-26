// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

contract EIP712 {
    bytes32 public constant EIP712_DOMAIN_TYPEHASH =
        keccak256(
            abi.encodePacked(
                "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
            )
        );
    bytes32 public DOMAIN_SEPARATOR;

    bytes32 public constant STAKE_PARAM_TYPEHASH =
        keccak256(
            abi.encodePacked(
                "StakeParams(uint256 extraData,address claimaddr,address withdrawaddr,bytes[] pubkeys,bytes[] signatures)"
            )
        );

    function _hashDomain(
        string memory name,
        string memory version
    ) internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    EIP712_DOMAIN_TYPEHASH,
                    keccak256(bytes(name)),
                    keccak256(bytes(version)),
                    block.chainid,
                    address(this)
                )
            );
    }

    function _hashBytesArrary(
        bytes[] calldata arr
    ) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](arr.length);
        for (uint256 i = 0; i < arr.length; i++) {
            hashes[i] = keccak256(arr[i]);
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function _hashStakeParams(
        uint256 extraData,
        address claimaddr,
        address withdrawaddr,
        bytes[] calldata pubkeys,
        bytes[] calldata signatures
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    STAKE_PARAM_TYPEHASH,
                    extraData,
                    claimaddr,
                    withdrawaddr,
                    _hashBytesArrary(pubkeys),
                    _hashBytesArrary(signatures)
                )
            );
    }

    function _hashToSign(bytes32 paramHash) internal view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, paramHash)
            );
    }
}
