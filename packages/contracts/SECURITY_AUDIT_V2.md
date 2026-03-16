# BastionSwap Security Audit Report V2

**Date:** 2026-03-16
**Auditor:** Claude Opus 4.6 (automated)
**Scope:** All 7 core contracts in `packages/contracts/src/`
**Solidity Version:** 0.8.26
**Methodology:** Slither static analysis + line-by-line manual review

---

## Executive Summary

This audit covers the full BastionSwap protocol: BastionHook, EscrowVault, InsurancePool,
TriggerOracle, ReputationEngine, BastionSwapRouter, and BastionPositionRouter.

Two **Critical** vulnerabilities were found in the BastionPositionRouter that allow any
user to drain the issuer's LP position and steal accumulated fees. Two **High** findings
affect the sell-limit enforcement mechanism. Three **Medium** findings relate to edge cases
in the insurance and force-removal subsystems. Several Low and Informational items round
out the report.

| Severity      | Count |
|---------------|-------|
| Critical      | 2     |
| High          | 2     |
| Medium        | 3     |
| Low           | 4     |
| Informational | 4     |

---

## Critical

### C-01: Anyone Can Drain Issuer's LP via `removeIssuerLiquidity`

**Location:** `BastionPositionRouter.sol:292-313` + `BastionHook.sol:384-428`

**Description:**
`removeIssuerLiquidity()` has no access control — any external caller can invoke it.
The function removes LP from the issuer's salt-0 position and sends the resulting
tokens to `msg.sender` (the attacker).

The hook's `beforeRemoveLiquidity` fails to prevent this because it only checks whether
the caller is the issuer; when the caller is NOT the issuer, it falls through to the
"non-issuer using same router — allow freely" path without verifying that the position
being accessed (`params.salt == bytes32(0)`) belongs to the issuer.

```solidity
// BastionPositionRouter.sol:292 — NO ACCESS CONTROL
function removeIssuerLiquidity(
    PoolKey calldata key,
    uint128 liquidityToRemove,
    uint256 amount0Min, uint256 amount1Min, uint256 deadline
) external { ... }

// _handleRemoveIssuerLP uses salt=0 (issuer's position)
// and sends tokens to msg.sender (attacker)
(BalanceDelta delta,) = poolManager.modifyLiquidity(key,
    ModifyLiquidityParams({..., salt: 0}),
    abi.encode(sender)   // sender = attacker
);
_settle(key.currency0, sender, delta.amount0()); // tokens → attacker
```

The hook at `BastionHook.sol:386-428`:
```solidity
if (sender == _issuerLPOwner[poolId]) {
    if (hookData.length == 0) revert MustIdentifyUser();
    address user = abi.decode(hookData, (address));
    if (user == issuer) {
        // ... vesting checks (only applies to issuer) ...
    }
    // else: non-issuer using same router → allow freely  ← BUG
}
```

When `user != issuer`, the code skips all vesting enforcement, escrow recording,
and LP removal limits. The salt-0 position is accessed and drained.

**Impact:**
- Complete theft of the issuer's locked LP by any user
- Bypasses all escrow vesting schedules
- Bypasses daily/weekly LP removal limits
- Escrow records become inconsistent (escrow thinks LP is locked, but it's gone)

**Reproduction:**
1. Issuer creates pool via `createPool` → salt-0 position created with X liquidity
2. Attacker calls `removeIssuerLiquidity(key, X, 0, 0, deadline)`
3. All liquidity removed from salt-0 position, tokens sent to attacker

**Recommended Fix:**
Add a salt check in the hook's `beforeRemoveLiquidity`. When operating on the
salt-0 position via the issuer's router, require that `user == issuer`:

```solidity
if (sender == _issuerLPOwner[poolId]) {
    if (hookData.length == 0) revert MustIdentifyUser();
    address user = abi.decode(hookData, (address));
    if (params.salt == bytes32(0)) {
        // Salt-0 = issuer's position — ONLY issuer may access
        if (user != issuer) revert OnlyIssuer();
        // ... existing vesting checks ...
    }
    // else: non-zero salt, non-issuer position → allow freely
}
```

Additionally, add access control in the router as defense-in-depth:

```solidity
function removeIssuerLiquidity(...) external {
    // Query hook for issuer and verify
    address issuer = IBastionHook(bastionHook).getPoolIssuer(key.toId());
    require(msg.sender == issuer, "Only issuer");
    ...
}
```

---

### C-02: Anyone Can Steal Issuer's Accumulated Fees via `collectIssuerFees`

**Location:** `BastionPositionRouter.sol:331-339` + `BastionHook.sol:360-372`

**Description:**
Same root cause as C-01. `collectIssuerFees()` has no access control and operates
on the issuer's salt-0 position. Any caller can collect the issuer's accumulated
swap fees.

```solidity
// BastionPositionRouter.sol:331 — NO ACCESS CONTROL
function collectIssuerFees(PoolKey calldata key) external { ... }

// _handleCollectIssuerFees uses salt=0 and sends fees to msg.sender
(BalanceDelta delta,) = poolManager.modifyLiquidity(key,
    ModifyLiquidityParams({..., liquidityDelta: 0, salt: 0}),
    abi.encode(sender) // sender = attacker
);
_settle(key.currency0, sender, delta.amount0()); // fees → attacker
```

The hook's fee collection path (`liquidityDelta == 0`):
```solidity
if (removeAmount == 0) {
    if (sender == _issuerLPOwner[poolId] && hookData.length > 0) {
        address user = abi.decode(hookData, (address));
        if (user == issuer) {
            // Only checks trigger — but non-issuer skips this entirely
            if (escrowVault.isTriggered(escrowId)) revert EscrowTriggered();
        }
    }
    return IHooks.beforeRemoveLiquidity.selector; // ← allows through
}
```

When `user != issuer`, the trigger check is skipped and fee collection proceeds.

**Impact:**
- Theft of all accumulated swap fees from the issuer's LP position
- Can be called repeatedly as fees accumulate

**Reproduction:**
1. Pool with active trading accumulates fees for issuer's position
2. Attacker calls `collectIssuerFees(key)`
3. All accumulated fees sent to attacker

**Recommended Fix:**
Same as C-01 — add salt-0 verification in the hook and access control in the router.

For the fee collection path in the hook:
```solidity
if (removeAmount == 0) {
    if (sender == _issuerLPOwner[poolId] && params.salt == bytes32(0)) {
        if (hookData.length == 0) revert MustIdentifyUser();
        address user = abi.decode(hookData, (address));
        if (user != issuer) revert OnlyIssuer();
        if (escrowVault.isTriggered(_escrowIds[poolId])) revert EscrowTriggered();
    }
    return IHooks.beforeRemoveLiquidity.selector;
}
```

---

## High

### H-01: Issuer Can Bypass Sell Limits via Non-Cooperating Routers

**Location:** `BastionHook.sol:481`

**Description:**
The hook identifies the actual swapper via hookData:

```solidity
address actualSwapper = (hookData.length == 32)
    ? abi.decode(hookData, (address))
    : sender;
```

Only cooperating routers (BastionSwapRouter) encode the true swapper address.
The issuer can bypass all sell limits by:

1. **Using a generic V4 router** that doesn't encode the swapper in hookData —
   `actualSwapper` becomes the router address, not the issuer.
2. **Deploying a custom router** that either passes empty hookData or encodes
   a different address.
3. **Transferring tokens to another wallet** and selling from there — the new
   wallet is not identified as the issuer.

In all cases, `actualSwapper != poolIssuer`, so all sell limit checks in both
`beforeSwap` (line 492) and `afterSwap` (line 544) are skipped.

**Impact:**
- Complete bypass of daily/weekly issuer sell limits
- Issuer can dump tokens without restrictions
- The sell defense mechanism provides a false sense of security

**Recommended Fix:**
This is a fundamental design limitation of hookData-based identification. Possible
mitigations:

1. **Token-level transfer hooks**: If the issued token implements ERC-20 transfer
   hooks, sales from the issuer's address (or any wallet that received tokens from
   the issuer) could be tracked regardless of the router.
2. **Holder registry**: Track token transfers on-chain and flag wallets that received
   tokens from the issuer.
3. **Documentation**: Clearly document this limitation — the LP escrow is the primary
   protection, sell limits are a best-effort deterrent against cooperating-router paths only.

---

### H-02: Sell Limit Denominator Uses Global PoolManager Balance

**Location:** `BastionHook.sol:554, 1152, 1189`

**Description:**
All three sell-limit check functions use `ERC20(issuedToken).balanceOf(address(poolManager))`
as the denominator:

```solidity
// _checkSellLimits (line 1152)
uint256 currentReserve = ERC20(issuedToken).balanceOf(address(poolManager));

// afterSwap (line 554)
uint256 currentReserve = ERC20(issuedToken).balanceOf(address(poolManager));

// _enforceAfterSwapSellLimits (line 1189)
uint256 currentReserve = ERC20(issuedToken).balanceOf(address(poolManager));
```

In Uniswap V4, the PoolManager holds tokens for **ALL** pools, not just the target
pool. If the issued token exists in multiple pools (e.g., listed on other V4 pools),
`balanceOf(poolManager)` returns the combined reserves across all pools.

Sell BPS = `(cumSell * 10,000) / currentReserve`. A larger `currentReserve`
(inflated by other pools) produces a smaller BPS, making the sell limits weaker.

**Impact:**
- Sell limits become less restrictive than configured
- An issuer can sell a larger absolute amount before hitting limits
- Severity depends on how much of the token exists in other V4 pools

**Recommended Fix:**
Use the pool's individual reserve instead of the global PoolManager balance.
The pool's reserve can be computed from liquidity and sqrt price:

```solidity
// Use initialTotalSupply as a stable denominator instead
uint256 denominator = _initialTotalSupply[poolId];
uint256 sellBps = (dailySellCumulative[poolId] * 10_000) / denominator;
```

Alternatively, use `StateLibrary` to read the pool's actual liquidity and
compute the token reserve via the AMM formula.

---

## Medium

### M-01: Emergency Withdrawal Does Not Check Trigger Status

**Location:** `InsurancePool.sol:392-409`

**Description:**
`executeEmergencyWithdraw()` subtracts from `pool.balance` without checking
whether the pool has been triggered:

```solidity
function executeEmergencyWithdraw(bytes32 requestId) external onlyGovernance nonReentrant {
    // ... timelock check ...
    PoolData storage pool = _getPool(req.poolId);
    if (pool.balance < req.amount) revert InsufficientPoolBalance();
    pool.balance -= req.amount;
    // No check for pool.isTriggered!
    (bool success,) = req.to.call{value: req.amount}("");
}
```

Attack scenario:
1. Governance requests emergency withdrawal (2-day timelock)
2. During the 2-day wait, a trigger fires → `pool.payoutBalance` is snapshotted
3. Governance executes the emergency withdrawal → `pool.balance` decreases
4. Victims call `claimCompensation` → `pool.balance -= amount` underflows or
   insufficient balance remains

**Impact:**
- Victim claims may revert due to insufficient `pool.balance`
- Governance (or compromised keys) can drain triggered pool funds

**Recommended Fix:**
```solidity
function executeEmergencyWithdraw(bytes32 requestId) external onlyGovernance nonReentrant {
    // ...
    PoolData storage pool = _getPool(req.poolId);
    if (pool.isTriggered) revert AlreadyTriggered(); // ← ADD THIS
    // ...
}
```

---

### M-02: Force Removal Failure Silently Leaves LP Permanently Locked

**Location:** `EscrowVault.sol:198-231`

**Description:**
In `triggerForceRemoval`, the escrow state is updated BEFORE the external call
to `forceRemoveIssuerLP`. If the call fails, the escrow is marked as triggered
with `removedLiquidity = totalLiquidity`, but the actual LP is never removed
from the pool:

```solidity
function triggerForceRemoval(uint256 escrowId, uint8 triggerType_) external onlyTriggerOracle {
    // CEI: effects before interactions
    escrow.isTriggered = true;                          // ← state updated
    escrow.removedLiquidity = escrow.totalLiquidity;    // ← all "seized"

    if (remainingLiquidity > 0) {
        (bool success, bytes memory reason) = BASTION_HOOK.call(
            abi.encodeCall(IBastionHook.forceRemoveIssuerLP, (poolId))
        );
        if (success) {
            emit ForceRemoval(...);
        } else {
            emit ForceRemovalFailed(escrowId, reason);  // ← no revert!
        }
    }
}
```

If the call fails:
- Escrow thinks all LP was seized → no one can remove via vesting
- LP remains in the pool → locked forever (no access path exists)
- Insurance pool receives no LP funds → victims get only accumulated fees
- The `ForceRemovalFailed` event is the only indication

**Impact:**
- Significant value locked permanently in the pool
- Insurance compensation reduced (potentially by the majority of available funds)

**Recommended Fix:**
Option A — Revert on failure (simpler, ensures all-or-nothing):
```solidity
if (!success) revert ForceRemovalFailed(reason);
```

Option B — Keep the soft-fail but don't update `removedLiquidity` (allows retry):
```solidity
if (success) {
    escrow.removedLiquidity = escrow.totalLiquidity;
    emit ForceRemoval(...);
} else {
    emit ForceRemovalFailed(escrowId, reason);
}
```

---

### M-03: Fallback Mode Allows Post-Trigger Token Acquisition for Claims

**Location:** `InsurancePool.sol:312-342`

**Description:**
In fallback mode (guardian fails to submit Merkle root within 24h),
`claimCompensationFallback` verifies the claimant's balance using the
**current** `balanceOf`, not a snapshot:

```solidity
if (ERC20(pool.issuedToken).balanceOf(msg.sender) < holderBalance) {
    revert InsufficientTokenBalance();
}
```

After a trigger, the token price typically crashes. An attacker can:
1. Wait for the 24h Merkle submission deadline to pass
2. Buy issued tokens cheaply on secondary markets or remaining pool liquidity
3. Call `claimCompensationFallback` with their current balance
4. Receive pro-rata insurance compensation based on `totalEligibleSupply`

The flash-loan protection (`block.number > triggerBlockNumber`) only prevents
same-block attacks, not cross-block token acquisition.

**Impact:**
- Dilution of legitimate victims' compensation
- Attacker profit = (compensation received) - (cost of buying crashed tokens)

**Recommended Fix:**
This is a known limitation of the fallback mode. The Merkle mode (primary path)
is not affected. Mitigations:

1. Increase the Merkle submission deadline window to reduce fallback activation
2. Add a minimum holding duration check (e.g., tokens must have been held
   since before the trigger block)
3. Document this risk clearly and prioritize guardian availability

---

## Low

### L-01: Fee-on-Transfer Check Silently Passes Without Approval

**Location:** `BastionPositionRouter.sol:920-932`

**Description:**
The FoT check uses `transferFrom(msg.sender, address(this), 1)` via low-level call.
If the user hasn't approved the router for standard ERC-20 transfers (e.g., using
Permit2 flow), the call returns `success = false` and the check is silently skipped.

For the Permit2 path (`createPoolPermit2`), `_validateTokenCompatibility(token, false)`
is called with `checkFoT = false`, so FoT is never checked.

**Impact:** Fee-on-transfer tokens could enter the protocol through the Permit2 path,
causing accounting discrepancies in the pool.

**Recommended Fix:** Document that FoT tokens are not supported and rely on the
base token allowlist (governance-controlled) as the primary defense. Consider adding
a FoT check that doesn't require user approval (e.g., using the contract's own balance).

---

### L-02: ExactOutput Sell Uses Wrong Amount for 1st-Layer Limit Check

**Location:** `BastionHook.sol:499-501`

**Description:**
```solidity
uint256 sellAmount = params.amountSpecified < 0
    ? uint256(uint128(int128(-params.amountSpecified)))
    : uint256(int256(params.amountSpecified)); // ← output amount, not sell amount
```

For exactOutput swaps (`amountSpecified > 0`), this uses the requested output
amount as the sell amount. The actual sell (input) amount is determined by the
AMM and may be significantly different.

**Impact:** The 1st-layer check in `beforeSwap` may underestimate the actual sell
amount. The 2nd-layer check in `afterSwap` uses `BalanceDelta` and correctly
enforces limits, so this is not exploitable.

**Recommended Fix:** Skip the 1st-layer check for exactOutput swaps and rely
entirely on the 2nd-layer enforcement in `afterSwap`.

---

### L-03: Multi-hop `amountOut` Overwrite on Multiple Positive Deltas

**Location:** `BastionSwapRouter.sol:464-468`

**Description:**
```solidity
} else if (delta > 0) {
    uint256 amount = uint256(delta);
    poolManager.take(currencies[i], sender, amount);
    amountOut = amount; // ← overwrites on each iteration
}
```

If a malformed multi-hop path produces multiple currencies with positive
deltas (shouldn't happen with well-formed paths), only the last one's amount
is returned. The `minAmountOut` check would then apply to the wrong currency.

**Impact:** Only affects malformed user inputs. A properly constructed multi-hop
swap has exactly one output currency.

**Recommended Fix:** Assert that only one positive delta exists, or accumulate
the output for the expected output currency only.

---

### L-04: `_owner` Should Be Declared `immutable`

**Location:** `BastionHook.sol:119`

**Description:**
`_owner` is only set in the constructor and never modified. Declaring it
`immutable` saves ~2,100 gas per access (SLOAD → bytecode read).

Slither correctly flagged this: `BastionHook._owner should be immutable`.

**Recommended Fix:**
```solidity
address internal immutable _owner;
```

---

## Informational

### I-01: Epoch-Based Window Boundaries Allow Near-Double Limits

**Location:** `BastionHook.sol:1127-1140, 1192-1204`

**Description:**
Daily/weekly sell and LP removal windows use epoch-based resets:
```solidity
if (block.timestamp >= dailySellWindowStart[poolId] + 86400) {
    dailySellCumulative[poolId] = 0;
    dailySellWindowStart[poolId] = uint40(block.timestamp);
}
```

An issuer can sell up to the daily limit just before the window resets,
then sell again immediately after. This effectively allows up to 2x the
daily limit within a short time span (seconds or minutes).

True sliding windows would prevent this but are significantly more complex
and gas-intensive. The current approach is a standard tradeoff.

---

### I-02: `reportCommitmentBreach` Passes `totalEligibleSupply=0`

**Location:** `TriggerOracle.sol:174-185`

**Description:**
`reportCommitmentBreach` calls `_executeImmediate` with `totalEligibleSupply=0`.
This means `InsurancePool.executePayout` is NOT called (guarded by `if (totalEligibleSupply > 0)`).
Consequently:
- The EscrowVault escrow is triggered → force removal → funds sent to InsurancePool
- But the InsurancePool is NOT marked as triggered
- Governance can later call `claimTreasuryFunds` (since `pool.isTriggered == false`)
  and send the seized funds to treasury + issuer reward

This function is currently unused (not called from BastionHook), so it has
no present impact. If activated in v0.2, the flow should be reviewed.

---

### I-03: Residual ETH Sweep in `forceRemoveIssuerLP`

**Location:** `BastionHook.sol:640`

**Description:**
```solidity
uint256 ethBalance = address(this).balance;
```

This captures ALL ETH in the hook contract, not just ETH from the current force
removal. Any residual ETH from other operations would be swept into the insurance
pool. In practice, the hook should not hold ETH between transactions (insurance
fees are deposited immediately), so this is unlikely to cause issues.

---

### I-04: Slither False Positives

The following Slither findings are false positives or by-design patterns:

| Detector | Location | Assessment |
|----------|----------|------------|
| `divide-before-multiply` | Tick alignment `(MIN_TICK / spacing) * spacing` | Standard V4 tick alignment — intentional truncation |
| `arbitrary-send-erc20` | Router `_settle` with `safeTransferFrom` | By design — sender is authenticated via `msg.sender` in the entry function |
| `arbitrary-send-eth` | Router `_refundETH` | By design — refunds excess ETH to `msg.sender` |
| `uninitialized-state` | `InsurancePool._pools` mapping | Normal Solidity mapping — initialized on first access |
| `uninitialized-local` | `totalIssuerReward`, `totalTreasuryAmount` | Initialized to 0 (uint default), incremented later |
| `incorrect-equality` | `currentReserve == 0`, `removable == 0` | Intentional early-return guards |
| `reentrancy-balance` | `_validateTokenCompatibility` | Read-before-external-call is intentional for the FoT detection pattern |
| `naming-convention` | `GOVERNANCE`, `BASTION_HOOK`, etc. | Project convention — storage variables use SCREAMING_CASE |
| `unused-return` | `executePayout` in try/catch | Return value intentionally ignored in try/catch pattern |

---

## Attack Scenario Analysis

### Scenario 1: Issuer Attempts Full LP Removal

**Path:** Issuer calls `removeIssuerLiquidity` → hook checks vesting → reverts if
exceeds vested amount → `escrowVault.recordLPRemoval` tracks removal.

**Result:** BLOCKED by vesting schedule. Daily/weekly LP removal limits also apply.

**Caveat:** An attacker (non-issuer) can drain the issuer's LP via C-01.

### Scenario 2: Issuer Attempts Full Token Dump (Direct)

**Path:** Issuer calls `BastionSwapRouter.swapExactInput` → hookData encodes issuer
address → `beforeSwap` checks sell limits → `afterSwap` enforces limits via BalanceDelta.

**Result:** BLOCKED by daily/weekly sell limits when using BastionSwapRouter.

**Caveat:** Issuer can use a non-cooperating router to bypass (H-01).

### Scenario 3: Issuer Uses Aggregator/Generic Router

**Path:** Issuer sells via generic V4 router → hookData doesn't encode issuer address
→ `actualSwapper = sender` (router address) → `actualSwapper != poolIssuer` → sell
limits not enforced.

**Result:** NOT BLOCKED. See H-01.

### Scenario 4: Issuer Transfers Tokens to Different Wallet

**Path:** Issuer transfers tokens to Wallet B via ERC-20 `transfer` → Wallet B sells
via any router → hook sees Wallet B, not the issuer → sell limits not enforced.

**Result:** NOT BLOCKED. Same root cause as H-01.

### Scenario 5: Flash Loan Attack on Insurance Claims

**Path (Merkle mode):** Attacker flash-loans tokens → calls `claimCompensation` with
Merkle proof → proof requires (attacker_address, balance) leaf → attacker not in snapshot.

**Result:** BLOCKED. Merkle proof prevents unauthorized claims.

**Path (Fallback mode):** Attacker flash-loans tokens → trigger block check
(`block.number > triggerBlockNumber`) → flash loan is same-block → REVERTS.

**Result:** BLOCKED within the trigger block. Cross-block buying is possible (M-03).

### Scenario 6: Governance Key Compromise

**Path:** Attacker gains governance key → can set parameters to extreme values:
- Set `maxDailyLpRemovalBps` to 10,000 (100%)
- Set `feeRate` to 10 bps (minimum)
- Emergency withdraw triggered pool funds
- Transfer governance to attacker's address

**Mitigations in place:**
- Parameter range validation on all setters
- Emergency withdrawal has 2-day timelock
- Governance transfer requires current governance key

**Residual risk:** Compromised governance can still cause significant damage
within parameter bounds. Consider a timelock on governance actions.

### Scenario 7: Guardian Submits False Merkle Root

**Path:** Malicious guardian submits a Merkle root that includes attacker addresses
with inflated balances → attackers claim outsized compensation.

**Result:** NOT BLOCKED at the smart contract level. The guardian is trusted to
submit correct snapshots.

**Mitigation:** Guardian is set by governance. A compromised guardian can be
replaced via `setGuardian()`. The 24h window limits the damage window.

### Scenario 8: General User LP Griefing

**Path:** User adds massive LP to a pool → TVL cap enforced → respects per-token cap.
User removes LP freely → non-issuer LP has no restrictions.

**Result:** No griefing vector. Non-issuer LP operations don't affect issuer's
position or trigger thresholds.

### Scenario 9: Fee-on-Transfer Token Pool Creation

**Path:** User calls `createPool` with FoT token → `_validateTokenCompatibility`
checks for FoT (1 wei transfer test) → detected and reverted.

**Path (Permit2):** User calls `createPoolPermit2` → FoT check is skipped
(`checkFoT = false`) → FoT token enters the system.

**Result:** PARTIALLY BLOCKED. See L-01.

### Scenario 10: Issuer Sells at Daily Limit Repeatedly

**Path:** Issuer sells exactly up to daily limit every day (epoch boundary) →
cumulative daily sell resets each epoch → issuer can sell `maxDailySellBps` per
epoch indefinitely.

**Result:** ALLOWED by design. Weekly limits provide a secondary constraint.
Over 90 days of vesting, the issuer can sell their allocation gradually, which
is the intended behavior.

---

## Summary of Fixes

| ID | Severity | Status | Description |
|----|----------|--------|-------------|
| C-01 | Critical | **FIXED** | Added `params.salt == bytes32(0)` check in hook + `OnlyIssuer` router access control |
| C-02 | Critical | **FIXED** | Same fix as C-01 — fee collection path also checks salt + issuer identity |
| H-01 | High | Open (design) | Document limitation or implement token-level transfer tracking |
| H-02 | High | **FIXED** | Replaced `balanceOf(poolManager)` with per-pool virtual reserves via `_getPoolIssuedTokenReserve()` |
| M-01 | Medium | **FIXED** | Added `pool.isTriggered` check in `executeEmergencyWithdraw` |
| M-02 | Medium | **FIXED** | `triggerForceRemoval` now reverts on force removal failure (`ForceRemovalCallFailed`) |
| M-03 | Medium | Open | Add minimum holding duration check in fallback mode |
| L-01 | Low | **FIXED** | Permit2 path now checks FoT (`checkFoT = true`) |

### Fix Details

**C-01/C-02 (BastionHook.sol + BastionPositionRouter.sol):**
- Hook `beforeRemoveLiquidity`: when `sender == _issuerLPOwner && params.salt == bytes32(0)`, requires `user == issuer` (reverts `OnlyIssuer`)
- Force-removal bypass: fee collection path now checks `_FORCE_REMOVAL_SLOT` to allow force fee collection during trigger
- Router: `removeIssuerLiquidity()` and `collectIssuerFees()` verify `msg.sender == hook.getPoolIssuer(poolId)`

**H-02 (BastionHook.sol):**
- New internal helper `_getPoolIssuedTokenReserve(poolId)` computes per-pool reserves from `getLiquidity()` + `getSlot0()`
- Public view `getPoolIssuedTokenReserve(poolId)` exposed for external consumers
- Three sell-limit functions updated: `_checkSellLimits`, `_enforceAfterSwapSellLimits`, `afterSwap` inline

**M-01 (InsurancePool.sol):**
- Added `if (pool.isTriggered) revert AlreadyTriggered()` in `executeEmergencyWithdraw`

**M-02 (EscrowVault.sol):**
- `triggerForceRemoval` now: attempt force removal first → revert if fails → mark escrow as triggered only on success
- New error: `ForceRemovalCallFailed(bytes reason)`
- Protected by `nonReentrant` modifier (safe despite CEI inversion)

### Test Results

- **396/399 tests pass** (3 failures are pre-existing fork-only tests requiring `--fork-url`)
- **86/86 fork tests pass** (with `--fork-url https://mainnet.base.org`)
- All contracts under 24,576 byte limit (BastionHook: 24,485 bytes)

---

*End of report.*
