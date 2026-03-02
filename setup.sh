#!/bin/bash
set -euo pipefail

V4_CORE_REV="e50237c43811bd9b526eff40f26772152a42daba"
V4_PERIPHERY_REV="3779387e5d296f39df543d23524b050f89a62917"

# Install Foundry if not already installed
if ! command -v forge &> /dev/null
then
    echo "Installing Foundry..."
    curl -L https://foundry.paradigm.xyz | bash
    source ~/.bashrc
    foundryup
fi

# Initialize tracked submodules (top-level + nested, e.g. doppler deps)
git submodule update --init --recursive

# Install missing dependencies required by remappings
if [ ! -d "lib/openzeppelin-contracts/contracts" ]; then
    forge install --no-git OpenZeppelin/openzeppelin-contracts
fi
if [ ! -d "lib/openzeppelin-contracts-upgradeable/contracts" ]; then
    forge install --no-git OpenZeppelin/openzeppelin-contracts-upgradeable
fi
if [ ! -d "lib/forge-std/src" ]; then
    forge install --no-git foundry-rs/forge-std
fi
# Pin Uniswap dependencies to known-good revisions from foundry.lock.
# If an incompatible version is present, replace it.
if [ ! -f "lib/v4-core/.liquid-editions-rev" ] || [ "$(cat lib/v4-core/.liquid-editions-rev 2>/dev/null)" != "${V4_CORE_REV}" ]; then
    rm -rf lib/v4-core
    forge install --no-git "Uniswap/v4-core@rev=${V4_CORE_REV}"
    printf "%s\n" "${V4_CORE_REV}" > lib/v4-core/.liquid-editions-rev
fi
if [ ! -f "lib/v4-periphery/.liquid-editions-rev" ] || [ "$(cat lib/v4-periphery/.liquid-editions-rev 2>/dev/null)" != "${V4_PERIPHERY_REV}" ]; then
    rm -rf lib/v4-periphery
    forge install --no-git "Uniswap/v4-periphery@rev=${V4_PERIPHERY_REV}"
    printf "%s\n" "${V4_PERIPHERY_REV}" > lib/v4-periphery/.liquid-editions-rev
fi
if [ ! -d "lib/continuous-clearing-auction/src" ]; then
    forge install --no-git Uniswap/continuous-clearing-auction
fi

# Build the project
forge build

echo "Setup complete!"
