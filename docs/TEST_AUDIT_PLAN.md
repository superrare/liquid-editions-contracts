# Liquid System — Tests-Only Audit Template

Use this template for a focused review of test coverage and test quality for the Liquid System.

## 1) Audit Scope

- [ ] **Scope is tests only** (no production contracts reviewed)
- [ ] Test directories included:
  - [ ] `test/`
  - [ ] `tests/`
  - [ ] `spec/`
  - [ ] Other:
- [ ] Excluded from scope:
  - [ ] Fuzz/invariant suites excluded
  - [ ] Mainnet/live environment / infra docs excluded
- [ ] Auditor/date:
  - [ ] Auditor:
  - [ ] Date:

## 2) Test Inventory

| File | Target contract/module | Framework | Key fixtures/helpers | Notes |
| --- | --- | --- | --- | --- |
| | | | | |

### Skipped / ignored tests
- [ ] `skip` / `it.skip`
- [ ] `xdescribe` / `describe.skip`
- [ ] `--grep` exclusions
- [ ] TODO/expected-to-fail comments

## 3) Coverage Checklist

### Path coverage
- [ ] Positive path tested
- [ ] Negative/revert path tested
- [ ] Access-control authorized path tested
- [ ] Access-control unauthorized path tested
- [ ] Input edge cases tested (zero/empty/max/overflow/invalid)
- [ ] Time/state-dependent behavior tested (epochs, windows, deadlines, pauses)
- [ ] Upgrade-related paths tested (if upgradeable)
- [ ] Event emissions checked where applicable

### Security-relevant branches
- [ ] Reentrancy/composability boundaries
- [ ] Role transitions (admin/grant/revoke)
- [ ] Funds movement and accounting invariants
- [ ] Commitment/merkle/oracle-style trust boundaries
- [ ] Cross-module sequencing (step ordering, dependencies)
- [ ] Failure modes around external calls/dependency failures

## 4) Assertion Quality

- [ ] Reverts assert explicit reasons/messages (not just generic failures)
- [ ] State assertions check exact expected values
- [ ] Partial comparisons used only when exactness is impossible/unnecessary
- [ ] No meaningless assertions (`assert(true)`, placeholder checks)
- [ ] Fixture assumptions are necessary and justified
- [ ] Fuzz/invariant test assumptions are not over-restrictive
- [ ] Invariant properties are precise and non-trivial

## 5) Reliability / Determinism

- [ ] Tests are isolated (no hidden dependency on prior test state)
- [ ] Shared helpers are deterministic
- [ ] No reliance on call order across test files
- [ ] Flaky tests identified and explained
- [ ] Fuzz seeds/repeatability documented where applicable

## 6) Findings Log

Use severity:
- **Critical**: missing checks for unauthorized access, funds loss, invalid state transitions
- **High**: incorrect or missing expected-revert validation, weak core invariants
- **Medium**: edge-case and role/state coverage gaps, brittle setup assumptions
- **Low**: maintainability/test-quality issues not directly affecting correctness

### Finding template

- **Severity**:
- **Category**:
- **File**:
- **Line(s)**:
- **Expected behavior**:
- **Observed gap in tests**:
- **Risk/impact**:
- **Recommended test**:

## 7) Coverage Matrix (per module)

- Module / Contract:
- Happy path coverage:
- Negative path coverage:
- Access-control coverage:
- Edge-case coverage:
- Gas/DoS/reliability checks:
- Notable risks:
- Overall confidence:

## 8) Summary / Outcome

- Total tests audited:
- Total test files:
- Findings by severity:
  - Critical:
  - High:
  - Medium:
  - Low:
- Known untestable gaps due to scope:
- Final risk statement:

> In a tests-only audit, avoid asserting production vulnerabilities unless the test gaps directly imply exploitable behavior in production logic.
