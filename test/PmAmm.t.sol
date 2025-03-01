// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {DynamicPoolBasedMinter} from "../src/DynamicPoolBasedMinter.sol";

import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Fixtures} from "./utils/Fixtures.sol";

import {Hook} from "../src/Hook.sol"; // <-- your updated Hook contract

/**
 * @notice Example test that calls the new Hook with "initializeTime", "initializeMarket",
 *         "addLiquidity", "removeLiquidity", "getMarketState", etc.
 */
contract EnhancedPmAMMTest is Test, Fixtures {
    using PoolIdLibrary for PoolKey;

    Hook hook;
    PoolId poolId;

    // Example usage in the test
    bytes32 marketId; // Will store the same bytes32 as key.toId()

    // For demonstration
    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    // Market parameters
    uint256 constant INITIAL_LIQUIDITY = 100e18;
    int256 constant LIQUIDITY_FACTOR = 1e18; // L = 1.0 in 1e18
    uint256 constant MARKET_DURATION = 7 days;
    MockERC20 USDC;
    DynamicPoolBasedMinter dpMinter;

    function setUp() public {
        // Set up manager + tokens
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // Optional: position manager for v4, not strictly needed
        deployAndApprovePosm(manager);

        // Deploy the Hook:
        // "flags" merges the BEFORE_SWAP, BEFORE_ADD_LIQUIDITY, etc. into an address
        address flags = address(
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG)
                ^ (0x4444 << 144) // Just a "namespace" trick
        );
        USDC = new MockERC20("Real Cash Money", "USDC");
        // Deploy the Hook with constructor `Hook(IPoolManager manager)`
        bytes memory constructorArgs = abi.encode(manager, USDC);
        deployCodeTo("Hook.sol:Hook", constructorArgs, flags);
        hook = Hook(flags);
        dpMinter = new DynamicPoolBasedMinter(manager, address(hook), USDC);
        hook.setMinter(dpMinter);
        // Create a pool key and initialize it
        key = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = key.toId();
        // manager.initialize(key, 79228162514264337593543950336);

        tickLower = TickMath.minUsableTick(key.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        // Transfer some tokens to "address(this)"
        currency0.transfer(address(this), 100e18);
        currency1.transfer(address(this), 100e18);

        // Use the same ID for "marketId"
    }

    function test_makeMarket() public {
        // Just sets T=100 in the Hook’s pool state, and sets L=1e18, X=Y=0
        // hook.initializeTime(key, 100);
        USDC.mint(address(this), 100e18);
        USDC.approve(address(hook), 100e18);
        // Now read the pool’s state
        hook.MakeMarket("a", 10, 100e18, 1e18, 1e18);
    }
 function test_dynamicMint() public {
        // Just sets T=100 in the Hook’s pool state, and sets L=1e18, X=Y=0
        // hook.initializeTime(key, 100);
        USDC.mint(address(this), 100e18);
        USDC.approve(address(hook), 100e18);
        // Now read the pool’s state
        hook.MakeMarket("a", 10, 100e18, 1e18, 1e18);
   
        // Now read the pool’s state
        uint256 money = 100e18;
        USDC.mint(address(this),money );
        USDC.approve(address(dpMinter), money );
        dpMinter.depositAndMint(money );
      

        // console.log("Market initialized successfully");
    }
    function test_marketInitialization() public {
        // Just sets T=100 in the Hook’s pool state, and sets L=1e18, X=Y=0
        // hook.initializeTime(key, 100);

        // Now read the pool’s state
        (int256 reserveX, int256 reserveY, int256 liquidityFactor) = hook.getMarketState(key);

        // The test expects 0, 0, and LIQUIDITY_FACTOR
        assertEq(reserveX, 0);
        assertEq(reserveY, 0);
        assertEq(liquidityFactor, 0);

        console.log("Market initialized successfully");
    }

    // 2) Test adding liquidity to a market
    function test_liquidityAddition() public {
        // "initializeMarket" sets L, X=0, Y=0
        // hook.initializeTime(key, block.timestamp + 100);

        // Send tokens to the address(this) or to the manager, etc.
        // For demonstration we just do approvals
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), 20e18);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), 20e18);

        // Add liquidity to the pool
        hook.addLiquidity(key, 10e18, 10e18);

        // Check updated state
        (int256 reserveX, int256 reserveY, int256 liqF) = hook.getMarketState(key);
        assertEq(reserveX, int256(10e18));
        assertEq(reserveY, int256(10e18));
        console.log(liqF);
        console.log("Liquidity added successfully");
        console.log("Reserve X:", uint256(reserveX));
        console.log("Reserve Y:", uint256(reserveY));
    }

    // 3) Test swapping in the market
    function test_pmAmmSwap() public {
        // Initialize with smaller L=1e10, zero reserves
        // hook.initializeTime(key, block.timestamp + 100);

        // Approve & add liquidity
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), 120e18);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), 120e18);
        hook.addLiquidity(key, 50e18, 50e18);

        // Do a small swap with the v4 manager's "swap" function
        uint256 amountToSwap = 1e15;
        bool zeroForOne = true;
        int256 amountSpecified = -int256(amountToSwap); // negative for exact-input

        // Print old
        (int256 reserveXBefore, int256 reserveYBefore,) = hook.getMarketState(key);
        console.log("Old Reserve X:", uint256(reserveXBefore));
        console.log("Old Reserve Y:", uint256(reserveYBefore));

        // This uses the PoolSwapTest swap() from v4-core test harness
        swap(key, zeroForOne, amountSpecified, ZERO_BYTES);

        // Print new
        (int256 reserveXAfter, int256 reserveYAfter,) = hook.getMarketState(key);
        console.log("New Reserve X:", uint256(reserveXAfter));
        console.log("New Reserve Y:", uint256(reserveYAfter));

        // A second small swap in opposite direction
        swap(key, !zeroForOne, amountSpecified / 200, ZERO_BYTES);

        // Final state
        (int256 reserveXEnd, int256 reserveYEnd,) = hook.getMarketState(key);
        console.log("Final Reserve X:", uint256(reserveXEnd));
        console.log("Final Reserve Y:", uint256(reserveYEnd));
    }

    // 4) Test the price calculation in a PM market
    function test_marketPrice() public {
        // Start with balanced liquidity
        // hook.initializeTime(key, block.timestamp + 100);
        // Approve & add liquidity
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), 120e18);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), 120e18);
        hook.addLiquidity(key, 50e18, 50e18);

        // Price should be near 0.5
        uint256 initialPrice = hook.getPoolPrice(key);
        console.log("Initial price with equal reserves:", uint256(initialPrice));
        assertTrue(initialPrice == 1e18); //Tokens are 1:1

        // Add more X reserves => price should go down
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), 5e18);
        hook.addLiquidity(key, 5e18, 0);

        uint256 newPrice = hook.getPoolPrice(key);
        console.log("New price after adding more X:", uint256(newPrice));
        assertTrue(newPrice < initialPrice);
    }

    // 5) Test the time decay mechanism
    function test_dynamicLiquidity() public {
        //With this test we should see that swapping twice will return less tokens
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), 120e18);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), 120e18);
        hook.addLiquidity(key, 50e18, 50e18);

        // First swap
        uint256 userBalance0 = currency1.balanceOf(address(this));

        swap(key, true, -1e16, abi.encode(address(this))); // exact input of 1 token0
        uint256 userBalance1 = currency1.balanceOf(address(this));
        uint256 output1 = userBalance1 - userBalance0;
        console.log("Output from first swap:", output1);

        // Replenish

        // Advance time => T is smaller => typically less output
        vm.warp(block.timestamp + (MARKET_DURATION * 2 / 4));

        vm.prank(address(this));
        swap(key, true, -1e16, abi.encode(address(this)));
        uint256 userBalance2 = currency1.balanceOf(address(this));
        uint256 output2 = userBalance2 - userBalance1;

        console.log("Output from second swap (closer to expiry):", output2);
        // Expect less
        assertTrue(output2 < output1);
    }

    // 6) Test removing liquidity
    function test_liquidityRemoval() public {
        uint256 expirationTime = block.timestamp + MARKET_DURATION;
        // Start with 10,10 reserves
        // hook.initializeTime(key, block.timestamp + 100);

        // Add 10,10 more => total 20,20
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), 20e18);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), 20e18);
        hook.addLiquidity(key, 10e18, 10e18);

        // Current reserves => 20,20
        (int256 reserveXBefore, int256 reserveYBefore,) = hook.getMarketState(key);
        console.log("Before removal - X:", uint256(reserveXBefore), " Y:", uint256(reserveYBefore));

        // Remove 5,5 => new reserves => 15,15
        uint256 totalShares = hook.totalLiquidityShares(key.toId());
        uint256 myShares = hook.userLiquidityShares(key.toId(), address(this));

        hook.removeLiquidity(key, myShares);

        (int256 reserveXAfter, int256 reserveYAfter,) = hook.getMarketState(key);
        console.log("Reserves after removal - X:", uint256(reserveXAfter), " Y:", uint256(reserveYAfter));
        assertEq(reserveXAfter, 0);
        assertEq(reserveYAfter, 0);
    }

    // Helper function to show what's happening
    function _printTestType(bool zeroForOne, int256 amountSpecified) internal {
        console.log("--- TEST TYPE ---");
        string memory zeroForOneString = zeroForOne ? "zeroForOne" : "oneForZero";
        string memory swapType = amountSpecified < 0 ? "exactInput" : "exactOutput";
        console.log("This is a", zeroForOneString, swapType, "swap");
    }
}
