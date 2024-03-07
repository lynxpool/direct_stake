// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "solidity-bytes-utils/contracts/BytesLib.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IRewardsVault} from "./interfaces/IRewardsVault.sol";

/**
 * @title Reward Pool Contract for Execution Layer
 * This contract manages the reward distribution and withdrawal for the Lynx Execution Layer.
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

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant CONTROLLER_ROLE = keccak256("CONTROLLER_ROLE");

    uint256 private constant MULTIPLIER = 1e18;

    struct UserInfo {
        uint256 accSharePoint; // share starting point
        uint256 amount; // user's share
        uint256 rewardBalance; // user's pending reward
    }

    uint256 public managerFeeShare; // manager's fee in 1/1000

    uint256 private managerRevenue; // manager's revenue
    uint256 private totalShares; // total shares
    uint256 private accShare; // accumulated earnings per 1 share
    mapping(address => UserInfo) public userInfo; // claimaddr -> info

    uint256 private accountedBalance; // for tracking of overall deposits

    /**
     * ======================================================================================
     *
     * SYSTEM SETTINGS, OPERATED VIA OWNER(DAO/TIMELOCK)
     *
     * ======================================================================================
     */

    /**
     * @dev Fallback function to accept ETH transfers
     */
    receive() external payable {}

     /**
     * @dev Pause the contract
     * Only callable by addresses with the PAUSER_ROLE
     */
    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause the contract
     * Only callable by addresses with the PAUSER_ROLE
     */
    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @dev Initialize the contract
     * Sets default values and grants roles to the contract deployer
     */
    function initialize() public initializer {
        __Pausable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();

        // init default values
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
     * @dev Allows the manager to withdraw revenue.
     * @param amount The amount of revenue to withdraw.
     * @param to The address to receive the withdrawn revenue.
    */
    function withdrawManagerRevenue(
        uint256 amount,
        address to
    ) external nonReentrant onlyRole(MANAGER_ROLE) {
        updateReward();

        require(amount <= managerRevenue, "WITHDRAW_EXCEEDED_MANAGER_REVENUE");

        // track balance change
        _balanceDecrease(amount);
        managerRevenue -= amount;

        payable(to).sendValue(amount);

        emit ManagerFeeWithdrawed(amount, to);
    }

    /**
     * @dev Sets the manager's fee share in 1/1000.
     * @param milli The manager's fee share to set, in 1/1000.
     */
    function setManagerFeeShare(
        uint256 milli
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
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
     * @dev Allows a user to join the rewards vault pool.
     * @param claimaddr The address of the user joining the pool.
     * @param amount The amount of tokens to be deposited into the pool.
     */
    function joinVault(
        address claimaddr,
        uint256 amount
    ) external override onlyRole(CONTROLLER_ROLE) whenNotPaused {
        updateReward();

        UserInfo storage info = userInfo[claimaddr];

        // settle current pending distribution
        info.rewardBalance +=
            ((accShare - info.accSharePoint) * info.amount) /
            MULTIPLIER;
        info.amount += amount;
        info.accSharePoint = accShare;

        // update total shares
        totalShares += amount;

        // log
        emit PoolJoined(claimaddr, amount);
    }

    /**
     * @dev Allows a user to leave the rewards vault pool.
     * @param claimaddr The address of the user leaving the pool.
     * @param amount The amount of tokens to be withdrawn from the pool.
     */
    function leaveVault(
        address claimaddr,
        uint256 amount
    ) external override onlyRole(CONTROLLER_ROLE) whenNotPaused {
        updateReward();

        UserInfo storage info = userInfo[claimaddr];
        require(info.amount >= amount, "INSUFFICIENT_AMOUNT");

        // settle current pending distribution
        info.rewardBalance +=
            ((accShare - info.accSharePoint) * info.amount) /
            MULTIPLIER;
        info.amount -= amount;
        info.accSharePoint = accShare;

        // update total shares
        totalShares -= amount;

        // log
        emit PoolLeft(claimaddr, amount);
    }

    /**
     * @dev Allows a user to claim rewards from the rewards vault pool.
     * @param beneficiary The address where the claimed rewards will be sent.
     * @param amount The amount of rewards to be claimed.
     */
    function claimRewards(
        address beneficiary,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        updateReward();

        UserInfo storage info = userInfo[msg.sender];

        // settle current pending distribution
        info.rewardBalance +=
            ((accShare - info.accSharePoint) * info.amount) /
            MULTIPLIER;
        info.accSharePoint = accShare;

        // check
        require(info.rewardBalance >= amount, "INSUFFICIENT_REWARD");

        // account & transfer
        info.rewardBalance -= amount;
        _balanceDecrease(amount);
        payable(beneficiary).sendValue(amount);

        // log
        emit Claimed(beneficiary, amount);
    }

    // claimRewardsFor an account, the rewards will be only be claimed to the claim address for safety
    //  this function plays the role as 'settler for accounts', could only be called by controller contract.
    /**
     * @dev Allows the controller contract to claim rewards on behalf of an account.
    * @param account The address of the account to claim rewards for.
    */
    function claimRewardsFor(
        address account
    ) external nonReentrant whenNotPaused onlyRole(CONTROLLER_ROLE) {
        updateReward();

        UserInfo storage info = userInfo[account];

        // settle current pending distribution
        info.rewardBalance +=
            ((accShare - info.accSharePoint) * info.amount) /
            MULTIPLIER;
        info.accSharePoint = accShare;

        // account & transfer
        uint256 amount = info.rewardBalance;
        info.rewardBalance -= amount;
        _balanceDecrease(amount);
        payable(account).sendValue(amount);

        // log
        emit Claimed(account, amount);
    }

    /**
     * @dev Updates the reward distribution based on the transaction fee.
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
     * @dev Retrieves the total shares accumulated in the contract.
     * @return The total number of shares.
     */
    function getTotalShare() external view returns (uint256) {
        return totalShares;
    }

    /**
     * @dev Retrieves the accounted balance in the contract.
     * @return The accounted balance.
     */
    function getAccountedBalance() external view returns (uint256) {
        return accountedBalance;
    }

    /**
     * @dev Retrieves the pending reward for a specific claim address.
     * @param claimaddr The claim address for which the pending reward is to be retrieved.
     * @return The pending reward for the specified claim address.
    */
    function getPendingReward(
        address claimaddr
    ) external view returns (uint256) {
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
     * @param amount The amount to decrease from the accounted balance.
     */
    function _balanceDecrease(uint256 amount) internal {
        accountedBalance -= amount;
    }

    /**
     * @dev Calculates the pending reward for the manager and the pool.
     * @return managerR The pending reward for the manager.
     * @return poolR The pending reward for the pool.
     */
    function _calcPendingReward()
        internal
        view
        returns (uint256 managerR, uint256 poolR)
    {
        uint256 reward = address(this).balance - accountedBalance;

        // distribute to manager and pool
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
     * @dev Emitted when an address joins the pool by depositing funds.
     * @param claimaddr The address of the user who joined the pool.
     * @param amount The amount deposited by the user.
     */
    event PoolJoined(address claimaddr, uint256 amount);

    /**
     * @dev Emitted when an address leaves the pool by withdrawing funds.
     * @param claimaddr The address of the user who left the pool.
     * @param amount The amount withdrawn by the user.
     */
    event PoolLeft(address claimaddr, uint256 amount);

    /**
     * @dev Emitted when an address claims their reward.
     * @param beneficiary The address of the user who claimed the reward.
     * @param amount The amount of reward claimed by the user.
     */
    event Claimed(address beneficiary, uint256 amount);

    /**
     * @dev Emitted when the manager withdraws their fee from the pool.
     * @param amount The amount of fee withdrawn by the manager.
     * @param to The address where the fee is withdrawn to.
     */
    event ManagerFeeWithdrawed(uint256 amount, address to);

    /**
     * @dev Emitted when the manager fee share is set.
     * @param milli The new manager fee share expressed in milli (1/1000).
     */
    event ManagerFeeSet(uint256 milli);
}
