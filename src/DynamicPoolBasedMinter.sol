// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MockERC20} from "./MockERC20.sol";
import {Hook} from "./Hook.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title DynamicPoolBasedMinter
/// @notice Splits a USDC deposit between tokenX and tokenY based on a pool price.
/// - When pool price is 1e18, 1 USDC mints 0.5 tokenX and 0.5 tokenY (equal value).
/// - When pool price is 2e17, tokenY is worth 100% more than tokenX, so 1 USDC mints ~0.33 tokenX and ~0.66 tokenY.
/// The ratio is linearly interpolated for values in between.
/// Also provides a function to return the market winner from the hook.

contract DynamicPoolBasedMinter {
    MockERC20 public tokenX;
    MockERC20 public tokenY;
    Hook public hook;
    MockERC20 public USDC;

    constructor(address _hook) {
        tokenX = new MockERC20("NO", "NO");
        tokenY = new MockERC20("YES", "YES");
        hook = Hook(_hook);
    }

    function depositAndMint(uint256 usdcAmount, PoolKey calldata key) external {
        uint256 poolPrice = hook.getPoolPrice(key);
        require(poolPrice > 0, "Invalid pool price");

        (uint256 tokenXAmount, uint256 tokenYAmount) = mintTokens(usdcAmount, poolPrice);
        USDC.transferFrom(msg.sender, address(this), usdcAmount);
        tokenX.mint(msg.sender, tokenXAmount);
        tokenY.mint(msg.sender, tokenYAmount);
    }

    uint256 private constant DECIMALS = 1e18;

    function mintTokens(uint256 deposit, uint256 poolPrice)
        internal
        pure
        returns (uint256 noTokens, uint256 yesTokens)
    {
        // The total "weight" is poolPrice (for YES) + 1e18 (for NO).
        uint256 denominator = poolPrice + DECIMALS;

        // Calculate YES tokens as the fraction of the deposit corresponding to the pool price.
        yesTokens = (deposit * poolPrice) / denominator;
        // Calculate NO tokens as the remainder.
        noTokens = (deposit * DECIMALS) / denominator;
    }

    function getNOPrice(PoolKey calldata key) external view returns (uint256) {
        uint256 poolPrice = hook.getPoolPrice(key);

        (uint256 x, uint256 y) = mintTokens(1, poolPrice);
        return x;
    }

    function getYESPrice(PoolKey calldata key) external view returns (uint256) {
        uint256 poolPrice = hook.getPoolPrice(key);

        (uint256 x, uint256 y) = mintTokens(1, poolPrice);
        return y;
    }

    function redeemTokenX(uint256 amount) external {
        if (hook.getWinner() != false) revert("Not the winner");
        if (hook.isFinalized() == false) revert("Not finalized");
        tokenX.transferFrom(msg.sender, address(this), amount);
        USDC.transfer(msg.sender, amount);
    }

    function redeemTokenY(uint256 amount) external {
        if (hook.getWinner() != true) revert("Not the winner");
        if (hook.isFinalized() == false) revert("Not finalized");

        tokenX.transferFrom(msg.sender, address(this), amount);
        USDC.transfer(msg.sender, amount);
    }
}
