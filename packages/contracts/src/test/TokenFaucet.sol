// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";

/// @title TokenFaucet — Dispenses test tokens for demo purposes
/// @notice Rate-limited: 1 claim per address per 24 hours
contract TokenFaucet {
    ERC20 public immutable token;
    uint256 public constant CLAIM_AMOUNT = 1000e18;
    uint256 public constant COOLDOWN = 24 hours;

    mapping(address => uint256) public lastClaim;

    event Claimed(address indexed recipient, uint256 amount);

    constructor(ERC20 _token) {
        token = _token;
    }

    function claim() external {
        require(
            block.timestamp >= lastClaim[msg.sender] + COOLDOWN,
            "Wait 24h between claims"
        );
        require(
            token.balanceOf(address(this)) >= CLAIM_AMOUNT,
            "Faucet empty"
        );

        lastClaim[msg.sender] = block.timestamp;
        SafeTransferLib.safeTransfer(token, msg.sender, CLAIM_AMOUNT);

        emit Claimed(msg.sender, CLAIM_AMOUNT);
    }

    function canClaim(address account) external view returns (bool) {
        return block.timestamp >= lastClaim[account] + COOLDOWN
            && token.balanceOf(address(this)) >= CLAIM_AMOUNT;
    }
}
