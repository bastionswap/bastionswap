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
