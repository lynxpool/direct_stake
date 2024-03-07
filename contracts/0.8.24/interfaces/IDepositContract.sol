// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// Importing libraries and interfaces
import "solidity-bytes-utils/contracts/BytesLib.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IRewardsVault} from "./interfaces/IRewardsVault.sol";

/**
 * @title Reward Pool
 * @dev This contract manages a reward pool where users can join and claim rewards.
 */
contract LynxExecutionLayerRewardsVault is
    Initializable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    IRewardsVault
{
    using SafeERC20 for IERC20;
    using Address for address payable;
    using Address for address;

    // Constants and state variables declaration
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant CONTROLLER_ROLE = keccak256("CONTROLLER_ROLE");

    uint256 private constant MULTIPLIER = 1e18;

    struct UserInfo {
        uint256 accSharePoint; // Share starting point
        uint256 amount; // User's share
        uint256 rewardBalance; // User's pending reward
    }

    uint256 public managerFeeShare; // Manager's fee in 1/1000

    uint256 private managerRevenue; // Manager's revenue
    uint256 private totalShares; // Total shares
    uint256 private accShare; // Accumulated earnings per 1 share
    mapping(address => UserInfo) public userInfo; // Mapping from claim address to UserInfo

    uint256 private accountedBalance; // For tracking of overall deposits

    /**
     * ======================================================================================
     *
     * SYSTEM SETTINGS, OPERATED VIA OWNER(DAO/TIMELOCK)
     *
     * ======================================================================================
     */

    // Fallback function to receive ether
    receive() external payable {}

    /**
     * @dev Pause the contract
     */
    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause the contract
     */
    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @dev Initialization function to set up roles and default values
     */
    function initialize() public initializer {
        __Pausable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();

        // Initialize default values and grant roles
        managerFeeShare = 200; // 20%
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(CONTROLLER_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);
    }

    /**
     * ======================================================================================
     *
     * MANAGER FUNCTIONS
     *
     * ======================================================================================
     */

    /**
     * @dev Manager withdraws revenue
     * @param amount Amount to withdraw
     * @param to Address to withdraw to
     */
    function withdrawManagerRevenue(uint256 amount, address to)
        external
        nonReentrant
        onlyRole(MANAGER_ROLE)
    {
        updateReward();

        require(amount <= managerRevenue, "WITHDRAW_EXCEEDED_MANAGER_REVENUE");

        // Track balance change
        _balanceDecrease(amount);
        managerRevenue -= amount;

        payable(to).sendValue(amount);

        emit ManagerFeeWithdrawed(amount, to);
    }

    /**
     * @dev Set manager's fee in 1/1000
     * @param milli Manager's fee in 1/1000
     */
    function setManagerFeeShare(uint256 milli)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(milli >= 0 && milli <= 1000, "SHARE_OUT_OF_RANGE");
        managerFeeShare = milli;

        emit ManagerFeeSet(milli);
    }

    /**
     * ======================================================================================
     *
     * USER FUNCTIONS
     *
     * ======================================================================================
     */

    /**
     * @dev To join the reward pool
     * @param claimaddr Address to claim tokens 
     * @param amount Claim amount 
     */
    function joinVault(address claimaddr, uint256 amount)
        external
        override
        onlyRole(CONTROLLER_ROLE)
        whenNotPaused
    {
        updateReward();

        UserInfo storage info = userInfo[claimaddr];

        // Settle current pending distribution
        info.rewardBalance +=
            ((accShare - info.accSharePoint) * info.amount) /
            MULTIPLIER;
        info.amount += amount;
        info.accSharePoint = accShare;

        // Update total shares
        totalShares += amount;

        emit PoolJoined(claimaddr, amount);
    }

    /**
     * @dev To leave a pool
     * @param claimaddr Address to claim tokens 
     * @param amount Claim amount 
     */
    function leaveVault(address claimaddr, uint256 amount)
        external
        override
        onlyRole(CONTROLLER_ROLE)
        whenNotPaused
    {
        updateReward();

        UserInfo storage info = userInfo[claimaddr];
        require(info.amount >= amount, "INSUFFICIENT_AMOUNT");

        // Settle current pending distribution
        info.rewardBalance +=
            ((accShare - info.accSharePoint) * info.amount) /
            MULTIPLIER;
        info.amount -= amount;
        info.accSharePoint = accShare;

        // Update total shares
        totalShares -= amount;

        emit PoolLeft(claimaddr, amount);
    }

    /**
     * @dev To Claim rewards
     * @param beneficiary Address of the beneficiary
     * @param amount reward amount 
     */
    function claimRewards(address beneficiary, uint256 amount)
        external
        nonReentrant
        whenNotPaused
    {
        updateReward();

        UserInfo storage info = userInfo[msg.sender];

        // Settle current pending distribution
        info.rewardBalance +=
            ((accShare - info.accSharePoint) * info.amount) /
            MULTIPLIER;
        info.accSharePoint = accShare;

        // Check
        require(info.rewardBalance >= amount, "INSUFFICIENT_REWARD");

        // Account & transfer
        info.rewardBalance -= amount;
        _balanceDecrease(amount);
        payable(beneficiary).sendValue(amount);

        emit Claimed(beneficiary, amount);
    }

    // Claim rewards for an account, the rewards will only be claimed to the claim address for safety
    // This function plays the role as 'settler for accounts' and could only be called by the controller contract.
    /**
     * @dev To Claim rewards for input address
     * @param account Address of the beneficiary account for rewards
     */
    function claimRewardsFor(address account)
        external
        nonReentrant
        whenNotPaused
        onlyRole(CONTROLLER_ROLE)
    {
        updateReward();

        UserInfo storage info = userInfo[account];

        // Settle current pending distribution
        info.rewardBalance +=
            ((accShare - info.accSharePoint) * info.amount) /
            MULTIPLIER;
        info.accSharePoint = accShare;

        // Account & transfer
        uint256 amount = info.rewardBalance;
        info.rewardBalance -= amount;
        _balanceDecrease(amount);
        payable(account).sendValue(amount);

        emit Claimed(account, amount);
    }

    /**
     * @dev Update reward of transaction fee
     */
    function updateReward() public {
        if (address(this).balance > accountedBalance && totalShares > 0) {
            (uint256 managerR, uint256 poolR) = _calcPendingReward();
            accShare += (poolR * MULTIPLIER) / totalShares;
            managerRevenue += managerR;
            accountedBalance = address(this).balance;
        }
    }

    /**
     * ======================================================================================
     *
     * VIEW FUNCTIONS
     *
     * ======================================================================================
     */

    /**
     * @dev Retrieves the total shares in the reward pool.
     * @return The total shares in the reward pool.
     */
    function getTotalShare() external view returns (uint256) {
        return totalShares;
    }

    /**
     * @dev Retrieves the accounted balance in the contract.
     * @return The accounted balance in the contract.
     */
    function getAccountedBalance() external view returns (uint256) {
        return accountedBalance;
    }

    /**
     * @dev Retrieves the pending reward for a specific claim address.
     * @param claimaddr The address for which to retrieve the pending reward.
     * @return The pending reward amount for the specified address.
     */
    function getPendingReward(address claimaddr)
        external
        view
        returns (uint256)
    {
        UserInfo storage info = userInfo[claimaddr];
        if (totalShares == 0) {
            return info.rewardBalance;
        }

        uint256 poolReward;
        if (address(this).balance > accountedBalance) {
            (, poolReward) = _calcPendingReward();
        }

        return
            info.rewardBalance +
            ((accShare +
                (poolReward * MULTIPLIER) /
                totalShares -
                info.accSharePoint) * info.amount) /
            MULTIPLIER;
    }

    /**
     * @dev Retrieves the pending manager revenue.
     * @return The pending manager revenue.
     */
    function getPendingManagerRevenue() external view returns (uint256) {
        uint256 managerReward;
        if (address(this).balance > accountedBalance) {
            (managerReward, ) = _calcPendingReward();
        }

        return managerRevenue + managerReward;
    }

    /**
     * ======================================================================================
     *
     * INTERNAL FUNCTIONS
     *
     * ======================================================================================
     */

   /**
     * @dev Decreases the accounted balance by the specified amount.
     * @param amount The amount to decrease the accounted balance by.
     */
    function _balanceDecrease(uint256 amount) internal {
        accountedBalance -= amount;
    }

    /**
     * @dev Calculates the pending rewards for the manager and the pool.
     * @return managerR The pending reward for the manager.
     * @return poolR The pending reward for the pool.
     */
    function _calcPendingReward()
        internal
        view
        returns (uint256 managerR, uint256 poolR)
    {
        uint256 reward = address(this).balance - accountedBalance;

        // Distribute to manager and pool
        managerR = (reward * managerFeeShare) / 1000;
        poolR = reward - managerR;

        return (managerR, poolR);
    }

    /**
     * ======================================================================================
     *
     * SYSTEM EVENTS
     *
     * ======================================================================================
     */

    /**
     * @dev Emitted when a user joins the reward pool.
     * @param claimaddr The address of the user joining the pool.
     * @param amount The amount of tokens deposited by the user.
     */
    event PoolJoined(address claimaddr, uint256 amount);

    /**
     * @dev Emitted when a user leaves the reward pool.
     * @param claimaddr The address of the user leaving the pool.
     * @param amount The amount of tokens withdrawn by the user.
     */    
    event PoolLeft(address claimaddr, uint256 amount);

    /**
     * @dev Emitted when a user claims their rewards.
     * @param beneficiary The address of the user claiming the rewards.
     * @param amount The amount of rewards claimed by the user.
     */    
    event Claimed(address beneficiary, uint256 amount);

    /**
     * @dev Emitted when the manager withdraws their fee.
     * @param amount The amount of tokens withdrawn by the manager as their fee.
     * @param to The address to which the manager fee is withdrawn.
     */    
    event ManagerFeeWithdrawed(uint256 amount, address to);

    /**
     * @dev Emitted when the manager fee percentage is set or updated.
     * @param milli The new manager fee percentage in 1/1000.
     */    
    event ManagerFeeSet(uint256 milli);
}

