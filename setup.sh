#!/bin/bash
set -euo pipefail

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

# Verify required dependency submodules are present
required_paths=(
    "lib/forge-std/src"
    "lib/openzeppelin-contracts/contracts"
    "lib/openzeppelin-contracts-upgradeable/contracts"
    "lib/v4-core/src"
    "lib/v4-periphery/src"
    "lib/continuous-clearing-auction/src"
    "lib/doppler/src"
)

for path in "${required_paths[@]}"; do
    if [ ! -e "$path" ]; then
        echo "Missing dependency path: $path"
        echo "Dependencies are expected to be committed as git submodules."
        echo "Run dependency bootstrap from a branch that includes submodule pointers,"
        echo "or install and commit them with forge submodules."
        exit 1
    fi
done

# Build the project
forge build

echo "Setup complete!"
