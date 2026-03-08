#!/bin/bash
set -e

CONTRACTS_OUT="packages/contracts/out"
FRONTEND_ABIS="packages/frontend/src/config/abis"

mkdir -p "$FRONTEND_ABIS"

for CONTRACT in BastionHook EscrowVault InsurancePool TriggerOracle ReputationEngine BastionSwapRouter BastionPositionRouter; do
  jq '.abi' "$CONTRACTS_OUT/$CONTRACT.sol/$CONTRACT.json" > "$FRONTEND_ABIS/$CONTRACT.json"
  echo "Copied ABI: $CONTRACT"
done

# PoolManager ABI from Uniswap V4 core
if [ -f "$CONTRACTS_OUT/PoolManager.sol/PoolManager.json" ]; then
  jq '.abi' "$CONTRACTS_OUT/PoolManager.sol/PoolManager.json" > "$FRONTEND_ABIS/PoolManager.json"
  echo "Copied ABI: PoolManager"
fi

echo "All ABIs copied to $FRONTEND_ABIS"
