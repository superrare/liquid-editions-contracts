# Liquid Edition Contracts Makefile

# Load environment variables from .env.test file
-include .env.test
export

# Use environment variables for RPC URLs (fallback to public endpoints if not set)
FORK_URL ?= https://mainnet.base.org
SEPOLIA_FORK_URL ?= https://sepolia.base.org

# Test commands
.PHONY: test test-factory test-liquid test-mainnet test-bonding test-bonding-explorer test-unit test-rare test-burner test-invariants test-mev coverage coverage-report help

help:
	@echo "Available commands:"
	@echo "  test              - Run all tests (mainnet tests create forks automatically)"
	@echo "  test-factory      - Run factory tests (LiquidFactory.mainnet.t.sol)"
	@echo "  test-liquid       - Run basic liquid tests (Liquid.mainnet.basic.t.sol)"
	@echo "  test-mainnet      - Run mainnet integration tests (Liquid.mainnet.t.sol)"
	@echo "  test-bonding      - Run bonding curve analysis tests"
	@echo "  test-bonding-explorer - Run interactive bonding curve explorer tests"
	@echo "  test-burner       - Run burner integration tests"
	@echo "  test-invariants   - Run invariant tests"
	@echo "  test-mev          - Run MEV protection tests"
	@echo "  test-unit         - Run mainnet unit tests"
	@echo "  test-rare         - Run RARE burn config tests (no fork)"
	@echo "  coverage          - Generate test coverage summary"
	@echo "  coverage-report   - Generate HTML coverage report (requires lcov)"
	@echo ""
	@echo "ℹ️  Mainnet fork tests create their own forks automatically in setUp()"
	@echo "   FORK_URL env var can override default: $(FORK_URL)"
	@echo "   Tests run with --jobs 2 to avoid RPC rate limits"

# Run all tests (mainnet tests create forks in setUp)
# --jobs 1 limits parallelism to avoid RPC rate limits  
# Skip invariant and bonding tests
test:
	forge test --jobs 1 -v

# Run factory tests (creates fork in setUp)
test-factory:
	forge test test/LiquidFactory.mainnet.t.sol --jobs 2 -v

# Run basic liquid tests (creates fork in setUp)
test-liquid:
	forge test test/Liquid.mainnet.basic.t.sol --jobs 2 -v

# Run Base mainnet integration tests (creates fork in setUp)
test-mainnet:
	forge test test/Liquid.mainnet.t.sol --jobs 2 -v

# Run bonding curve analysis (creates fork in setUp)
test-bonding:
	forge test test/Liquid.mainnet.bonding.t.sol --jobs 2 -vv

# Run bonding curve explorer tests (interactive exploration)
test-bonding-explorer:
	forge test test/Liquid.mainnet.bonding.explorer.t.sol --jobs 2 -vv

# Run burner integration tests (creates fork in setUp)
test-burner:
	forge test test/Liquid.mainnet.burner.t.sol --jobs 2 -v

# Run invariant tests (creates fork in setUp)
test-invariants:
	forge test test/Liquid.mainnet.invariants.t.sol --jobs 2 -v

# Run MEV protection tests (creates fork in setUp)
test-mev:
	forge test test/Liquid.mainnet.mev.t.sol --jobs 2 -v

# Run mainnet unit tests (creates fork in setUp)
test-unit:
	forge test test/Liquid.mainnet.unit.t.sol --jobs 2 -v

# Run RARE burn tests (no fork needed)
test-rare:
	forge test test/RAREBurn.t.sol --jobs 2 -v

# Coverage commands
coverage:
	@echo "Generating test coverage summary..."
	@echo "Note: Using --ir-minimum to avoid stack too deep errors"
	@echo "      Coverage data may have slightly inaccurate source mappings"
	forge coverage --report summary --ir-minimum

coverage-report:
	@echo "Generating HTML coverage report..."
	@echo "Note: Requires lcov (install with: brew install lcov)"
	@echo "      Using --ir-minimum to avoid stack too deep errors"
	forge coverage --report lcov --ir-minimum
	@if command -v genhtml > /dev/null; then \
		genhtml -o coverage-report lcov.info --branch-coverage --function-coverage; \
		echo "✅ Coverage report generated in coverage-report/index.html"; \
		echo "   Open with: open coverage-report/index.html"; \
	else \
		echo "⚠️  genhtml not found. Install lcov: brew install lcov"; \
	fi

# Deploy commands
deploy-factory:
	forge script script/LiquidFactoryDeploy.s.sol --fork-url $(FORK_URL) --broadcast

deploy-factory-dry:
	forge script script/LiquidFactoryDeploy.s.sol --fork-url $(FORK_URL)

# Clean
clean:
	forge clean