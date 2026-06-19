// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";
import {IERC5313} from "@openzeppelin/contracts/interfaces/IERC5313.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";

import {SovereignERC20} from "liquid-editions/SovereignERC20.sol";
import {IERC1046, ISovereignERC20} from "liquid-editions/interfaces/ISovereignERC20.sol";

contract SovereignERC20UnitTest is Test {
    event TokenURIUpdated(string oldTokenURI, string newTokenURI);

    uint256 internal constant OWNER_PK = 0xA11CE;
    address internal owner = vm.addr(OWNER_PK);
    address internal user = makeAddr("user");
    address internal spender = makeAddr("spender");

    SovereignERC20 internal implementation;

    function setUp() public {
        implementation = new SovereignERC20();
    }

    function _deployToken(
        address initialOwner,
        string memory name_,
        string memory symbol_,
        string memory tokenURI_,
        uint256 initialSupply,
        uint256 maxSupply_
    ) internal returns (SovereignERC20 token) {
        token = SovereignERC20(Clones.clone(address(implementation)));
        token.initialize(initialOwner, name_, symbol_, tokenURI_, initialSupply, maxSupply_);
    }

    function _deployDefaultToken() internal returns (SovereignERC20) {
        return _deployToken(owner, "Sovereign Token", "SVG", "ipfs://metadata", 100 ether, 1_000 ether);
    }

    function test_Initialize_SetsCoreState() public {
        SovereignERC20 token = _deployDefaultToken();

        assertEq(token.owner(), owner);
        assertEq(token.name(), "Sovereign Token");
        assertEq(token.symbol(), "SVG");
        assertEq(token.decimals(), 18);
        assertEq(token.tokenURI(), "ipfs://metadata");
        assertEq(token.maxSupply(), 1_000 ether);
        assertEq(token.totalSupply(), 100 ether);
        assertEq(token.balanceOf(owner), 100 ether);
    }

    function test_Initialize_AllowsEmptyTokenURI() public {
        SovereignERC20 token = _deployToken(owner, "Sovereign Token", "SVG", "", 100 ether, 1_000 ether);

        assertEq(token.tokenURI(), "");
    }

    function test_Initialize_AllowsZeroInitialSupply() public {
        SovereignERC20 token = _deployToken(owner, "Sovereign Token", "SVG", "ipfs://metadata", 0, 1_000 ether);

        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(owner), 0);

        vm.prank(owner);
        token.mint(owner, 10 ether);

        assertEq(token.totalSupply(), 10 ether);
        assertEq(token.balanceOf(owner), 10 ether);
    }

    function test_Initialize_RevertsWhenNameEmpty() public {
        SovereignERC20 token = SovereignERC20(Clones.clone(address(implementation)));

        vm.expectRevert(ISovereignERC20.EmptyName.selector);
        token.initialize(owner, "", "SVG", "ipfs://metadata", 0, 0);
    }

    function test_Initialize_RevertsWhenSymbolEmpty() public {
        SovereignERC20 token = SovereignERC20(Clones.clone(address(implementation)));

        vm.expectRevert(ISovereignERC20.EmptySymbol.selector);
        token.initialize(owner, "Sovereign Token", "", "ipfs://metadata", 0, 0);
    }

    function test_Initialize_RevertsWhenMaxSupplyBelowInitialSupply() public {
        SovereignERC20 token = SovereignERC20(Clones.clone(address(implementation)));

        vm.expectRevert(
            abi.encodeWithSelector(ISovereignERC20.MaxSupplyBelowInitialSupply.selector, 99 ether, 100 ether)
        );
        token.initialize(owner, "Sovereign Token", "SVG", "ipfs://metadata", 100 ether, 99 ether);
    }

    function test_Initialize_RevertsWhenOwnerZero() public {
        SovereignERC20 token = SovereignERC20(Clones.clone(address(implementation)));

        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableInvalidOwner.selector, address(0)));
        token.initialize(address(0), "Sovereign Token", "SVG", "ipfs://metadata", 0, 0);
    }

    function test_Initialize_RevertsWhenCalledTwice() public {
        SovereignERC20 token = _deployDefaultToken();

        vm.expectRevert();
        token.initialize(owner, "Again", "AGN", "ipfs://again", 0, 0);
    }

    function test_ImplementationCannotBeInitialized() public {
        vm.expectRevert();
        implementation.initialize(owner, "Sovereign Token", "SVG", "ipfs://metadata", 0, 0);
    }

    function test_SetTokenURI_OwnerOnlyAndEmits() public {
        SovereignERC20 token = _deployDefaultToken();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        token.setTokenURI("ipfs://blocked");

        vm.expectEmit(false, false, false, true, address(token));
        emit TokenURIUpdated("ipfs://metadata", "ipfs://updated");

        vm.prank(owner);
        token.setTokenURI("ipfs://updated");

        assertEq(token.tokenURI(), "ipfs://updated");
    }

    function test_SetTokenURI_AllowsEmptyString() public {
        SovereignERC20 token = _deployDefaultToken();

        vm.prank(owner);
        token.setTokenURI("");

        assertEq(token.tokenURI(), "");
    }

    function test_Mint_OwnerOnly() public {
        SovereignERC20 token = _deployDefaultToken();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        token.mint(user, 1 ether);

        vm.prank(owner);
        token.mint(user, 1 ether);

        assertEq(token.balanceOf(user), 1 ether);
        assertEq(token.totalSupply(), 101 ether);
    }

    function test_Mint_UncappedWhenMaxSupplyIsZero() public {
        SovereignERC20 token = _deployToken(owner, "Sovereign Token", "SVG", "ipfs://metadata", 100 ether, 0);

        vm.prank(owner);
        token.mint(user, 1_000_000 ether);

        assertEq(token.maxSupply(), 0);
        assertEq(token.totalSupply(), 1_000_100 ether);
        assertEq(token.balanceOf(user), 1_000_000 ether);
    }

    function test_Mint_EnforcesMaxSupply() public {
        SovereignERC20 token = _deployToken(owner, "Sovereign Token", "SVG", "ipfs://metadata", 90 ether, 100 ether);

        vm.prank(owner);
        token.mint(user, 10 ether);

        assertEq(token.totalSupply(), 100 ether);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ISovereignERC20.MaxSupplyExceeded.selector, 100 ether, 100 ether, 1));
        token.mint(user, 1);
    }

    function test_Mint_CapUsesCurrentTotalSupplyAfterBurn() public {
        SovereignERC20 token = _deployToken(owner, "Sovereign Token", "SVG", "ipfs://metadata", 100 ether, 100 ether);

        vm.prank(owner);
        token.burn(25 ether);

        vm.prank(owner);
        token.mint(user, 25 ether);

        assertEq(token.totalSupply(), 100 ether);
        assertEq(token.balanceOf(user), 25 ether);
    }

    function test_Mint_RevertsWhenRecipientZero() public {
        SovereignERC20 token = _deployDefaultToken();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.mint(address(0), 1 ether);
    }

    function test_Burn_ReducesBalanceAndTotalSupply() public {
        SovereignERC20 token = _deployDefaultToken();

        vm.prank(owner);
        token.burn(40 ether);

        assertEq(token.balanceOf(owner), 60 ether);
        assertEq(token.totalSupply(), 60 ether);
    }

    function test_BurnFrom_UsesAllowance() public {
        SovereignERC20 token = _deployDefaultToken();

        vm.prank(owner);
        token.approve(spender, 25 ether);

        vm.prank(spender);
        token.burnFrom(owner, 20 ether);

        assertEq(token.balanceOf(owner), 80 ether);
        assertEq(token.totalSupply(), 80 ether);
        assertEq(token.allowance(owner, spender), 5 ether);
    }

    function test_BurnFrom_RevertsWhenAllowanceInsufficient() public {
        SovereignERC20 token = _deployDefaultToken();

        vm.prank(owner);
        token.approve(spender, 5 ether);

        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 5 ether, 6 ether)
        );
        token.burnFrom(owner, 6 ether);
    }

    function test_Permit_WorksWithVersionOneDomain() public {
        SovereignERC20 token = _deployDefaultToken();

        (
            bytes1 fields,
            string memory domainName,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = token.eip712Domain();

        assertEq(uint8(fields), 0x0f);
        assertEq(domainName, "Sovereign Token");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(token));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);

        uint256 value = 42 ether;
        uint256 deadline = block.timestamp + 1 days;
        bytes32 permitTypehash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(abi.encode(permitTypehash, owner, spender, value, token.nonces(owner), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, digest);

        token.permit(owner, spender, value, deadline, v, r, s);

        assertEq(token.allowance(owner, spender), value);
        assertEq(token.nonces(owner), 1);
    }

    function test_RenounceOwnership_FreezesOwnerOnlyActions() public {
        SovereignERC20 token = _deployDefaultToken();

        vm.prank(owner);
        token.renounceOwnership();

        assertEq(token.owner(), address(0));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, owner));
        token.mint(owner, 1 ether);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, owner));
        token.setTokenURI("ipfs://blocked");
    }

    function test_SupportsRelevantInterfaces() public {
        SovereignERC20 token = _deployDefaultToken();

        assertTrue(token.supportsInterface(type(IERC165).interfaceId));
        assertTrue(token.supportsInterface(type(ISovereignERC20).interfaceId));
        assertTrue(token.supportsInterface(type(IERC1046).interfaceId));
        assertTrue(token.supportsInterface(type(IERC20).interfaceId));
        assertTrue(token.supportsInterface(type(IERC20Metadata).interfaceId));
        assertTrue(token.supportsInterface(type(IERC20Permit).interfaceId));
        assertTrue(token.supportsInterface(type(IERC5267).interfaceId));
        assertTrue(token.supportsInterface(type(IERC5313).interfaceId));
        assertFalse(token.supportsInterface(0xffffffff));
    }
}
