#!/bin/bash
set -e

echo "Redeploying contracts to fork..."

# Check for BASE_MAINNET_RPC
if [ -z "$BASE_MAINNET_RPC" ]; then
  echo "ERROR: BASE_MAINNET_RPC is not set."
  exit 1
fi

# 1. Reset fork state (back to mainnet state, removes BastionSwap deployment)
echo "Resetting fork state..."
cast rpc anvil_reset \
  --rpc-url http://127.0.0.1:8545 \
  -- --forking "{\"jsonRpcUrl\":\"$BASE_MAINNET_RPC\"}" \
  2>/dev/null || true
sleep 2

# Clear EIP-7702 delegation code at Anvil default accounts (needed for Permit2 ecrecover)
# On Base mainnet, these addresses may have contract code which makes Permit2 use ERC-1271
# instead of ecrecover for signature verification.
echo "Clearing code at default accounts for Permit2 compatibility..."
cast rpc anvil_setCode --rpc-url http://127.0.0.1:8545 \
  "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" "0x" 2>/dev/null || true
cast rpc anvil_setCode --rpc-url http://127.0.0.1:8545 \
  "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" "0x" 2>/dev/null || true

# 2. Build contracts
echo "Building..."
cd packages/contracts
forge build

# 3. Redeploy
echo "Deploying..."
forge script script/DeployLocal.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  -vvv
cd ../..

# 4. Update frontend config + ABIs
echo "Updating frontend..."
bash scripts/copy-abis.sh
bash scripts/generate-frontend-config.sh

echo ""
echo "Redeployment complete!"
echo "  Refresh browser to see changes."
