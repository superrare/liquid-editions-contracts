#!/usr/bin/env ts-node
/**
 * @title Check Sepolia Deploy Readiness
 * @notice Validates configuration for full Liquid System deployment on Sepolia
 * @dev Checks:
 *   - Environment variables are set correctly
 *   - NetworkConfig has correct addresses
 *   - DeployConfig uses LiquidGuard (not SwapGuard)
 *   - Factory will be configured with LiquidGuard
 *   - RAREBurner exists and won't be redeployed
 */

import { config } from "dotenv";
import { readFileSync } from "fs";
import { join } from "path";

config();

interface ConfigCheck {
  name: string;
  status: "✅" | "❌" | "⚠️";
  message: string;
}

const checks: ConfigCheck[] = [];

// Check environment variables
function checkEnvVars() {
  const requiredVars = [
    "DEPLOYER_PRIVATE_KEY",
    "PROTOCOL_FEE_RECIPIENT",
    "ETH_SEPOLIA",
  ];

  const deployFlags = {
    DEPLOY_BURNER: false,
    DEPLOY_LIQUID_GUARD: true,
    DEPLOY_SWAP_GUARD: false,
    DEPLOY_FACTORY: true,
    DEPLOY_ROUTER: true,
    DEPLOY_AUCTIONEER: true,
  };

  // Check required vars
  for (const varName of requiredVars) {
    const value = process.env[varName];
    if (!value) {
      checks.push({
        name: `Env: ${varName}`,
        status: "❌",
        message: `Missing required environment variable: ${varName}`,
      });
    } else {
      checks.push({
        name: `Env: ${varName}`,
        status: "✅",
        message: `Set: ${varName.substring(0, 20)}...`,
      });
    }
  }

  // Check deploy flags
  for (const [key, expectedValue] of Object.entries(deployFlags)) {
    const actualValue = process.env[key] === "true";
    if (actualValue !== expectedValue) {
      checks.push({
        name: `Deploy Flag: ${key}`,
        status: "❌",
        message: `Expected ${expectedValue}, got ${actualValue}. Update .env file.`,
      });
    } else {
      checks.push({
        name: `Deploy Flag: ${key}`,
        status: "✅",
        message: `Correctly set to ${expectedValue}`,
      });
    }
  }
}

// Check DeployConfig
function checkDeployConfig() {
  const deployConfigPath = join(
    __dirname,
    "../script/config/DeployConfig.sol"
  );
  const deployConfigContent = readFileSync(deployConfigPath, "utf-8");

  // Check useLiquidGuard is true
  if (deployConfigContent.includes("useLiquidGuard: true")) {
    checks.push({
      name: "DeployConfig: useLiquidGuard",
      status: "✅",
      message: "useLiquidGuard is set to true",
    });
  } else {
    checks.push({
      name: "DeployConfig: useLiquidGuard",
      status: "❌",
      message: "useLiquidGuard must be set to true",
    });
  }

  // Check useSwapGuard is false
  if (deployConfigContent.includes("useSwapGuard: false")) {
    checks.push({
      name: "DeployConfig: useSwapGuard",
      status: "✅",
      message: "useSwapGuard is set to false",
    });
  } else {
    checks.push({
      name: "DeployConfig: useSwapGuard",
      status: "❌",
      message: "useSwapGuard must be set to false",
    });
  }
}

// Check NetworkConfig for Sepolia
function checkNetworkConfig() {
  const networkConfigPath = join(
    __dirname,
    "../script/config/NetworkConfig.sol"
  );
  const networkConfigContent = readFileSync(networkConfigPath, "utf-8");

  // Extract Sepolia config (chainId 11155111)
  const sepoliaMatch = networkConfigContent.match(
    /chainId == 11155111[\s\S]*?liquid: LiquidAddresses\(\{[\s\S]*?\}\)/
  );

  if (!sepoliaMatch) {
    checks.push({
      name: "NetworkConfig: Sepolia",
      status: "❌",
      message: "Could not find Sepolia configuration",
    });
    return;
  }

  const sepoliaConfig = sepoliaMatch[0];

  // Check RAREBurner exists (should not be address(0))
  if (sepoliaConfig.includes("rareBurner: 0x")) {
    const burnerMatch = sepoliaConfig.match(/rareBurner: (0x[a-fA-F0-9]{40})/);
    if (burnerMatch && burnerMatch[1] !== "address(0)") {
      checks.push({
        name: "NetworkConfig: RAREBurner",
        status: "✅",
        message: `RAREBurner exists: ${burnerMatch[1]}`,
      });
    } else {
      checks.push({
        name: "NetworkConfig: RAREBurner",
        status: "⚠️",
        message: "RAREBurner is address(0) - will use existing from NetworkConfig",
      });
    }
  }

  // Check factory exists
  if (sepoliaConfig.includes("factory: 0x")) {
    const factoryMatch = sepoliaConfig.match(/factory: (0x[a-fA-F0-9]{40})/);
    if (factoryMatch) {
      checks.push({
        name: "NetworkConfig: Factory",
        status: "✅",
        message: `Factory exists: ${factoryMatch[1]}`,
      });
    }
  }

  // Check liquidGuard is address(0) (will be deployed)
  if (sepoliaConfig.includes("liquidGuard: address(0)")) {
    checks.push({
      name: "NetworkConfig: LiquidGuard",
      status: "✅",
      message: "LiquidGuard is address(0) - will be deployed",
    });
  } else {
    checks.push({
      name: "NetworkConfig: LiquidGuard",
      status: "⚠️",
      message: "LiquidGuard already set - may be using existing",
    });
  }

  // Check swapGuard status
  if (sepoliaConfig.includes("swapGuard: address(0)")) {
    checks.push({
      name: "NetworkConfig: SwapGuard",
      status: "✅",
      message: "SwapGuard is address(0) - will not be used",
    });
  } else {
    const swapGuardMatch = sepoliaConfig.match(/swapGuard: (0x[a-fA-F0-9]{40})/);
    if (swapGuardMatch) {
      checks.push({
        name: "NetworkConfig: SwapGuard",
        status: "⚠️",
        message: `SwapGuard exists: ${swapGuardMatch[1]} - ensure factory uses LiquidGuard instead`,
      });
    }
  }
}

// Check if LiquidGuard implements required interface for factory validation
function checkLiquidGuardCompatibility() {
  const liquidGuardPath = join(__dirname, "../src/LiquidGuard.sol");
  const liquidGuardContent = readFileSync(liquidGuardPath, "utf-8");

  // Check if LiquidGuard has factory (public variable creates getter)
  if (
    liquidGuardContent.includes("address public factory") ||
    liquidGuardContent.includes("function factory()")
  ) {
    checks.push({
      name: "LiquidGuard: factory() method",
      status: "✅",
      message: "LiquidGuard has factory (public variable creates getter)",
    });
  } else {
    checks.push({
      name: "LiquidGuard: factory() method",
      status: "❌",
      message: "LiquidGuard missing factory",
    });
  }

  // Check if LiquidGuard implements ILiquidGuard
  if (liquidGuardContent.includes("ILiquidGuard")) {
    checks.push({
      name: "LiquidGuard: ILiquidGuard interface",
      status: "✅",
      message: "LiquidGuard implements ILiquidGuard",
    });
  }
}

// Check factory validation logic
function checkFactoryValidation() {
  const factoryPath = join(__dirname, "../src/LiquidFactory.sol");
  const factoryContent = readFileSync(factoryPath, "utf-8");

  // Check if factory supports ILiquidGuard (LiquidGuard)
  if (
    factoryContent.includes("ILiquidGuard") &&
    !factoryContent.includes("try ILiquidSwapGuard")
  ) {
    checks.push({
      name: "Factory: Hook Validation",
      status: "✅",
      message: "Factory supports ILiquidGuard-based hook validation",
    });
  } else if (
    factoryContent.includes("ILiquidSwapGuard") &&
    !factoryContent.includes("ILiquidGuard")
  ) {
    checks.push({
      name: "Factory: Hook Validation",
      status: "❌",
      message:
        "Factory only supports ILiquidSwapGuard - needs update for LiquidGuard",
    });
  } else {
    checks.push({
      name: "Factory: Hook Validation",
      status: "⚠️",
      message: "Could not verify factory hook validation support",
    });
  }

  // Check if addInitializer uses ILiquidGuard
  if (
    factoryContent.includes("ILiquidGuard(poolHooks).addInitializer")
  ) {
    checks.push({
      name: "Factory: addInitializer Support",
      status: "✅",
      message: "Factory addInitializer uses ILiquidGuard",
    });
  } else {
    checks.push({
      name: "Factory: addInitializer Support",
      status: "❌",
      message: "Factory addInitializer does not call ILiquidGuard.addInitializer",
    });
  }
}

// Main execution
function main() {
  console.log("========================================");
  console.log("Sepolia Deployment Readiness Check");
  console.log("========================================");
  console.log("");

  checkEnvVars();
  checkDeployConfig();
  checkNetworkConfig();
  checkLiquidGuardCompatibility();
  checkFactoryValidation();

  // Print results
  console.log("Check Results:");
  console.log("-------------");
  let allPassed = true;
  let warnings = 0;

  for (const check of checks) {
    console.log(`${check.status} ${check.name}: ${check.message}`);
    if (check.status === "❌") {
      allPassed = false;
    }
    if (check.status === "⚠️") {
      warnings++;
    }
  }

  console.log("");
  console.log("========================================");
  if (allPassed && warnings === 0) {
    console.log("✅ All checks passed! Ready to deploy.");
  } else if (allPassed) {
    console.log(
      `⚠️  All critical checks passed, but ${warnings} warning(s) found. Review before deploying.`
    );
  } else {
    console.log("❌ Some checks failed. Fix issues before deploying.");
  }
  console.log("========================================");
  console.log("");

  // Summary of deployment plan
  console.log("Deployment Plan Summary:");
  console.log("------------------------");
  console.log("✓ RAREBurner: Will use existing (not redeploying)");
  console.log("✓ LiquidGuard: Will be deployed");
  console.log("✓ FeeDistributor: Will be deployed (for LiquidGuard)");
  console.log("✓ Factory: Will be deployed (configured with LiquidGuard)");
  console.log("✓ Router: Will be deployed");
  console.log("✓ Auctioneer: Will be deployed");
  console.log("✓ LiquidRegistry: Check if needs deployment");
  console.log("");
  console.log(
    "⚠️  IMPORTANT: After deployment, verify factory.poolHooks() is set to LiquidGuard address"
  );
  console.log(
    "⚠️  IMPORTANT: Verify LiquidGuard.factory() is set to Factory address"
  );
  console.log(
    "⚠️  IMPORTANT: Verify FeeDistributor.setHookApproval(LiquidGuard, true) was called"
  );
}

main();
