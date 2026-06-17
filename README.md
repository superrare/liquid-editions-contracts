# Liquid Edition Contracts

A decentralized protocol for launching ERC-20 tokens with bonding curve-based pricing and automated liquidity provision on Uniswap V4.

## Overview

Liquid Edition Contracts is a smart contract suite that enables:
- **Token Creation**: Launch ERC-20 tokens with immediate Uniswap V4 liquidity
- **Bonding Curve**: Simulated bonding curve via constant-product AMM (900K tokens + 0.001 ETH)
- **Automated Market Making**: Direct Uniswap V4 PoolManager integration for all trades
- **Protocol Rewards**: Configurable fee distribution between beneficiaries and protocol (with RARE burn support)
- **RARE Token Integration**: Support for RARE token burning via V4 pools

## Core Contracts

### `LiquidFactory.sol`
The main factory contract for deploying new Liquid token instances. Manages protocol-wide settings including:
- Protocol fee configuration and recipient
- Integration with RAREBurner
- Token deployment and tracking
- V4 hooks, pool bootstrap parameters, and registry wiring
### `LiquidInstant.sol`
The instant-launch ERC-20 token implementation featuring:
- Uniswap V4 PoolManager integration via unlock callbacks
- Immediate pool creation with 900K tokens + configurable RARE liquidity
- Quote functions for buy/sell operations
- Creator launch reward distribution

### `LiquidGraduated.sol`
The graduated-launch ERC-20 token implementation featuring:
- CCA (Continuous Clearing Auction) integration via LBP strategy
- Pool creation at auction-discovered price (after graduation)
- Quote functions for buy/sell operations
- Creator launch reward distribution

### `LiquidMultiCurve.sol`
The multicurve anti-sniping ERC-20 token implementation featuring:
- Multiple concentrated liquidity positions for launch price protection
- Immediate pool creation with distributed liquidity across tick ranges
- Quote functions for buy/sell operations
- Creator launch reward distribution

### `LiquidRouter.sol`
Router contract enabling fee-wrapped trading for any registered ERC20 token:
- Routes swaps through Uniswap Universal Router (V2/V3/V4 support)
- Does not collect fees itself in-trade; V4 fee collection is performed in `LiquidGuard`
- through callback hooks, then forwarded to `FeeDistributor.notifyFee`
- Supports buy (ETH → token), sell (token → ETH), and swap (any → any) operations
- Uses Permit2 for secure token approvals
- Emits trade events with fee fields as zeros because the active split is applied downstream.

### `LiquidAuctioneer.sol`
Router contract for CCA auction interactions:
- Bid on auctions using ETH or ERC20 tokens (swapped to RARE)
- Exit bids and claim filled tokens
- Routes swaps through Uniswap Universal Router
- Uses legacy auction compatibility flow for native-ETH bid fees (`totalFeeBPS` + `distributeFees`), which is intentionally a compatibility no-op in current V4 distributor.

### `FeeDistributor.sol`
Fee distribution contract that splits trading fees:
- Skims RARE via `LiquidGuard` hooks, then attempts inline RARE→ETH conversion and distribution.
- Falls back to direct RARE forwarding when conversion is disabled, stale, or fails.
- Follows compatibility no-op behavior for legacy auction selectors (`totalFeeBPS`, etc.).
- Protocol fee recipient is immutable at construction.

### `LiquidRegistry.sol`
Centralized registry of valid Liquid tokens and their beneficiaries:
- Token registration requirement for Router and Auctioneer trading
- Beneficiary mapping for fee distribution
- Writer-based access control (factory can register tokens)

### `LiquidSwapGuard.sol`
Uniswap V4 hook that restricts swaps and pool initialization:
- Only whitelisted routers/callers can swap (prevents unauthorized direct swaps)
- Only whitelisted Liquid token contracts can initialize pools (prevents pool pre-initialization DoS)
- Uses IMsgSender trusted-router pattern

### `LiquidInitGuard.sol`
Lightweight Uniswap V4 hook that restricts pool initialization only:
- Only whitelisted Liquid token contracts can initialize pools
- Swaps are unrestricted (use when swap restriction not needed)
- Simpler alternative to LiquidSwapGuard

### `RAREBurner.sol`
Non-reverting ETH accumulator that performs best-effort RARE token burns:
- Converts ETH to RARE tokens via Uniswap V4 swaps
- Burns RARE tokens to designated burn address
- Configurable slippage protection
- V4 pool support only

### `V4LiquidityHelper.sol`
Helper contract for managing Uniswap V4 liquidity positions:
- Simplified V4 position management
- Liquidity addition and removal
- Position tracking and queries

## Canonical behavior map

Use [`docs/FLOW.md`](docs/FLOW.md) as the canonical onboarding and behavior reference.
It includes one concise flow summary each for:
- Create
- Buy
- Sell
- Swap
- Auction bid
- Fee conversion/distribution
- Burn

This doc also contains the required `Feature -> File -> Functions -> Events` mapping.

## Known compatibility / no-op behavior

- `IFeeDistributor.totalFeeBPS`, `quoteFeeBreakdown`, `distributeFees`, and `setTotalFeeBPS` are compatibility entrypoints for historical interfaces and no-ops in the active V4 path.
- `LiquidAuctioneer` native-ETH bid fee collection uses the legacy compatibility path via those selectors.
- Router event fields `ethFee`, `protocolFee`, and `beneficiaryFee` are intentionally zero in this architecture.

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
2. Initialize all git submodules recursively
3. Verify required dependency submodules are present
4. Build all contracts

### Manual Setup

```bash
# Install Foundry (if not already installed)
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Clone the repository
git clone --recurse-submodules <repository-url>
cd liquid-edition-contracts

# If you already cloned without --recurse-submodules
git submodule update --init --recursive

# Build contracts
forge build
```

### Maintainer Dependency Bootstrap

Use this once when normalizing dependency tracking so `lib/*` entries are committed as submodules:

```bash
# Remove non-submodule dependency folders and stale module metadata
rm -rf lib/forge-std lib/openzeppelin-contracts lib/openzeppelin-contracts-upgradeable lib/continuous-clearing-auction lib/v4-core lib/v4-periphery
rm -rf .git/modules/lib/forge-std .git/modules/lib/openzeppelin-contracts .git/modules/lib/openzeppelin-contracts-upgradeable .git/modules/lib/continuous-clearing-auction .git/modules/lib/v4-core .git/modules/lib/v4-periphery

# Re-add as forge-managed git submodules
git submodule add --force https://github.com/foundry-rs/forge-std lib/forge-std
git submodule add --force https://github.com/OpenZeppelin/openzeppelin-contracts lib/openzeppelin-contracts
git submodule add --force https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable lib/openzeppelin-contracts-upgradeable
git submodule add --force https://github.com/Uniswap/continuous-clearing-auction lib/continuous-clearing-auction
git submodule add --force https://github.com/Uniswap/v4-core lib/v4-core
git submodule add --force https://github.com/Uniswap/v4-periphery lib/v4-periphery

# Pin Uniswap revisions expected by this repo
git -C lib/v4-core checkout e50237c43811bd9b526eff40f26772152a42daba
git -C lib/v4-periphery checkout 3779387e5d296f39df543d23524b050f89a62917

# Persist submodule pointers
git add .gitmodules lib/forge-std lib/openzeppelin-contracts lib/openzeppelin-contracts-upgradeable lib/continuous-clearing-auction lib/v4-core lib/v4-periphery
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
│   ├── LiquidInstant.sol   # Instant-launch token implementation
│   ├── LiquidGraduated.sol # Graduated-launch token implementation
│   ├── LiquidMultiCurve.sol # Multicurve anti-sniping token implementation
│   ├── LiquidFactory.sol   # Factory contract
│   ├── LiquidRouter.sol    # Router for fee-wrapped trading
│   ├── LiquidAuctioneer.sol # Router for auction interactions
│   ├── LiquidSwapGuard.sol # V4 hook for swap/init restrictions
│   ├── LiquidInitGuard.sol # V4 hook for init-only restrictions
│   ├── FeeDistributor.sol  # Fee distribution contract
│   ├── LiquidRegistry.sol  # Token and beneficiary registry
│   ├── RAREBurner.sol      # RARE token burning
│   └── RoutePolicy.sol     # Universal Router route validation
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
