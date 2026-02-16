# Liquid Edition Contracts Makefile

# Load environment variables from .env and .env.test files
# .env contains RPC URLs with paid Alchemy API keys
-include .env
-include .env.test
export

# FORK_URL comes from .env (required for make test)
export FORK_URL

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
	@echo "   Set FORK_URL in .env (required for make test)"
	@echo "   Tests run with --jobs 1 to avoid RPC rate limits"

# Run all tests (mainnet tests create forks in setUp)
# --jobs 1 limits parallelism to avoid RPC rate limits
# FORK_URL must be set in .env (no fallbacks)
test:
	@[ -f .env ] && set -a && . ./.env && set +a || true; \
	if [ -z "$${FORK_URL}" ]; then \
		echo "Error: FORK_URL is required. Set FORK_URL in .env"; \
		exit 1; \
	fi; \
	FORK_URL="$$FORK_URL" forge test --jobs 1 -v

# Run factory tests (unit: no fork; fork: creates fork in setUp)
test-factory:
	forge test test/unit/LiquidFactory.unit.t.sol test/e2e/LiquidFactory.fork.t.sol --jobs 2 -v

# Run basic liquid tests (creates fork in setUp)
test-liquid:
	forge test test/e2e/Liquid.mainnet.basic.t.sol --jobs 2 -v

# Run Base mainnet integration tests (creates fork in setUp)
test-mainnet:
	forge test test/e2e/Liquid.mainnet.t.sol --jobs 2 -v

# Run bonding curve analysis (creates fork in setUp)
test-bonding:
	forge test test/scenarios/Liquid.mainnet.bonding.t.sol --jobs 2 -vv

# Run bonding curve explorer tests (interactive exploration)
test-bonding-explorer:
	forge test test/scenarios/Liquid.mainnet.bonding.explorer.t.sol --jobs 2 -vv

# Run burner integration tests (creates fork in setUp)
test-burner:
	forge test test/e2e/RAREBurner.mainnet.t.sol --jobs 2 -v

# Run invariant tests (creates fork in setUp)
test-invariants:
	forge test test/invariants/Liquid.mainnet.invariants.t.sol --jobs 2 -v

# Run MEV protection tests (creates fork in setUp)
test-mev:
	forge test test/scenarios/Liquid.mainnet.mev.t.sol --jobs 2 -v

# Run mainnet unit tests (creates fork in setUp)
test-unit:
	forge test test/e2e/Liquid.mainnet.unit.t.sol --jobs 2 -v

# Run RARE burn tests (no fork needed)
test-rare:
	forge test test/integration/RAREBurner.t.sol -v && forge test test/unit/RAREBurner.unit.t.sol -v

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