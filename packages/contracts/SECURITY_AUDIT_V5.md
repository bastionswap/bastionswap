# BastionSwap Security Audit V5

**Date**: 2026-03-17
**Scope**: All contracts in `packages/contracts/src/` — current codebase only
**Contracts Audited**: BastionHook, EscrowVault, InsurancePool, TriggerOracle, ReputationEngine, BastionSwapRouter, BastionPositionRouter
**Tools**: Manual review + Slither v0.10.x static analysis

---

## Summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 1 |
| Low | 2 |
| Informational | 4 |

---

## Findings

---

### [M-01] Issuer Can Bypass `IssuerMustUseSaltZero` via Custom Router to Add/Remove Unrestricted LP

**Severity**: Medium
**Location**: `BastionHook.sol:332-336`

**Description**:
The `IssuerMustUseSaltZero` check only fires when `hookData` contains the issuer's address. A custom router that passes empty `hookData` (or encodes a non-issuer address) bypasses this identity check entirely, allowing the issuer to add LP with non-zero salt outside the escrow system.

**Code**:
```solidity
// BastionHook.sol:332-336
if (liquidity > 0 && _issuers[poolId] != address(0) && params.salt != bytes32(0)) {
    if (hookData.length >= 32) {                              // ← bypassed if hookData is empty
        address user = abi.decode(hookData, (address));
        if (user == _issuers[poolId]) revert IssuerMustUseSaltZero();
    }
}
```

**Exploit Path**:
1. Issuer creates pool via `BastionPositionRouter.createPool` — salt=0, LP escrowed (e.g., 10 ETH).
2. Issuer deploys a trivial custom router (copies `BastionPositionRouter`, passes empty `hookData` to `modifyLiquidity`).
3. Issuer calls custom router to add LP with non-zero salt and empty hookData.
4. In `beforeAddLiquidity`: `hookData.length < 32` → inner check skipped → LP added without revert.
5. The custom router LP is NOT tracked in `_issuerLiquidity` or escrow.
6. Issuer removes this LP freely via the same custom router — `sender ≠ _issuerLPOwner` → line 400 skips all issuer checks.
7. Pool loses 99% of liquidity, token price crashes. Escrowed 1% remains locked but is meaningless.

**Impact**:
Undermines the core escrow guarantee. The issuer can provide the majority of liquidity through an unrestricted position, then withdraw it at will — a rug-pull that bypasses the escrow system. Token holders who rely on the `IssuerMustUseSaltZero` protection face near-total loss.

**Mitigating Factors**:
- Requires the issuer to deploy a custom router (visible on-chain).
- Requires additional capital beyond the escrowed amount.
- TVL cap (`maxPoolTVL`) can limit the unrestricted LP if governance sets appropriate caps.
- Same effect is theoretically achievable by transferring tokens to a different wallet and adding LP from there.
- This is a known limitation of the V4 hook identity model (hooks can't verify end-user identity from non-cooperating routers).

**Recommendation**:
1. Set meaningful `maxPoolTVL` caps per base token so unrestricted LP additions are bounded.
2. Add off-chain monitoring to detect LP additions from non-registered routers for Bastion-protected pools.
3. Consider a frontend warning when the majority of pool liquidity is NOT in the salt=0 (escrowed) position, using `_issuerLiquidity` vs `_totalLiquidity` ratio.

---

### [L-01] Fee-on-Transfer Token Validation Bypass via Permit2 Pool Creation

**Severity**: Low
**Location**: `BastionPositionRouter.sol:982-994`

**Description**:
`_validateTokenCompatibility` checks for fee-on-transfer (FoT) tokens by calling `transferFrom(msg.sender, address(this), 1)`. This requires the sender to have granted a direct ERC20 approval to the router. When using `createPoolPermit2`, the sender has only approved via Permit2 (not direct ERC20 approval), so the `transferFrom` call fails silently (`success = false`) and the FoT check is skipped entirely.

**Code**:
```solidity
// BastionPositionRouter.sol:985-994
(bool success,) = token.call(
    abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, msg.sender, address(this), 1)
);
if (success) {   // ← false when no direct approval (Permit2 flow), skips FoT check
    uint256 balAfter = IERC20Minimal(token).balanceOf(address(this));
    uint256 received = balAfter - balBefore;
    if (received < 1) revert FeeOnTransferNotSupported();
    SafeTransferLib.safeTransfer(ERC20(token), msg.sender, received);
}
```

**Impact**:
A FoT token can bypass the validation when the pool creator uses the Permit2 path. The resulting pool would have incorrect insurance fee accounting — `depositFeeToken` records the pre-fee amount while InsurancePool actually receives less. Claims from this pool's insurance would eventually fail with insufficient balance.

**Recommendation**:
Check the Permit2 approval before calling `_validateTokenCompatibility`, or restructure the FoT check to use a different method that doesn't depend on direct ERC20 approval (e.g., transfer from the contract's own balance).

---

### [L-02] `executePayout` Failure in TriggerOracle Silently Locks Escrow Funds

**Severity**: Low
**Location**: `TriggerOracle.sol:215-219`

**Description**:
`_executeImmediate` wraps the `InsurancePool.executePayout` call in a try/catch. If this call fails, the trigger still completes: the escrow is marked as triggered, issuer LP is force-removed, and funds are transferred to InsurancePool via `receiveEscrowFunds`. However, without a successful `executePayout`, InsurancePool's `pool.isTriggered` remains `false`, meaning no claim mechanism (Merkle or fallback) is activated. The escrow funds become permanently locked in InsurancePool.

**Code**:
```solidity
// TriggerOracle.sol:215-219
try IInsurancePool(INSURANCE_POOL).executePayout(
    poolId, uint8(triggerType), totalEligibleSupply, _poolIssuedTokens[key]
) {} catch {
    emit ExternalCallFailed("InsurancePool.executePayout", poolId);  // ← funds locked
}
```

**Impact**:
If `executePayout` fails (e.g., `totalEligibleSupply == 0` reaching the call, or gas issues), escrow funds from force removal sit in InsurancePool with no claim path. ETH escrow funds cannot be recovered via `executeEmergencyWithdraw` (only drains `pool.balance`, not `pool.escrowEthBalance`). ERC-20 escrow tokens can be partially rescued via `executeEmergencyTokenWithdraw` but without proper accounting.

**Likelihood**: Very low — `totalEligibleSupply` is gated by `> 0` check at line 214, and double-trigger is prevented upstream. Requires an unusual edge case.

**Recommendation**:
Remove the try/catch and let the revert propagate. If `executePayout` fails, the entire trigger should fail to maintain state consistency across all contracts. Alternatively, add a governance rescue function for stuck escrow funds.

---

### [I-01] Sell Limit Denominator Uses Post-Swap Reserve in `afterSwap`

**Severity**: Informational
**Location**: `BastionHook.sol:1234`

**Description**:
`_enforceAfterSwapSellLimits` (Layer 2) reads `_getPoolIssuedTokenReserve(poolId)` AFTER the swap has executed. When the issuer sells issued tokens, the pool's issued token reserve increases (more tokens in the pool). A larger denominator means the same absolute sell amount represents fewer BPS, allowing approximately 10% more cumulative selling than if a fixed denominator were used.

Layer 1 (`_checkSellLimits` in `beforeSwap`) uses the pre-swap reserve, which is more conservative. However, only Layer 2 updates state, so the effective enforcement uses the post-swap (larger) denominator.

**Impact**: Minor — allows approximately 10% more selling than the strict BPS interpretation. Not exploitable for a significant advantage.

---

### [I-02] No `weekly >= daily` Validation for Sell BPS Thresholds

**Severity**: Informational
**Location**: `BastionHook.sol:1129-1163`, `TriggerOracle.sol:376-387`

**Description**:
`_validateAndStoreCommitment` validates `weeklyLpRemovalBps >= dailyLpRemovalBps` (line 1143) but does NOT perform the equivalent check for sell thresholds (`weeklyDumpThresholdPercent >= dumpThresholdPercent`). Similarly, `_validateTriggerConfig` in TriggerOracle validates ranges but not the weekly >= daily relationship for any threshold.

An issuer could set `maxDailySellBps = 1000` (10%) and `maxWeeklySellBps = 300` (3%). This is logically contradictory — you can't sell 10% daily but only 3% weekly. In practice, the weekly limit dominates, making the daily limit useless but not harmful.

**Impact**: None — the stricter limit always applies. Inconsistency only.

---

### [I-03] `BastionHook._owner` Could Be Declared Immutable

**Severity**: Informational
**Location**: `BastionHook.sol:119`

**Description**:
`_owner` is set in the constructor and never modified. Declaring it `immutable` saves ~2100 gas on every `setBastionRouter` call (SLOAD vs bytecode read).

---

### [I-04] Issuer Can Bypass Sell Limits via Custom Router with Spoofed `hookData`

**Severity**: Informational
**Location**: `BastionHook.sol:497`

**Description**:
The hook identifies the swapper via `hookData`: `actualSwapper = (hookData.length == 32) ? abi.decode(hookData, (address)) : sender`. A non-cooperating router that doesn't encode the actual swapper (or encodes a different address) causes `actualSwapper ≠ poolIssuer`, bypassing all sell limit enforcement.

This is a **known design limitation** documented in the codebase. The protocol's hook-based architecture cannot enforce identity across arbitrary routers. The official `BastionSwapRouter` always encodes `msg.sender` correctly.

**Impact**: The issuer can sell without limits through a custom router. However, the same effect is achievable by transferring tokens to a different wallet. The sell limits are deterrence for the issuer using the official UI/router, not a hard on-chain guarantee.

---

## Section Analysis

### 1. Slither Results (True Positives Only)

Slither reported 177 results. After filtering false positives:

- **`immutable-states` on `BastionHook._owner`**: True positive (I-03 above). `_owner` is write-once in constructor and can be `immutable`.
- All other Slither findings are false positives:
  - `arbitrary-send-erc20/eth` on routers: `sender` is always `msg.sender` from the original call.
  - `divide-before-multiply` on tick alignment: Intentional Uniswap V4 pattern.
  - `reentrancy-no-eth` on `EscrowVault.triggerForceRemoval`: Protected by `nonReentrant`.
  - `uninitialized-state` on `InsurancePool._pools`: Standard mapping, initialized on first write.
  - `uninitialized-local` on `InsurancePool` local variables: Solidity defaults to 0, intentional.

### 2. Fund Flow Analysis

All fund transfer paths verified:

| Contract | Function | Access | Destination | Accounting |
|----------|----------|--------|-------------|------------|
| BastionHook | `_depositInsuranceFee` | onlyPoolManager (via hook) | InsurancePool | Per-pool `pool.balance` / `pool.baseTokenFeeBalance` |
| BastionHook | `forceRemoveIssuerLP` | onlyEscrowVault | InsurancePool | Per-pool escrow balances via `receiveEscrowFunds` |
| InsurancePool | `executeEmergencyWithdraw` | onlyGovernance + timelock | `req.to` | Decrements `pool.balance` |
| InsurancePool | `executeEmergencyTokenWithdraw` | onlyGovernance + timelock | `req.to` | Decrements `pool.baseTokenFeeBalance` |
| InsurancePool | `claimTreasuryFunds` | onlyGovernance + fully vested | treasury/issuer | Drains `pool.balance` + `pool.baseTokenFeeBalance` |
| InsurancePool | `_executeClaimTransfers` | public (with proof) | msg.sender | Per-pool tracked, safety check vs `payoutBalance` |
| InsurancePool | `sweepExpiredPool` | onlyGovernance + triggered + 30d grace | treasury | Per-pool tracked (`payoutBalance - totalClaimed`) |
| Routers | `_settle` / `_refundETH` | within unlock callback | sender / msg.sender | V4 delta system |

- **No `balanceOf(this)` cross-pool contamination** in InsurancePool: All accounting uses per-pool internal variables.
- **`balanceOf(address(this))` in `forceRemoveIssuerLP`** (BastionHook:659-677): Safe because the hook never holds persistent funds. Fee deposits are atomic (take → transfer within same call). Force removal is the only path that temporarily holds tokens, and `nonReentrant` on EscrowVault prevents concurrent force removals.
- **No unauthorized fund drain paths** identified.

### 3. Access Control Audit

All external/public functions verified:

**BastionHook** (17 external functions):
- Hook callbacks (4): `onlyPoolManager` ✅
- `setBastionRouter`: `_owner` check ✅
- `forceRemoveIssuerLP`: `onlyEscrowVault` ✅
- Governance setters (10): `onlyGovernance` ✅
- `executeTrigger`: permissionless, validates threshold ✅
- `syncFeeRate`: permissionless, reads from InsurancePool ✅

**Salt=0 position protection**:
- Fee collection (liquidityDelta=0): Requires `hookData` with `user == issuer` ✅
- LP removal: Requires `hookData` with `user == issuer`, checks vesting ✅
- Force removal: Uses transient storage flag, bypasses checks ✅
- Non-zero salt addition: Blocked for identified issuer (M-01 caveat) ✅

**EscrowVault** (11 functions):
- State-changing: `onlyHook` or `onlyTriggerOracle` + `nonReentrant` ✅
- `setCommitment`: `onlyIssuer`, only stricter changes ✅

**InsurancePool** (19 functions):
- Deposits: `onlyHook` ✅
- Payout: `onlyTriggerOracle` + `nonReentrant` ✅
- Claims: public, Merkle proof or balanceOf with token lock ✅
- Emergency: `onlyGovernance` + timelock ✅
- Treasury: `onlyGovernance` + not triggered + fully vested ✅
- `safeTransferExternal`: self-call only (`msg.sender == address(this)`) ✅

**TriggerOracle** (12 functions):
- Trigger execution: `onlyHook` + `whenNotPaused` ✅
- Config/registration: `onlyHook` ✅
- Pause/unpause: `onlyGuardian` ✅
- `updatePoolTriggerConfig`: `onlyGovernance` + only non-registered pools ✅

**Routers**:
- `forceRemoveLiquidity` / `forceCollectFees`: `onlyHook` ✅
- `removeIssuerLiquidity` / `addIssuerLiquidity` / `collectIssuerFees`: `msg.sender == getPoolIssuer()` ✅
- `unlockCallback`: `onlyPoolManager` ✅

### 4. Commitment Verification

- Lock duration ≥ `minLockDuration` (BastionHook:869) ✅
- Vesting duration ≥ `minVestingDuration` (BastionHook:870) ✅
- LP removal thresholds ≤ governance defaults (BastionHook:1140-1141) ✅
- Weekly LP ≥ daily LP (BastionHook:1143) ✅
- Sell thresholds > 0 (BastionHook:1145-1146) ✅
- Sell thresholds ≤ governance defaults (BastionHook:1147-1148) ✅
- Commitment immutability: No setter exists for `_poolCommitments` after creation ✅
- Governance cannot modify existing pool commitments ✅
- EscrowVault safety floor: `MIN_LOCK_DURATION` and `MIN_VESTING_DURATION` constants (EscrowVault:17-18) ✅
- Missing: weekly ≥ daily for sell BPS (I-02) — harmless inconsistency

### 5. Sell Limit Dual Defense

**Layer 1 (`beforeSwap`)**:
- exactInput sells (`amountSpecified < 0`): View-only check using pre-swap reserve. No state update ✅
- exactOutput sells (`amountSpecified > 0`): Deferred to Layer 2 (correct — can't know sell amount until delta is computed) ✅

**Layer 2 (`afterSwap`)**:
- Gets actual sold amount from `BalanceDelta` (`issuedDelta < 0`) ✅
- Updates cumulative counters (`dailySellCumulative`, `weeklySellCumulative`) ✅
- Reverts if limits exceeded → entire swap rolls back ✅
- Denominator: `_getPoolIssuedTokenReserve(poolId)` — per-pool virtual reserves ✅

**Window reset logic**:
- Daily: 86400 seconds, reset when `block.timestamp >= windowStart + 86400` ✅
- Weekly: 7 days, reset when `block.timestamp >= windowStart + 7 days` ✅
- Revert causes full rollback including counter updates ✅

**Ceil division**: Applied consistently: `(projected * 10_000 + poolReserve - 1) / poolReserve` ✅

**No double-counting**: Layer 1 is view-only, only Layer 2 updates state ✅

### 6. LP Removal Limits

- Daily/weekly cumulative tracking with epoch-based windows ✅
- `initialLiquidity` as denominator (not current total) ✅
- Ceil division applied ✅
- Window reset before check, counters updated after validation ✅
- Limits enforced even after vesting completion (by design — prevents rapid LP dump) ✅
- Non-issuer LP: No restrictions (line 400-444 only targets `sender == _issuerLPOwner` with salt=0) ✅
- Issuer blocked from non-zero salt via official router (M-01 bypass via custom router noted above) ✅
- `_issuerLiquidity` tracking: Incremented on salt=0 additions, decremented on removals ✅

### 7. Insurance Pool State Machine

**State transitions verified**:
```
Normal → executePayout → Triggered (24h waiting)
  ├─→ submitMerkleRoot (within deadline) → Merkle Mode → claimCompensation (30d)
  └─→ 24h elapsed → Fallback Mode → claimCompensationFallback (7d)

Post-claim: sweepExpiredPool (after all claim periods + 30d grace)
```

- Merkle → Fallback blocked: `if (pool.useMerkleProof) revert NotInFallbackMode()` ✅
- Fallback → Merkle blocked: `if (block.timestamp > triggerTimestamp + snapshotMerkleDeadline) revert FallbackAlreadyActive()` ✅
- Fallback irreversibility: Once deadline passes, `submitMerkleRoot` is permanently blocked ✅
- Issuer excluded from claims: Both modes check `msg.sender == getPoolIssuer()` ✅
- Fallback token lock: `safeTransferFrom(issuedToken, msg.sender, address(this), holderBalance)` ✅
- Double-claim prevention: `pool.claimed[msg.sender]` checked before, set before transfer ✅
- Flash-loan protection: `block.number <= pool.triggerBlockNumber` → `MustWaitOneBlock` ✅
- `claimTreasuryFunds`: Only untriggered pools ✅
- `emergencyWithdraw`: Only untriggered pools ✅
- `sweepExpiredPool`: Only triggered pools + 30d grace after all claim periods ✅
- Governance param snapshot at trigger time (M-03 fix): `snapshotMerkleDeadline`, `snapshotMerkleClaimPeriod`, `snapshotFallbackClaimPeriod` ✅
- Accounting: Per-pool internal variables, not `balanceOf`. Safety check `totalClaimed + amount > payoutBalance` ✅

### 8. Escrow + Trigger Consistency

**Trigger propagation chain**:
1. `BastionHook.executeTrigger` → sets `isPoolTriggered[poolId] = true`
2. → `TriggerOracle.executeTrigger` → sets `state.isTriggered = true`
3. → `EscrowVault.triggerForceRemoval` → calls `BastionHook.forceRemoveIssuerLP`
4. → Force removal → `InsurancePool.receiveEscrowFunds`
5. → `InsurancePool.executePayout` (try/catch — see L-02)

- **Atomicity**: Steps 1-4 are mandatory (revert propagates). Step 5 is try/catch (L-02) ✅
- **Post-trigger blocking**: All contracts check triggered status:
  - BastionHook: `isPoolTriggered[poolId]` blocks sells and LP removal ✅
  - EscrowVault: `escrow.isTriggered` blocks LP removal records and new commitments ✅
  - InsurancePool: `pool.isTriggered` blocks emergency withdraw and treasury claims ✅
  - TriggerOracle: `state.isTriggered` blocks double trigger ✅

### 9. Reentrancy + Integer Arithmetic

**Reentrancy**:
- BastionHook: Transient storage (EIP-1153) for cross-callback state. PoolManager enforces strict callback ordering. No CEI violations ✅
- EscrowVault: OpenZeppelin `ReentrancyGuard` on all state-changing functions. `triggerForceRemoval` writes state AFTER external call but is protected by `nonReentrant` ✅
- InsurancePool: `ReentrancyGuard` on claims, emergency, treasury, sweep. CEI pattern (mark claimed before transfer) ✅
- TriggerOracle: `ReentrancyGuard` on trigger execution ✅
- Routers: V4 unlock pattern prevents reentrancy (PoolManager enforces single unlock at a time) ✅

**Integer arithmetic**:
- Solidity 0.8.26 built-in overflow protection ✅
- BPS calculations: `uint256 * 10_000` — no overflow for realistic values (< 2^128 * 10_000 < 2^142) ✅
- Ceil division consistent: `(a * 10_000 + b - 1) / b` ✅
- Division by zero: Checked (`poolReserve == 0` → return, `initLiq == 0` → skip, `totalEligibleSupply == 0` → checked) ✅
- Vesting calculation: `uint128 * uint256 / uint256` — no overflow ✅
- `FullMath.mulDiv` for claim compensation — overflow-safe ✅

### 10. Attack Scenarios

| # | Scenario | Result | Defense |
|---|----------|--------|---------|
| 1 | Non-issuer steals salt=0 LP | **Defended** | Router: `OnlyIssuer`. Hook: `sender == _issuerLPOwner` + hookData `user == issuer` (BastionHook:400-405) |
| 2 | Non-issuer steals salt=0 fees | **Defended** | Router: `OnlyIssuer`. Hook: fee collection requires hookData `user == issuer` (BastionHook:375-384) |
| 3 | Custom router sell limit bypass | **Known limitation** (I-04) | hookData identity model can't enforce across non-cooperating routers |
| 4 | Token transfer + sell from different wallet | **Known limitation** | Same as #3; protocol relies on deterrence, not hard enforcement |
| 5 | Fallback double claim (token transfer) | **Defended** | Tokens locked via `safeTransferFrom` + `claimed` mapping (InsurancePool:357,733) |
| 6 | Flash-loan insurance drain | **Defended** | `block.number <= triggerBlockNumber` + token lock (InsurancePool:350,357) |
| 7 | Governance key compromise | **Within threat model** | Timelock on emergency. Can't modify existing commitments. Governance is trusted role |
| 8 | False Merkle root | **Within threat model** | Guardian trust assumption. Fallback mode activates if guardian fails (24h) |
| 9 | forceRemoveIssuerLP reentrancy | **Defended** | EscrowVault: `nonReentrant`. Hook: transient storage flag (BastionHook:644,653) |
| 10 | Reserve manipulation for sell limit expansion | **Defended** | Reserves calculated from in-range liquidity + sqrtPrice (per-pool, not balanceOf). Price manipulation has self-limiting effects on reserves |
| 11 | Trigger → issuer additional actions | **Defended** | `isPoolTriggered` blocks sells (BastionHook:510), LP removal (407), fee collection (382) |
| 12 | emergencyWithdraw on triggered pool | **Defended** | `pool.isTriggered → revert AlreadyTriggered` (InsurancePool:420,477) |
| 13 | sweepExpiredPool early/cross-pool | **Defended** | Requires triggered + 30d grace (InsurancePool:658,668). Per-pool PoolId isolation |
| 14 | Issuer ETH rejection blocks treasury | **Defended** | Failed issuer transfer → redirect to treasury (InsurancePool:607-611). ERC-20: try/catch → redirect (630-635) |
| 15 | Fee-on-transfer token pool creation | **Partially defended** (L-01) | `_validateTokenCompatibility` checks FoT. Bypass via Permit2 path |
| 16 | Issuer creates pool with sell limit 0 | **Defended** | `dumpThresholdPercent == 0 → revert ValueOutOfRange` (BastionHook:1145) |

---

## Slither Summary

177 results, 0 true positive vulnerabilities. 1 gas optimization (I-03). All high/medium severity Slither findings are false positives due to:
- Intentional Uniswap V4 patterns (tick alignment, poolManager interaction)
- `nonReentrant` guards covering reentrancy paths
- Standard mapping/variable initialization patterns
- Authorized `transferFrom` patterns (sender is always the original caller)
