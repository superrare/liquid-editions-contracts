#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

/**
 * Script to compile all Solidity contracts and tests into text files
 * 
 * Usage:
 *   node compile-contracts.js                    # Creates compiled-contracts.txt and compiled-tests.txt
 *   node compile-contracts.js my-contracts.txt   # Creates my-contracts.txt and my-tests.txt
 *   ./compile-contracts.js                       # Same as first option (if executable)
 * 
 * Features:
 * - Recursively scans src/ and test/ directories for .sol files
 * - Maintains file structure and organization
 * - Adds clear file separators and headers
 * - Includes compilation metadata (timestamp, file count)
 * - Handles errors gracefully
 * - Sorts files alphabetically for consistent output
 */

const SRC_DIR = path.join(__dirname, 'src');
const TEST_DIR = path.join(__dirname, 'test');
const DEFAULT_CONTRACTS_OUTPUT = 'compiled-contracts.txt';
const DEFAULT_TESTS_OUTPUT = 'compiled-tests.txt';

// Get output files from command line argument or use defaults
const contractsOutputFile = process.argv[2] || DEFAULT_CONTRACTS_OUTPUT;
// Derive test output file name from contracts output file
const testsOutputFile = process.argv[2] 
    ? contractsOutputFile.replace(/\.txt$/, '').replace(/contracts/i, 'tests') + '.txt'
    : DEFAULT_TESTS_OUTPUT;

/**
 * Recursively find all .sol files in a directory
 */
function findSolidityFiles(dir) {
    const files = [];
    
    function traverse(currentDir) {
        const items = fs.readdirSync(currentDir);
        
        for (const item of items) {
            const fullPath = path.join(currentDir, item);
            const stat = fs.statSync(fullPath);
            
            if (stat.isDirectory()) {
                traverse(fullPath);
            } else if (item.endsWith('.sol')) {
                files.push(fullPath);
            }
        }
    }
    
    traverse(dir);
    return files.sort(); // Sort for consistent ordering
}

/**
 * Format file content with header and separator
 */
function formatFileContent(filePath, content) {
    const relativePath = path.relative(__dirname, filePath);
    const separator = '='.repeat(80);
    const header = `FILE: ${relativePath}`;
    
    return `${separator}\n${header}\n${separator}\n\n${content}\n\n`;
}

/**
 * Compile files from a directory to an output file
 */
function compileDirectory(dir, outputFile, title) {
    try {
        console.log(`\n🔍 Scanning ${title}...`);
        
        // Check if directory exists
        if (!fs.existsSync(dir)) {
            console.warn(`⚠️  Directory not found: ${dir}, skipping...`);
            return false;
        }
        
        // Find all .sol files
        const solidityFiles = findSolidityFiles(dir);
        
        if (solidityFiles.length === 0) {
            console.warn(`⚠️  No Solidity files found in ${dir}, skipping...`);
            return false;
        }
        
        console.log(`📄 Found ${solidityFiles.length} Solidity files:`);
        solidityFiles.forEach(file => {
            console.log(`   - ${path.relative(__dirname, file)}`);
        });
        
        // Compile all files into a single string
        let compiledContent = '';
        compiledContent += `${title.toUpperCase()}\n`;
        compiledContent += `Generated on: ${new Date().toISOString()}\n`;
        compiledContent += `Total files: ${solidityFiles.length}\n`;
        compiledContent += `${'='.repeat(80)}\n\n`;
        
        for (const filePath of solidityFiles) {
            try {
                const content = fs.readFileSync(filePath, 'utf8');
                compiledContent += formatFileContent(filePath, content);
                console.log(`✅ Processed: ${path.relative(__dirname, filePath)}`);
            } catch (error) {
                console.error(`❌ Error reading ${filePath}:`, error.message);
                compiledContent += formatFileContent(filePath, `ERROR: Could not read file - ${error.message}`);
            }
        }
        
        // Write compiled content to output file
        fs.writeFileSync(outputFile, compiledContent, 'utf8');
        
        console.log(`🎉 Successfully compiled to: ${outputFile}`);
        console.log(`📊 Output file size: ${(fs.statSync(outputFile).size / 1024).toFixed(2)} KB`);
        
        return true;
    } catch (error) {
        console.error(`❌ Compilation failed for ${title}:`, error.message);
        return false;
    }
}

/**
 * Main compilation function
 */
function compileContracts() {
    try {
        console.log('='.repeat(80));
        console.log('LIQUID EDITION CONTRACTS & TESTS COMPILATION');
        console.log('='.repeat(80));
        
        let contractsSuccess = compileDirectory(
            SRC_DIR, 
            contractsOutputFile, 
            'Liquid Edition Contracts Compilation'
        );
        
        let testsSuccess = compileDirectory(
            TEST_DIR, 
            testsOutputFile, 
            'Liquid Edition Tests Compilation'
        );
        
        console.log('\n' + '='.repeat(80));
        if (contractsSuccess || testsSuccess) {
            console.log('✅ Compilation complete!');
            if (contractsSuccess) console.log(`   Contracts: ${contractsOutputFile}`);
            if (testsSuccess) console.log(`   Tests: ${testsOutputFile}`);
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

module.exports = { compileContracts, compileDirectory, findSolidityFiles };
