# BastionSwap Security

## Threat Model

BastionSwap operates in an adversarial environment where token issuers, traders, and external actors may attempt to exploit the protocol. The core security goal is: **protect traders from malicious issuers while preventing abuse of the protection mechanisms themselves.**

### Trust Assumptions

| Entity | Trust Level | Rationale |
|---|---|---|
| Uniswap V4 PoolManager | Fully trusted | Core infrastructure; hook callbacks are authoritative |
| Deployer | Trusted at deployment | Sets initial addresses; governance transferable post-deployment |
| Governance | Semi-trusted | Controls protocol-wide params (fee rate, durations, thresholds, whitelist). Changes only affect new pools. Fee range capped at 10–500 BPS. Emergency withdraw has 2-day timelock. |
| Guardian | Semi-trusted | Can pause TriggerOracle (max 7 days) and submit Merkle roots. No fund access. |
| Token Issuers | **Untrusted** | Primary adversary; sell limits + LP seizure enforce accountability |
| Traders | **Untrusted** | May attempt to game insurance claims; Merkle proofs + flash-loan guard mitigate |

### Security Invariants

These properties must **always** hold:

1. **LP removal rights are safe**: Issuer LP can only be removed through valid vesting schedules or trigger-based forced removal
2. **Violations are blocked pre-emptively**: All issuer violations (sell limits, LP removal limits) revert the transaction before state changes are committed (v1). Trigger infrastructure preserved for v2
3. **Insurance is solvent**: Payout balance is snapshotted at trigger time; total claims cannot exceed the snapshot
4. **Cross-contract references are immutable**: No address can modify contract references post-deployment
5. **Commitments are immutable**: Per-pool parameters set at creation cannot be changed afterward
6. **Sell limits are enforced**: Issuer swaps exceeding daily/weekly limits revert the entire transaction
7. **Governance cannot affect existing pools**: Parameter changes only apply to newly created pools

## Known Attack Vectors & Mitigations

### 1. Rug-Pull via LP Removal

**Attack**: Issuer removes all liquidity in a single transaction, crashing the token price.

**Mitigation (v1 — revert-only enforcement)**:
- **Daily limit**: `beforeRemoveLiquidity` reverts if daily LP removals within a 24h rolling window exceed `maxDailyLpRemovalBps` (default 10% of initial LP) → `DailyLpRemovalExceeded`
- **Weekly limit**: `beforeRemoveLiquidity` reverts if weekly LP removals within a 7-day rolling window exceed `maxWeeklyLpRemovalBps` (default 30% of initial LP) → `WeeklyLpRemovalExceeded`
- **Vesting enforcement**: Cannot remove more LP than currently vested
- All checks are pre-emptive — the state change rolls back on revert
- Trigger-based LP seizure infrastructure (`executeTrigger()`, `forceRemoveIssuerLP`) is preserved for v2 watcher network

### 2. Issuer Token Dump

**Attack**: Issuer sells large amounts of their token to extract value before rug-pull.

**Mitigation (hard enforcement via revert)**:
- `beforeSwap` identifies issuer via hookData (`abi.encode(actualSwapper)` from cooperating routers)
- `afterSwap` checks BalanceDelta to detect sell direction (negative delta = issuer sends tokens)
- Epoch-based daily/weekly sliding windows track cumulative issuer sells
- Daily limit: >3% of initial supply per 24h → **revert entire swap**
- Weekly limit: >15% of initial supply per 7d → **revert entire swap**
- Blocks sales via any path including routers and aggregators
- No trigger fired — the sale simply cannot complete

**Known limitation**: Issuer can transfer tokens to secondary wallets before selling. Pre-transferred tokens are not detected. Mitigated by LP/supply ratio transparency on dashboard.

### 3. Honeypot Token (Planned — v2)

**Attack**: Token contract blocks `transfer()` after launch, trapping buyer funds.

**Current mitigation**: Fee-on-transfer and rebase tokens are rejected at pool creation via transfer amount validation. This catches some but not all honeypot patterns.

**Planned mitigation (v2)**: Decentralized watcher network detects transfer() reverts and submits proofs for LP seizure + compensation.

### 4. Hidden Tax Token (Planned — v2)

**Attack**: Token implements undisclosed transfer fees (buy/sell tax).

**Current mitigation**: Fee-on-transfer tokens are detected and rejected at pool creation. Tokens that pass the creation check but later enable fees are not currently detected.

**Planned mitigation (v2)**: Decentralized watcher network compares expected vs actual swap output and submits proofs for LP seizure.

### 5. False Trigger Attack

**Attack**: Malicious actor fabricates a trigger to steal issuer's LP.

**Mitigation**:
- In v1, daily/weekly LP removal violations revert the transaction — no trigger is fired, so no LP seizure occurs
- `executeTrigger()` exists for v2 but only succeeds when on-chain LP removal tracking confirms threshold is breached
- LP removal amounts are tracked in BastionHook via `_dailyLpRemoved`/`_weeklyLpRemoved` mappings, updated only in `beforeRemoveLiquidity` (which only PoolManager can call)
- TriggerOracle config validation enforces range bounds (BPS 1–10000, time windows 1h–30d)
- Guardian can pause the system if a vulnerability is discovered

### 6. Insurance Claim Fraud

**Attack**: Trader claims more compensation than entitled or claims without holding tokens.

**Mitigation**:
- **Merkle mode**: Guardian submits Merkle root of trigger-time balances within the Merkle submission deadline (default: 24h, governance-adjustable 6h–72h). Holders submit Merkle proofs — cannot inflate balance.
- **Fallback mode**: If guardian does not respond within the deadline, fallback mode activates (irreversible). Claims use `balanceOf` but require token holding at or before trigger block (flash-loan prevention).
- Each address can only claim once per triggered pool (`claimed` mapping)
- Issuer address excluded from all compensation claims
- Merkle mode: 30-day window. Fallback mode: 7-day window.

**Known Limitation**: Fallback mode reflects claim-time balances, not trigger-time balances. The 7-day window + trigger-block holding requirement minimize manipulation but do not eliminate it.

### 7. Commitment Bypass

**Attack**: Issuer attempts to weaken pool parameters after creation.

**Mitigation**:
- Per-pool `PoolCommitment` is **immutable** — set once at pool creation and stored permanently
- Validated at creation: all thresholds must be equal to or stricter than governance minimums (`CommitmentTooLenient` error)
- No `setCommitment()` function exists — there is no way to modify commitments after creation
- Governance parameter changes never affect existing pool commitments

### 8. Governance Key Compromise

**Attack**: Attacker gains control of governance address.

**Impact** (limited to):
- Adjusting insurance fee rate (capped within 10–500 BPS range)
- Modifying base token whitelist, default durations, and threshold defaults
- Emergency withdrawal from InsurancePool (2-day timelock)
- Transferring governance to another address

**Mitigation**:
- Governance address should be a multisig or timelock contract in production
- Fee rate has hard bounds (10–500 BPS) enforced in contract
- Emergency withdrawal requires 2-day timelock
- **Changes only affect newly created pools** — existing pool commitments are immutable
- No governance control over existing pool parameters or escrow states

### 9. Guardian Key Compromise

**Attack**: Attacker gains control of guardian address.

**Impact** (limited to):
- Pausing/unpausing TriggerOracle (max 7-day duration)
- Submitting Merkle roots for triggered pool compensation (could submit incorrect roots)

**Mitigation**:
- Guardian address should be a multisig in production
- Pause has max duration of 7 days — auto-expires
- If guardian submits no Merkle root within 24h, fallback mode activates automatically (irreversible) — holders can still claim via balanceOf
- Guardian cannot modify thresholds, steal funds, or bypass escrow
- Guardian is set by governance and can be replaced

### 10. LP Removal Tracking Manipulation

**Attack**: Spamming small LP removals to evade cumulative detection.

**Mitigation**:
- LP removal tracking uses daily (`_dailyLpRemoved`/`_dailyLpWindowStart`) and weekly (`_weeklyLpRemoved`/`_weeklyLpWindowStart`) sliding window mappings per pool
- Each removal in `beforeRemoveLiquidity` adds to both daily and weekly counters, then checks thresholds — exceeding either reverts (and rolls back the addition)
- Windows reset automatically when the time period (24h daily, 7d weekly) has elapsed
- Denominator is `_initialLiquidity` (set at pool creation) — cannot be manipulated
- BPS calculations use ceil division to prevent rounding-based threshold bypass
- Both daily (`DailyLpRemovalExceeded`) and weekly (`WeeklyLpRemovalExceeded`) violations revert pre-emptively

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

- [ ] **LP removal rights**: Verify `createEscrow()` correctly records lock-up and vesting parameters
- [ ] **Vesting calculation**: Verify linear vesting respects lock duration and returns correct vested amount over time
- [ ] **Sell limit enforcement**: Verify `afterSwap` correctly detects issuer sells via hookData + BalanceDelta and reverts when daily/weekly limits exceeded (denominator = current pool reserve via `balanceOf(poolManager)`)
- [ ] **LP removal enforcement**: Verify `beforeRemoveLiquidity` reverts on both daily threshold (`DailyLpRemovalExceeded`) and weekly threshold (`WeeklyLpRemovalExceeded`)
- [ ] **Trigger execution**: Verify `executeTrigger()` interface preserved for v2; only succeeds when LP removal threshold is actually breached
- [ ] **Insurance payout**: Verify `executePayout()` correctly snapshots balance and both Merkle and fallback claim modes compute pro-rata correctly
- [ ] **Claim double-spend**: Verify `claimed` mapping prevents duplicate claims
- [ ] **Issuer exclusion**: Verify issuer address cannot claim compensation
- [ ] **Fallback irreversibility**: Verify Merkle root cannot be submitted after fallback mode activates
- [ ] **Flash-loan guard**: Verify trigger-block holding requirement prevents flash-loan claims

### Access Control

- [ ] **Hook authorization**: Only PoolManager can call hook functions
- [ ] **EscrowVault authorization**: `createEscrow()` only from BastionHook, `forceRemoveIssuerLP()` only from TriggerOracle
- [ ] **InsurancePool authorization**: `depositFee()` only from BastionHook, `executePayout()` only from TriggerOracle
- [ ] **TriggerOracle authorization**: `executeTrigger()` only from BastionHook
- [ ] **ReputationEngine authorization**: `recordEvent()` only from BastionHook, EscrowVault, or TriggerOracle
- [ ] **Immutable references**: Verify all cross-contract references are immutable (no setter functions)
- [ ] **Governance transfer**: Verify `transferGovernance()` only callable by current governance (rejects zero address)
- [ ] **TriggerConfig validation**: Verify `setDefaultTriggerConfig()` and `updatePoolTriggerConfig()` enforce range bounds

### Arithmetic Safety

- [ ] **BPS calculations**: Verify no overflow in `(amount * bps) / 10000` calculations
- [ ] **Linear vesting calculation**: Verify `(elapsed - lockDuration) / vestingDuration` computes correctly at boundaries
- [ ] **Sell limit epoch tracking**: Verify epoch-based daily/weekly windows cannot be bypassed at epoch boundaries
- [ ] **Insurance pro-rata rounding**: Verify floor division doesn't allow over-claiming
- [ ] **LP daily/weekly tracking**: Verify no overflow in `_dailyLpRemoved`/`_weeklyLpRemoved` accumulation and correct window reset

### Edge Cases

- [ ] **Zero-amount escrow**: Should revert
- [ ] **Duplicate escrow for same pool+issuer**: Should revert
- [ ] **Trigger on already-triggered pool**: Should revert (`PoolTriggered` error)
- [ ] **Claim on non-triggered pool**: Should revert
- [ ] **Claim after window expiry**: Should revert (30d for Merkle, 7d for fallback)
- [ ] **Release from triggered escrow**: Should revert
- [ ] **LP removal underflow**: Subtraction should not underflow
- [ ] **Issuer sell after trigger**: Should revert (`PoolTriggered` error)
- [ ] **Fee-on-transfer token pool creation**: Should revert
- [ ] **Commitment too lenient**: Should revert if issuer thresholds exceed governance defaults
- [ ] **Merkle root after fallback**: Should revert (fallback is irreversible)

### Gas & DoS

- [ ] **Hook callbacks**: All hook functions (beforeAddLiquidity, beforeRemoveLiquidity, beforeSwap, afterSwap) complete within reasonable gas limits for V4 hooks
- [ ] **executeTrigger gas**: LP seizure + insurance payout in single transaction — verify gas cost is acceptable
- [ ] **Sell limit check gas**: Epoch tracking + BPS calculation in afterSwap — verify minimal overhead

### Integration

- [ ] **V4 Hook flag alignment**: Deployed address lower bits must match (BEFORE_ADD_LIQUIDITY | BEFORE_REMOVE_LIQUIDITY | BEFORE_SWAP | AFTER_SWAP)
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
- Known limitations documented above (multi-wallet evasion, fallback mode accuracy, slow drain within limits)
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
