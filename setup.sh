#!/bin/bash

# Install Foundry if not already installed
if ! command -v forge &> /dev/null
then
    echo "Installing Foundry..."
    curl -L https://foundry.paradigm.xyz | bash
    source ~/.bashrc
    foundryup
fi

# Install dependencies
forge install OpenZeppelin/openzeppelin-contracts
forge install foundry-rs/forge-std

# Build the project
forge build

echo "Setup complete!" 