// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @title TestToken — ERC20 with built-in faucet for local development
contract TestToken is ERC20 {
    uint256 public constant FAUCET_AMOUNT = 1000e18;
    uint256 public constant FAUCET_COOLDOWN = 24 hours;

    mapping(address => uint256) public lastFaucetClaim;

    event FaucetClaimed(address indexed recipient, uint256 amount);

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        uint256 initialSupply
    ) ERC20(name_, symbol_, decimals_) {
        _mint(msg.sender, initialSupply);
    }

    function faucet() external {
        require(
            block.timestamp >= lastFaucetClaim[msg.sender] + FAUCET_COOLDOWN,
            "Wait 24h between claims"
        );
        lastFaucetClaim[msg.sender] = block.timestamp;
        _mint(msg.sender, FAUCET_AMOUNT);
        emit FaucetClaimed(msg.sender, FAUCET_AMOUNT);
    }

    function canClaimFaucet(address account) external view returns (bool) {
        return block.timestamp >= lastFaucetClaim[account] + FAUCET_COOLDOWN;
    }
}
