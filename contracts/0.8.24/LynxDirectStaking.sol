// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IRewardsVault} from "./interfaces/IRewardsVault.sol";
import "solidity-bytes-utils/contracts/BytesLib.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IDepositContract} from "./interfaces/IDepositContract.sol";
import "./EIP712.sol";

/**
 * @title RockX Ethereum Direct Staking Contract
 */
contract LynxDirectStaking is
    Initializable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    EIP712
{
    //events
    event RewardsVaultSet(address addr);
    event OracleSet(address addr);
    event Staked(address addr, uint256 amount);

    using SafeERC20 for IERC20;
    using Address for address payable;
    using Address for address;

    // structure to record taking info.
    struct ValidatorInfo {
        bytes pubkey;
        address claimAddr;
        uint256 extraData; // a 256bit extra data, could be used in DID to ref a user
        // mark exiting
        bool exiting;
    }

    // Variables
    bytes32 public constant REGISTRY_ROLE = keccak256("REGISTRY_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    uint256 public constant DEPOSIT_SIZE = 32 ether;

    uint256 private constant DEPOSIT_AMOUNT_UNIT = 1000000000 wei;
    uint256 private constant SIGNATURE_LENGTH = 96;

    // the deposit contract address in eth2.0
    address public depositContract;

    address public rewardsVault; // rewards vault address
    address public oracle; // the signer for signing parameters in stake()

    // validator registry
    ValidatorInfo[] private validatorRegistry;

    // users's signed params to avert doubled staking
    mapping(bytes32 => bool) private signedParams;

    // user apply for validator exit
    uint256[] private exitQueue;

    // Always extend storage instead of modifying it
    bytes private DEPOSIT_AMOUNT_LITTLE_ENDIAN;

    /**
     * @dev This contract will not accept direct ETH transactions.
     */
    receive() external payable {
        revert("Do not send ETH here");
    }

    /**
     * @dev pause the contract
     */
    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @dev unpause the contract
     */
    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @dev Initializes the Lynx Direct Staking contract with the specified deposit contract address.
     * @param _depositContract The address of the deposit contract for the Ethereum 2.0 network.
     * Initializes contract state variables, access control roles, and domain separator.
     * Sets the default admin role, registry role, and pauser role to the deploying address.
     * Calculates the domain separator using the contract name and version.
     * Calculates the little endian representation of the deposit amount.
     * @param _depositContract The address of the deposit contract for the Ethereum 2.0 network.
     */
    function initialize(address _depositContract) public initializer {
        depositContract = _depositContract;
        __Pausable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(REGISTRY_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);

        // init domain separator
        DOMAIN_SEPARATOR = _hashDomain("LynxDirectStaking", "1.0.0");
        // little endian deposit amount
        uint256 depositAmount = DEPOSIT_SIZE / DEPOSIT_AMOUNT_UNIT;
        DEPOSIT_AMOUNT_LITTLE_ENDIAN = to_little_endian_64(
            uint64(depositAmount)
        );
    }

    /**
     * @dev Sets the address of the oracle responsible for signing stake parameters.
     * Only the account with the DEFAULT_ADMIN_ROLE can call this function.
     * @param _oracle The address of the oracle.
     */
    function setOracle(address _oracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        oracle = _oracle;

        emit OracleSet(_oracle);
    }

    /**
     * @dev Sets the address of the reward pool contract.
     * Only the account with the DEFAULT_ADMIN_ROLE can call this function.
     * @param _rewardsVault The address of the reward pool contract.
     */
    function setRewardsVault(
        address _rewardsVault
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        rewardsVault = _rewardsVault;

        emit RewardsVaultSet(_rewardsVault);
    }

    /**
     * ======================================================================================
     *
     * VIEW FUNCTIONS
     *
     * ======================================================================================
     */

    /**
     * @dev Validates the authorization of the oracle to sign stake parameters.
     * @param extraData Extra data associated with the stake.
     * @param claimaddr The address where rewards will be claimed.
     * @param withdrawaddr The address where the staked ETH can be withdrawn.
     * @param pubkeys An array of public keys associated with the validator.
     * @param signatures An array of signatures, each corresponding to a public key.
     * @param paramsSig The signature of the stake parameters, signed by the oracle.
     * @return A boolean indicating whether the oracle is authorized to sign the stake parameters.
     */
    function validateOracleAuthorization(
        uint256 extraData,
        address claimaddr,
        address withdrawaddr,
        bytes[] calldata pubkeys,
        bytes[] calldata signatures,
        bytes calldata paramsSig
    ) public view returns (bool) {
        // do not accept paramsSig.length == 64
        require(paramsSig.length == 65, "PARAMSIG_LENGTH_MISMATCH");
        bytes32 paramHash = _hashStakeParams(extraData, claimaddr, withdrawaddr, pubkeys, signatures);
        bytes32 digest = _hashToSign(paramHash);
        address signer = ECDSA.recover(digest, paramsSig);
        return (signer == oracle);
    }

    /**
     * @dev Returns the information of a registered validator by index.
     * @param idx The index of the validator in the registry.
     * @return pubkey The public key of the validator.
     * @return claimAddress The address where rewards will be claimed.
     * @return extraData Extra data associated with the validator.
     */
    function getValidatorInfo(
        uint256 idx
    )
        external
        view
        returns (bytes memory pubkey, address claimAddress, uint256 extraData)
    {
        ValidatorInfo storage info = validatorRegistry[idx];
        return (info.pubkey, info.claimAddr, info.extraData);
    }

    /**
     * @dev Returns the information of registered validators within a specified range.
     * @param from The start index of the range.
     * @param to The end index of the range.
     * @return pubkeys An array of public keys of the validators.
     * @return claimAddresses An array of addresses where rewards will be claimed.
     * @return extraDatas An array of extra data associated with the validators.
     */
    function getValidatorInfos(
        uint256 from,
        uint256 to
    )
        external
        view
        returns (
            bytes[] memory pubkeys,
            address[] memory claimAddresses,
            uint256[] memory extraDatas
        )
    {
        pubkeys = new bytes[](to - from);
        claimAddresses = new address[](to - from);
        extraDatas = new uint256[](to - from);

        uint256 counter = 0;
        for (uint i = from; i < to; i++) {
            ValidatorInfo storage info = validatorRegistry[i];
            pubkeys[counter] = info.pubkey;
            claimAddresses[counter] = info.claimAddr;
            extraDatas[counter] = info.extraData;

            counter++;
        }
    }

    /**
     * @dev Returns the total number of registered validators.
     * @return The total number of registered validators.
     */
    function getNextValidators() external view returns (uint256) {
        return validatorRegistry.length;
    }

    /**
     * @dev Returns the exit queue within the specified range.
     * @param from The start index of the range.
     * @param to The end index of the range.
     * @return An array containing the indices of validators in the exit queue.
     */
    function getExitQueue(
        uint256 from,
        uint256 to
    ) external view returns (uint256[] memory) {
        uint256[] memory ids = new uint256[](to - from);
        uint256 counter = 0;
        for (uint i = from; i < to; i++) {
            ids[counter] = exitQueue[i];
            counter++;
        }
        return ids;
    }

    /**
     * @dev Returns the length of the exit queue.
     * @return The length of the exit queue.
     */
    function getExitQueueLength() external view returns (uint256) {
        return exitQueue.length;
    }

    /**
     * ======================================================================================
     *
     * USER EXTERNAL FUNCTIONS
     *
     * ======================================================================================
     */

    /**
     * @dev Allows a user to stake ETH to become a validator in the Lynx network.
     * @param claimaddr The address where rewards will be claimed.
     * @param withdrawaddr The address where the staked ETH can be withdrawn.
     * @param pubkeys An array of public keys associated with the validator.
     * @param signatures An array of signatures, each corresponding to a public key.
     * @param paramsSig The signature of the stake parameters, signed by the oracle.
     * @param extradata Additional data associated with the stake.
     * @param tips Amount of ETH to be used as tips for the contract.
     */
    function stake(
        address claimaddr,
        address withdrawaddr,
        bytes[] calldata pubkeys,
        bytes[] calldata signatures,
        bytes calldata paramsSig,
        uint256 extradata,
        uint256 tips
    ) external payable nonReentrant whenNotPaused {
        // global check
        _require(!signedParams[keccak256(paramsSig)], "REPLAYED_PARAMS");
        _require(signatures.length <= 500, "RISKY_DEPOSITS");
        _require(signatures.length == pubkeys.length, "INCORRECT_SUBMITS");
        _require(
            oracle != address(0x0) &&
                depositContract != address(0x0) &&
                rewardsVault != address(0x0),
            "NOT_INITIATED"
        );

        // params signature verification
        _require(
            validateOracleAuthorization(
                extradata,
                claimaddr,
                withdrawaddr,
                pubkeys,
                signatures,
                paramsSig
            ),
            "SIGNER_MISMATCH"
        );

        // validity check
        _require(
            withdrawaddr != address(0x0) && claimaddr != address(0x0),
            "ZERO_ADDRESS"
        );

        // may add a minimum tips for each stake
        uint256 ethersToStake = msg.value - tips;
        _require(ethersToStake % DEPOSIT_SIZE == 0, "ETHERS_NOT_ALIGNED");
        uint256 nodesAmount = ethersToStake / DEPOSIT_SIZE;
        _require(signatures.length == nodesAmount, "MISMATCHED_ETHERS");

        // build withdrawal credential from withdraw address
        // uint8('0x1') + 11 bytes(0) + withdraw address
        bytes memory cred = abi.encodePacked(
            bytes1(0x01),
            new bytes(11),
            withdrawaddr
        );
        bytes32 withdrawal_credential = BytesLib.toBytes32(cred, 0);

        // deposit
        for (uint256 i = 0; i < nodesAmount; i++) {
            ValidatorInfo memory info;
            info.pubkey = pubkeys[i];
            info.claimAddr = claimaddr;
            info.extraData = extradata;
            validatorRegistry.push(info);

            // deposit to offical contract.
            _deposit(pubkeys[i], signatures[i], withdrawal_credential);
        }

        // join the MEV reward pool once it's deposited to official one.
        IRewardsVault(rewardsVault).joinVault(
            claimaddr,
            DEPOSIT_SIZE * nodesAmount
        );

        // update signedParams to avert repeated use of signature
        signedParams[keccak256(paramsSig)] = true;

        // log
        emit Staked(msg.sender, msg.value);
    }

    /**
     * @dev Initiates an exit request for a validator owned by the caller.
     * @param validatorId The ID of the validator to exit.
     * 
    */
    function exit(uint256 validatorId) external {
        _exitValidator(validatorId, msg.sender);
    }

    /**
     * @dev Initiates batch exit requests for validators owned by the caller.
     * @param validatorIds An array of validator IDs to exit.
     */
    function batchExit(uint256[] memory validatorIds) external {
        for (uint i = 0; i < validatorIds.length; i++) {
            _exitValidator(validatorIds[i], msg.sender);
        }
    }

    /**
     * @dev admin exit a validator in emergency, and return it's principal to validator owner,
     *  optionally to exit unclaimed mev rewards to claim address.
     * @param validatorId The ID of the validator to exit.
     * @param exitToClaimAddress Whether to exit unclaimed MEV rewards to the claim address.
     *
     * NOTE: a user must have contact with us to perform this operation.
     */
    function emergencyExit(
        uint256 validatorId,
        bool exitToClaimAddress
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _emergencyExit(validatorId, exitToClaimAddress);
    }

    /**
     * @dev Initiates batch emergency exits for validators by the admin.
     * @param validatorIds An array of validator IDs to emergency exit.
     * @param exitToClaimAddress Whether to exit unclaimed MEV rewards to the claim address.
    */
    function batchEmergencyExit(
        uint256[] memory validatorIds,
        bool exitToClaimAddress
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint i = 0; i < validatorIds.length; i++) {
            _emergencyExit(validatorIds[i], exitToClaimAddress);
        }
    }

    /** 

     * ======================================================================================
     *
     * INTERNAL FUNCTIONS
     *
     * ======================================================================================
     */

    /**
     * @dev Initiates an emergency exit for a validator.
     * @param validatorId The ID of the validator to exit.
     * @param exitToClaimAddress Indicates whether to exit unclaimed MEV rewards to the claim address.
     */
    function _emergencyExit(
        uint256 validatorId,
        bool exitToClaimAddress
    ) internal {
        ValidatorInfo storage info = validatorRegistry[validatorId];
        require(!info.exiting, "EXITING");
        require(info.claimAddr != address(0x0), "CLAIM_ADDR_MISMATCH");

        info.exiting = true;
        exitQueue.push(validatorId);

        // to leave the MEV reward pool
        IRewardsVault(rewardsVault).leaveVault(info.claimAddr, DEPOSIT_SIZE);

        // allow to exit to claim address
        //  condition:
        //      1. EOA
        //      2. contracts which accept ETH
        if (exitToClaimAddress) {
            IRewardsVault(rewardsVault).claimRewardsFor(info.claimAddr);
        }
    }

    /**
     * @dev Initiates an exit request for a single validator.
     * @param validatorId The ID of the validator to exit.
     * @param sender The address initiating the exit request, must match the claim address of the validator.
     */
    function _exitValidator(uint256 validatorId, address sender) internal {
        ValidatorInfo storage info = validatorRegistry[validatorId];
        require(!info.exiting, "EXITING");
        require(sender == info.claimAddr, "CLAIM_ADDR_MISMATCH");

        info.exiting = true;
        exitQueue.push(validatorId);

        // to leave the MEV reward pool
        IRewardsVault(rewardsVault).leaveVault(info.claimAddr, DEPOSIT_SIZE);
    }

    /**
     * @dev Invokes a deposit call to the official Deposit contract.
     * @param pubkey The public key of the validator.
     * @param signature The signature of the validator.
     * @param withdrawal_credential The withdrawal credential associated with the validator.
     */
    function _deposit(
        bytes calldata pubkey,
        bytes calldata signature,
        bytes32 withdrawal_credential
    ) internal {
        // Compute deposit data root (`DepositData` hash tree root)
        // https://etherscan.io/address/0x00000000219ab540356cbb839cbe05303d7705fa#code
        bytes32 pubkey_root = sha256(abi.encodePacked(pubkey, bytes16(0)));
        bytes32 signature_root = sha256(
            abi.encodePacked(
                sha256(BytesLib.slice(signature, 0, 64)),
                sha256(
                    abi.encodePacked(
                        BytesLib.slice(signature, 64, SIGNATURE_LENGTH - 64),
                        bytes32(0)
                    )
                )
            )
        );

        bytes32 depositDataRoot = sha256(
            abi.encodePacked(
                sha256(abi.encodePacked(pubkey_root, withdrawal_credential)),
                sha256(
                    abi.encodePacked(
                        DEPOSIT_AMOUNT_LITTLE_ENDIAN,
                        bytes24(0),
                        signature_root
                    )
                )
            )
        );

        IDepositContract(depositContract).deposit{value: DEPOSIT_SIZE}(
            pubkey,
            abi.encodePacked(withdrawal_credential),
            signature,
            depositDataRoot
        );
    }

    /**
     * @dev Converts a uint64 value to little endian format.
     * @param value The uint64 value to be converted.
     * @return ret The little endian representation of the input value.
     * https://etherscan.io/address/0x00000000219ab540356cbb839cbe05303d7705fa#code
     */
    function to_little_endian_64(
        uint64 value
    ) internal pure returns (bytes memory ret) {
        ret = new bytes(8);
        bytes8 bytesValue = bytes8(value);
        // Byteswapping during copying to bytes.
        ret[0] = bytesValue[7];
        ret[1] = bytesValue[6];
        ret[2] = bytesValue[5];
        ret[3] = bytesValue[4];
        ret[4] = bytesValue[3];
        ret[5] = bytesValue[2];
        ret[6] = bytesValue[1];
        ret[7] = bytesValue[0];
    }

    /**
     * @dev code size will be smaller
     */
    function _require(bool condition, string memory text) private pure {
        require(condition, text);
    }
}
