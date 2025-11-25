# Liquid Edition Contracts

A decentralized protocol for launching ERC-20 tokens with bonding curve-based pricing and automated liquidity provision on Uniswap V4.

## Overview

Liquid Edition Contracts is a smart contract suite that enables:
- **Token Creation**: Launch ERC-20 tokens with immediate Uniswap V4 liquidity
- **Bonding Curve**: Simulated bonding curve via constant-product AMM (900K tokens + 0.001 ETH)
- **Automated Market Making**: Direct Uniswap V4 PoolManager integration for all trades
- **Protocol Rewards**: Configurable three-tier fee distribution (creator, protocol, referrer, RARE burn)
- **RARE Token Integration**: Support for RARE token burning via V4 pools

## Core Contracts

### `LiquidFactory.sol`
The main factory contract for deploying new Liquid token instances. Manages protocol-wide settings including:
- Protocol fee configuration and recipient
- Integration with RAREBurner
- Token deployment and tracking

### `Liquid.sol`
The primary ERC-20 token implementation featuring:
- Uniswap V4 PoolManager integration via unlock callbacks
- Buy/sell functionality with native ETH (no WETH for trades)
- Immediate pool creation with 900K tokens + configurable ETH
- Automated LP fee collection and distribution
- Creator and protocol fee distribution with RARE burn support

### `RAREBurner.sol`
Handles RARE token burning through Uniswap swaps:
- Converts ETH to RARE tokens
- Burns RARE tokens to designated burn address
- Configurable slippage protection
- V3 and V4 pool support

### `V4LiquidityHelper.sol`
Helper contract for managing Uniswap V4 liquidity positions:
- Simplified V4 position management
- Liquidity addition and removal
- Position tracking and queries

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (includes `forge`, `cast`, and `anvil`)
- Node.js and npm (optional, for additional tooling)
- An RPC provider (Alchemy, Infura, QuickNode, etc.)
- A wallet with ETH for deployment (private key)

## Installation

### Quick Setup

Run the automated setup script:

```bash
chmod +x setup.sh
./setup.sh
```

This will:
1. Install Foundry (if not already installed)
2. Install OpenZeppelin and Forge-std dependencies
3. Build all contracts

### Manual Setup

```bash
# Install Foundry (if not already installed)
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Clone the repository
git clone <repository-url>
cd liquid-edition-contracts

# Install dependencies
forge install OpenZeppelin/openzeppelin-contracts
forge install OpenZeppelin/openzeppelin-contracts-upgradeable
forge install foundry-rs/forge-std
forge install Uniswap/v4-core

# Build contracts
forge build
```

## Configuration

### Environment Setup

1. Copy the example environment file:
```bash
cp env.example .env
```

2. Configure required variables in `.env`:

```bash
# Required for all deployments
DEPLOYER_PRIVATE_KEY=your_private_key_here

# RPC Configuration
ALCHEMY_API_KEY=your_alchemy_api_key_here

# These will be constructed automatically
MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}
BASE_RPC_URL=https://base-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}
BASE_SEPOLIA_RPC_URL=https://base-sepolia.g.alchemy.com/v2/${ALCHEMY_API_KEY}

# Required for LiquidFactory deployment
PROTOCOL_FEE_RECIPIENT=0x...  # Address to receive protocol fees
```

### Network Configuration

Network-specific addresses (Uniswap routers, RARE token, WETH, etc.) are configured in `script/NetworkConfig.sol`. Supported networks:
- Ethereum Mainnet (Chain ID: 1)
- Base Mainnet (Chain ID: 8453)
- Base Sepolia (Chain ID: 84532)

## Testing

The project includes a comprehensive test suite covering unit tests, integration tests, and invariant tests.

### Run All Tests

```bash
make test
```

### Run Specific Test Suites

```bash
# Factory tests
make test-factory

# Basic Liquid token tests
make test-liquid

# Mainnet integration tests
make test-mainnet

# Bonding curve analysis
make test-bonding

# Bonding curve explorer (interactive)
make test-bonding-explorer

# RAREBurner tests
make test-burner

# Invariant tests
make test-invariants

# MEV protection tests
make test-mev

# Unit tests
make test-unit

# RARE burn configuration tests
make test-rare
```

### Coverage Reports

Generate test coverage:

```bash
# Summary report
make coverage

# HTML report (requires lcov: brew install lcov)
make coverage-report
```

## Deployment Guide

The deployment process follows a specific order due to contract dependencies.

### Step 1: Deploy RAREBurner

Required environment variables:
```bash
# Optional configuration (sensible defaults provided)
BURNER_TRY_ON_DEPOSIT=true
BURNER_POOL_FEE=3000
BURNER_TICK_SPACING=60
BURNER_HOOKS=0x0000000000000000000000000000000000000000
BURNER_BURN_ADDRESS=0x000000000000000000000000000000000000dEaD
BURNER_ENABLED=true
```

Deploy:
```bash
forge script script/RAREBurnerDeploy.s.sol:RAREBurnerDeploy \
  --rpc-url $BASE_RPC_URL \
  --broadcast \
  --verify
```

**Outputs:**
- RAREBurner contract address

### Step 2: Update NetworkConfig

Update `script/NetworkConfig.sol` with the deployed addresses for your target network:

```solidity
rareBurner: 0x...,       // From Step 1
```

### Step 3: Deploy LiquidFactory

Required environment variables:
```bash
PROTOCOL_FEE_RECIPIENT=0x...  # Address to receive protocol fees
```

Deploy:
```bash
forge script script/LiquidFactoryDeploy.s.sol:LiquidFactoryDeploy \
  --rpc-url $BASE_RPC_URL \
  --broadcast \
  --verify
```

**Outputs:**
- Liquid implementation contract address
- LiquidFactory contract address

### Step 4: Create a Token (Optional)

To create your first token through the factory:

Required environment variables:
```bash
FACTORY_ADDRESS=0x...         # From Step 4
TOKEN_CREATOR=0x...          # Address that will own the token
TOKEN_URI=ipfs://...         # Metadata URI for the token
TOKEN_NAME="My Token"        # Token name
TOKEN_SYMBOL="MTK"           # Token symbol
INITIAL_ETH=100000000000000000  # 0.1 ETH (optional)
```

Create token:
```bash
forge script script/CreateToken.s.sol:CreateToken \
  --rpc-url $BASE_RPC_URL \
  --broadcast
```

**Outputs:**
- New token contract address
- Token ID

## Advanced Operations

### Adding V4 Liquidity (Helper Contract)

After a token reaches its liquidity threshold and migrates to Uniswap V4, you can add liquidity:

```bash
# Set environment variables
ETH_AMOUNT=1000000000000000000     # 1 ETH
TOKEN_AMOUNT=1000000000000000000   # 1 token

forge script script/AddV4ViaHelper.s.sol:AddV4ViaHelper \
  --rpc-url $BASE_RPC_URL \
  --broadcast
```

### Deploy Custom V4 Pool

For advanced users who want to deploy a custom V4 pool:

```bash
# Optional pool configuration
SQRT_PRICE_X96=79228162514264337593543950336  # 1:1 price
POOL_FEE=3000
TICK_SPACING=60
TICK_LOWER=-120000
TICK_UPPER=120000
ADD_LIQUIDITY=true  # Automatically add liquidity after pool creation

forge script script/DeployV4Pool.s.sol:DeployV4Pool \
  --rpc-url $BASE_RPC_URL \
  --broadcast
```

### Verify Token Metadata

Verify that token metadata is correctly configured:

```bash
forge script script/VerifyTokenURI.s.sol:VerifyTokenURI \
  --rpc-url $BASE_RPC_URL
```

## Deployment Artifacts

Deployment information is automatically saved to the `deployments/` directory with timestamps. Each deployment creates a JSON file containing:
- All deployed contract addresses
- Transaction hashes
- Deployment parameters
- Network information

## Makefile Commands

The project includes a comprehensive Makefile for common operations:

```bash
make help              # Show all available commands
make test             # Run all tests
make test-factory     # Test factory contracts
make test-liquid      # Test Liquid token
make test-mainnet     # Test mainnet integrations
make coverage         # Generate coverage summary
make coverage-report  # Generate HTML coverage report
make clean           # Clean build artifacts
```

## Project Structure

```
liquid-edition-contracts/
├── src/                      # Contract source files
│   ├── interfaces/          # Contract interfaces
│   ├── Liquid.sol          # Main token implementation
│   ├── LiquidFactory.sol   # Factory contract
│   ├── RAREBurner.sol      # RARE token burning
│   ├── TickMath.sol        # Uniswap tick math library
│   └── V4LiquidityHelper.sol # V4 liquidity management
├── script/                  # Deployment scripts
│   ├── LiquidFactoryDeploy.s.sol
│   ├── RAREBurnerDeploy.s.sol
│   ├── CreateToken.s.sol
│   ├── AddV4ViaHelper.s.sol
│   ├── DeployV4Pool.s.sol
│   ├── NetworkConfig.sol   # Network-specific configuration
│   └── VerifyTokenURI.s.sol
├── test/                    # Test files
│   ├── LiquidFactory.mainnet.t.sol
│   ├── Liquid.mainnet.*.t.sol
│   ├── RAREBurner.*.t.sol
│   └── ...
├── lib/                     # Dependencies (forge-std, OpenZeppelin, v4-core)
├── deployments/            # Deployment artifacts (auto-generated)
├── docs/                   # Additional documentation
├── foundry.toml           # Foundry configuration
├── Makefile              # Build and test commands
├── setup.sh             # Automated setup script
└── env.example         # Environment variable template
```

## Security Considerations

- **Private Keys**: Never commit private keys or `.env` files to version control
- **RPC URLs**: Use secure RPC providers and keep API keys private
- **Testnet First**: Always test deployments on testnets (Base Sepolia) before mainnet
- **Verification**: Verify all contracts on block explorers for transparency
- **Access Control**: Carefully manage admin roles and protocol fee recipients
- **Audits**: Consider security audits before mainnet deployment

## Troubleshooting

### Build Errors

If you encounter build errors:
```bash
forge clean
forge build
```

### RPC Rate Limits

Tests use `--jobs 1` or `--jobs 2` to avoid rate limits. If you have a premium RPC provider:
```bash
forge test --jobs 4 -v  # Increase parallelism
```

### Stack Too Deep Errors

The project uses `via_ir = true` in `foundry.toml` to handle stack depth. If you still encounter issues:
```bash
forge build --optimize --optimizer-runs 200
```

## Additional Resources

- [Foundry Book](https://book.getfoundry.sh/)
- [Solidity Documentation](https://docs.soliditylang.org/)
- [Uniswap V3 Documentation](https://docs.uniswap.org/protocol/reference/core/interfaces/IUniswapV3Pool)
- [Uniswap V4 Documentation](https://docs.uniswap.org/contracts/v4/overview)
- [OpenZeppelin Contracts](https://docs.openzeppelin.com/contracts/)
