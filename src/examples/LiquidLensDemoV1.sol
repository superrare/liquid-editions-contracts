// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// forge-lint: disable-start(unsafe-typecast) -- safe: rendering code uses bounded values (randVal % N, etc).

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {LiquidInstant} from "liquid-editions/LiquidInstant.sol";

/// @title LiquidLensDemo
/// @notice Art Blocks-inspired generative art NFTs that visualize Liquid Edition market state.
///         Each token generates unique artwork based on tokenId and current market conditions.
/// @dev Hybrid visual style: Concentric rings (Meridian-inspired) + Grid subdivisions (QQL-inspired)
///      with sophisticated muted color palettes. All rendering is on-chain SVG.
contract LiquidLensDemoV1 is ERC721, Ownable {
    /// @notice The linked Liquid Edition contract
    address public immutable LIQUID_EDITION;

    /// @notice Maximum number of NFTs that can be minted (small collection: 10)
    uint256 public constant MAX_SUPPLY = 10;

    /// @notice Next token ID to mint (starts at 1, reserving 0 for ERC20 metadata)
    uint256 public nextTokenId = 1;

    /// @notice Collection name for metadata
    string public collectionName;

    /// @notice Collection description for metadata
    string public collectionDescription;

    /// @notice Error thrown when trying to mint beyond max supply
    error MaxSupplyExceeded();

    /// @notice Error thrown when Liquid Edition address is zero
    error InvalidLiquidEdition();

    /// @notice Constructor
    /// @param _liquidEdition Address of the Liquid Edition contract to read state from
    /// @param _name ERC721 token name
    /// @param _symbol ERC721 token symbol
    /// @param _collectionName Name of the collection for metadata
    /// @param _collectionDescription Description of the collection for metadata
    constructor(
        address _liquidEdition,
        string memory _name,
        string memory _symbol,
        string memory _collectionName,
        string memory _collectionDescription
    ) ERC721(_name, _symbol) Ownable(msg.sender) {
        if (_liquidEdition == address(0)) revert InvalidLiquidEdition();
        LIQUID_EDITION = _liquidEdition;
        collectionName = _collectionName;
        collectionDescription = _collectionDescription;
    }

    /// @notice Mint a new NFT (owner-only)
    /// @param to Address to mint the NFT to
    function mint(address to) external onlyOwner {
        if (nextTokenId > MAX_SUPPLY) revert MaxSupplyExceeded();
        _safeMint(to, nextTokenId);
        nextTokenId++;
    }

    /// @notice ERC721 tokenURI function - returns JSON metadata with dynamic SVG
    /// @param tokenId The token ID (0-10, where 0 is reserved for ERC20 metadata passthrough)
    /// @return JSON metadata string with base64-encoded SVG image
    function tokenURI(
        uint256 tokenId
    ) public view override returns (string memory) {
        // Token ID 0 is reserved for ERC20 metadata passthrough
        // For other tokens, validate existence
        if (tokenId > 0) {
            if (tokenId >= nextTokenId) {
                revert ERC721NonexistentToken(tokenId);
            }
            _requireOwned(tokenId);
        }

        // Fetch market state from Liquid Edition
        (
            uint256 rarePerToken,
            ,
            uint160 sqrtPriceX96,
            int24 currentTick,
            uint128 liquidity,
            uint256 currentSupply
        ) = ILiquid(LIQUID_EDITION).getMarketState();

        // Get static configuration
        uint256 maxTotalSupply = LiquidInstant(LIQUID_EDITION)
            .MAX_TOTAL_SUPPLY();

        // Calculate derived metrics for metadata
        DerivedMetrics memory metrics = _calculateDerivedMetrics(
            rarePerToken,
            currentSupply,
            maxTotalSupply,
            currentTick,
            liquidity,
            sqrtPriceX96
        );

        // Generate SVG artwork with market state influence
        string memory svg = _generateSVG(
            tokenId,
            rarePerToken,
            currentSupply,
            maxTotalSupply,
            currentTick,
            liquidity
        );

        // Get palette name for metadata
        string memory paletteName = _getPaletteName(tokenId);

        // Generate JSON metadata with both artistic and market state attributes
        return _generateMetadataJSON(tokenId, paletteName, metrics, svg);
    }

    /// @notice ERC20-compatible tokenURI() for passthrough to Liquid Edition
    /// @dev Returns tokenURI(0) which represents the base ERC20 artwork
    /// @return JSON metadata string
    function tokenURI() external view returns (string memory) {
        return tokenURI(0);
    }

    // ============================================================
    //                     DERIVED METRICS
    // ============================================================

    /// @notice Derived metrics calculated from raw market state
    struct DerivedMetrics {
        uint256 burnPercentage; // Percentage of supply burned (0-100)
        uint256 bondingProgress; // Progress along bonding curve (0-100)
        uint256 marketCap; // Market cap in RARE (totalSupply * rarePerToken)
        uint256 fdv; // Fully diluted valuation (MAX_TOTAL_SUPPLY * rarePerToken)
        string priceFormatted; // Human-readable price string
        string supplyFormatted; // Human-readable supply string
    }

    /// @notice Calculate derived metrics from raw market state
    /// @param rarePerToken Price in RARE per token
    /// @param currentSupply Current token supply
    /// @param maxTotalSupply Maximum total supply
    /// @param currentTick Current pool tick
    /// @return metrics Struct containing all derived metrics
    function _calculateDerivedMetrics(
        uint256 rarePerToken,
        uint256 currentSupply,
        uint256 maxTotalSupply,
        int24 currentTick,
        uint128 /* liquidity */,
        uint160 /* sqrtPriceX96 */
    ) internal pure returns (DerivedMetrics memory metrics) {
        // Calculate burn percentage
        uint256 burned = maxTotalSupply - currentSupply;
        metrics.burnPercentage = (burned * 100) / maxTotalSupply;

        // Calculate bonding curve progress (simplified - assumes tick range from factory)
        // Shift tick to positive range safely
        int256 tick256 = int256(int24(currentTick));
        int256 shiftedTick = tick256 + 887272;
        // forge-lint: disable-next-line(unsafe-typecast) -- safe: shiftedTick >= 0 guards non-negative
        uint256 normalizedTick = shiftedTick >= 0 ? uint256(shiftedTick) : 0;
        metrics.bondingProgress = normalizedTick % 101; // 0-100

        // Calculate market cap (currentSupply * price)
        metrics.marketCap = (currentSupply * rarePerToken) / 1e18;

        // Calculate FDV (maxSupply * price)
        metrics.fdv = (maxTotalSupply * rarePerToken) / 1e18;

        // Format price (RARE per token with 6 decimal places)
        metrics.priceFormatted = _formatDecimal(rarePerToken, 6);

        // Format supply (with 0 decimal places, divide by 1e18)
        metrics.supplyFormatted = _formatDecimal(currentSupply, 0);
    }

    /// @notice Format a wei value as a decimal string
    /// @param value Value in wei
    /// @param decimals Number of decimal places to show
    /// @return Formatted string
    function _formatDecimal(
        uint256 value,
        uint256 decimals
    ) internal pure returns (string memory) {
        if (value == 0) return "0";

        uint256 divisor = 10 ** (18 - decimals);
        uint256 wholePart = value / 1e18;
        uint256 fractionalPart = (value / divisor) % (10 ** decimals);

        if (fractionalPart == 0) {
            return _uintToString(wholePart);
        }

        // Format with leading zeros for fractional part
        string memory fractionalStr = _uintToString(fractionalPart);
        uint256 fractionalLen = decimals;
        while (bytes(fractionalStr).length < fractionalLen) {
            fractionalStr = string(abi.encodePacked("0", fractionalStr));
        }

        return
            string(
                abi.encodePacked(_uintToString(wholePart), ".", fractionalStr)
            );
    }

    // ============================================================
    //                     PRNG SYSTEM
    // ============================================================

    /// @notice Generate next random value from seed using keccak256 chaining
    /// @param seed Current seed value
    /// @return value Random value derived from seed
    /// @return nextSeed New seed for next random call
    function _nextRandom(
        uint256 seed
    ) internal pure returns (uint256 value, uint256 nextSeed) {
        nextSeed = uint256(keccak256(abi.encodePacked(seed)));
        value = nextSeed;
    }

    /// @notice Create master seed combining tokenId and market state
    /// @param tokenId Token ID for base randomness
    /// @param rarePerToken Price for market influence
    /// @param currentSupply Supply for density influence
    /// @param currentTick Tick for rotation influence
    /// @return Master seed for all visual generation
    function _createMasterSeed(
        uint256 tokenId,
        uint256 rarePerToken,
        uint256 currentSupply,
        int24 currentTick
    ) internal pure returns (uint256) {
        return
            uint256(
                keccak256(
                    abi.encodePacked(
                        tokenId,
                        rarePerToken,
                        currentSupply,
                        currentTick
                    )
                )
            );
    }

    // ============================================================
    //                     COLOR PALETTE SYSTEM
    // ============================================================

    /// @notice Get color palette for a token (8 sophisticated palettes)
    /// @param tokenId Token ID to select palette
    /// @return colors Array of 5 hex color strings [bg, primary, secondary, accent, highlight]
    function _getPalette(
        uint256 tokenId
    ) internal pure returns (string[5] memory colors) {
        uint256 paletteId = tokenId % 8;

        if (paletteId == 0) {
            // Dusk - muted purple/rose
            colors = ["1a1a2e", "4a4e69", "9a8c98", "c9ada7", "f2e9e4"];
        } else if (paletteId == 1) {
            // Ocean - deep blue/grey
            colors = ["0d1b2a", "1b263b", "415a77", "778da9", "e0e1dd"];
        } else if (paletteId == 2) {
            // Forest - dark green/sage
            colors = ["1b2021", "2d3a3a", "4a5759", "7d8a7d", "b8c4b8"];
        } else if (paletteId == 3) {
            // Ember - warm brown/copper
            colors = ["1c1917", "292524", "57534e", "a8a29e", "d4a574"];
        } else if (paletteId == 4) {
            // Mineral - cool grey/silver
            colors = ["18181b", "27272a", "52525b", "a1a1aa", "d4d4d8"];
        } else if (paletteId == 5) {
            // Fog - blue-grey/lavender
            colors = ["1e1e24", "2d2d36", "4b4b5c", "8b8b9e", "d1d1e0"];
        } else if (paletteId == 6) {
            // Slate - navy/steel
            colors = ["0f172a", "1e293b", "334155", "64748b", "94a3b8"];
        } else {
            // Terra - earth brown/sand
            colors = ["1c1715", "2e2420", "4d3d32", "8b7355", "c4a77d"];
        }
    }

    /// @notice Get palette name for metadata
    /// @param tokenId Token ID
    /// @return Palette name string
    function _getPaletteName(
        uint256 tokenId
    ) internal pure returns (string memory) {
        uint256 paletteId = tokenId % 8;
        if (paletteId == 0) return "Dusk";
        if (paletteId == 1) return "Ocean";
        if (paletteId == 2) return "Forest";
        if (paletteId == 3) return "Ember";
        if (paletteId == 4) return "Mineral";
        if (paletteId == 5) return "Fog";
        if (paletteId == 6) return "Slate";
        return "Terra";
    }

    // ============================================================
    //                     UTILITY FUNCTIONS
    // ============================================================

    /// @notice Convert uint256 to string
    /// @param value The value to convert
    /// @return String representation
    function _uintToString(
        uint256 value
    ) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            // forge-lint: disable-next-line(unsafe-typecast) -- safe: value % 10 is 0-9, 48+9=57 fits uint8
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    /// @notice Convert int256 to string (handles negative)
    /// @param value The value to convert
    /// @return String representation
    function _intToString(int256 value) internal pure returns (string memory) {
        if (value >= 0) {
            // forge-lint: disable-next-line(unsafe-typecast) -- safe: value >= 0
            return _uintToString(uint256(value));
        }
        // forge-lint: disable-next-line(unsafe-typecast) -- safe: -value is positive when value < 0
        return string(abi.encodePacked("-", _uintToString(uint256(-value))));
    }

    // ============================================================
    //                     ARC GENERATION
    // ============================================================

    /// @notice Generate concentric arcs layer (20-30 arcs)
    /// @param seed Random seed
    /// @param tickOffset Tick value for rotation influence
    /// @param priceMultiplier Price for stroke weight influence (1-3x)
    /// @param palette Color palette
    /// @return SVG string for all arcs
    function _generateConcentricArcs(
        uint256 seed,
        int24 tickOffset,
        uint256 priceMultiplier,
        string[5] memory palette
    ) internal pure returns (string memory) {
        string memory arcs = '<g fill="none" stroke-linecap="round">';

        // Base rotation from tick (convert to degrees 0-360)
        int256 baseRotation = int256(tickOffset) % 360;
        if (baseRotation < 0) baseRotation += 360;

        // Generate 24 arcs with varying parameters
        uint256 currentSeed = seed;
        for (uint256 i = 0; i < 24; i++) {
            uint256 randVal;
            (randVal, currentSeed) = _nextRandom(currentSeed);

            // Radius: 30 to 180px
            uint256 radius = 30 + (randVal % 151);

            (randVal, currentSeed) = _nextRandom(currentSeed);
            // Stroke width: 1 to 12px, influenced by price
            uint256 baseStroke = 1 + (randVal % 8);
            uint256 strokeWidth = (baseStroke * priceMultiplier) / 100;
            if (strokeWidth < 1) strokeWidth = 1;
            if (strokeWidth > 15) strokeWidth = 15;

            (randVal, currentSeed) = _nextRandom(currentSeed);
            // Arc length: 45 to 300 degrees
            uint256 arcLength = 45 + (randVal % 256);

            (randVal, currentSeed) = _nextRandom(currentSeed);
            // Rotation: 0 to 360 degrees, offset by tick
            // forge-lint: disable-next-line(unsafe-typecast) -- safe: randVal % 360 and i*15 fit int256
            int256 rotation = int256(randVal % 360) +
                baseRotation +
                int256(i * 15);

            (randVal, currentSeed) = _nextRandom(currentSeed);
            // Color from palette (indices 1-4)
            uint256 colorIdx = 1 + (randVal % 4);
            string memory color = palette[colorIdx];

            (randVal, currentSeed) = _nextRandom(currentSeed);
            // Dash pattern: 0=solid, 1=dashed, 2=dotted
            uint256 dashType = randVal % 3;

            (randVal, currentSeed) = _nextRandom(currentSeed);
            // Opacity: 0.3 to 0.9
            uint256 opacity = 30 + (randVal % 60);

            // Generate arc SVG
            arcs = string(
                abi.encodePacked(
                    arcs,
                    _generateSingleArc(
                        radius,
                        strokeWidth,
                        arcLength,
                        rotation,
                        color,
                        dashType,
                        opacity
                    )
                )
            );
        }

        arcs = string(abi.encodePacked(arcs, "</g>"));
        return arcs;
    }

    /// @notice Generate a single arc path
    /// @param radius Arc radius from center
    /// @param strokeWidth Stroke width in pixels
    /// @param arcLength Arc length in degrees
    /// @param rotation Rotation offset in degrees
    /// @param color Hex color (without #)
    /// @param dashType 0=solid, 1=dashed, 2=dotted
    /// @param opacity Opacity 0-100
    /// @return SVG path element
    function _generateSingleArc(
        uint256 radius,
        uint256 strokeWidth,
        uint256 arcLength,
        int256 rotation,
        string memory color,
        uint256 dashType,
        uint256 opacity
    ) internal pure returns (string memory) {
        // Calculate start and end angles
        // Start at rotation, end at rotation + arcLength
        // We'll use a circle with stroke-dasharray to create the arc effect

        string memory dashArray = "";
        if (dashType == 1) {
            // Dashed
            dashArray = string(
                abi.encodePacked(
                    ' stroke-dasharray="',
                    _uintToString(20 + (strokeWidth * 2)),
                    " ",
                    _uintToString(10 + strokeWidth),
                    '"'
                )
            );
        } else if (dashType == 2) {
            // Dotted
            dashArray = string(
                abi.encodePacked(
                    ' stroke-dasharray="',
                    _uintToString(strokeWidth),
                    " ",
                    _uintToString(strokeWidth * 2),
                    '"'
                )
            );
        }

        // Calculate circumference and dash offset for arc
        // circumference = 2 * π * r ≈ 6.28 * r
        uint256 circumference = (radius * 628) / 100;
        uint256 arcPortion = (circumference * arcLength) / 360;
        uint256 gapPortion = circumference - arcPortion;

        // Build the arc as a circle with stroke-dasharray
        string memory arc = string(
            abi.encodePacked(
                '<circle cx="200" cy="200" r="',
                _uintToString(radius),
                '" stroke="#',
                color,
                '" stroke-width="',
                _uintToString(strokeWidth),
                '" opacity="0.',
                _uintToString(opacity),
                '"'
            )
        );

        // Add arc-specific dasharray (overrides dashType for partial circle)
        if (arcLength < 360) {
            arc = string(
                abi.encodePacked(
                    arc,
                    ' stroke-dasharray="',
                    _uintToString(arcPortion),
                    " ",
                    _uintToString(gapPortion),
                    '"'
                )
            );
        } else if (bytes(dashArray).length > 0) {
            arc = string(abi.encodePacked(arc, dashArray));
        }

        // Add rotation transform
        arc = string(
            abi.encodePacked(
                arc,
                ' transform="rotate(',
                _intToString(rotation),
                ' 200 200)"/>'
            )
        );

        return arc;
    }

    // ============================================================
    //                     GRID GENERATION
    // ============================================================

    /// @notice Generate grid cells layer with geometric fills
    /// @param seed Random seed
    /// @param gridSize Grid dimensions (6-10)
    /// @param palette Color palette
    /// @return SVG string for grid cells
    function _generateGridCells(
        uint256 seed,
        uint256 gridSize,
        string[5] memory palette
    ) internal pure returns (string memory) {
        string memory cells = '<g opacity="0.25">';
        uint256 cellSize = 400 / gridSize;
        uint256 currentSeed = seed;

        for (uint256 row = 0; row < gridSize; row++) {
            for (uint256 col = 0; col < gridSize; col++) {
                uint256 randVal;
                (randVal, currentSeed) = _nextRandom(currentSeed);

                // 40% chance to draw a shape in this cell
                if (randVal % 100 < 40) {
                    uint256 x = col * cellSize;
                    uint256 y = row * cellSize;

                    (randVal, currentSeed) = _nextRandom(currentSeed);
                    // Shape type: 0=circle, 1=rect, 2=quarter-arc, 3=triangle
                    uint256 shapeType = randVal % 4;

                    (randVal, currentSeed) = _nextRandom(currentSeed);
                    // Color from palette (1-3)
                    uint256 colorIdx = 1 + (randVal % 3);
                    string memory color = palette[colorIdx];

                    (randVal, currentSeed) = _nextRandom(currentSeed);
                    // Opacity 15-40
                    uint256 opacity = 15 + (randVal % 26);

                    cells = string(
                        abi.encodePacked(
                            cells,
                            _generateGridShape(
                                x,
                                y,
                                cellSize,
                                shapeType,
                                color,
                                opacity
                            )
                        )
                    );
                }
            }
        }

        cells = string(abi.encodePacked(cells, "</g>"));
        return cells;
    }

    /// @notice Generate a single grid shape
    /// @param x X position
    /// @param y Y position
    /// @param size Cell size
    /// @param shapeType 0=circle, 1=rect, 2=quarter-arc, 3=triangle
    /// @param color Hex color
    /// @param opacity Opacity 0-100
    /// @return SVG element
    function _generateGridShape(
        uint256 x,
        uint256 y,
        uint256 size,
        uint256 shapeType,
        string memory color,
        uint256 opacity
    ) internal pure returns (string memory) {
        if (shapeType == 0) {
            // Circle inscribed in cell
            uint256 cx = x + size / 2;
            uint256 cy = y + size / 2;
            uint256 r = (size * 40) / 100; // 80% of half-size
            return
                string(
                    abi.encodePacked(
                        '<circle cx="',
                        _uintToString(cx),
                        '" cy="',
                        _uintToString(cy),
                        '" r="',
                        _uintToString(r),
                        '" fill="#',
                        color,
                        '" opacity="0.',
                        _uintToString(opacity),
                        '"/>'
                    )
                );
        } else if (shapeType == 1) {
            // Rectangle with slight inset
            uint256 inset = size / 10;
            return
                string(
                    abi.encodePacked(
                        '<rect x="',
                        _uintToString(x + inset),
                        '" y="',
                        _uintToString(y + inset),
                        '" width="',
                        _uintToString(size - inset * 2),
                        '" height="',
                        _uintToString(size - inset * 2),
                        '" fill="#',
                        color,
                        '" opacity="0.',
                        _uintToString(opacity),
                        '"/>'
                    )
                );
        } else if (shapeType == 2) {
            // Quarter arc (fan shape)
            uint256 r = (size * 90) / 100;
            return
                string(
                    abi.encodePacked(
                        '<path d="M',
                        _uintToString(x),
                        ",",
                        _uintToString(y),
                        " L",
                        _uintToString(x + r),
                        ",",
                        _uintToString(y),
                        " A",
                        _uintToString(r),
                        ",",
                        _uintToString(r),
                        " 0 0 1 ",
                        _uintToString(x),
                        ",",
                        _uintToString(y + r),
                        ' Z" fill="#',
                        color,
                        '" opacity="0.',
                        _uintToString(opacity),
                        '"/>'
                    )
                );
        } else {
            // Triangle
            uint256 x1 = x + size / 2;
            uint256 y1 = y + size / 10;
            uint256 x2 = x + size / 10;
            uint256 y2 = y + (size * 90) / 100;
            uint256 x3 = x + (size * 90) / 100;
            uint256 y3 = y + (size * 90) / 100;
            return
                string(
                    abi.encodePacked(
                        '<polygon points="',
                        _uintToString(x1),
                        ",",
                        _uintToString(y1),
                        " ",
                        _uintToString(x2),
                        ",",
                        _uintToString(y2),
                        " ",
                        _uintToString(x3),
                        ",",
                        _uintToString(y3),
                        '" fill="#',
                        color,
                        '" opacity="0.',
                        _uintToString(opacity),
                        '"/>'
                    )
                );
        }
    }

    // ============================================================
    //                     TEXTURE & EFFECTS
    // ============================================================

    /// @notice Generate noise texture pattern for grain effect
    /// @param seed Random seed for dot positions
    /// @return SVG defs and rect for noise overlay
    function _generateNoiseTexture(
        uint256 seed
    ) internal pure returns (string memory) {
        // Create a pattern with small semi-transparent dots
        string memory dots = "";
        uint256 currentSeed = seed;

        // Generate 50 random dots in a 20x20 pattern tile
        for (uint256 i = 0; i < 50; i++) {
            uint256 randVal;
            (randVal, currentSeed) = _nextRandom(currentSeed);
            uint256 x = randVal % 20;
            (randVal, currentSeed) = _nextRandom(currentSeed);
            uint256 y = randVal % 20;
            (randVal, currentSeed) = _nextRandom(currentSeed);
            uint256 opacity = 5 + (randVal % 10); // 0.05 - 0.15

            // Format opacity as two digits (05-14)
            string memory opacityStr = opacity < 10
                ? string(abi.encodePacked("0", _uintToString(opacity)))
                : _uintToString(opacity);

            dots = string(
                abi.encodePacked(
                    dots,
                    '<circle cx="',
                    _uintToString(x),
                    '" cy="',
                    _uintToString(y),
                    '" r="0.5" fill="#fff" opacity="0.',
                    opacityStr,
                    '"/>'
                )
            );
        }

        return
            string(
                abi.encodePacked(
                    '<pattern id="noise" width="20" height="20" patternUnits="userSpaceOnUse">',
                    dots,
                    "</pattern>"
                )
            );
    }

    /// @notice Generate flow lines for subtle movement
    /// @param seed Random seed
    /// @param direction Direction influenced by tick (-180 to 180)
    /// @param color Hex color for lines
    /// @return SVG group with flow lines
    function _generateFlowLines(
        uint256 seed,
        int256 direction,
        string memory color
    ) internal pure returns (string memory) {
        string memory lines = string(
            abi.encodePacked(
                '<g stroke="#',
                color,
                '" stroke-width="0.5" fill="none" opacity="0.3">'
            )
        );

        uint256 currentSeed = seed;

        // Generate 20 curved flow lines
        for (uint256 i = 0; i < 20; i++) {
            uint256 randVal;
            (randVal, currentSeed) = _nextRandom(currentSeed);

            // Starting point
            uint256 startX = randVal % 400;
            (randVal, currentSeed) = _nextRandom(currentSeed);
            uint256 startY = randVal % 400;

            // Control point offset based on direction
            (randVal, currentSeed) = _nextRandom(currentSeed);
            int256 ctrlOffset = int256(50 + (randVal % 100));

            // Calculate control point (safe: startX/startY from randVal % 400 fit int256)
            // forge-lint: disable-next-line(unsafe-typecast)
            int256 ctrlX = int256(startX) + (ctrlOffset * direction) / 180;
            // forge-lint: disable-next-line(unsafe-typecast)
            int256 ctrlY = int256(startY) + ctrlOffset;

            // End point
            (randVal, currentSeed) = _nextRandom(currentSeed);
            int256 endOffset = int256(100 + (randVal % 150));
            // forge-lint: disable-next-line(unsafe-typecast)
            int256 endX = int256(startX) + (endOffset * direction) / 90;
            // forge-lint: disable-next-line(unsafe-typecast)
            int256 endY = int256(startY) +
                (endOffset * (180 - _abs(direction))) /
                180;

            // Clamp values to canvas
            ctrlX = _clamp(ctrlX, 0, 400);
            ctrlY = _clamp(ctrlY, 0, 400);
            endX = _clamp(endX, 0, 400);
            endY = _clamp(endY, 0, 400);

            lines = string(
                abi.encodePacked(
                    lines,
                    '<path d="M',
                    _uintToString(startX),
                    ",",
                    _uintToString(startY),
                    " Q",
                    _intToString(ctrlX),
                    ",",
                    _intToString(ctrlY),
                    " ",
                    _intToString(endX),
                    ",",
                    _intToString(endY),
                    '"/>'
                )
            );
        }

        lines = string(abi.encodePacked(lines, "</g>"));
        return lines;
    }

    /// @notice Generate accent shapes (floating geometric elements)
    /// @param seed Random seed
    /// @param shapeCount Number of shapes (4-8)
    /// @param palette Color palette
    /// @return SVG group with accent shapes
    function _generateAccentShapes(
        uint256 seed,
        uint256 shapeCount,
        string[5] memory palette
    ) internal pure returns (string memory) {
        string memory shapes = "<g>";
        uint256 currentSeed = seed;

        for (uint256 i = 0; i < shapeCount; i++) {
            uint256 randVal;
            (randVal, currentSeed) = _nextRandom(currentSeed);

            // Position in corners/edges (avoid center)
            uint256 x;
            uint256 y;
            uint256 quadrant = randVal % 4;
            (randVal, currentSeed) = _nextRandom(currentSeed);

            if (quadrant == 0) {
                // Top-left
                x = 20 + (randVal % 80);
                (randVal, currentSeed) = _nextRandom(currentSeed);
                y = 20 + (randVal % 80);
            } else if (quadrant == 1) {
                // Top-right
                x = 300 + (randVal % 80);
                (randVal, currentSeed) = _nextRandom(currentSeed);
                y = 20 + (randVal % 80);
            } else if (quadrant == 2) {
                // Bottom-left
                x = 20 + (randVal % 80);
                (randVal, currentSeed) = _nextRandom(currentSeed);
                y = 300 + (randVal % 80);
            } else {
                // Bottom-right
                x = 300 + (randVal % 80);
                (randVal, currentSeed) = _nextRandom(currentSeed);
                y = 300 + (randVal % 80);
            }

            (randVal, currentSeed) = _nextRandom(currentSeed);
            // Size 15-50
            uint256 size = 15 + (randVal % 36);

            (randVal, currentSeed) = _nextRandom(currentSeed);
            // Shape: 0=circle, 1=rounded rect
            uint256 shapeType = randVal % 2;

            (randVal, currentSeed) = _nextRandom(currentSeed);
            // Color from accent/highlight (3-4)
            uint256 colorIdx = 3 + (randVal % 2);
            string memory color = palette[colorIdx];

            (randVal, currentSeed) = _nextRandom(currentSeed);
            // Opacity 30-70
            uint256 opacity = 30 + (randVal % 41);

            if (shapeType == 0) {
                shapes = string(
                    abi.encodePacked(
                        shapes,
                        '<circle cx="',
                        _uintToString(x),
                        '" cy="',
                        _uintToString(y),
                        '" r="',
                        _uintToString(size / 2),
                        '" fill="#',
                        color,
                        '" opacity="0.',
                        _uintToString(opacity),
                        '"/>'
                    )
                );
            } else {
                uint256 rx = size / 5; // Rounded corners
                shapes = string(
                    abi.encodePacked(
                        shapes,
                        '<rect x="',
                        _uintToString(x - size / 2),
                        '" y="',
                        _uintToString(y - size / 2),
                        '" width="',
                        _uintToString(size),
                        '" height="',
                        _uintToString(size),
                        '" rx="',
                        _uintToString(rx),
                        '" fill="#',
                        color,
                        '" opacity="0.',
                        _uintToString(opacity),
                        '"/>'
                    )
                );
            }
        }

        shapes = string(abi.encodePacked(shapes, "</g>"));
        return shapes;
    }

    /// @notice Absolute value helper
    function _abs(int256 x) internal pure returns (int256) {
        return x >= 0 ? x : -x;
    }

    /// @notice Clamp value to range
    function _clamp(
        int256 val,
        int256 minVal,
        int256 maxVal
    ) internal pure returns (int256) {
        if (val < minVal) return minVal;
        if (val > maxVal) return maxVal;
        return val;
    }

    // ============================================================
    //                     MAIN SVG COMPOSER
    // ============================================================

    /// @notice Generate complete SVG artwork
    /// @param tokenId Token ID for unique seed
    /// @param rarePerToken Price for stroke weight influence
    /// @param currentSupply Supply for grid density
    /// @param maxTotalSupply Max supply for calculations
    /// @param currentTick Tick for rotation/direction
    /// @param liquidity Liquidity for shape count
    /// @return Complete SVG string
    function _generateSVG(
        uint256 tokenId,
        uint256 rarePerToken,
        uint256 currentSupply,
        uint256 maxTotalSupply,
        int24 currentTick,
        uint128 liquidity
    ) internal pure returns (string memory) {
        // Get color palette for this token
        string[5] memory palette = _getPalette(tokenId);

        // Create master seed
        uint256 masterSeed = _createMasterSeed(
            tokenId,
            rarePerToken,
            currentSupply,
            currentTick
        );

        // Calculate market-influenced parameters
        // Price multiplier: 100-300 (higher price = bolder strokes)
        uint256 priceMultiplier = 100 + ((rarePerToken % 1e18) * 200) / 1e18;
        if (priceMultiplier > 300) priceMultiplier = 300;

        // Grid size: 6-10 (more supply = denser grid)
        uint256 supplyRatio = (currentSupply * 100) / maxTotalSupply;
        uint256 gridSize = 6 + (supplyRatio * 4) / 100;
        if (gridSize > 10) gridSize = 10;

        // Shape count: 4-8 (more liquidity = more shapes)
        uint256 shapeCount = 4 +
            ((uint256(liquidity) % 1000000000) * 4) /
            1000000000;
        if (shapeCount > 8) shapeCount = 8;

        // Direction from tick
        int256 direction = int256(currentTick) % 180;

        // Build SVG with all layers
        string memory svg = string(
            abi.encodePacked(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">',
                "<defs>",
                // Vignette gradient
                '<radialGradient id="vignette" cx="50%" cy="50%" r="70%">',
                '<stop offset="0%" stop-color="#000" stop-opacity="0"/>',
                '<stop offset="100%" stop-color="#000" stop-opacity="0.4"/>',
                "</radialGradient>",
                // Noise pattern
                _generateNoiseTexture(masterSeed),
                "</defs>"
            )
        );

        // Layer 1: Background
        svg = string(
            abi.encodePacked(
                svg,
                '<rect width="400" height="400" fill="#',
                palette[0],
                '"/>',
                '<rect width="400" height="400" fill="url(#vignette)"/>'
            )
        );

        // Layer 2: Noise texture
        svg = string(
            abi.encodePacked(
                svg,
                '<rect width="400" height="400" fill="url(#noise)" opacity="0.05"/>'
            )
        );

        // Layer 3: Grid cells
        uint256 gridSeed;
        (, gridSeed) = _nextRandom(masterSeed);
        svg = string(
            abi.encodePacked(
                svg,
                _generateGridCells(gridSeed, gridSize, palette)
            )
        );

        // Layer 4: Concentric arcs
        uint256 arcSeed;
        (, arcSeed) = _nextRandom(gridSeed);
        svg = string(
            abi.encodePacked(
                svg,
                _generateConcentricArcs(
                    arcSeed,
                    currentTick,
                    priceMultiplier,
                    palette
                )
            )
        );

        // Layer 5: Flow lines
        uint256 flowSeed;
        (, flowSeed) = _nextRandom(arcSeed);
        svg = string(
            abi.encodePacked(
                svg,
                _generateFlowLines(flowSeed, direction, palette[3])
            )
        );

        // Layer 6: Accent shapes
        uint256 accentSeed;
        (, accentSeed) = _nextRandom(flowSeed);
        svg = string(
            abi.encodePacked(
                svg,
                _generateAccentShapes(accentSeed, shapeCount, palette)
            )
        );

        // Layer 7: Center point
        svg = string(
            abi.encodePacked(
                svg,
                '<circle cx="200" cy="200" r="3" fill="#',
                palette[4],
                '" opacity="0.8"/>',
                "</svg>"
            )
        );

        return svg;
    }

    // ============================================================
    //                     METADATA
    // ============================================================

    /// @notice Generate JSON metadata with base64-encoded SVG
    /// @param tokenId Token ID
    /// @param paletteName Name of the color palette
    /// @param metrics Derived market metrics
    /// @param svg SVG string to encode
    /// @return JSON metadata string
    function _generateMetadataJSON(
        uint256 tokenId,
        string memory paletteName,
        DerivedMetrics memory metrics,
        string memory svg
    ) internal pure returns (string memory) {
        // Build name
        string memory name = _getTokenName(tokenId);

        // Build image URI
        string memory imageURI = _buildImageURI(svg);

        // Build attributes (artistic + market state)
        string memory attributes = _buildAttributes(
            tokenId,
            paletteName,
            metrics
        );

        // Combine into JSON - split into parts to avoid stack depth
        string memory part1 = string(abi.encodePacked('{"name":"', name, '",'));

        string memory part2 = string(
            abi.encodePacked(
                '"description":"Generative artwork reflecting Liquid Edition market dynamics.",',
                '"image":"',
                imageURI,
                '",'
            )
        );

        return
            string(
                abi.encodePacked(part1, part2, '"attributes":', attributes, "}")
            );
    }

    /// @notice Get token name
    function _getTokenName(
        uint256 tokenId
    ) internal pure returns (string memory) {
        if (tokenId == 0) {
            return "Liquid Lens Genesis";
        }
        return
            string(abi.encodePacked("Liquid Lens #", _uintToString(tokenId)));
    }

    /// @notice Build image URI from SVG
    function _buildImageURI(
        string memory svg
    ) internal pure returns (string memory) {
        return
            string(
                abi.encodePacked(
                    "data:image/svg+xml;base64,",
                    _base64Encode(bytes(svg))
                )
            );
    }

    /// @notice Build attributes JSON array (artistic + market state)
    function _buildAttributes(
        uint256 /* tokenId */,
        string memory paletteName,
        DerivedMetrics memory metrics
    ) internal pure returns (string memory) {
        // Artistic attributes
        string memory artistic = string(
            abi.encodePacked(
                '[{"trait_type":"Palette","value":"',
                paletteName,
                '"},',
                '{"trait_type":"Style","value":"Generative Rings"},'
            )
        );

        // Market state attributes
        string memory market = string(
            abi.encodePacked(
                '{"trait_type":"Price (RARE)","value":"',
                metrics.priceFormatted,
                '"},',
                '{"trait_type":"Supply","value":"',
                metrics.supplyFormatted,
                '"},',
                '{"trait_type":"Burn %","value":"',
                _uintToString(metrics.burnPercentage),
                '"},',
                '{"trait_type":"Bonding Progress","value":"',
                _uintToString(metrics.bondingProgress),
                '%"},',
                '{"trait_type":"Market Cap (RARE)","value":"',
                _formatDecimal(metrics.marketCap, 2),
                '"}'
            )
        );

        return string(abi.encodePacked(artistic, market, "]"));
    }

    // ============================================================
    //                     BASE64 ENCODING
    // ============================================================

    /// @notice Base64 encode function
    /// @param data Bytes to encode
    /// @return Base64 encoded string
    function _base64Encode(
        bytes memory data
    ) internal pure returns (string memory) {
        bytes
            memory table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        uint256 encodedLen = 4 * ((data.length + 2) / 3);
        bytes memory result = new bytes(encodedLen + 32);

        uint256 i = 0;
        uint256 j = 0;
        for (; i + 3 <= data.length; i += 3) {
            uint256 a = uint256(uint8(data[i]));
            uint256 b = uint256(uint8(data[i + 1]));
            uint256 c = uint256(uint8(data[i + 2]));

            uint256 bitmap = (a << 16) | (b << 8) | c;

            result[j++] = table[bitmap >> 18];
            result[j++] = table[(bitmap >> 12) & 63];
            result[j++] = table[(bitmap >> 6) & 63];
            result[j++] = table[bitmap & 63];
        }

        if (i + 2 == data.length) {
            uint256 a = uint256(uint8(data[i]));
            uint256 b = uint256(uint8(data[i + 1]));
            uint256 bitmap = (a << 16) | (b << 8);

            result[j++] = table[bitmap >> 18];
            result[j++] = table[(bitmap >> 12) & 63];
            result[j++] = table[(bitmap >> 6) & 63];
            result[j++] = 0x3D; // '='
        } else if (i + 1 == data.length) {
            uint256 a = uint256(uint8(data[i]));
            uint256 bitmap = a << 16;

            result[j++] = table[bitmap >> 18];
            result[j++] = table[(bitmap >> 12) & 63];
            result[j++] = 0x3D; // '='
            result[j++] = 0x3D; // '='
        }

        assembly {
            mstore(result, j)
        }

        return string(result);
    }
}
// forge-lint: disable-end(unsafe-typecast)
