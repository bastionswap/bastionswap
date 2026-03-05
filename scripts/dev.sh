#!/bin/bash
set -e

echo "BastionSwap Local Dev (Base Mainnet Fork)"
echo "============================================="

# Check for BASE_MAINNET_RPC
if [ -z "$BASE_MAINNET_RPC" ]; then
  echo "ERROR: BASE_MAINNET_RPC is not set."
  echo "  Get a free RPC from Alchemy/Infura/QuickNode."
  echo "  Export it: export BASE_MAINNET_RPC=https://..."
  exit 1
fi

# 1. Kill existing Anvil
pkill -f "anvil" 2>/dev/null || true
sleep 1

# 2. Start Anvil (Base mainnet fork)
echo "Starting Anvil (forking Base mainnet)..."
anvil \
  --fork-url "$BASE_MAINNET_RPC" \
  --chain-id 31337 \
  --block-time 2 \
  --accounts 10 \
  --balance 10000 \
  &
ANVIL_PID=$!
sleep 3

# Verify Anvil is running
if ! kill -0 $ANVIL_PID 2>/dev/null; then
  echo "ERROR: Anvil failed to start. Check your BASE_MAINNET_RPC."
  exit 1
fi

# 3. Build contracts
echo "Building contracts..."
cd packages/contracts
forge build
cd ../..

# 4. Deploy BastionSwap to fork
echo "Deploying BastionSwap to fork..."
cd packages/contracts
forge script script/DeployLocal.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  -vvv
cd ../..

# 5. Copy ABIs
echo "Copying ABIs..."
bash scripts/copy-abis.sh

# 6. Generate frontend config
echo "Generating frontend config..."
bash scripts/generate-frontend-config.sh

# 7. Start frontend
echo "Starting frontend..."
cd packages/frontend
pnpm dev &
FRONTEND_PID=$!
cd ../..

echo ""
echo "============================================="
echo "BastionSwap Local Dev Ready!"
echo "============================================="
echo ""
echo "  Anvil RPC:    http://127.0.0.1:8545"
echo "  Frontend:     http://localhost:3000"
echo "  Chain ID:     31337 (Base mainnet fork)"
echo ""
echo "  From the fork you get:"
echo "    Uniswap V4 PoolManager"
echo "    USDC, WETH, and real tokens"
echo "    Existing V4 pools (All Pools tab)"
echo ""
echo "  Test accounts (10,000 ETH each):"
echo "  #0 (Deployer): 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
echo "  #1 (Trader):   0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
echo ""
echo "  Press Ctrl+C to stop all services"
echo ""

trap "echo 'Shutting down...'; kill $ANVIL_PID $FRONTEND_PID 2>/dev/null; exit" SIGINT SIGTERM
wait
