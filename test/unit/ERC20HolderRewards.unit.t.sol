// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ERC20HolderRewards} from "liquid-editions/extensions/ERC20HolderRewards.sol";
import {IERC20HolderRewards} from "liquid-editions/interfaces/IERC20HolderRewards.sol";
import {MockERC20, MockFeeOnTransferToken} from "liquid-editions-test/helpers/MockERC20.sol";

contract HolderRewardsHarness is ERC20, Ownable, ERC20HolderRewards {
    constructor(address initialOwner, address rewardToken_, address[] memory systemExcludedAccounts)
        ERC20("Holder Rewards", "HLD")
        Ownable(initialOwner)
    {
        _initializeHolderRewards(rewardToken_, systemExcludedAccounts);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function reinitializeRewards(address rewardToken_) external {
        address[] memory systemExcludedAccounts = new address[](0);
        _initializeHolderRewards(rewardToken_, systemExcludedAccounts);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        _holderRewardsAfterTokenTransfer(from, to, value);
    }

    function _holderRewardsBalanceOf(address account) internal view override returns (uint256) {
        return balanceOf(account);
    }

    function _checkHolderRewardsOwner() internal view override {
        _checkOwner();
    }
}

contract MockZeroReceivedToken is MockERC20 {
    function transferFrom(address from, address, uint256 amount) public override returns (bool) {
        if (allowance[from][msg.sender] >= amount) {
            allowance[from][msg.sender] -= amount;
        } else {
            revert("ERC20: insufficient allowance");
        }

        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
        return true;
    }
}

contract ERC20HolderRewardsUnitTest is Test {
    event HolderRewardsNotified(address indexed funder, uint256 amount);
    event HolderRewardsSynced(uint256 amount);
    event HolderRewardsClaimed(address indexed account, address indexed recipient, uint256 amount);
    event RewardsExcluded(address indexed account);
    event RewardsIncluded(address indexed account);

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal funder = makeAddr("funder");
    address internal systemCustody = makeAddr("systemCustody");

    MockERC20 internal reward;
    HolderRewardsHarness internal token;

    function setUp() public {
        reward = new MockERC20();
        token = _newToken(address(reward));
    }

    function _newToken(address rewardToken_) internal returns (HolderRewardsHarness) {
        address[] memory systemExcludedAccounts = new address[](0);
        return new HolderRewardsHarness(owner, rewardToken_, systemExcludedAccounts);
    }

    function _newTokenWithSystem(address rewardToken_, address systemAccount) internal returns (HolderRewardsHarness) {
        address[] memory systemExcludedAccounts = new address[](1);
        systemExcludedAccounts[0] = systemAccount;
        return new HolderRewardsHarness(owner, rewardToken_, systemExcludedAccounts);
    }

    function _mintDefaultHolders() internal {
        token.mint(alice, 100 ether);
        token.mint(bob, 100 ether);
    }

    function _notify(uint256 amount) internal {
        reward.mint(funder, amount);
        vm.prank(funder);
        reward.approve(address(token), amount);
        vm.prank(funder);
        token.notifyHolderRewards(amount);
    }

    function _assertEligibleSupplyFor(address[] memory accounts) internal view {
        uint256 expected;
        for (uint256 i = 0; i < accounts.length; i++) {
            if (!token.rewardsExcluded(accounts[i])) {
                expected += token.balanceOf(accounts[i]);
            }
        }
        assertEq(token.eligibleSupply(), expected, "eligible supply");
    }

    function test_InitializesRewardTokenAndSystemExclusions() public {
        HolderRewardsHarness withSystem = _newTokenWithSystem(address(reward), systemCustody);

        assertEq(withSystem.rewardToken(), address(reward));
        assertTrue(withSystem.rewardsExcluded(address(0)));
        assertTrue(withSystem.systemRewardsExcluded(address(0)));
        assertTrue(withSystem.rewardsExcluded(address(withSystem)));
        assertTrue(withSystem.systemRewardsExcluded(address(withSystem)));
        assertTrue(withSystem.rewardsExcluded(systemCustody));
        assertTrue(withSystem.systemRewardsExcluded(systemCustody));
        assertTrue(withSystem.supportsInterface(type(IERC20HolderRewards).interfaceId));
    }

    function test_SelfRewardSentinelResolvesToTokenAddress() public {
        HolderRewardsHarness selfReward = _newToken(address(1));

        assertEq(selfReward.rewardToken(), address(selfReward));
        assertTrue(selfReward.rewardsExcluded(address(selfReward)));
        assertTrue(selfReward.systemRewardsExcluded(address(selfReward)));
    }

    function test_RevertWhen_RewardTokenIsNativeEthSentinel() public {
        address[] memory systemExcludedAccounts = new address[](0);

        vm.expectRevert(IERC20HolderRewards.HolderRewardsInvalidRewardToken.selector);
        new HolderRewardsHarness(owner, address(0), systemExcludedAccounts);
    }

    function test_RevertWhen_ReinitializingRewardToken() public {
        vm.expectRevert(IERC20HolderRewards.HolderRewardsAlreadyInitialized.selector);
        token.reinitializeRewards(address(reward));
    }

    function test_NotifyPullsAndAccruesActualReceivedAmount() public {
        MockFeeOnTransferToken feeReward = new MockFeeOnTransferToken();
        HolderRewardsHarness feeToken = _newToken(address(feeReward));
        feeToken.mint(alice, 100 ether);
        feeToken.mint(bob, 100 ether);

        feeReward.mint(funder, 100 ether);
        vm.prank(funder);
        feeReward.approve(address(feeToken), 100 ether);

        vm.expectEmit(true, false, false, true);
        emit HolderRewardsNotified(funder, 99 ether);
        vm.prank(funder);
        feeToken.notifyHolderRewards(100 ether);

        assertEq(feeReward.balanceOf(address(feeToken)), 99 ether);
        assertEq(feeToken.totalHolderRewardsAccrued(), 99 ether);
        assertEq(feeToken.claimableRewards(alice), 49.5 ether);
        assertEq(feeToken.claimableRewards(bob), 49.5 ether);
    }

    function test_RevertWhen_NotifyReceivesZeroRewardTokens() public {
        MockZeroReceivedToken zeroReward = new MockZeroReceivedToken();
        HolderRewardsHarness zeroToken = _newToken(address(zeroReward));
        zeroToken.mint(alice, 100 ether);

        zeroReward.mint(funder, 100 ether);
        vm.prank(funder);
        zeroReward.approve(address(zeroToken), 100 ether);

        vm.expectRevert(IERC20HolderRewards.HolderRewardsZeroAmountReceived.selector);
        vm.prank(funder);
        zeroToken.notifyHolderRewards(100 ether);
    }

    function test_DirectTransfersRequireSyncBeforeAccruing() public {
        _mintDefaultHolders();
        reward.mint(funder, 90 ether);

        vm.prank(funder);
        reward.transfer(address(token), 90 ether);

        assertEq(token.claimableRewards(alice), 0);
        assertEq(token.accountedRewardBalance(), 0);

        vm.expectEmit(false, false, false, true);
        emit HolderRewardsSynced(90 ether);
        uint256 synced = token.syncRewards();

        assertEq(synced, 90 ether);
        assertEq(token.accountedRewardBalance(), 90 ether);
        assertEq(token.claimableRewards(alice), 45 ether);
        assertEq(token.claimableRewards(bob), 45 ether);
    }

    function test_InternalSyncRunsBeforeNotify() public {
        _mintDefaultHolders();
        reward.mint(funder, 90 ether);

        vm.prank(funder);
        reward.transfer(address(token), 60 ether);
        vm.prank(funder);
        reward.approve(address(token), 30 ether);

        vm.prank(funder);
        token.notifyHolderRewards(30 ether);

        assertEq(token.totalHolderRewardsAccrued(), 90 ether);
        assertEq(token.accountedRewardBalance(), 90 ether);
        assertEq(token.claimableRewards(alice), 45 ether);
        assertEq(token.claimableRewards(bob), 45 ether);
    }

    function test_InternalSyncRunsBeforeClaim() public {
        token.mint(alice, 100 ether);
        reward.mint(funder, 50 ether);

        vm.prank(funder);
        reward.transfer(address(token), 50 ether);

        vm.prank(alice);
        uint256 claimed = token.claimRewards(alice);

        assertEq(claimed, 50 ether);
        assertEq(reward.balanceOf(alice), 50 ether);
        assertEq(token.accountedRewardBalance(), 0);
    }

    function test_RewardsBufferWhenEligibleSupplyIsZeroAndDistributeOnlyOnExplicitSync() public {
        _notify(100 ether);

        assertEq(token.accRewardPerEligibleToken(), 0);
        assertEq(token.pendingUndistributedRewards(), 100 ether);
        assertEq(token.claimableRewards(alice), 0);

        token.mint(alice, 10 ether);

        assertEq(token.pendingUndistributedRewards(), 100 ether);
        assertEq(token.claimableRewards(alice), 0);

        assertEq(token.syncRewards(), 0);

        assertEq(token.pendingUndistributedRewards(), 0);
        assertEq(token.claimableRewards(alice), 100 ether);
    }

    function test_BufferedRewardsDoNotAccrueToTransientHolderOnTransfer() public {
        HolderRewardsHarness withSystem = _newTokenWithSystem(address(reward), systemCustody);
        address router = makeAddr("router");

        reward.mint(funder, 100 ether);
        vm.prank(funder);
        reward.approve(address(withSystem), 100 ether);
        vm.prank(funder);
        withSystem.notifyHolderRewards(100 ether);

        withSystem.mint(systemCustody, 10 ether);

        vm.prank(systemCustody);
        withSystem.transfer(router, 10 ether);
        vm.prank(router);
        withSystem.transfer(alice, 10 ether);

        assertEq(withSystem.balanceOf(alice), 10 ether);
        assertEq(withSystem.balanceOf(router), 0);
        assertEq(withSystem.pendingUndistributedRewards(), 100 ether);
        assertEq(withSystem.claimableRewards(router), 0);
        assertEq(withSystem.claimableRewards(alice), 0);

        assertEq(withSystem.syncRewards(), 0);

        assertEq(withSystem.pendingUndistributedRewards(), 0);
        assertEq(withSystem.claimableRewards(router), 0);
        assertEq(withSystem.claimableRewards(alice), 100 ether);
    }

    function test_RoundingDustRollsIntoLaterRewards() public {
        token.mint(alice, 1 ether);
        token.mint(bob, 1 ether);
        token.mint(carol, 1 ether);

        _notify(1 ether);

        assertEq(token.pendingUndistributedRewards(), 1);
        assertEq(token.claimableRewards(alice), 333333333333333333);
        assertEq(token.claimableRewards(bob), 333333333333333333);
        assertEq(token.claimableRewards(carol), 333333333333333333);

        _notify(2);

        assertEq(token.pendingUndistributedRewards(), 0);
        assertEq(token.claimableRewards(alice), 333333333333333334);
        assertEq(token.claimableRewards(bob), 333333333333333334);
        assertEq(token.claimableRewards(carol), 333333333333333334);
    }

    function test_ClaimRewardsUpdatesAccountingAndEmitsBeforeTransferCompletes() public {
        token.mint(alice, 100 ether);
        _notify(40 ether);

        vm.expectEmit(true, true, false, true);
        emit HolderRewardsClaimed(alice, carol, 40 ether);
        vm.prank(alice);
        uint256 claimed = token.claimRewards(carol);

        assertEq(claimed, 40 ether);
        assertEq(token.claimedRewards(alice), 40 ether);
        assertEq(token.totalHolderRewardsClaimed(), 40 ether);
        assertEq(token.accountedRewardBalance(), 0);
        assertEq(reward.balanceOf(carol), 40 ether);
        assertEq(token.claimableRewards(alice), 0);
    }

    function test_RevertWhen_ClaimRecipientIsZero() public {
        token.mint(alice, 100 ether);
        _notify(1 ether);

        vm.expectRevert(IERC20HolderRewards.HolderRewardsInvalidRecipient.selector);
        vm.prank(alice);
        token.claimRewards(address(0));
    }

    function test_RevertWhen_ClaimRecipientIsTokenContract() public {
        token.mint(alice, 100 ether);
        _notify(1 ether);

        vm.expectRevert(IERC20HolderRewards.HolderRewardsInvalidRecipient.selector);
        vm.prank(alice);
        token.claimRewards(address(token));
    }

    function test_SystemExclusionsCannotBeRemoved() public {
        HolderRewardsHarness withSystem = _newTokenWithSystem(address(reward), systemCustody);

        vm.expectRevert(abi.encodeWithSelector(IERC20HolderRewards.HolderRewardsSystemExcluded.selector, systemCustody));
        vm.prank(owner);
        withSystem.removeRewardsExcluded(systemCustody);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20HolderRewards.HolderRewardsSystemExcluded.selector, address(withSystem))
        );
        vm.prank(owner);
        withSystem.removeRewardsExcluded(address(withSystem));
    }

    function test_OwnerManagedExclusionsCanBeAddedAndRemoved() public {
        _mintDefaultHolders();

        vm.expectEmit(true, false, false, true);
        emit RewardsExcluded(bob);
        vm.prank(owner);
        token.addRewardsExcluded(bob);

        assertTrue(token.rewardsExcluded(bob));
        assertTrue(token.ownerRewardsExcluded(bob));
        assertEq(token.eligibleSupply(), 100 ether);

        vm.expectEmit(true, false, false, true);
        emit RewardsIncluded(bob);
        vm.prank(owner);
        token.removeRewardsExcluded(bob);

        assertFalse(token.rewardsExcluded(bob));
        assertFalse(token.ownerRewardsExcluded(bob));
        assertEq(token.eligibleSupply(), 200 ether);
    }

    function test_RevertWhen_NonOwnerManagesExclusions() public {
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        vm.prank(alice);
        token.addRewardsExcluded(bob);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        vm.prank(alice);
        token.removeRewardsExcluded(bob);
    }

    function test_RenounceFreezesOwnerManagedExclusionChanges() public {
        vm.prank(owner);
        token.addRewardsExcluded(bob);

        vm.prank(owner);
        token.renounceOwnership();

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", owner));
        vm.prank(owner);
        token.addRewardsExcluded(bob);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", owner));
        vm.prank(owner);
        token.removeRewardsExcluded(bob);
    }

    function test_ExcludingPreservesEarnedRewardsAndOnlyAffectsFutureAccrual() public {
        _mintDefaultHolders();
        _notify(100 ether);

        assertEq(token.claimableRewards(alice), 50 ether);

        vm.prank(owner);
        token.addRewardsExcluded(alice);

        assertEq(token.eligibleSupply(), 100 ether);
        assertEq(token.claimableRewards(alice), 50 ether);

        _notify(100 ether);

        assertEq(token.claimableRewards(alice), 50 ether);
        assertEq(token.claimableRewards(bob), 150 ether);

        vm.prank(owner);
        token.removeRewardsExcluded(alice);

        assertEq(token.claimableRewards(alice), 50 ether);

        _notify(100 ether);

        assertEq(token.claimableRewards(alice), 100 ether);
        assertEq(token.claimableRewards(bob), 200 ether);
    }

    function test_EligibleTransferPreservesSenderRewardsAndBlocksRecipientHistoricalRewards() public {
        _mintDefaultHolders();
        _notify(100 ether);

        vm.prank(alice);
        token.transfer(carol, 50 ether);

        assertEq(token.claimableRewards(alice), 50 ether);
        assertEq(token.claimableRewards(bob), 50 ether);
        assertEq(token.claimableRewards(carol), 0);

        _notify(100 ether);

        assertEq(token.claimableRewards(alice), 75 ether);
        assertEq(token.claimableRewards(bob), 100 ether);
        assertEq(token.claimableRewards(carol), 25 ether);
    }

    function test_TokensEnteringEligibilityCannotClaimHistoricalRewards() public {
        token.mint(alice, 100 ether);

        vm.prank(owner);
        token.addRewardsExcluded(bob);
        token.mint(bob, 100 ether);

        _notify(100 ether);

        assertEq(token.claimableRewards(alice), 100 ether);
        assertEq(token.claimableRewards(bob), 0);

        vm.prank(owner);
        token.removeRewardsExcluded(bob);

        assertEq(token.claimableRewards(bob), 0);
    }

    function test_TokensLeavingEligibilityKeepPreviouslyEarnedRewards() public {
        _mintDefaultHolders();

        vm.prank(owner);
        token.addRewardsExcluded(carol);

        _notify(100 ether);

        vm.prank(alice);
        token.transfer(carol, 50 ether);

        assertEq(token.claimableRewards(alice), 50 ether);
        assertEq(token.claimableRewards(carol), 0);
        assertEq(token.eligibleSupply(), 150 ether);

        _notify(75 ether);

        assertEq(token.claimableRewards(alice), 75 ether);
        assertEq(token.claimableRewards(bob), 100 ether);
        assertEq(token.claimableRewards(carol), 0);
    }

    function test_SameTokenRewardsClaimFromExcludedContractBalanceWithoutHistoricalRewards() public {
        HolderRewardsHarness selfReward = _newToken(address(1));
        selfReward.mint(alice, 100 ether);
        selfReward.mint(bob, 100 ether);

        vm.prank(alice);
        selfReward.approve(address(selfReward), 100 ether);

        vm.prank(alice);
        selfReward.notifyHolderRewards(100 ether);

        assertEq(selfReward.balanceOf(address(selfReward)), 100 ether);
        assertEq(selfReward.claimableRewards(bob), 100 ether);
        assertEq(selfReward.claimableRewards(alice), 0);
        assertEq(selfReward.eligibleSupply(), 100 ether);

        vm.prank(bob);
        uint256 claimed = selfReward.claimRewards(bob);

        assertEq(claimed, 100 ether);
        assertEq(selfReward.balanceOf(address(selfReward)), 0);
        assertEq(selfReward.balanceOf(bob), 200 ether);
        assertEq(selfReward.claimableRewards(bob), 0);
        assertEq(selfReward.eligibleSupply(), 200 ether);

        vm.prank(bob);
        selfReward.approve(address(selfReward), 100 ether);
        vm.prank(bob);
        selfReward.notifyHolderRewards(100 ether);

        assertEq(selfReward.claimableRewards(bob), 100 ether);
    }

    function test_Invariant_EligibleSupplyEqualsBalancesOfNonExcludedActors() public {
        _mintDefaultHolders();
        token.mint(carol, 25 ether);

        vm.prank(owner);
        token.addRewardsExcluded(bob);
        vm.prank(alice);
        token.transfer(carol, 10 ether);
        vm.prank(owner);
        token.removeRewardsExcluded(bob);
        token.burn(carol, 5 ether);

        address[] memory accounts = new address[](5);
        accounts[0] = alice;
        accounts[1] = bob;
        accounts[2] = carol;
        accounts[3] = address(token);
        accounts[4] = address(0);

        _assertEligibleSupplyFor(accounts);
    }

    function test_Invariant_TotalClaimedPlusClaimableNeverExceedsAccruedRewards() public {
        token.mint(alice, 100 ether);
        token.mint(bob, 100 ether);
        token.mint(carol, 100 ether);

        _notify(101 ether);

        vm.prank(alice);
        token.claimRewards(alice);

        vm.prank(owner);
        token.addRewardsExcluded(carol);

        _notify(50 ether);

        uint256 pendingClaimable =
            token.claimableRewards(alice) + token.claimableRewards(bob) + token.claimableRewards(carol);
        uint256 accounted = token.totalHolderRewardsClaimed() + pendingClaimable + token.pendingUndistributedRewards();

        assertLe(accounted, token.totalHolderRewardsAccrued());
    }

    function test_Invariant_DirectTransfersAndSyncCannotDoubleCountAccountedRewards() public {
        _mintDefaultHolders();
        reward.mint(funder, 100 ether);

        vm.prank(funder);
        reward.transfer(address(token), 100 ether);

        assertEq(token.syncRewards(), 100 ether);
        assertEq(token.syncRewards(), 0);
        assertEq(token.totalHolderRewardsAccrued(), 100 ether);
        assertEq(token.claimableRewards(alice), 50 ether);
        assertEq(token.claimableRewards(bob), 50 ether);
    }
}
