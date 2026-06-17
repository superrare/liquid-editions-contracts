// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @title Mock Burner for testing
/// @dev Receives ETH but does not perform actual burns. Used when RAREBurner is disabled or for simple ETH flow tests.
contract MockBurner {
    receive() external payable {}

    function depositForBurn() external payable {}
}
