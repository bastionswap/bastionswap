.PHONY: build build-deploy test test-gas deploy-testnet deploy-testnet-dry deploy-mainnet clean

build:
	forge build

build-deploy:
	FOUNDRY_PROFILE=deploy forge build

test:
	forge test -vvv

test-gas:
	forge test -vvv --gas-report

deploy-testnet-dry:
	forge script script/Deploy.s.sol:Deploy \
		--rpc-url base_sepolia \
		-vvvv

deploy-testnet:
	forge script script/Deploy.s.sol:Deploy \
		--rpc-url base_sepolia \
		--broadcast \
		--verify \
		-vvvv

deploy-mainnet:
	forge script script/Deploy.s.sol:Deploy \
		--rpc-url base_mainnet \
		--broadcast \
		--verify \
		--slow \
		-vvvv

clean:
	forge clean
