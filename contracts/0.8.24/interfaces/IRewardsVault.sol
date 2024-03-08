// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// Interface for a rewards vault contract
interface IRewardsVault {
    function joinVault(address claimaddr, uint256 amount) external;   // Function to deposit tokens into the rewards vault
    function leaveVault(address claimaddr, uint256 amount) external;  // Function to withdraw tokens from the rewards vault
    function claimRewards(address beneficiary, uint256 amount) external;  // Function to claim rewards for a specific beneficiary
    function claimRewardsFor(address account) external;  // Function to claim rewards for a specified account
}