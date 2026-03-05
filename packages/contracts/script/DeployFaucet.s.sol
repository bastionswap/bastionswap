// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

import {TokenFaucet} from "../src/test/TokenFaucet.sol";

/// @title DeployFaucet — Deploy faucet for BTT and BTST test tokens
contract DeployFaucet is Script {
    // Test tokens deployed by TestE2E (v2 deployment)
    address constant BTT = 0x410521668Ad1625527562CA90475406b1b9cB8Af;
    address constant BTST = 0x69ce9bACB558F35bCAC2e6fd54caa8770AEE85d4;

    // Seed each faucet with 10,000 tokens
    uint256 constant SEED_AMOUNT = 10_000e18;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console2.log("=== Deploy Token Faucets ===");
        console2.log("Deployer:", deployer);

        vm.startBroadcast(deployerKey);

        TokenFaucet bttFaucet = new TokenFaucet(ERC20(BTT));
        TokenFaucet btstFaucet = new TokenFaucet(ERC20(BTST));

        // Seed faucets with tokens
        ERC20(BTT).transfer(address(bttFaucet), SEED_AMOUNT);
        ERC20(BTST).transfer(address(btstFaucet), SEED_AMOUNT);

        vm.stopBroadcast();

        console2.log("BTT Faucet:", address(bttFaucet));
        console2.log("BTST Faucet:", address(btstFaucet));
        console2.log("BTT Faucet balance:", ERC20(BTT).balanceOf(address(bttFaucet)));
        console2.log("BTST Faucet balance:", ERC20(BTST).balanceOf(address(btstFaucet)));
    }
}
