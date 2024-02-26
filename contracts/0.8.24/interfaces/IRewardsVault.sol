// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IRewardsVault {
    function joinVault(address claimaddr, uint256 amount) external;
    function leaveVault(address claimaddr, uint256 amount) external;
    function claimRewards(address beneficiary, uint256 amount) external;
    function claimRewardsFor(address account) external;
}