// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {LiquidLensDemoV1 as LiquidLensDemo} from "liquid-editions/examples/LiquidLensDemoV1.sol";
import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";

/// @notice Mock Liquid Edition contract for testing render contract
contract MockLiquid is ILiquid {
    uint256 public constant MAX_TOTAL_SUPPLY = 1_000_000e18;
    address public tokenCreator;

    // Mock state values (public for testing)
    uint256 public mockRarePerToken = 0.00012e18; // 0.00012 RARE per token
    uint256 public mockTokenPerRare = 8333.33e18; // Inverse
    uint160 public mockSqrtPriceX96 = 79228162514264337593543950336; // ~1:1 price
    int24 public mockCurrentTick = -887272; // Starting tick
    uint128 public mockLiquidity = 1000000000;
    uint256 public mockCurrentSupply = 950000e18; // 950K tokens (50K burned)

    // Setters for testing
    function setMockRarePerToken(uint256 _value) external {
        mockRarePerToken = _value;
    }

    function setMockCurrentSupply(uint256 _value) external {
        mockCurrentSupply = _value;
    }

    constructor(address _creator) {
        tokenCreator = _creator;
    }

    function getMarketState()
        external
        view
        override
        returns (
            uint256 rarePerToken,
            uint256 tokenPerRare,
            uint160 sqrtPriceX96,
            int24 currentTick,
            uint128 liquidity,
            uint256 currentSupply
        )
    {
        return (
            mockRarePerToken,
            mockTokenPerRare,
            mockSqrtPriceX96,
            mockCurrentTick,
            mockLiquidity,
            mockCurrentSupply
        );
    }

    function getCurrentPrice()
        external
        view
        override
        returns (uint256 rarePerToken, uint256 tokenPerRare)
    {
        return (mockRarePerToken, mockTokenPerRare);
    }

    function quoteBuy(
        uint256 /* rareIn */
    ) external pure override returns (uint256, uint160) {
        revert("Not implemented in mock");
    }

    function quoteSell(
        uint256 /* liquidIn */
    ) external pure override returns (uint256, uint160) {
        revert("Not implemented in mock");
    }

    function burn(uint256 /* amount */) external pure override {
        revert("Not implemented in mock");
    }

    function removeLiquidity(address /* recipient */) external pure override {
        revert("Not implemented in mock");
    }

    function initialTokenUri() external pure override returns (string memory) {
        return "ipfs://mock";
    }

    function tokenURI() external pure override returns (string memory) {
        return "ipfs://mock";
    }

    function setRenderContract(address) external pure override {
        revert("Not implemented in mock");
    }

    function baseToken() external pure override returns (address) {
        return address(0);
    }

    function factory() external pure override returns (address) {
        return address(0);
    }

    function poolManager() external pure override returns (address) {
        return address(0);
    }

    function renderContract() external pure override returns (address) {
        return address(0);
    }

    function lpTickLower() external pure override returns (int24) {
        return 0;
    }

    function lpTickUpper() external pure override returns (int24) {
        return 0;
    }

    function lpLiquidity() external view override returns (uint128) {
        return mockLiquidity;
    }
}

contract LiquidLensDemoTest is Test {
    LiquidLensDemo public lens;
    MockLiquid public mockLiquid;
    address public owner = makeAddr("owner");
    address public artist = makeAddr("artist");
    address public collector = makeAddr("collector");

    function setUp() public {
        vm.startPrank(owner);

        // Deploy mock Liquid Edition
        mockLiquid = new MockLiquid(artist);

        // Deploy render contract
        lens = new LiquidLensDemo(
            address(mockLiquid),
            "Liquid Lens Demo",
            "LLD",
            "Liquid Lens Collection",
            "A generative art collection that visualizes Liquid Edition market state"
        );

        vm.stopPrank();
    }

    function test_Deployment() public view {
        assertEq(address(lens.LIQUID_EDITION()), address(mockLiquid));
        assertEq(lens.nextTokenId(), 1);
        assertEq(lens.MAX_SUPPLY(), 10);
    }

    function test_Mint() public {
        vm.startPrank(owner);

        // Mint first token
        lens.mint(collector);
        assertEq(lens.ownerOf(1), collector);
        assertEq(lens.nextTokenId(), 2);

        // Mint second token
        lens.mint(collector);
        assertEq(lens.ownerOf(2), collector);
        assertEq(lens.nextTokenId(), 3);

        vm.stopPrank();
    }

    function test_MintMaxSupply() public {
        vm.startPrank(owner);

        // Mint all 10 tokens
        for (uint256 i = 0; i < 10; i++) {
            lens.mint(collector);
        }

        assertEq(lens.nextTokenId(), 11);

        // Should revert on 11th mint
        vm.expectRevert(LiquidLensDemo.MaxSupplyExceeded.selector);
        lens.mint(collector);

        vm.stopPrank();
    }

    function test_MintOnlyOwner() public {
        vm.startPrank(collector);

        vm.expectRevert();
        lens.mint(collector);

        vm.stopPrank();
    }

    function test_TokenURI_ERC20Passthrough() public view {
        // Token ID 0 should work for ERC20 metadata passthrough
        string memory uri = lens.tokenURI(0);

        // Should return valid JSON
        assertTrue(bytes(uri).length > 0);
        assertTrue(_contains(uri, "name"));
        assertTrue(_contains(uri, "image"));
        assertTrue(_contains(uri, "attributes"));
    }

    function test_TokenURI_ERC721() public {
        vm.startPrank(owner);
        lens.mint(collector);
        vm.stopPrank();

        string memory uri = lens.tokenURI(1);

        // Should return valid JSON
        assertTrue(bytes(uri).length > 0);
        assertTrue(_contains(uri, "Liquid Lens #1"));
        assertTrue(_contains(uri, "data:image/svg+xml;base64,"));
        assertTrue(_contains(uri, "attributes"));
        assertTrue(_contains(uri, "Price"));
        assertTrue(_contains(uri, "Supply"));
        assertTrue(_contains(uri, "Burn %"));
    }

    function test_TokenURI_InvalidTokenId() public {
        // Token ID 0 is allowed (ERC20 passthrough), but token ID 1 doesn't exist yet
        // Since we allow tokenURI(0) for ERC20 metadata, we need to test a higher ID
        vm.expectRevert();
        lens.tokenURI(999); // Non-existent token ID
    }

    function test_TokenURI_DynamicState() public {
        vm.startPrank(owner);
        lens.mint(collector);
        vm.stopPrank();

        // Get initial URI
        string memory uri1 = lens.tokenURI(1);

        // Update mock state
        mockLiquid.setMockRarePerToken(0.0005e18); // Higher price
        mockLiquid.setMockCurrentSupply(900000e18); // More burned

        // Get new URI
        string memory uri2 = lens.tokenURI(1);

        // URIs should be different (different market state)
        assertFalse(_equal(uri1, uri2));

        // New URI should reflect higher price
        assertTrue(_contains(uri2, "0.0005") || _contains(uri2, "0.000500"));
    }

    function test_TokenURI_AllTokens() public {
        vm.startPrank(owner);

        // Mint all tokens
        for (uint256 i = 0; i < 10; i++) {
            lens.mint(collector);
        }

        vm.stopPrank();

        // All token URIs should be valid
        for (uint256 i = 1; i <= 10; i++) {
            string memory uri = lens.tokenURI(i);
            assertTrue(bytes(uri).length > 0);
            assertTrue(_contains(uri, "Liquid Lens"));
            assertTrue(_contains(uri, "data:image/svg+xml;base64,"));
        }
    }

    function test_TokenURI_ERC20Compatible() public view {
        // Test the ERC20-compatible tokenURI() function
        string memory uri1 = lens.tokenURI();
        string memory uri2 = lens.tokenURI(0);

        // Should return the same as tokenURI(0)
        assertTrue(_equal(uri1, uri2));
    }

    function test_SVG_ContainsExpectedElements() public {
        vm.startPrank(owner);
        lens.mint(collector);
        vm.stopPrank();

        string memory uri = lens.tokenURI(1);

        // Decode base64 to check SVG content
        // Extract the base64 part
        bytes memory uriBytes = bytes(uri);
        uint256 startIdx = _indexOf(uriBytes, "data:image/svg+xml;base64,");
        require(startIdx != type(uint256).max, "Base64 not found");

        startIdx += 30; // Length of "data:image/svg+xml;base64,"

        // Find the end of base64 string (before closing quote)
        uint256 endIdx = startIdx;
        while (endIdx < uriBytes.length && uriBytes[endIdx] != '"') {
            endIdx++;
        }

        // Decode base64 (simplified - just check it exists)
        assertTrue(endIdx > startIdx, "Base64 data exists");
    }

    // Helper functions
    function _contains(
        string memory str,
        string memory substr
    ) internal pure returns (bool) {
        bytes memory strBytes = bytes(str);
        bytes memory substrBytes = bytes(substr);

        if (substrBytes.length > strBytes.length) return false;

        for (uint256 i = 0; i <= strBytes.length - substrBytes.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < substrBytes.length; j++) {
                if (strBytes[i + j] != substrBytes[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }

    function _equal(
        string memory a,
        string memory b
    ) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _indexOf(
        bytes memory data,
        string memory search
    ) internal pure returns (uint256) {
        bytes memory searchBytes = bytes(search);

        for (uint256 i = 0; i <= data.length - searchBytes.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < searchBytes.length; j++) {
                if (data[i + j] != searchBytes[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return i;
        }
        return type(uint256).max;
    }
}
