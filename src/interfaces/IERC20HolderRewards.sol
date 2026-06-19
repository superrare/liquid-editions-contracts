// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @title IERC20HolderRewards
/// @notice Optional ERC20 extension for permissionless pro rata holder rewards.
interface IERC20HolderRewards {
    event HolderRewardsNotified(address indexed funder, uint256 amount);
    event HolderRewardsSynced(uint256 amount);
    event HolderRewardsClaimed(address indexed account, address indexed recipient, uint256 amount);
    event RewardsExcluded(address indexed account);
    event RewardsIncluded(address indexed account);

    error HolderRewardsAlreadyInitialized();
    error HolderRewardsInvalidRewardToken();
    error HolderRewardsInvalidRecipient();
    error HolderRewardsReentrantCall();
    error HolderRewardsSystemExcluded(address account);
    error HolderRewardsZeroAmountReceived();

    function rewardToken() external view returns (address);
    function accRewardPerEligibleToken() external view returns (uint256);
    function eligibleSupply() external view returns (uint256);
    function pendingUndistributedRewards() external view returns (uint256);
    function accountedRewardBalance() external view returns (uint256);
    function totalHolderRewardsAccrued() external view returns (uint256);
    function totalHolderRewardsClaimed() external view returns (uint256);
    function rewardsExcluded(address account) external view returns (bool);
    function systemRewardsExcluded(address account) external view returns (bool);
    function ownerRewardsExcluded(address account) external view returns (bool);
    function rewardCorrections(address account) external view returns (int256);
    function claimedRewards(address account) external view returns (uint256);
    function claimableRewards(address account) external view returns (uint256);

    function notifyHolderRewards(uint256 amount) external;
    function syncRewards() external returns (uint256 synced);
    function claimRewards(address recipient) external returns (uint256 claimed);
    function addRewardsExcluded(address account) external;
    function removeRewardsExcluded(address account) external;
}
