// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IERC20HolderRewards} from "liquid-editions/interfaces/IERC20HolderRewards.sol";

/// @title ERC20HolderRewards
/// @notice Abstract ERC20 rewards-accounting mixin.
/// @dev Inheriting tokens must call `_holderRewardsAfterTokenTransfer` from their ERC20 transfer hook.
abstract contract ERC20HolderRewards is IERC20HolderRewards, ERC165 {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 internal constant HOLDER_REWARD_SCALE = 1e18;

    /// @notice Factory/config sentinel for same-token rewards. Stored reward token resolves to address(this).
    address public constant SELF_REWARD_TOKEN = address(1);

    address public rewardToken;
    uint256 public accRewardPerEligibleToken;
    uint256 public eligibleSupply;
    uint256 public pendingUndistributedRewards;
    uint256 public accountedRewardBalance;
    uint256 public totalHolderRewardsAccrued;
    uint256 public totalHolderRewardsClaimed;

    mapping(address account => bool excluded) public rewardsExcluded;
    mapping(address account => bool excluded) public systemRewardsExcluded;
    mapping(address account => bool excluded) public ownerRewardsExcluded;
    mapping(address account => int256 correction) public rewardCorrections;
    mapping(address account => uint256 claimed) public claimedRewards;

    bool private _holderRewardsInitialized;
    uint256 private _holderRewardsReentrancyStatus;

    modifier nonReentrantHolderRewards() {
        _nonReentrantHolderRewardsBefore();
        _;
        _nonReentrantHolderRewardsAfter();
    }

    function _nonReentrantHolderRewardsBefore() internal {
        if (_holderRewardsReentrancyStatus == 2) revert HolderRewardsReentrantCall();
        _holderRewardsReentrancyStatus = 2;
    }

    function _nonReentrantHolderRewardsAfter() internal {
        _holderRewardsReentrancyStatus = 1;
    }

    /// @notice One-time reward-token initialization.
    /// @dev Call before minting eligible supply. Preexisting reward-token balance is snapshotted as already accounted.
    function _initializeHolderRewards(address rewardToken_, address[] memory systemExcludedAccounts) internal virtual {
        if (_holderRewardsInitialized) revert HolderRewardsAlreadyInitialized();

        address resolvedRewardToken = rewardToken_ == SELF_REWARD_TOKEN ? address(this) : rewardToken_;
        if (resolvedRewardToken == address(0)) revert HolderRewardsInvalidRewardToken();

        _holderRewardsInitialized = true;
        rewardToken = resolvedRewardToken;

        _excludeRewards(address(0), true);
        _excludeRewards(address(this), true);

        for (uint256 i = 0; i < systemExcludedAccounts.length; i++) {
            _excludeRewards(systemExcludedAccounts[i], true);
        }

        accountedRewardBalance = _rewardBalance();
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC20HolderRewards).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @notice Pull reward tokens from caller and accrue the actual amount received.
    function notifyHolderRewards(uint256 amount) external nonReentrantHolderRewards {
        _syncRewards();

        uint256 balanceBefore = _rewardBalance();
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = _rewardBalance();

        if (balanceAfter <= balanceBefore) revert HolderRewardsZeroAmountReceived();

        uint256 received = balanceAfter - balanceBefore;
        accountedRewardBalance += received;
        totalHolderRewardsAccrued += received;
        _accrueHolderRewards(received);

        emit HolderRewardsNotified(msg.sender, received);
    }

    /// @notice Accrue direct reward-token transfers into holder accounting.
    function syncRewards() external nonReentrantHolderRewards returns (uint256 synced) {
        return _syncRewards();
    }

    /// @notice Claim caller's rewards to `recipient`.
    function claimRewards(address recipient) external nonReentrantHolderRewards returns (uint256 claimed) {
        if (recipient == address(0) || recipient == address(this)) revert HolderRewardsInvalidRecipient();

        _syncRewards();

        claimed = claimableRewards(msg.sender);
        if (claimed == 0) return 0;

        claimedRewards[msg.sender] += claimed;
        totalHolderRewardsClaimed += claimed;

        uint256 balanceBefore = _rewardBalance();
        IERC20(rewardToken).safeTransfer(recipient, claimed);
        uint256 balanceAfter = _rewardBalance();
        uint256 spent = balanceBefore > balanceAfter ? balanceBefore - balanceAfter : 0;

        if (spent >= accountedRewardBalance) {
            accountedRewardBalance = 0;
        } else {
            accountedRewardBalance -= spent;
        }

        emit HolderRewardsClaimed(msg.sender, recipient, claimed);
    }

    function addRewardsExcluded(address account) external {
        _checkHolderRewardsOwner();
        _excludeRewards(account, false);
    }

    function removeRewardsExcluded(address account) external {
        _checkHolderRewardsOwner();
        if (systemRewardsExcluded[account]) revert HolderRewardsSystemExcluded(account);
        _includeRewards(account);
    }

    function claimableRewards(address account) public view returns (uint256) {
        uint256 accumulated = _accumulativeRewardsOf(account);
        uint256 claimed = claimedRewards[account];
        return accumulated > claimed ? accumulated - claimed : 0;
    }

    /// @notice Internal sweep used by reward entry points and claim.
    function _syncRewards() internal virtual returns (uint256 synced) {
        uint256 balance = _rewardBalance();
        uint256 accounted = accountedRewardBalance;

        if (balance <= accounted) {
            _distributePendingRewards();
            return 0;
        }

        synced = balance - accounted;
        accountedRewardBalance = balance;
        totalHolderRewardsAccrued += synced;
        _accrueHolderRewards(synced);

        emit HolderRewardsSynced(synced);
    }

    /// @dev Must be called after the inheriting ERC20 updates balances.
    function _holderRewardsAfterTokenTransfer(address from, address to, uint256 amount) internal virtual {
        if (!_holderRewardsInitialized || amount == 0) return;

        uint256 accumulator = accRewardPerEligibleToken;

        if (from != address(0) && !rewardsExcluded[from]) {
            eligibleSupply -= amount;
            rewardCorrections[from] += _scaledReward(amount, accumulator);
        }

        if (to != address(0) && !rewardsExcluded[to]) {
            eligibleSupply += amount;
            rewardCorrections[to] -= _scaledReward(amount, accumulator);
        }
    }

    function _accrueHolderRewards(uint256 amount) internal virtual {
        pendingUndistributedRewards += amount;
        _distributePendingRewards();
    }

    function _distributePendingRewards() internal virtual {
        uint256 supply = eligibleSupply;
        uint256 pending = pendingUndistributedRewards;
        if (supply == 0 || pending == 0) return;

        uint256 rewardPerToken = Math.mulDiv(pending, HOLDER_REWARD_SCALE, supply);
        if (rewardPerToken == 0) return;

        uint256 distributed = Math.mulDiv(rewardPerToken, supply, HOLDER_REWARD_SCALE);
        if (distributed == 0) return;

        pendingUndistributedRewards = pending - distributed;
        accRewardPerEligibleToken += rewardPerToken;
    }

    function _excludeRewards(address account, bool system) internal virtual {
        if (system) {
            systemRewardsExcluded[account] = true;
        } else {
            ownerRewardsExcluded[account] = true;
        }

        if (rewardsExcluded[account]) return;

        rewardsExcluded[account] = true;

        uint256 balance = _holderRewardsBalanceOf(account);
        if (balance > 0) {
            eligibleSupply -= balance;
            rewardCorrections[account] += _scaledReward(balance, accRewardPerEligibleToken);
        }

        emit RewardsExcluded(account);
    }

    function _includeRewards(address account) internal virtual {
        if (!rewardsExcluded[account]) return;

        rewardsExcluded[account] = false;
        ownerRewardsExcluded[account] = false;

        uint256 balance = _holderRewardsBalanceOf(account);
        if (balance > 0) {
            eligibleSupply += balance;
            rewardCorrections[account] -= _scaledReward(balance, accRewardPerEligibleToken);
        }

        emit RewardsIncluded(account);
        _distributePendingRewards();
    }

    function _accumulativeRewardsOf(address account) internal view virtual returns (uint256) {
        int256 scaledRewards = rewardCorrections[account];

        if (!rewardsExcluded[account]) {
            scaledRewards += _scaledReward(_holderRewardsBalanceOf(account), accRewardPerEligibleToken);
        }

        if (scaledRewards <= 0) return 0;
        return uint256(scaledRewards) / HOLDER_REWARD_SCALE;
    }

    function _scaledReward(uint256 amount, uint256 accumulator) internal pure returns (int256) {
        if (amount == 0 || accumulator == 0) return 0;
        return (amount * accumulator).toInt256();
    }

    function _rewardBalance() internal view returns (uint256) {
        if (rewardToken == address(this)) return _holderRewardsBalanceOf(address(this));
        return IERC20(rewardToken).balanceOf(address(this));
    }

    function _markHolderRewardsBalanceAccounted() internal {
        accountedRewardBalance = _rewardBalance();
    }

    function _holderRewardsBalanceOf(address account) internal view virtual returns (uint256);

    function _checkHolderRewardsOwner() internal view virtual;
}
