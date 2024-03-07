// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

contract EIP712 {
    // Storage Variables
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

    /**
     * @dev Constructs the EIP712 domain separator hash
     * @param name The name of the domain
     * @param version The version of the domain
     * @return bytes32 The EIP712 domain separator hash
     */
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

    /**
     * @dev Hashes an array of bytes
     * @param arr The array of bytes to hash
     * @return bytes32 The hash of the array of bytes
     */
    function _hashBytesArrary(
        bytes[] calldata arr
    ) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](arr.length);
        for (uint256 i = 0; i < arr.length; i++) {
            hashes[i] = keccak256(arr[i]);
        }
        return keccak256(abi.encodePacked(hashes));
    }

    /**
     * @dev Hashes stake parameters
     * @param extraData The extra data for the stake
     * @param claimaddr The address to claim stakes
     * @param withdrawaddr The address to withdraw stakes
     * @param pubkeys The array of public keys
     * @param signatures The array of signatures
     * @return bytes32 The hash of the stake parameters
     */
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


    /**
     * @dev Calculates the hash to sign
     * @param paramHash The hash of the parameters
     * @return bytes32 The hash to sign
     */
    function _hashToSign(bytes32 paramHash) internal view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, paramHash)
            );
    }
}
