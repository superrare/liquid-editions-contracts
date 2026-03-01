// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

// forge-lint: disable-start(unsafe-typecast) -- safe: rendering code uses bounded values.

import {ILiquid} from "liquid-editions/interfaces/ILiquid.sol";
import {IRender} from "liquid-editions/interfaces/IRender.sol";
import {LiquidInstant} from "liquid-editions/LiquidInstant.sol";

/// @title LiquidRenderSimpleV4
/// @notice Plotter art-inspired render contract with hash-avalanche sensitivity.
///         Every visual parameter is independently derived from keccak256(masterSeed, index)
///         so even a 1-unit market-state change completely reshuffles the artwork.
/// @dev HTML artifact page output (including embedded SVG preview). Implements IRender for tokenURI() passthrough.
contract LiquidRenderSimpleV4 is IRender {
    address public immutable LIQUID_EDITION;
    string public collectionName;
    string public collectionDescription;

    error InvalidLiquidEdition();

    struct MarketSnapshot {
        uint256 rarePerToken;
        uint160 sqrtPriceX96;
        int24 currentTick;
        uint128 liquidity;
        uint256 currentSupply;
        uint256 maxTotalSupply;
    }

    constructor(
        address _liquidEdition,
        string memory _collectionName,
        string memory _collectionDescription
    ) {
        if (_liquidEdition == address(0)) revert InvalidLiquidEdition();
        LIQUID_EDITION = _liquidEdition;
        collectionName = _collectionName;
        collectionDescription = _collectionDescription;
    }

    function tokenURI() external view override returns (string memory) {
        MarketSnapshot memory snapshot = _readMarketSnapshot();
        uint256 masterSeed = _createMasterSeed(snapshot);
        string memory svg = _generateSVG(masterSeed, snapshot);
        return _generateMetadataJSON(masterSeed, snapshot, svg);
    }

    function tokenURI(
        uint256 /* tokenId */
    ) external view override returns (string memory) {
        return this.tokenURI();
    }

    function _readMarketSnapshot() internal view returns (MarketSnapshot memory s) {
        (
            s.rarePerToken,
            ,
            s.sqrtPriceX96,
            s.currentTick,
            s.liquidity,
            s.currentSupply
        ) = ILiquid(LIQUID_EDITION).getMarketState();
        s.maxTotalSupply = LiquidInstant(LIQUID_EDITION).MAX_TOTAL_SUPPLY();
    }

    function _createMasterSeed(
        MarketSnapshot memory s
    ) internal view returns (uint256) {
        return
            uint256(
                keccak256(
                    abi.encodePacked(
                        address(this),
                        s.rarePerToken,
                        s.sqrtPriceX96,
                        s.currentTick,
                        s.liquidity,
                        s.currentSupply,
                        s.maxTotalSupply
                    )
                )
            );
    }

    // ============================================================
    //                     PALETTE SYSTEM
    // ============================================================

    function _getPalette(
        uint256 seed
    ) internal pure returns (string[4] memory colors, string memory name) {
        uint256 paletteId = seed % 8;
        if (paletteId == 0) {
            colors = ["f5f0e6", "2d1b0e", "6b4423", "8b6914"];
            name = "Manuscript";
        } else if (paletteId == 1) {
            colors = ["0a1628", "e8f4f8", "4a9ead", "87ceeb"];
            name = "Blueprint";
        } else if (paletteId == 2) {
            colors = ["0a0a0a", "e5e5e5", "808080", "c0c0c0"];
            name = "Noir";
        } else if (paletteId == 3) {
            colors = ["c4a77d", "1a1a1a", "f5f5f5", "4a3728"];
            name = "Kraft";
        } else if (paletteId == 4) {
            colors = ["f8f8f5", "1e3a5f", "8b1a1a", "2d4a6f"];
            name = "Technical";
        } else if (paletteId == 5) {
            colors = ["1a1a1f", "b87333", "d4af37", "cd7f32"];
            name = "Copper";
        } else if (paletteId == 6) {
            colors = ["faf8f0", "2856a3", "e8505b", "6b4c9a"];
            name = "Risograph";
        } else {
            colors = ["e8dcc4", "3d3d3d", "5c5c5c", "7a6f5d"];
            name = "Aged";
        }
    }

    // ============================================================
    //                     TRIG HELPERS
    // ============================================================

    function _sin(int256 angle) internal pure returns (int256) {
        while (angle < 0) angle += 360;
        angle = angle % 360;

        int256[13] memory angles = [
            int256(0), 30, 60, 90, 120, 150, 180, 210, 240, 270, 300, 330, 360
        ];
        int256[13] memory values = [
            int256(0), 500, 866, 1000, 866, 500, 0, -500, -866, -1000, -866, -500, 0
        ];

        for (uint256 i = 0; i < 12; i++) {
            if (angle >= angles[i] && angle < angles[i + 1]) {
                int256 t = ((angle - angles[i]) * 1000) / (angles[i + 1] - angles[i]);
                return values[i] + ((values[i + 1] - values[i]) * t) / 1000;
            }
        }
        return 0;
    }

    function _cos(int256 angle) internal pure returns (int256) {
        return _sin(angle + 90);
    }

    function _clamp(int256 val, int256 lo, int256 hi) internal pure returns (int256) {
        if (val < lo) return lo;
        if (val > hi) return hi;
        return val;
    }

    // ============================================================
    //                     MAIN SVG COMPOSER
    // ============================================================

    function _generateSVG(
        uint256 masterSeed,
        MarketSnapshot memory s
    ) internal pure returns (string memory) {
        uint256 paletteSeed = uint256(keccak256(abi.encodePacked(masterSeed, "pal")));
        (string[4] memory pal, ) = _getPalette(paletteSeed);

        string memory svg = string(
            abi.encodePacked(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">',
                '<rect width="400" height="400" fill="#', pal[0], '"/>'
            )
        );

        svg = string(abi.encodePacked(svg, _hatchGrid(masterSeed, pal[1])));
        svg = string(abi.encodePacked(svg, _contourField(masterSeed, s, pal[2])));
        svg = string(abi.encodePacked(svg, _flowCurves(masterSeed, pal[1], pal[3])));
        svg = string(abi.encodePacked(svg, _stippleCloud(masterSeed, pal[1])));
        svg = string(abi.encodePacked(svg, _radialTicks(masterSeed, s, pal[2], pal[3])));

        svg = string(
            abi.encodePacked(
                svg,
                '<g stroke="#', pal[1],
                '" stroke-width="0.5" fill="none" opacity="0.6">',
                '<circle cx="200" cy="200" r="4"/>',
                '<line x1="196" y1="200" x2="204" y2="200"/>',
                '<line x1="200" y1="196" x2="200" y2="204"/>',
                '</g></svg>'
            )
        );

        return svg;
    }

    // ============================================================
    //                  HASH-AVALANCHE HATCH GRID
    // ============================================================

    function _hatchGrid(
        uint256 masterSeed,
        string memory inkColor
    ) internal pure returns (string memory) {
        string memory out = string(
            abi.encodePacked(
                '<g stroke="#', inkColor,
                '" stroke-width="0.4" opacity="0.25">'
            )
        );

        uint256 cellSize = 50;
        for (uint256 i = 0; i < 64; i++) {
            uint256 w = uint256(keccak256(abi.encodePacked(masterSeed, "hatch", i)));
            uint256 col = i % 8;
            uint256 row = i / 8;
            uint256 cx = col * cellSize;
            uint256 cy = row * cellSize;

            int256 angle = int256(w % 180);
            uint256 lineCount = 3 + (w >> 8) % 3;
            uint256 spacing = 5 + (w >> 16) % 5;

            int256 cosA = _cos(angle);
            int256 sinA = _sin(angle);
            int256 halfCell = 25;

            for (uint256 ln = 0; ln < lineCount; ln++) {
                int256 offset = int256(ln * spacing) - int256((lineCount * spacing) / 2);
                int256 x1 = int256(cx) + halfCell + (offset * cosA) / 1000 - (halfCell * sinA) / 1000;
                int256 y1 = int256(cy) + halfCell + (offset * sinA) / 1000 + (halfCell * cosA) / 1000;
                int256 x2 = int256(cx) + halfCell + (offset * cosA) / 1000 + (halfCell * sinA) / 1000;
                int256 y2 = int256(cy) + halfCell + (offset * sinA) / 1000 - (halfCell * cosA) / 1000;

                out = string(
                    abi.encodePacked(
                        out,
                        '<line x1="', _intToString(x1),
                        '" y1="', _intToString(y1),
                        '" x2="', _intToString(x2),
                        '" y2="', _intToString(y2), '"/>'
                    )
                );
            }
        }

        return string(abi.encodePacked(out, "</g>"));
    }

    // ============================================================
    //                     CONTOUR FIELD
    // ============================================================

    function _contourField(
        uint256 masterSeed,
        MarketSnapshot memory s,
        string memory inkColor
    ) internal pure returns (string memory) {
        uint256 numRings = 4 + ((uint256(s.liquidity) % 1000000000) * 4) / 1000000000;
        if (numRings > 8) numRings = 8;

        string memory out = string(
            abi.encodePacked(
                '<g stroke="#', inkColor,
                '" stroke-width="0.6" fill="none">'
            )
        );

        for (uint256 ring = 0; ring < numRings; ring++) {
            uint256 ringWord = uint256(keccak256(abi.encodePacked(masterSeed, "contour", ring)));
            uint256 baseRadius = 25 + ring * 18;
            if (baseRadius > 180) break;

            uint256 opacity = 20 + (ring * 5);
            if (opacity > 70) opacity = 70;

            string memory path = "";
            bool first = true;

            for (uint256 deg = 0; deg < 360; deg += 10) {
                uint256 ptWord = uint256(keccak256(abi.encodePacked(ringWord, deg)));
                uint256 distortion = 5 + ((s.rarePerToken % 1e18) * 25) / 1e18;
                int256 noiseOffset = int256(ptWord % distortion) - int256(distortion / 2);
                int256 radius = int256(baseRadius) + noiseOffset;

                int256 x = 200 + (_cos(int256(deg)) * radius) / 1000;
                int256 y = 200 + (_sin(int256(deg)) * radius) / 1000;

                if (first) {
                    path = string(abi.encodePacked("M", _intToString(x), ",", _intToString(y)));
                    first = false;
                } else {
                    path = string(abi.encodePacked(path, " L", _intToString(x), ",", _intToString(y)));
                }
            }

            out = string(
                abi.encodePacked(
                    out,
                    '<path d="', path, ' Z" opacity="0.', _uintToString(opacity), '"/>'
                )
            );
        }

        return string(abi.encodePacked(out, "</g>"));
    }

    // ============================================================
    //                     FLOW CURVES
    // ============================================================

    function _flowCurves(
        uint256 masterSeed,
        string memory primaryInk,
        string memory accentInk
    ) internal pure returns (string memory) {
        string memory out = "";

        for (uint256 i = 0; i < 20; i++) {
            uint256 curveWord = uint256(keccak256(abi.encodePacked(masterSeed, "flow", i)));
            bool useAccent = (curveWord & 1) == 1;
            string memory ink = useAccent ? accentInk : primaryInk;
            uint256 opacity = 25 + ((curveWord >> 8) % 45);

            int256 x = int256((curveWord >> 16) % 400);
            int256 y = int256((curveWord >> 32) % 400);
            int256 baseAngle = int256((curveWord >> 48) % 360);

            string memory path = string(
                abi.encodePacked("M", _intToString(x), ",", _intToString(y))
            );

            uint256 segments = 8 + ((curveWord >> 64) % 7);
            for (uint256 j = 0; j < segments; j++) {
                uint256 stepWord = uint256(keccak256(abi.encodePacked(curveWord, j)));
                int256 localAngle = baseAngle +
                    (_sin((x * 360) / 400) * 50) / 1000 +
                    (_cos((y * 360) / 400) * 50) / 1000 +
                    int256(stepWord % 20) - 10;

                int256 stepSize = 6 + int256(stepWord % 10);
                x = _clamp(x + (_cos(localAngle) * stepSize) / 1000, 5, 395);
                y = _clamp(y + (_sin(localAngle) * stepSize) / 1000, 5, 395);

                path = string(abi.encodePacked(path, " L", _intToString(x), ",", _intToString(y)));
            }

            out = string(
                abi.encodePacked(
                    out,
                    '<path d="', path,
                    '" stroke="#', ink,
                    '" stroke-width="1.05" fill="none" stroke-linecap="round" opacity="0.',
                    _uintToString(opacity), '"/>'
                )
            );
        }

        return out;
    }

    // ============================================================
    //                     STIPPLE CLOUD
    // ============================================================

    function _stippleCloud(
        uint256 masterSeed,
        string memory inkColor
    ) internal pure returns (string memory) {
        string memory out = string(
            abi.encodePacked('<g fill="none" stroke="#', inkColor, '" stroke-width="0.9">')
        );

        for (uint256 i = 0; i < 80; i++) {
            uint256 w = uint256(keccak256(abi.encodePacked(masterSeed, "dot", i)));
            uint256 x = w % 400;
            uint256 y = (w >> 16) % 400;

            int256 dx = int256(x) - 200;
            int256 dy = int256(y) - 200;
            int256 dist = dx * dx + dy * dy;

            if (int256((w >> 32) % 40000) > dist / 4) {
                uint256 r = 2;
                uint256 opacity = 15 + ((w >> 48) % 30);
                out = string(
                    abi.encodePacked(
                        out,
                        '<circle cx="', _uintToString(x),
                        '" cy="', _uintToString(y),
                        '" r="', _uintToString(r),
                        '" opacity="0.', _uintToString(opacity), '"/>'
                    )
                );
            }
        }

        return string(abi.encodePacked(out, "</g>"));
    }

    // ============================================================
    //                     RADIAL TICKS
    // ============================================================

    function _radialTicks(
        uint256 masterSeed,
        MarketSnapshot memory s,
        string memory ink1,
        string memory ink2
    ) internal pure returns (string memory) {
        string memory group = '<g transform="translate(200 200)">';
        uint256[4] memory values = [
            s.rarePerToken,
            uint256(s.sqrtPriceX96),
            uint256(s.liquidity),
            s.currentSupply
        ];

        for (uint256 ring = 0; ring < 4; ring++) {
            uint256 ringWord = uint256(
                keccak256(abi.encodePacked(masterSeed, "ring", ring, values[ring]))
            );
            uint256 r = 35 + (ring * 22);
            string memory ink = (ring % 2 == 0) ? ink1 : ink2;

            for (uint256 t = 0; t < 24; t++) {
                uint256 tickWord = uint256(
                    keccak256(abi.encodePacked(ringWord, t, s.currentTick))
                );
                if ((tickWord & 1) == 0) continue;
                uint256 angle = t * 15;
                uint256 len = 3 + ((tickWord >> 8) % 10);
                uint256 opacity = 40 + ((tickWord >> 24) % 40);
                group = string(
                    abi.encodePacked(
                        group,
                        '<line x1="', _uintToString(r),
                        '" y1="0" x2="', _uintToString(r + len),
                        '" y2="0" stroke="#', ink,
                        '" stroke-width="1.1" transform="rotate(',
                        _uintToString(angle),
                        ')" opacity="0.', _uintToString(opacity), '"/>'
                    )
                );
            }
        }

        return string(abi.encodePacked(group, "</g>"));
    }

    // ============================================================
    //                     METADATA
    // ============================================================

    function _generateMetadataJSON(
        uint256 masterSeed,
        MarketSnapshot memory s,
        string memory svg
    ) internal view returns (string memory) {
        uint256 paletteSeed = uint256(keccak256(abi.encodePacked(masterSeed, "pal")));
        (, string memory paletteName) = _getPalette(paletteSeed);
        string memory html = _generateMetadataHTML(masterSeed, s, svg);
        string memory htmlImage = _buildHTMLDataURI(html);

        return
            string(
                abi.encodePacked(
                    '{"name":"',
                    collectionName,
                    '","description":"',
                    collectionDescription,
                    '","image":"',
                    htmlImage,
                    '","attributes":[',
                    '{"trait_type":"Palette","value":"', paletteName, '"},',
                    '{"trait_type":"Style","value":"Reactive Plotter Art (HTML Artifact)"},',
                    '{"trait_type":"Render Media","value":"HTML page with embedded SVG"},',
                    _buildMarketAttributes(s),
                    "]}"
                )
            );
    }

    function _generateMetadataHTML(
        uint256 masterSeed,
        MarketSnapshot memory s,
        string memory svg
    ) internal view returns (string memory) {
        uint256 paletteSeed = uint256(keccak256(abi.encodePacked(masterSeed, "pal")));
        (, string memory paletteName) = _getPalette(paletteSeed);
        string memory svgImage = _buildSVGDataURI(svg);

        return
            string(
                abi.encodePacked(
                    '<!DOCTYPE html><html><head><meta charset="UTF-8"/><meta name="viewport" content="width=device-width, initial-scale=1"/>',
                    '<title>',
                    collectionName,
                    '</title><style>body{margin:0;padding:20px;font-family:Georgia,Times New Roman,Times,serif;background:linear-gradient(140deg,#fff4e6,#f8f2de);color:#1f1a16}main{max-width:760px;margin:0 auto;background:#fffdf7;border:3px solid #1f1a16;padding:20px;box-shadow:0 12px 0 #1f1a16}h1{font-size:30px;margin:0 0 8px;line-height:1.1}p{opacity:0.85;margin:0 0 12px;line-height:1.4}.artframe{border:2px solid #1f1a16;background:#faf5ea;padding:6px;margin:16px 0}img{width:100%;height:auto;display:block}.stats{display:grid;grid-template-columns:1fr;gap:6px} .stat{display:flex;justify-content:space-between;border-bottom:1px solid rgba(31,26,22,0.12);padding-bottom:4px;margin-bottom:4px}@media (max-width:600px){body{padding:12px}main{padding:14px}h1{font-size:24px}}</style></head><body><main><h1>',
                    collectionName,
                    '</h1><p>',
                    collectionDescription,
                    '</p><div class="artframe"><img src="',
                    svgImage,
                    '" alt="reactive-plotter-artwork"/></div><div class="stats"><div class="stat"><span>Palette</span><strong>',
                    paletteName,
                    '</strong></div><div class="stat"><span>Style</span><strong>Reactive Plotter Art (HTML)</strong></div><div class="stat"><span>Seed</span><strong>',
                    _uintToString(masterSeed),
                    '</strong></div><div class="stat"><span>Price (RARE)</span><strong>',
                    _formatDecimal(s.rarePerToken, 6),
                    '</strong></div><div class="stat"><span>Supply</span><strong>',
                    _uintToString(s.currentSupply),
                    '</strong></div><div class="stat"><span>Tick</span><strong>',
                    _intToString(int256(s.currentTick)),
                    '</strong></div><div class="stat"><span>Liquidity</span><strong>',
                    _uintToString(uint256(s.liquidity)),
                    '</strong></div></div></main></body></html>'
                )
            );
    }

    function _buildMarketAttributes(
        MarketSnapshot memory s
    ) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                '{"trait_type":"Price (RARE)","value":"',
                _formatDecimal(s.rarePerToken, 6),
                '"},{"trait_type":"Supply","value":"',
                _uintToString(s.currentSupply),
                '"},{"trait_type":"Tick","value":"',
                _intToString(int256(s.currentTick)),
                '"},{"trait_type":"Liquidity","value":"',
                _uintToString(uint256(s.liquidity)),
                '"}'
            )
        );
    }

    function _buildHTMLDataURI(
        string memory html
    ) internal pure returns (string memory) {
        return
            string(
                abi.encodePacked(
                    "data:text/html;base64,",
                    _base64Encode(bytes(html))
                )
            );
    }

    function _buildSVGDataURI(
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

    // ============================================================
    //                     UTILITY FUNCTIONS
    // ============================================================

    function _formatDecimal(
        uint256 value,
        uint256 decimals
    ) internal pure returns (string memory) {
        if (value == 0) return "0";
        if (decimals == 0) return _uintToString(value / 1e18);

        uint256 divisor = 10 ** (18 - decimals);
        uint256 wholePart = value / 1e18;
        uint256 fractionalPart = (value / divisor) % (10 ** decimals);

        if (fractionalPart == 0) return _uintToString(wholePart);

        string memory fractionalStr = _uintToString(fractionalPart);
        while (bytes(fractionalStr).length < decimals) {
            fractionalStr = string(abi.encodePacked("0", fractionalStr));
        }
        return string(abi.encodePacked(_uintToString(wholePart), ".", fractionalStr));
    }

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
            digits--;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    function _intToString(int256 value) internal pure returns (string memory) {
        if (value >= 0) return _uintToString(uint256(value));
        return string(abi.encodePacked("-", _uintToString(uint256(-value))));
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
            uint256 a2 = uint256(uint8(data[i]));
            uint256 b2 = uint256(uint8(data[i + 1]));
            uint256 bitmap2 = (a2 << 16) | (b2 << 8);

            result[j++] = table[bitmap2 >> 18];
            result[j++] = table[(bitmap2 >> 12) & 63];
            result[j++] = table[(bitmap2 >> 6) & 63];
            result[j++] = 0x3D;
        } else if (i + 1 == data.length) {
            uint256 a1 = uint256(uint8(data[i]));
            uint256 bitmap1 = a1 << 16;

            result[j++] = table[bitmap1 >> 18];
            result[j++] = table[(bitmap1 >> 12) & 63];
            result[j++] = 0x3D;
            result[j++] = 0x3D;
        }

        assembly {
            mstore(result, j)
        }

        return string(result);
    }
}
// forge-lint: disable-end(unsafe-typecast)
