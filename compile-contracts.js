#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

/**
 * Script to compile all Solidity contracts and tests into text files
 *
 * Usage:
 *   node compile-contracts.js                    # Creates compiled-*.txt files
 *   node compile-contracts.js my-prefix          # Creates my-prefix-*.txt files
 *   ./compile-contracts.js                       # Same as first option (if executable)
 *
 * Output files:
 *   - compiled-contracts.txt         Main Liquid Edition contracts (src/)
 *   - compiled-script-config-and-deploy.txt  Script config + deployment and submodules:
 *                                      - script/config/NetworkConfig.sol, DeployConfig.sol
 *                                      - script/DeployLiquidSystem.s.sol
 *                                      - script/deployers/* (all deployers used by DeployLiquidSystem)
 *   - compiled-tests.txt             Test files (test/)
 *   - compiled-deps-uniswap-v4-core.txt     Key Uniswap V4 core contracts
 *   - compiled-deps-uniswap-v4-periphery.txt Key Uniswap V4 periphery contracts
 *   - compiled-deps-doppler.txt              Key Doppler contracts (Multicurve, Position)
 *   - compiled-deps-continuous-clearing-auction.txt  Key continuous-clearing-auction interfaces
 */

const ROOT = __dirname;
const SRC_DIR = path.join(ROOT, 'src');
const TEST_DIR = path.join(ROOT, 'test');
const SCRIPT_DIR = path.join(ROOT, 'script');
const LIB_DIR = path.join(ROOT, 'lib');

// Script config + deployment and all deployer submodules (order: config, main script, deployers)
const SCRIPT_CONFIG_AND_DEPLOY_FILES = [
    path.join(SCRIPT_DIR, 'config', 'NetworkConfig.sol'),
    path.join(SCRIPT_DIR, 'config', 'DeployConfig.sol'),
    path.join(SCRIPT_DIR, 'DeployLiquidSystem.s.sol'),
    path.join(SCRIPT_DIR, 'deployers', 'DeployRAREBurner.s.sol'),
    path.join(SCRIPT_DIR, 'deployers', 'DeployLiquidFactory.s.sol'),
    path.join(SCRIPT_DIR, 'deployers', 'DeployLiquid.s.sol'),
    path.join(SCRIPT_DIR, 'deployers', 'DeployLiquidMultiCurve.s.sol'),
    path.join(SCRIPT_DIR, 'deployers', 'DeployLiquidGraduated.s.sol'),
    path.join(SCRIPT_DIR, 'deployers', 'DeployLiquidRouter.s.sol'),
    path.join(SCRIPT_DIR, 'deployers', 'DeployLiquidAuctioneer.s.sol'),
    path.join(SCRIPT_DIR, 'deployers', 'DeployLiquidSwapGuard.s.sol'),
    path.join(SCRIPT_DIR, 'deployers', 'DeployLiquidInitGuard.s.sol'),
    path.join(SCRIPT_DIR, 'deployers', 'DeployLiquidGuard.s.sol'),
    path.join(SCRIPT_DIR, 'deployers', 'DeployLiquidMigrationExecutor.s.sol'),
    path.join(SCRIPT_DIR, 'deployers', 'DeployLiquidSystemReconcile.s.sol'),
];

// Files and directories to exclude from src/ compilation
const SRC_EXCLUDES = [
    path.join(SRC_DIR, 'examples'),        // Exclude examples directory
];

// Output prefix from CLI (e.g. "compiled" or "my-prefix")
const outputPrefix = process.argv[2] || 'compiled';

// Major dependency files to include (relative to lib/)
const DEPENDENCY_SETS = {
    'uniswap-v4-core': {
        title: 'Uniswap V4 Core (v4-core)',
        basePath: path.join(LIB_DIR, 'v4-core', 'src'),
        files: [
            'PoolManager.sol',
            'interfaces/IPoolManager.sol',
            'interfaces/IHooks.sol',
            'interfaces/callback/IUnlockCallback.sol',
            'types/PoolKey.sol',
            'types/PoolId.sol',
            'types/Currency.sol',
            'types/BalanceDelta.sol',
            'types/BeforeSwapDelta.sol',
            'libraries/TickMath.sol',
            'libraries/StateLibrary.sol',
            'libraries/FullMath.sol',
            'libraries/FixedPoint96.sol',
            'libraries/Hooks.sol',
        ],
    },
    'uniswap-v4-periphery': {
        title: 'Uniswap V4 Periphery (v4-periphery)',
        basePath: path.join(LIB_DIR, 'v4-periphery', 'src'),
        files: [
            'lens/V4Quoter.sol',
            'interfaces/IV4Quoter.sol',
            'interfaces/IMsgSender.sol',
            'libraries/QuoterRevert.sol',
        ],
    },
    'doppler': {
        title: 'Doppler',
        basePath: path.join(LIB_DIR, 'doppler', 'src'),
        files: [
            'libraries/Multicurve.sol',
            'types/Position.sol',
        ],
    },
    'continuous-clearing-auction': {
        title: 'Continuous Clearing Auction',
        basePath: path.join(LIB_DIR, 'continuous-clearing-auction', 'src'),
        files: [
            'interfaces/external/IDistributionStrategy.sol',
            'interfaces/IContinuousClearingAuction.sol',
        ],
    },
};

/**
 * Recursively find all .sol files in a directory
 */
function findSolidityFiles(dir, excludes = []) {
    const files = [];

    function traverse(currentDir) {
        const items = fs.readdirSync(currentDir);

        for (const item of items) {
            const fullPath = path.join(currentDir, item);

            // Skip excluded files and directories
            if (excludes.some((ex) => fullPath === ex || fullPath.startsWith(ex + path.sep))) {
                continue;
            }

            const stat = fs.statSync(fullPath);

            if (stat.isDirectory()) {
                traverse(fullPath);
            } else if (item.endsWith('.sol')) {
                files.push(fullPath);
            }
        }
    }

    traverse(dir);
    return files.sort();
}

/**
 * Format file content with header and separator
 */
function formatFileContent(filePath, content) {
    const relativePath = path.relative(ROOT, filePath);
    const separator = '='.repeat(80);
    const header = `FILE: ${relativePath}`;

    return `${separator}\n${header}\n${separator}\n\n${content}\n\n`;
}

/**
 * Compile a list of files to an output file
 */
function compileFileList(files, outputFile, title, options = {}) {
    const shouldAppend = options.append ?? false;
    let compiledContent = '';
    const leading = shouldAppend && fs.existsSync(outputFile) ? '\n' : '';
    compiledContent += `${title.toUpperCase()}\n`;
    compiledContent += `Generated on: ${new Date().toISOString()}\n`;
    compiledContent += `Total files: ${files.length}\n`;
    compiledContent += `${'='.repeat(80)}\n\n`;

    for (const filePath of files) {
        try {
            const content = fs.readFileSync(filePath, 'utf8');
            compiledContent += formatFileContent(filePath, content);
            console.log(`   ✅ ${path.relative(ROOT, filePath)}`);
        } catch (error) {
            console.error(`   ❌ ${filePath}: ${error.message}`);
            compiledContent += formatFileContent(filePath, `ERROR: Could not read file - ${error.message}`);
        }
    }

    fs.writeFileSync(outputFile, leading + compiledContent, {
        flag: shouldAppend ? 'a' : 'w',
        encoding: 'utf8',
    });
    return files.length;
}

/**
 * Compile files from a directory to an output file
 */
function compileDirectory(dir, outputFile, title, excludes = []) {
    try {
        if (!fs.existsSync(dir)) {
            console.warn(`⚠️  Directory not found: ${dir}, skipping...`);
            return false;
        }

        const solidityFiles = findSolidityFiles(dir, excludes);

        if (solidityFiles.length === 0) {
            console.warn(`⚠️  No Solidity files found in ${dir}, skipping...`);
            return false;
        }

        console.log(`\n🔍 ${title} (${solidityFiles.length} files)`);
        const count = compileFileList(solidityFiles, outputFile, title);
        console.log(`   📄 Output: ${path.relative(ROOT, outputFile)} (${(fs.statSync(outputFile).size / 1024).toFixed(2)} KB)`);
        return true;
    } catch (error) {
        console.error(`❌ Compilation failed for ${title}:`, error.message);
        return false;
    }
}

/**
 * Compile a dependency set to an output file
 */
function compileDependencySet(key, outputFile) {
    const config = DEPENDENCY_SETS[key];
    if (!config) return false;

    const basePath = config.basePath;
    if (!fs.existsSync(basePath)) {
        console.warn(`⚠️  Dependency dir not found: ${basePath}, skipping ${key}...`);
        return false;
    }

    const files = config.files
        .map((f) => path.join(basePath, f))
        .filter((p) => fs.existsSync(p));

    if (files.length === 0) {
        console.warn(`⚠️  No files found for ${key}, skipping...`);
        return false;
    }

    console.log(`\n🔍 ${config.title} (${files.length} files)`);
    compileFileList(files, outputFile, config.title);
    console.log(`   📄 Output: ${path.relative(ROOT, outputFile)} (${(fs.statSync(outputFile).size / 1024).toFixed(2)} KB)`);
    return true;
}

/**
 * Main compilation function
 */
function compileContracts() {
    try {
        console.log('='.repeat(80));
        console.log('LIQUID EDITION CONTRACTS & TESTS COMPILATION');
        console.log('='.repeat(80));

        const outputs = [];

        // 1. Main contracts (src/)
        const contractsFile = path.join(ROOT, `${outputPrefix}-contracts.txt`);
        if (compileDirectory(SRC_DIR, contractsFile, 'Liquid Edition Contracts', SRC_EXCLUDES)) {
            outputs.push(contractsFile);
        }

        // 2. Script config + deployment and deployer submodules (own file)
        const scriptDeployFile = path.join(ROOT, `${outputPrefix}-script-config-and-deploy.txt`);
        const scriptDeployFiles = SCRIPT_CONFIG_AND_DEPLOY_FILES.filter((f) => fs.existsSync(f));
        if (scriptDeployFiles.length > 0) {
            console.log(`\n🔍 Script Config & Deployment (${scriptDeployFiles.length} files)`);
            compileFileList(scriptDeployFiles, scriptDeployFile, 'Script Config & Deployment');
            console.log(`   📄 Output: ${path.relative(ROOT, scriptDeployFile)} (${(fs.statSync(scriptDeployFile).size / 1024).toFixed(2)} KB)`);
            outputs.push(scriptDeployFile);
        }

        // 3. Tests (test/)
        const testsFile = path.join(ROOT, `${outputPrefix}-tests.txt`);
        if (compileDirectory(TEST_DIR, testsFile, 'Liquid Edition Tests')) {
            outputs.push(testsFile);
        }

        // 4. Dependency sets
        for (const key of Object.keys(DEPENDENCY_SETS)) {
            const depFile = path.join(ROOT, `${outputPrefix}-deps-${key}.txt`);
            if (compileDependencySet(key, depFile)) {
                outputs.push(depFile);
            }
        }

        console.log('\n' + '='.repeat(80));
        if (outputs.length > 0) {
            console.log('✅ Compilation complete!');
            outputs.forEach((f) => console.log(`   ${path.relative(ROOT, f)}`));
        } else {
            console.log('⚠️  No files were compiled');
        }
        console.log('='.repeat(80));
    } catch (error) {
        console.error('❌ Compilation failed:', error.message);
        process.exit(1);
    }
}

// Run the compilation
if (require.main === module) {
    compileContracts();
}

module.exports = {
    compileContracts,
    compileDirectory,
    compileDependencySet,
    findSolidityFiles,
    DEPENDENCY_SETS,
    SCRIPT_CONFIG_AND_DEPLOY_FILES,
};
