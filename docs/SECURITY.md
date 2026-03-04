# BastionSwap Security

## Threat Model

BastionSwap operates in an adversarial environment where token issuers, traders, and external actors may attempt to exploit the protocol. The core security goal is: **protect traders from malicious issuers while preventing abuse of the protection mechanisms themselves.**

### Trust Assumptions

| Entity | Trust Level | Rationale |
|---|---|---|
| Uniswap V4 PoolManager | Fully trusted | Core infrastructure; hook callbacks are authoritative |
| Deployer | Trusted at deployment | Sets immutable addresses; no ongoing privilege after deployment |
| Governance | Semi-trusted | Can only adjust fee rate (capped at 2%) and emergency withdraw |
| Guardian | Semi-trusted | Can only pause/unpause TriggerOracle; no fund access |
| Token Issuers | **Untrusted** | Primary adversary; escrow + triggers enforce accountability |
| Traders | **Untrusted** | May attempt to game insurance claims |
| Off-chain Bots | **Untrusted** | Proof submissions are validated on-chain before acceptance |

### Security Invariants

These properties must **always** hold:

1. **Escrow funds are safe**: Escrowed tokens can only be released through valid vesting schedules or trigger redistribution
2. **Triggers are honest**: Only verified on-chain state or validated proofs can fire triggers
3. **Insurance is solvent**: Payout balance is snapshotted at trigger time; total claims cannot exceed the snapshot
4. **Access control is immutable**: No address can modify cross-contract references post-deployment
5. **Commitments are monotonically strict**: Issuers can only tighten, never loosen, their commitments

## Known Attack Vectors & Mitigations

### 1. Rug-Pull via LP Removal

**Attack**: Issuer removes all liquidity in a single transaction, crashing the token price.

**Mitigation**:
- `beforeRemoveLiquidity` hook reports all LP removals to TriggerOracle
- Single-transaction threshold detection (default: 50% of total LP)
- Cumulative sliding window detection for slow-rug patterns (default: 80%)
- On trigger: remaining escrow funds are redistributed to InsurancePool

### 2. Issuer Token Dump

**Attack**: Issuer sells large amounts of their token to extract value before rug-pull.

**Mitigation**:
- `afterSwap` hook detects issuer sell transactions
- 24-hour sliding window tracks cumulative issuer sales
- Threshold-based trigger (default: 30% of total supply in 24h)
- `maxSellPercent` commitment limits issuer's daily sell volume

### 3. Honeypot Token

**Attack**: Token contract blocks `transfer()` after launch, trapping buyer funds.

**Mitigation**:
- Off-chain monitoring bots submit proofs via `submitHoneypotProof()`
- 1-hour grace period before trigger execution
- Insurance pool compensates affected holders

### 4. Hidden Tax Token

**Attack**: Token implements undisclosed transfer fees (buy/sell tax).

**Mitigation**:
- Off-chain bots compare expected vs actual swap output
- `submitHiddenTaxProof()` with deviation threshold (default: >5%)
- On-chain validation: `actualOutput < expectedOutput` and deviation exceeds threshold

### 5. False Trigger Attack

**Attack**: Malicious actor fabricates a trigger to steal issuer's escrow funds.

**Mitigation**:
- On-chain triggers (RUG_PULL, ISSUER_DUMP) are based on verified blockchain state — cannot be spoofed
- Off-chain triggers (HONEYPOT, HIDDEN_TAX) require proof validation against on-chain data
- 1-hour grace period allows detection of false positives
- Guardian can pause the system if a vulnerability is discovered

### 6. Insurance Claim Fraud

**Attack**: Trader claims more compensation than entitled or claims without holding tokens.

**Mitigation**:
- Claims are pull-based: holder self-reports their `holderBalance`
- Pro-rata formula: `payoutBalance × holderBalance / totalEligibleSupply`
- Each address can only claim once per triggered pool (`claimed` mapping)
- 30-day claim window limits exposure

**Known Limitation**: The current implementation relies on self-reported `holderBalance`. A production deployment should integrate a token balance snapshot mechanism (e.g., ERC20Snapshot or Merkle proof against a block hash) to prevent inflated claims.

### 7. Commitment Bypass

**Attack**: Issuer attempts to set looser vesting commitments after pool creation.

**Mitigation**:
- `setCommitment()` enforces a **strictness ratchet**: new commitment must be strictly tighter than current
  - `dailyWithdrawLimit` can only decrease (or stay equal)
  - `lockDuration` can only increase (or stay equal)
  - `maxSellPercent` can only decrease (or stay equal)
- At least one field must actually change (prevents no-op calls)

### 8. Governance Key Compromise

**Attack**: Attacker gains control of governance address.

**Impact** (limited to):
- Adjusting insurance fee rate (capped at 2% max by `MAX_FEE_RATE`)
- Emergency withdrawal from InsurancePool

**Mitigation**:
- Governance address should be a multisig or timelock contract in production
- Fee rate has a hard cap of 200 BPS (2%) enforced in contract
- No governance control over escrow funds, trigger thresholds, or hook behavior

### 9. Guardian Key Compromise

**Attack**: Attacker gains control of guardian address.

**Impact** (limited to):
- Pausing/unpausing TriggerOracle (disabling new trigger detection)

**Mitigation**:
- Guardian address should be a multisig in production
- Pause only affects **new** trigger detection — existing pending triggers remain executable
- Guardian cannot modify thresholds, steal funds, or bypass escrow

### 10. Sliding Window Overflow

**Attack**: Spamming small LP removals or sales to fill the sliding window array, evading cumulative detection.

**Mitigation**:
- `MAX_TRACKER_ENTRIES = 50` — oldest entries are pruned when limit reached
- `_pushRecord()` shifts array left, removing stale entries
- Window sum only considers entries within `dumpWindowSeconds`

**Known Limitation**: If an attacker submits >50 small removals before a large one, early entries are pruned. The 50-entry cap provides practical protection for typical usage patterns but could theoretically be gamed with sustained high-frequency micro-removals.

### 11. Reentrancy

**Mitigation**:
- EscrowVault: `releaseVested()` and `triggerRedistribution()` use OpenZeppelin `ReentrancyGuard`
- InsurancePool: `executePayout()` and `claimCompensation()` use `ReentrancyGuard`
- ETH transfers use low-level `call` with return value checks
- State updates happen before external calls (checks-effects-interactions pattern)

### 12. CREATE2 Address Manipulation

**Attack**: Front-running the deployment to deploy a malicious contract at the pre-computed hook address.

**Mitigation**:
- The CREATE2 deployer factory is deployed by the same deployer in the same transaction batch
- Salt mining produces an address with specific flag bits — an attacker would need to find the same salt for different bytecode
- All deployed addresses are verified with `require()` checks in the deployment script

## Audit Checklist

### Critical Path

- [ ] **Escrow fund safety**: Verify `createEscrow()` correctly transfers and locks tokens
- [ ] **Vesting calculation**: Verify `_calculateVestedAmount()` respects lock duration and schedule monotonicity
- [ ] **Daily withdrawal limit**: Verify per-day tracking cannot be bypassed across day boundaries
- [ ] **Trigger redistribution**: Verify `triggerRedistribution()` sends correct remaining amount to InsurancePool
- [ ] **Insurance payout**: Verify `executePayout()` correctly snapshots balance and `claimCompensation()` computes pro-rata correctly
- [ ] **Claim double-spend**: Verify `claimed` mapping prevents duplicate claims

### Access Control

- [ ] **Hook authorization**: Only PoolManager can call hook functions
- [ ] **EscrowVault authorization**: `createEscrow()` only from BastionHook, `triggerRedistribution()` only from TriggerOracle
- [ ] **InsurancePool authorization**: `depositFee()` only from BastionHook, `executePayout()` only from TriggerOracle
- [ ] **TriggerOracle authorization**: `reportLPRemoval()` / `reportIssuerSale()` only from BastionHook
- [ ] **ReputationEngine authorization**: `recordEvent()` only from BastionHook, EscrowVault, or TriggerOracle
- [ ] **Immutable addresses**: Verify all cross-contract references are immutable (no setter functions)

### Arithmetic Safety

- [ ] **BPS calculations**: Verify no overflow in `(amount * bps) / 10000` calculations
- [ ] **Vesting schedule validation**: Final step must be exactly 10000 BPS
- [ ] **Daily limit rounding**: Verify floor division doesn't allow over-withdrawal via repeated small calls
- [ ] **Insurance pro-rata rounding**: Verify floor division doesn't allow over-claiming
- [ ] **Sliding window sum**: Verify no overflow in cumulative amount tracking

### Edge Cases

- [ ] **Zero-amount escrow**: Should revert
- [ ] **Empty vesting schedule**: Should revert
- [ ] **Duplicate escrow for same pool+issuer**: Should revert
- [ ] **Trigger on already-triggered pool**: Should revert
- [ ] **Claim on non-triggered pool**: Should revert
- [ ] **Claim after 30-day window**: Should revert
- [ ] **Release from triggered escrow**: Should revert
- [ ] **LP removal underflow**: `_totalLiquidity` subtraction should not underflow
- [ ] **Grace period re-trigger**: Cannot create a new pending trigger while one exists

### Gas & DoS

- [ ] **Sliding window gas cost**: `_sumWindow()` iterates up to 50 entries — acceptable for on-chain calls
- [ ] **Vesting schedule iteration**: Up to 10 steps — acceptable
- [ ] **Array shift in `_pushRecord()`**: Up to 49 iterations — acceptable gas cost
- [ ] **Hook callbacks**: All hook functions complete within reasonable gas limits for V4 hooks

### Integration

- [ ] **V4 Hook flag alignment**: Deployed address lower 14 bits must equal `0x0A40` (BEFORE_ADD_LIQUIDITY | BEFORE_REMOVE_LIQUIDITY | AFTER_SWAP)
- [ ] **Cross-contract address consistency**: All five contracts reference the same set of addresses
- [ ] **Deployment nonce ordering**: Verify pre-computed addresses match deployed addresses
- [ ] **PoolManager compatibility**: Verify hook return values match V4 expectations

## Bug Bounty

> **Note**: Bug bounty program is planned for post-audit launch. Details below are preliminary.

### Planned Scope

**In scope:**
- All smart contracts in `src/`
- Deployment scripts in `script/`
- Trigger detection logic and threshold bypasses
- Fund loss or unauthorized access vulnerabilities
- Denial of service that prevents trigger detection or compensation claims
- Logic errors in vesting calculation or commitment enforcement

**Out of scope:**
- Frontend/UI issues
- Off-chain bot implementations
- Known limitations documented above (self-reported balance, sliding window cap)
- Issues requiring compromised governance/guardian keys
- Gas optimization suggestions

### Planned Severity Levels

| Severity | Description | Planned Reward |
|---|---|---|
| **Critical** | Direct fund loss or permanent freeze of escrowed/insurance funds | TBD |
| **High** | Bypass trigger detection, manipulate compensation calculations, break invariants | TBD |
| **Medium** | Governance/guardian privilege escalation, DoS of non-critical functions | TBD |
| **Low** | Informational, code quality, minor gas inefficiencies | TBD |

## Contact

For security reports, contact: **security@bastionswap.xyz** _(placeholder — update before launch)_

Do **not** disclose security vulnerabilities publicly until a fix has been deployed and a reasonable disclosure timeline agreed upon. Follow responsible disclosure practices.
