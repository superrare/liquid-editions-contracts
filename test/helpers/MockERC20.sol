// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Mock ERC20 Token for testing
/// @dev Includes Permit2 simulation for sell testing (LiquidRouter pulls via Permit2)
contract MockERC20 is IERC20 {
    string public name = "Mock Token";
    string public symbol = "MOCK";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /// @notice Canonical Permit2 address (same on all chains)
    address internal constant PERMIT2 =
        0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function transfer(
        address to,
        uint256 amount
    ) external virtual returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external virtual returns (bool) {
        // Check if spender has direct allowance OR if Permit2 has allowance
        // This simulates how Permit2 allows approved protocols to pull tokens
        if (allowance[from][msg.sender] >= amount) {
            allowance[from][msg.sender] -= amount;
        } else if (allowance[from][PERMIT2] >= amount) {
            allowance[from][PERMIT2] -= amount;
        } else {
            revert("ERC20: insufficient allowance");
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// @title Mock Fee-On-Transfer ERC20
/// @dev Burns 1% on each transfer/transferFrom to simulate deflationary behavior
contract MockFeeOnTransferToken is MockERC20 {
    uint256 public constant FEE_BPS = 100; // 1%

    function transfer(
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        uint256 fee = (amount * FEE_BPS) / 10_000;
        uint256 sendAmount = amount - fee;

        balanceOf[msg.sender] -= amount;
        balanceOf[to] += sendAmount;
        totalSupply -= fee;

        emit Transfer(msg.sender, to, sendAmount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        if (allowance[from][msg.sender] >= amount) {
            allowance[from][msg.sender] -= amount;
        } else if (allowance[from][PERMIT2] >= amount) {
            allowance[from][PERMIT2] -= amount;
        } else {
            revert("ERC20: insufficient allowance");
        }

        uint256 fee = (amount * FEE_BPS) / 10_000;
        uint256 sendAmount = amount - fee;

        balanceOf[from] -= amount;
        balanceOf[to] += sendAmount;
        totalSupply -= fee;

        emit Transfer(from, to, sendAmount);
        return true;
    }
}
