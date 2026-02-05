// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ILiquid} from "../interfaces/ILiquid.sol";
import {Liquid} from "../Liquid.sol";

/// @title LiquidLensDemoV2
/// @notice Plotter art-inspired generative NFTs visualizing Liquid Edition market state.
///         Inspired by artists like Anders Hoff (inconvergent), Matt DesLauriers, and Licia He.
///         Features flow fields, hatching patterns, and line-only aesthetics.
/// @dev All rendering uses strokes only (no fills) - plotter/pen-friendly SVG output.
contract LiquidLensDemoV2 is ERC721, Ownable {
    /// @notice The linked Liquid Edition contract
    address public immutable liquidEdition;

    /// @notice Maximum number of NFTs that can be minted
    uint256 public constant MAX_SUPPLY = 10;

    /// @notice Next token ID to mint
    uint256 public nextTokenId = 1;

    /// @notice Collection name for metadata
    string public collectionName;

    /// @notice Collection description for metadata
    string public collectionDescription;

    error MaxSupplyExceeded();
    error InvalidLiquidEdition();

    constructor(
        address _liquidEdition,
        string memory _name,
        string memory _symbol,
        string memory _collectionName,
        string memory _collectionDescription
    ) ERC721(_name, _symbol) Ownable(msg.sender) {
        if (_liquidEdition == address(0)) revert InvalidLiquidEdition();
        liquidEdition = _liquidEdition;
        collectionName = _collectionName;
        collectionDescription = _collectionDescription;
    }

    function mint(address to) external onlyOwner {
        if (nextTokenId > MAX_SUPPLY) revert MaxSupplyExceeded();
        _safeMint(to, nextTokenId);
        nextTokenId++;
    }

    function tokenURI(
        uint256 tokenId
    ) public view override returns (string memory) {
        if (tokenId > 0) {
            if (tokenId >= nextTokenId) {
                revert ERC721NonexistentToken(tokenId);
            }
            _requireOwned(tokenId);
        }

        (
            uint256 rarePerToken,
            ,
            uint160 sqrtPriceX96,
            int24 currentTick,
            uint128 liquidity,
            uint256 currentSupply
        ) = ILiquid(liquidEdition).getMarketState();

        uint256 maxTotalSupply = Liquid(liquidEdition).MAX_TOTAL_SUPPLY();

        DerivedMetrics memory metrics = _calculateDerivedMetrics(
            rarePerToken,
            currentSupply,
            maxTotalSupply,
            currentTick,
            liquidity,
            sqrtPriceX96
        );

        string memory svg = _generateSVG(
            tokenId,
            rarePerToken,
            currentSupply,
            maxTotalSupply,
            currentTick,
            liquidity
        );

        string memory paletteName = _getPaletteName(tokenId);
        return _generateMetadataJSON(tokenId, paletteName, metrics, svg);
    }

    function tokenURI() external view returns (string memory) {
        return tokenURI(0);
    }

    // ============================================================
    //                     DERIVED METRICS
    // ============================================================

    struct DerivedMetrics {
        uint256 burnPercentage;
        uint256 bondingProgress;
        uint256 marketCap;
        uint256 fdv;
        string priceFormatted;
        string supplyFormatted;
    }

    function _calculateDerivedMetrics(
        uint256 rarePerToken,
        uint256 currentSupply,
        uint256 maxTotalSupply,
        int24 currentTick,
        uint128 liquidity,
        uint160 /* sqrtPriceX96 */
    ) internal pure returns (DerivedMetrics memory metrics) {
        uint256 burned = maxTotalSupply - currentSupply;
        metrics.burnPercentage = (burned * 100) / maxTotalSupply;

        int256 tick256 = int256(int24(currentTick));
        int256 shiftedTick = tick256 + 887272;
        uint256 normalizedTick = shiftedTick >= 0 ? uint256(shiftedTick) : 0;
        metrics.bondingProgress = normalizedTick % 101;

        metrics.marketCap = (currentSupply * rarePerToken) / 1e18;
        metrics.fdv = (maxTotalSupply * rarePerToken) / 1e18;
        metrics.priceFormatted = _formatDecimal(rarePerToken, 6);
        metrics.supplyFormatted = _formatDecimal(currentSupply, 0);
    }

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

        string memory fractionalStr = _uintToString(fractionalPart);
        while (bytes(fractionalStr).length < decimals) {
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

    function _nextRandom(
        uint256 seed
    ) internal pure returns (uint256 value, uint256 nextSeed) {
        nextSeed = uint256(keccak256(abi.encodePacked(seed)));
        value = nextSeed;
    }

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
    //                     INK PALETTE SYSTEM
    // ============================================================

    /// @notice Plotter-inspired palettes: paper color + 2-3 ink colors
    /// @dev [background, primary ink, secondary ink, accent ink]
    function _getPalette(
        uint256 tokenId
    ) internal pure returns (string[4] memory colors) {
        uint256 paletteId = tokenId % 8;

        if (paletteId == 0) {
            // Manuscript - warm cream paper, sepia ink
            colors = ["f5f0e6", "2d1b0e", "6b4423", "8b6914"];
        } else if (paletteId == 1) {
            // Blueprint - deep blue paper, white/cyan lines
            colors = ["0a1628", "e8f4f8", "4a9ead", "87ceeb"];
        } else if (paletteId == 2) {
            // Noir - black paper, white/silver ink
            colors = ["0a0a0a", "e5e5e5", "808080", "c0c0c0"];
        } else if (paletteId == 3) {
            // Kraft - brown paper, black/white ink
            colors = ["c4a77d", "1a1a1a", "f5f5f5", "4a3728"];
        } else if (paletteId == 4) {
            // Technical - off-white, navy/red technical pen
            colors = ["f8f8f5", "1e3a5f", "8b1a1a", "2d4a6f"];
        } else if (paletteId == 5) {
            // Copper - dark slate, copper/gold ink
            colors = ["1a1a1f", "b87333", "d4af37", "cd7f32"];
        } else if (paletteId == 6) {
            // Risograph - cream, blue/pink overlay
            colors = ["faf8f0", "2856a3", "e8505b", "6b4c9a"];
        } else {
            // Aged - yellowed paper, faded black
            colors = ["e8dcc4", "3d3d3d", "5c5c5c", "7a6f5d"];
        }
    }

    function _getPaletteName(
        uint256 tokenId
    ) internal pure returns (string memory) {
        uint256 paletteId = tokenId % 8;
        if (paletteId == 0) return "Manuscript";
        if (paletteId == 1) return "Blueprint";
        if (paletteId == 2) return "Noir";
        if (paletteId == 3) return "Kraft";
        if (paletteId == 4) return "Technical";
        if (paletteId == 5) return "Copper";
        if (paletteId == 6) return "Risograph";
        return "Aged";
    }

    // ============================================================
    //                     UTILITY FUNCTIONS
    // ============================================================

    function _uintToString(
        uint256 value
    ) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    function _intToString(int256 value) internal pure returns (string memory) {
        if (value >= 0) return _uintToString(uint256(value));
        return string(abi.encodePacked("-", _uintToString(uint256(-value))));
    }

    /// @notice Simple sine approximation (Taylor series, scaled)
    /// @param angle Angle in degrees (0-360)
    /// @return Sine value scaled by 1000 (-1000 to 1000)
    function _sin(int256 angle) internal pure returns (int256) {
        // Normalize to 0-360
        while (angle < 0) angle += 360;
        angle = angle % 360;

        // Convert to radians * 1000 for precision
        // sin lookup table for key angles (scaled by 1000)
        if (angle == 0) return 0;
        if (angle == 30) return 500;
        if (angle == 45) return 707;
        if (angle == 60) return 866;
        if (angle == 90) return 1000;
        if (angle == 120) return 866;
        if (angle == 135) return 707;
        if (angle == 150) return 500;
        if (angle == 180) return 0;
        if (angle == 210) return -500;
        if (angle == 225) return -707;
        if (angle == 240) return -866;
        if (angle == 270) return -1000;
        if (angle == 300) return -866;
        if (angle == 315) return -707;
        if (angle == 330) return -500;

        // Linear interpolation between known values
        int256[13] memory angles = [
            int256(0),
            30,
            60,
            90,
            120,
            150,
            180,
            210,
            240,
            270,
            300,
            330,
            360
        ];
        int256[13] memory values = [
            int256(0),
            500,
            866,
            1000,
            866,
            500,
            0,
            -500,
            -866,
            -1000,
            -866,
            -500,
            0
        ];

        for (uint256 i = 0; i < 12; i++) {
            if (angle > angles[i] && angle < angles[i + 1]) {
                int256 t = ((angle - angles[i]) * 1000) /
                    (angles[i + 1] - angles[i]);
                return values[i] + ((values[i + 1] - values[i]) * t) / 1000;
            }
        }
        return 0;
    }

    function _cos(int256 angle) internal pure returns (int256) {
        return _sin(angle + 90);
    }

    function _abs(int256 x) internal pure returns (int256) {
        return x >= 0 ? x : -x;
    }

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
    //                     FLOW FIELD GENERATION
    // ============================================================

    /// @notice Generate flow field lines (inspired by inconvergent/Anders Hoff)
    /// @dev Creates organic flowing curves that follow a procedural vector field
    function _generateFlowField(
        uint256 seed,
        int256 fieldAngle,
        uint256 lineCount,
        string memory inkColor
    ) internal pure returns (string memory) {
        string memory lines = string(
            abi.encodePacked(
                '<g stroke="#',
                inkColor,
                '" stroke-width="0.8" fill="none" stroke-linecap="round">'
            )
        );

        uint256 currentSeed = seed;

        for (uint256 i = 0; i < lineCount; i++) {
            uint256 randVal;
            (randVal, currentSeed) = _nextRandom(currentSeed);

            // Starting position
            int256 x = int256(randVal % 400);
            (randVal, currentSeed) = _nextRandom(currentSeed);
            int256 y = int256(randVal % 400);

            // Build path with 12-20 segments
            (randVal, currentSeed) = _nextRandom(currentSeed);
            uint256 segments = 12 + (randVal % 9);

            string memory path = string(
                abi.encodePacked("M", _intToString(x), ",", _intToString(y))
            );

            for (uint256 j = 0; j < segments; j++) {
                // Flow field direction based on position + global angle
                int256 localAngle = fieldAngle +
                    (_sin((x * 360) / 400) * 45) /
                    1000 +
                    (_cos((y * 360) / 400) * 45) /
                    1000 +
                    int256(j * 5);

                // Step along the field
                int256 stepSize = 8 + int256((i * 3) % 12);
                int256 dx = (_cos(localAngle) * stepSize) / 1000;
                int256 dy = (_sin(localAngle) * stepSize) / 1000;

                x = _clamp(x + dx, 5, 395);
                y = _clamp(y + dy, 5, 395);

                path = string(
                    abi.encodePacked(
                        path,
                        " L",
                        _intToString(x),
                        ",",
                        _intToString(y)
                    )
                );
            }

            // Vary opacity for depth
            (randVal, currentSeed) = _nextRandom(currentSeed);
            uint256 opacity = 30 + (randVal % 50);

            lines = string(
                abi.encodePacked(
                    lines,
                    '<path d="',
                    path,
                    '" opacity="0.',
                    _uintToString(opacity),
                    '"/>'
                )
            );
        }

        return string(abi.encodePacked(lines, "</g>"));
    }

    // ============================================================
    //                     HATCHING GENERATION
    // ============================================================

    /// @notice Generate hatching pattern (parallel lines for shading)
    /// @dev Creates pencil/pen shading effect common in plotter art
    function _generateHatching(
        uint256 seed,
        uint256 density,
        int256 angle,
        string memory inkColor
    ) internal pure returns (string memory) {
        string memory hatches = string(
            abi.encodePacked(
                '<g stroke="#',
                inkColor,
                '" stroke-width="0.4" opacity="0.3">'
            )
        );

        uint256 currentSeed = seed;

        // Line spacing based on density (more density = closer lines)
        uint256 spacing = 8 + (100 - density) / 10;
        if (spacing < 3) spacing = 3;

        // Calculate rotation
        int256 cosA = _cos(angle);
        int256 sinA = _sin(angle);

        // Generate parallel lines across a circular region
        uint256 numLines = 400 / spacing;

        for (uint256 i = 0; i < numLines && i < 60; i++) {
            uint256 randVal;
            (randVal, currentSeed) = _nextRandom(currentSeed);

            // Base position offset
            int256 offset = int256(i * spacing) - 200;

            // Add slight variation
            int256 jitter = int256(randVal % 6) - 3;
            offset += jitter;

            // Calculate line endpoints (rotated)
            int256 x1 = 200 + (offset * cosA) / 1000 - (200 * sinA) / 1000;
            int256 y1 = 200 + (offset * sinA) / 1000 + (200 * cosA) / 1000;
            int256 x2 = 200 + (offset * cosA) / 1000 + (200 * sinA) / 1000;
            int256 y2 = 200 + (offset * sinA) / 1000 - (200 * cosA) / 1000;

            // Clip to circular mask (simplified - just draw within bounds)
            if (
                x1 > 0 &&
                x1 < 400 &&
                y1 > 0 &&
                y1 < 400 &&
                x2 > 0 &&
                x2 < 400 &&
                y2 > 0 &&
                y2 < 400
            ) {
                hatches = string(
                    abi.encodePacked(
                        hatches,
                        '<line x1="',
                        _intToString(x1),
                        '" y1="',
                        _intToString(y1),
                        '" x2="',
                        _intToString(x2),
                        '" y2="',
                        _intToString(y2),
                        '"/>'
                    )
                );
            }
        }

        return string(abi.encodePacked(hatches, "</g>"));
    }

    // ============================================================
    //                     CONTOUR LINES
    // ============================================================

    /// @notice Generate contour/topographic lines
    /// @dev Creates concentric distorted circles like topographic maps
    function _generateContours(
        uint256 seed,
        uint256 numContours,
        uint256 distortion,
        string memory inkColor
    ) internal pure returns (string memory) {
        string memory contours = string(
            abi.encodePacked(
                '<g stroke="#',
                inkColor,
                '" stroke-width="0.6" fill="none">'
            )
        );

        uint256 currentSeed = seed;

        for (uint256 ring = 0; ring < numContours; ring++) {
            uint256 baseRadius = 30 + ring * 18;
            if (baseRadius > 180) break;

            // Build path with distorted circle
            string memory path = "";
            bool first = true;

            for (uint256 deg = 0; deg < 360; deg += 10) {
                uint256 randVal;
                (randVal, currentSeed) = _nextRandom(currentSeed);

                // Radius with noise distortion
                int256 noiseOffset = int256((randVal % distortion)) -
                    int256(distortion / 2);
                int256 radius = int256(baseRadius) + noiseOffset;

                int256 x = 200 + (_cos(int256(deg)) * radius) / 1000;
                int256 y = 200 + (_sin(int256(deg)) * radius) / 1000;

                if (first) {
                    path = string(
                        abi.encodePacked(
                            "M",
                            _intToString(x),
                            ",",
                            _intToString(y)
                        )
                    );
                    first = false;
                } else {
                    path = string(
                        abi.encodePacked(
                            path,
                            " L",
                            _intToString(x),
                            ",",
                            _intToString(y)
                        )
                    );
                }
            }

            path = string(abi.encodePacked(path, " Z"));

            // Vary opacity by ring
            uint256 opacity = 20 + (ring * 5);
            if (opacity > 70) opacity = 70;

            contours = string(
                abi.encodePacked(
                    contours,
                    '<path d="',
                    path,
                    '" opacity="0.',
                    _uintToString(opacity),
                    '"/>'
                )
            );
        }

        return string(abi.encodePacked(contours, "</g>"));
    }

    // ============================================================
    //                     STIPPLING
    // ============================================================

    /// @notice Generate stippling pattern (dots for shading)
    /// @dev Creates pointillist effect common in plotter/pen art
    function _generateStippling(
        uint256 seed,
        uint256 density,
        string memory inkColor
    ) internal pure returns (string memory) {
        string memory dots = string(
            abi.encodePacked('<g fill="#', inkColor, '">')
        );

        uint256 currentSeed = seed;
        uint256 numDots = density * 3;
        if (numDots > 300) numDots = 300;

        for (uint256 i = 0; i < numDots; i++) {
            uint256 randVal;
            (randVal, currentSeed) = _nextRandom(currentSeed);
            uint256 x = randVal % 400;

            (randVal, currentSeed) = _nextRandom(currentSeed);
            uint256 y = randVal % 400;

            // Distance from center affects density
            int256 dx = int256(x) - 200;
            int256 dy = int256(y) - 200;
            uint256 dist = uint256(_abs(dx) + _abs(dy));

            // More dots near center
            (randVal, currentSeed) = _nextRandom(currentSeed);
            if (randVal % 400 > dist) {
                (randVal, currentSeed) = _nextRandom(currentSeed);
                uint256 radius = 1 + (randVal % 2);

                (randVal, currentSeed) = _nextRandom(currentSeed);
                uint256 opacity = 20 + (randVal % 40);

                dots = string(
                    abi.encodePacked(
                        dots,
                        '<circle cx="',
                        _uintToString(x),
                        '" cy="',
                        _uintToString(y),
                        '" r="',
                        _uintToString(radius),
                        '" opacity="0.',
                        _uintToString(opacity),
                        '"/>'
                    )
                );
            }
        }

        return string(abi.encodePacked(dots, "</g>"));
    }

    // ============================================================
    //                     SPIRAL CURVES
    // ============================================================

    /// @notice Generate Archimedean spiral
    /// @dev Mathematical spiral common in plotter generative art
    function _generateSpiral(
        uint256 seed,
        uint256 turns,
        string memory inkColor
    ) internal pure returns (string memory) {
        uint256 currentSeed = seed;
        uint256 randVal;
        (randVal, currentSeed) = _nextRandom(currentSeed);

        // Random offset for spiral center
        int256 cx = 200 + int256(randVal % 60) - 30;
        (randVal, currentSeed) = _nextRandom(currentSeed);
        int256 cy = 200 + int256(randVal % 60) - 30;

        string memory path = "";
        bool first = true;

        uint256 maxAngle = turns * 360;
        uint256 step = 5;

        for (uint256 angle = 0; angle < maxAngle; angle += step) {
            // Archimedean spiral: r = a + b*theta
            int256 radius = int256(angle) / 6;
            if (radius > 180) break;

            int256 x = cx + (_cos(int256(angle % 360)) * radius) / 1000;
            int256 y = cy + (_sin(int256(angle % 360)) * radius) / 1000;

            if (first) {
                path = string(
                    abi.encodePacked("M", _intToString(x), ",", _intToString(y))
                );
                first = false;
            } else {
                path = string(
                    abi.encodePacked(
                        path,
                        " L",
                        _intToString(x),
                        ",",
                        _intToString(y)
                    )
                );
            }
        }

        return
            string(
                abi.encodePacked(
                    '<path d="',
                    path,
                    '" stroke="#',
                    inkColor,
                    '" stroke-width="0.5" fill="none" opacity="0.5"/>'
                )
            );
    }

    // ============================================================
    //                     CROSS-HATCHING
    // ============================================================

    /// @notice Generate cross-hatching (two layers of hatching at different angles)
    function _generateCrossHatch(
        uint256 seed,
        uint256 density,
        int256 baseAngle,
        string memory inkColor
    ) internal pure returns (string memory) {
        string memory layer1 = _generateHatching(
            seed,
            density,
            baseAngle,
            inkColor
        );
        uint256 nextSeed;
        (, nextSeed) = _nextRandom(seed);
        string memory layer2 = _generateHatching(
            nextSeed,
            density / 2,
            baseAngle + 90,
            inkColor
        );

        return string(abi.encodePacked(layer1, layer2));
    }

    // ============================================================
    //                     MAIN SVG COMPOSER
    // ============================================================

    function _generateSVG(
        uint256 tokenId,
        uint256 rarePerToken,
        uint256 currentSupply,
        uint256 maxTotalSupply,
        int24 currentTick,
        uint128 liquidity
    ) internal pure returns (string memory) {
        string[4] memory palette = _getPalette(tokenId);
        uint256 masterSeed = _createMasterSeed(
            tokenId,
            rarePerToken,
            currentSupply,
            currentTick
        );

        // Market-influenced parameters
        // Flow direction from tick
        int256 flowAngle = int256(currentTick) % 360;

        // Contour distortion from price volatility (higher price = more distortion)
        uint256 distortion = 10 + ((rarePerToken % 1e18) * 40) / 1e18;
        if (distortion > 50) distortion = 50;

        // Hatching density from supply ratio
        uint256 supplyRatio = (currentSupply * 100) / maxTotalSupply;
        uint256 hatchDensity = 20 + (supplyRatio * 60) / 100;

        // Number of contours from liquidity
        uint256 numContours = 5 +
            ((uint256(liquidity) % 1000000000) * 5) /
            1000000000;
        if (numContours > 10) numContours = 10;

        // Flow line count from price
        uint256 flowLineCount = 30 + ((rarePerToken % 1e18) * 40) / 1e18;
        if (flowLineCount > 70) flowLineCount = 70;

        // Build SVG
        string memory svg = string(
            abi.encodePacked(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">',
                // Background (paper color)
                '<rect width="400" height="400" fill="#',
                palette[0],
                '"/>'
            )
        );

        // Layer 1: Cross-hatching background texture
        uint256 hatchSeed;
        (, hatchSeed) = _nextRandom(masterSeed);
        svg = string(
            abi.encodePacked(
                svg,
                _generateCrossHatch(
                    hatchSeed,
                    hatchDensity / 3,
                    flowAngle + 45,
                    palette[1]
                )
            )
        );

        // Layer 2: Contour lines (topographic effect)
        uint256 contourSeed;
        (, contourSeed) = _nextRandom(hatchSeed);
        svg = string(
            abi.encodePacked(
                svg,
                _generateContours(
                    contourSeed,
                    numContours,
                    distortion,
                    palette[1]
                )
            )
        );

        // Layer 3: Flow field (primary visual element)
        uint256 flowSeed;
        (, flowSeed) = _nextRandom(contourSeed);
        svg = string(
            abi.encodePacked(
                svg,
                _generateFlowField(
                    flowSeed,
                    flowAngle,
                    flowLineCount,
                    palette[2]
                )
            )
        );

        // Layer 4: Spiral accent
        uint256 spiralSeed;
        (, spiralSeed) = _nextRandom(flowSeed);
        uint256 spiralTurns = 3 + (spiralSeed % 4);
        svg = string(
            abi.encodePacked(
                svg,
                _generateSpiral(spiralSeed, spiralTurns, palette[3])
            )
        );

        // Layer 5: Stippling for depth
        uint256 stippleSeed;
        (, stippleSeed) = _nextRandom(spiralSeed);
        uint256 stippleDensity = 30 + (supplyRatio * 40) / 100;
        svg = string(
            abi.encodePacked(
                svg,
                _generateStippling(stippleSeed, stippleDensity, palette[1])
            )
        );

        // Layer 6: Center marker (registration mark style)
        svg = string(
            abi.encodePacked(
                svg,
                '<g stroke="#',
                palette[1],
                '" stroke-width="0.5" fill="none" opacity="0.6">',
                '<circle cx="200" cy="200" r="4"/>',
                '<line x1="196" y1="200" x2="204" y2="200"/>',
                '<line x1="200" y1="196" x2="200" y2="204"/>',
                "</g>",
                "</svg>"
            )
        );

        return svg;
    }

    // ============================================================
    //                     METADATA
    // ============================================================

    function _generateMetadataJSON(
        uint256 tokenId,
        string memory paletteName,
        DerivedMetrics memory metrics,
        string memory svg
    ) internal pure returns (string memory) {
        string memory name = _getTokenName(tokenId);
        string memory imageURI = _buildImageURI(svg);
        string memory attributes = _buildAttributes(
            tokenId,
            paletteName,
            metrics
        );

        return
            string(
                abi.encodePacked(
                    '{"name":"',
                    name,
                    '","description":"Plotter-inspired generative art reflecting Liquid Edition market dynamics.","image":"',
                    imageURI,
                    '","attributes":',
                    attributes,
                    "}"
                )
            );
    }

    function _getTokenName(
        uint256 tokenId
    ) internal pure returns (string memory) {
        if (tokenId == 0) return "Liquid Topology Genesis";
        return
            string(
                abi.encodePacked("Liquid Topology #", _uintToString(tokenId))
            );
    }

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

    function _buildAttributes(
        uint256 tokenId,
        string memory paletteName,
        DerivedMetrics memory metrics
    ) internal pure returns (string memory) {
        string memory artistic = string(
            abi.encodePacked(
                '[{"trait_type":"Palette","value":"',
                paletteName,
                '"},{"trait_type":"Style","value":"Plotter Art"},'
            )
        );

        string memory market = string(
            abi.encodePacked(
                '{"trait_type":"Price (RARE)","value":"',
                metrics.priceFormatted,
                '"},{"trait_type":"Supply","value":"',
                metrics.supplyFormatted,
                '"},{"trait_type":"Burn %","value":"',
                _uintToString(metrics.burnPercentage),
                '"},{"trait_type":"Bonding Progress","value":"',
                _uintToString(metrics.bondingProgress),
                '%"},{"trait_type":"Market Cap (RARE)","value":"',
                _formatDecimal(metrics.marketCap, 2),
                '"}'
            )
        );

        return string(abi.encodePacked(artistic, market, "]"));
    }

    // ============================================================
    //                     BASE64 ENCODING
    // ============================================================

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
            result[j++] = 0x3D;
        } else if (i + 1 == data.length) {
            uint256 a = uint256(uint8(data[i]));
            uint256 bitmap = a << 16;

            result[j++] = table[bitmap >> 18];
            result[j++] = table[(bitmap >> 12) & 63];
            result[j++] = 0x3D;
            result[j++] = 0x3D;
        }

        assembly {
            mstore(result, j)
        }

        return string(result);
    }
}
