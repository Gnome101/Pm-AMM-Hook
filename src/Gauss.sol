// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.20;

// import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
// import {PoolKey} from "v4-core/src/types/PoolKey.sol";
// import {Hooks} from "v4-core/src/libraries/Hooks.sol";
// import {Currency} from "v4-core/src/types/Currency.sol";
// import {CurrencyLibrary} from "v4-core/src/types/Currency.sol";
// import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
// import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";
// import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";

// import {toBeforeSwapDelta, BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
// import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";

// import {BaseHook} from "./BaseHook.sol";
// import {Gaussian} from "lib/solstat/src/Gaussian.sol";
// import {VirtualReservesLib} from "./VirtualReservesLib.sol";

// import {console} from "forge-std/console.sol";
// import {IERC20} from "forge-std/interfaces/IERC20.sol";

// /**
//  * @title Example of pm-AMM with Time Decay and L Recalculation
//  * @notice Demonstrates:
//  *         (1) Recalculation of liquidityFactor (L) when adding liquidity.
//  *         (2) Decaying L over time via a decayRate.
//  *         (3) Reverting if an attempted swap would produce a negative output.
//  */
// contract EnhancedPmAMMWithTime is BaseHook, SafeCallback {
//     using CurrencySettler for Currency;
//     using CurrencyLibrary for Currency;
//     using SafeCast for uint256;
//     using Gaussian for int256;

//     // --------------------------------------------------
//     // Constants
//     // --------------------------------------------------
//     uint256 internal constant MAX_ITERS = 100;
//     int256 internal constant EPSILON = 1e4; // e.g. 1e-14 tolerance if 1e18 is "1"

//     // Example: Hardcode phi(0) if you like, or store in a library
//     // phi(0) ≈ 0.3989422804 in 1e18 fixed point
//     int256 internal constant PHI0 = 398942280401432677;

//     // --------------------------------------------------
//     // Market Struct
//     // --------------------------------------------------
//     struct Market {
//         int256 reserveX; // actual reserves of X (scaled 1e18)
//         int256 reserveY; // actual reserves of Y (scaled 1e18)
//         int256 liquidityFactor; // L parameter (scaled 1e18)
//         bool isInitialized;
//         // --- New fields for time decay ---
//         uint256 lastUpdate; // last timestamp we updated decay
//         int256 decayRate; // e.g. if > 0, then L decays by e^(-decayRate * deltaT)
//     }

//     mapping(bytes32 => Market) public markets;

//     // --------------------------------------------------
//     // Events
//     // --------------------------------------------------
//     event MarketInitialized(bytes32 indexed poolId, int256 liquidityFactor);
//     event LiquidityAdded(bytes32 indexed poolId, int256 amountX, int256 amountY, int256 newL);
//     event LiquidityRemoved(bytes32 indexed poolId, int256 amountX, int256 amountY);
//     event Swap(bytes32 indexed poolId, bool zeroForOne, int256 amountIn, int256 amountOut);

//     // --------------------------------------------------
//     // Constructor
//     // --------------------------------------------------
//     constructor(IPoolManager __poolManager) SafeCallback(__poolManager) {}

//     // --------------------------------------------------
//     // Public Hooks / Permissions
//     // --------------------------------------------------
//     function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
//         return Hooks.Permissions({
//             beforeInitialize: false,
//             afterInitialize: false,
//             beforeAddLiquidity: true,
//             beforeRemoveLiquidity: false,
//             afterAddLiquidity: false,
//             afterRemoveLiquidity: false,
//             beforeSwap: true,
//             afterSwap: false,
//             beforeDonate: false,
//             afterDonate: false,
//             beforeSwapReturnDelta: true,
//             afterSwapReturnDelta: false,
//             afterAddLiquidityReturnDelta: false,
//             afterRemoveLiquidityReturnDelta: false
//         });
//     }

//     // We do not allow direct v4 (tick-based) liquidity
//     function _beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
//         internal
//         pure
//         override
//         returns (bytes4)
//     {
//         revert("No v4 Liquidity allowed");
//     }

//     // --------------------------------------------------
//     // Market Initialization
//     // --------------------------------------------------
//     function initializeMarket(
//         PoolKey calldata key,
//         int256 liquidityFactor,
//         int256 initialX,
//         int256 initialY,
//         int256 decayRate // e.g. store how quickly L decays
//     ) external {
//         require(liquidityFactor > 0, "L must be positive");
//         require(initialX >= 0 && initialY >= 0, "Non-negative init reserves");

//         bytes32 poolId = _getPoolId(key);
//         require(!markets[poolId].isInitialized, "Already init");

//         markets[poolId] = Market({
//             reserveX: initialX,
//             reserveY: initialY,
//             liquidityFactor: liquidityFactor,
//             isInitialized: true,
//             lastUpdate: block.timestamp,
//             decayRate: decayRate
//         });

//         emit MarketInitialized(poolId, liquidityFactor);
//     }

//     function _getPoolId(PoolKey calldata key) internal pure returns (bytes32) {
//         return keccak256(abi.encode(key));
//     }

//     // --------------------------------------------------
//     // Time-Decay Update
//     // --------------------------------------------------
//     /**
//      * @dev Example of applying exponential decay to L:
//      *      L_new = L_old * exp( -decayRate * Δt ).
//      *      You can adjust or replace with your own logic.
//      */
//     function _applyDecay(bytes32 poolId) internal {
//         Market storage m = markets[poolId];
//         if (!m.isInitialized) return;

//         uint256 tNow = block.timestamp;
//         uint256 dt = tNow - m.lastUpdate;
//         if (dt == 0) return; // no change

//         // Decay factor: exp( -decayRate * dt )
//         // We'll treat decayRate in 1e18 scale, dt in seconds.
//         // So exponent = - (decayRate * dt). Then expWad(exponent) from a typical fixed-point library.
//         if (m.decayRate != 0) {
//             int256 exponent = -(m.decayRate * int256(dt));
//             // If your exp function expects 1e18 scaling, we remain consistent:
//             // For example, if decayRate is 1e16 => that is 0.01 per second => over dt seconds => exponent = - 0.01*dt
//             // Make sure the library's expWad is used correctly.
//             int256 scale = _expWad(exponent); // see helper below
//             // Scale new L:
//             int256 newL = (m.liquidityFactor * scale) / int256(1e18);
//             if (newL < 0) {
//                 // Should not happen if everything is normal; but just safe-check
//                 newL = 0;
//             }
//             m.liquidityFactor = newL;
//         }

//         m.lastUpdate = tNow;
//     }

//     // --------------------------------------------------
//     // Swaps
//     // --------------------------------------------------
//     function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
//         internal
//         override
//         returns (bytes4, BeforeSwapDelta, uint24)
//     {
//         bytes32 poolId = _getPoolId(key);
//         Market storage market = markets[poolId];
//         require(market.isInitialized, "Not init");

//         // 1) First, update decay
//         _applyDecay(poolId);

//         // 2) Proceed with normal pm‑AMM logic
//         bool zeroForOne = params.zeroForOne;
//         bool exactInput = (params.amountSpecified < 0);
//         uint256 swapAmount = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

//         (uint256 inAmount, uint256 outAmount) =
//             exactInput ? _swapExactIn(poolId, swapAmount, zeroForOne) : _swapExactOut(poolId, swapAmount, zeroForOne);

//         // If the “amount out” ended up negative or zero, revert (instead of returning 0).
//         // You can also do this check inside `_swapExactIn` / `_swapExactOut`.
//         require(outAmount > 0, "Swap yields negative/zero out");

//         // Transfer tokens from/to pool manager
//         Currency token0 = key.currency0;
//         Currency token1 = key.currency1;
//         if (exactInput) {
//             // user is sending in 'swapAmount'
//             if (zeroForOne) {
//                 token0.take(poolManager, address(this), inAmount, true);
//                 token1.settle(poolManager, address(this), outAmount, true);
//             } else {
//                 token1.take(poolManager, address(this), inAmount, true);
//                 token0.settle(poolManager, address(this), outAmount, true);
//             }
//         } else {
//             // exact output
//             if (zeroForOne) {
//                 // we want out in token0 => user receives 'swapAmount'
//                 token1.take(poolManager, address(this), inAmount, true);
//                 token0.settle(poolManager, address(this), swapAmount, true);
//             } else {
//                 token0.take(poolManager, address(this), inAmount, true);
//                 token1.settle(poolManager, address(this), swapAmount, true);
//             }
//         }

//         // Build deltas for Uniswap V4
//         int128 deltaAmt0;
//         int128 deltaAmt1;
//         if (exactInput) {
//             if (zeroForOne) {
//                 deltaAmt0 = int128(int256(inAmount));
//                 deltaAmt1 = -int128(int256(outAmount));
//             } else {
//                 deltaAmt0 = -int128(int256(outAmount));
//                 deltaAmt1 = int128(int256(inAmount));
//             }
//         } else {
//             // exactOut
//             if (zeroForOne) {
//                 deltaAmt0 = -int128(int256(swapAmount));
//                 deltaAmt1 = int128(int256(inAmount));
//             } else {
//                 deltaAmt0 = int128(int256(inAmount));
//                 deltaAmt1 = -int128(int256(swapAmount));
//             }
//         }

//         emit Swap(poolId, zeroForOne, int256(inAmount), int256(outAmount));
//         return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(deltaAmt0, deltaAmt1), 0);
//     }

//     // --------------------------------------------------
//     // pm-AMM Swap Routines (using Virtual Reserves)
//     // --------------------------------------------------
//     function _swapExactIn(bytes32 poolId, uint256 inAmount, bool zeroForOne)
//         internal
//         returns (uint256 inAmtActual, uint256 outAmtActual)
//     {
//         Market storage m = markets[poolId];

//         // 1) Convert actual->virtual
//         (int256 vX0, int256 vY0) = VirtualReservesLib.getVirtualReserves(m.reserveX, m.reserveY, m.liquidityFactor);

//         int256 inWad = int256(inAmount);
//         int256 vX1 = vX0;
//         int256 vY1 = vY0;
//         int256 outWadVirtual;

//         if (zeroForOne) {
//             // X in => vX1 = vX0 + inWad
//             vX1 = vX0 + inWad;
//             // solve Y from pm‑AMM
//             vY1 = _solveYGivenX(m.liquidityFactor, vX1, vY0);
//             outWadVirtual = (vY0 - vY1);
//             // revert if negative
//             require(outWadVirtual > 0, "Negative virOut");
//             outAmtActual = _mapVirtualOutputToActual(outWadVirtual, (m.reserveX + m.reserveY), (vX0 + vY0));
//         } else {
//             // Y in => vY1 = vY0 + inWad
//             vY1 = vY0 + inWad;
//             // solve X from pm‑AMM
//             vX1 = _solveXGivenY(m.liquidityFactor, vX0, vY1);
//             outWadVirtual = (vX0 - vX1);
//             require(outWadVirtual > 0, "Negative virOut");
//             outAmtActual = _mapVirtualOutputToActual(outWadVirtual, (m.reserveX + m.reserveY), (vX0 + vY0));
//         }

//         // 4) map back to actual domain
//         (int256 newX, int256 newY) = _fromVirtualReserves(
//             m.reserveX,
//             m.reserveY,
//             zeroForOne ? inWad : int256(0),
//             zeroForOne ? int256(outAmtActual) : int256(0),
//             zeroForOne ? int256(0) : inWad,
//             zeroForOne ? int256(0) : int256(outAmtActual),
//             vX1,
//             vY1,
//             m.liquidityFactor
//         );

//         m.reserveX = newX;
//         m.reserveY = newY;

//         return (inAmount, outAmtActual);
//     }

//     function _swapExactOut(bytes32 poolId, uint256 outAmount, bool zeroForOne)
//         internal
//         returns (uint256 inAmtActual, uint256 outAmtActual)
//     {
//         Market storage m = markets[poolId];

//         (int256 vX0, int256 vY0) = VirtualReservesLib.getVirtualReserves(m.reserveX, m.reserveY, m.liquidityFactor);

//         int256 outWad = int256(outAmount);
//         int256 vX1 = vX0;
//         int256 vY1 = vY0;

//         if (zeroForOne) {
//             // we want out X => vX1 = vX0 - outWad
//             int256 proposedX = vX0 - outWad;
//             require(proposedX >= 0, "Not enough virX");
//             vX1 = proposedX;
//             // solve for vY1
//             vY1 = _solveYGivenX(m.liquidityFactor, vX1, vY0);
//             // in = (vY1 - vY0)
//             int256 inVirtual = (vY1 - vY0);
//             require(inVirtual > 0, "Neg input");
//             inAmtActual = _mapVirtualInputToActual(inVirtual, (m.reserveX + m.reserveY), (vX0 + vY0));
//         } else {
//             // we want out Y => vY1 = vY0 - outWad
//             int256 proposedY = vY0 - outWad;
//             require(proposedY >= 0, "Not enough virY");
//             vY1 = proposedY;
//             // solve for vX1
//             vX1 = _solveXGivenY(m.liquidityFactor, vX0, vY1);
//             int256 inVirtual = (vX1 - vX0);
//             require(inVirtual > 0, "Neg input");
//             inAmtActual = _mapVirtualInputToActual(inVirtual, (m.reserveX + m.reserveY), (vX0 + vY0));
//         }
//         outAmtActual = outAmount;

//         // update actual
//         (int256 newX, int256 newY) = _fromVirtualReserves(
//             m.reserveX,
//             m.reserveY,
//             zeroForOne ? int256(inAmtActual) : int256(0),
//             zeroForOne ? int256(outAmtActual) : int256(0),
//             zeroForOne ? int256(0) : int256(inAmtActual),
//             zeroForOne ? int256(0) : int256(outAmtActual),
//             vX1,
//             vY1,
//             m.liquidityFactor
//         );
//         m.reserveX = newX;
//         m.reserveY = newY;

//         return (inAmtActual, outAmtActual);
//     }

//     // --------------------------------------------------
//     // Actual <-> Virtual Mapping
//     // --------------------------------------------------
//     function _mapVirtualOutputToActual(int256 outWadVirtual, int256 sumActual, int256 sumVirtual)
//         internal
//         pure
//         returns (uint256)
//     {
//         require(outWadVirtual >= 0, "Neg virOut");
//         // scale by ratio
//         int256 ratio = (sumVirtual == 0) ? int256(1) : sumVirtual;
//         int256 outWadActual = (outWadVirtual * sumActual) / ratio;
//         if (outWadActual < 0) return 0;
//         return uint256(outWadActual);
//     }

//     function _mapVirtualInputToActual(int256 inWadVirtual, int256 sumActual, int256 sumVirtual)
//         internal
//         pure
//         returns (uint256)
//     {
//         require(inWadVirtual >= 0, "Neg virIn");
//         int256 ratio = (sumVirtual == 0) ? int256(1) : sumVirtual;
//         int256 inWadActual = (inWadVirtual * sumActual) / ratio;
//         if (inWadActual < 0) return 0;
//         return uint256(inWadActual);
//     }

//     function _fromVirtualReserves(
//         int256 xOld,
//         int256 yOld,
//         int256 inX,
//         int256 outX,
//         int256 inY,
//         int256 outY,
//         int256 vX1,
//         int256 vY1,
//         int256 /*L*/
//     ) internal pure returns (int256 xNew, int256 yNew) {
//         // net flows
//         int256 netFlowX = (inX - outX);
//         int256 netFlowY = (inY - outY);

//         int256 sumOld = xOld + yOld;
//         int256 sumNew = sumOld + netFlowX + netFlowY;

//         int256 newDiff = (vY1 - vX1);

//         // Solve:
//         //   xNew + yNew = sumNew
//         //   yNew - xNew = newDiff
//         int256 half = (sumNew + newDiff) / 2;
//         xNew = sumNew - half;
//         yNew = half;

//         require(xNew >= 0 && yNew >= 0, "Negative reserves");
//         return (xNew, yNew);
//     }

//     // --------------------------------------------------
//     // Newton Routines for pm-AMM
//     // --------------------------------------------------
//     // f(x,y) = (y - x)*Φ(L*(y-x)) + L*ϕ(L*(y-x)) - y = 0

//     function _solveYGivenX(int256 L, int256 x, int256 yGuess) internal pure returns (int256) {
//         int256 yCurrent = yGuess;
//         for (uint256 i = 0; i < MAX_ITERS; i++) {
//             (int256 fVal, int256 fDeriv) = _pmInvariantAndDerivY(L, x, yCurrent);
//             if (fDeriv == 0) break;
//             int256 step = (fVal * 1e17) / fDeriv;
//             int256 yNext = yCurrent - step;
//             if (_abs(yNext - yCurrent) < EPSILON) {
//                 return yNext >= 0 ? yNext : int256(0);
//             }
//             yCurrent = yNext;
//         }
//         return yCurrent >= 0 ? yCurrent : int256(0);
//     }

//     function _solveXGivenY(int256 L, int256 xGuess, int256 y) internal pure returns (int256) {
//         int256 xCurrent = xGuess;
//         for (uint256 i = 0; i < MAX_ITERS; i++) {
//             (int256 fVal, int256 fDeriv) = _pmInvariantAndDerivX(L, xCurrent, y);
//             if (fDeriv == 0) break;
//             int256 step = (fVal * 1e17) / fDeriv;
//             int256 xNext = xCurrent - step;
//             if (_abs(xNext - xCurrent) < EPSILON) {
//                 return xNext >= 0 ? xNext : int256(0);
//             }
//             xCurrent = xNext;
//         }
//         return xCurrent >= 0 ? xCurrent : int256(0);
//     }

//     function _pmInvariantAndDerivY(int256 L, int256 x, int256 y) internal pure returns (int256 fVal, int256 fDeriv) {
//         int256 diff = (y - x);
//         int256 z = (L * diff) / 1e18;

//         int256 cdfZ = z.cdf();
//         int256 pdfZ = z.pdf();

//         // fVal
//         fVal = ((diff * cdfZ) / 1e18) + ((L * pdfZ) / 1e18) - y;

//         // derivative wrt y
//         int256 L2 = (L * L) / 1e18;
//         // df/dy = Φ(z) + diff*(L/1e18)*ϕ(z) - (L^2*z*ϕ(z)/1e36) - 1
//         // but careful with 1e18 scaling
//         int256 term1 = cdfZ;
//         int256 term2 = (diff * pdfZ * L) / (1e18 * 1e18);
//         int256 term3 = -((L2 * z * pdfZ) / (1e18 * 1e18));
//         fDeriv = term1 + term2 + term3 - 1e18;
//     }

//     function _poolManager() internal view override returns (IPoolManager) {
//         return IPoolManager(address(poolManager));
//     }

//     function _pmInvariantAndDerivX(int256 L, int256 x, int256 y) internal pure returns (int256 fVal, int256 fDeriv) {
//         int256 diff = (y - x);
//         int256 z = (L * diff) / 1e18;
//         int256 cdfZ = z.cdf();
//         int256 pdfZ = z.pdf();

//         fVal = ((diff * cdfZ) / 1e18) + ((L * pdfZ) / 1e18) - y;

//         int256 L2 = (L * L) / 1e18;
//         // derivative wrt x is basically the negative w.r.t. the diff
//         // you can match your original derivation
//         int256 term1 = -cdfZ;
//         int256 term2 = -((diff * pdfZ * L) / (1e18 * 1e18));
//         int256 term3 = ((L2 * z * pdfZ) / (1e18 * 1e18));
//         fDeriv = term1 + term2 + term3;
//     }

//     function _abs(int256 x) internal pure returns (int256) {
//         return x >= 0 ? x : -x;
//     }

//     // --------------------------------------------------
//     // Liquidity Management
//     // --------------------------------------------------
//     /**
//      * @notice Example: when adding liquidity, we “top up” reserves then recalc L.
//      *         A simple approach is to define L = (X + Y) / (2 * phi(0)) in 1e18 scale.
//      *         Or use your own formula (like sqrt(X^2 + Y^2), etc.).
//      */
//     function addLiquidity(PoolKey calldata key, int256 amountX, int256 amountY) external {
//         require(amountX >= 0 && amountY >= 0, "No negative deposit");

//         bytes32 poolId = _getPoolId(key);
//         Market storage market = markets[poolId];
//         require(market.isInitialized, "Not init");

//         // Move actual tokens in
//         poolManager.unlock(abi.encode(msg.sender, key.currency0, key.currency1, amountX, amountY, true));

//         // First, apply any time decay to L
//         _applyDecay(poolId);

//         // Then update reserves
//         market.reserveX += amountX;
//         market.reserveY += amountY;

//         // Example of recalculating L:
//         // Let sum = X + Y
//         // eq ~ sum/2  => L = eq / phi(0) => L = sum/(2 * phi(0))
//         // Or any formula you prefer:
//         int256 sumXY = market.reserveX + market.reserveY;
//         // clamp
//         if (sumXY < 0) sumXY = 0;

//         int256 newL = (sumXY * int256(1e18)) / (2 * PHI0);
//         if (newL < 0) newL = 0; // keep safe
//         market.liquidityFactor = newL;

//         emit LiquidityAdded(poolId, amountX, amountY, newL);
//     }

//     function removeLiquidity(PoolKey calldata key, int256 amountX, int256 amountY) external {
//         require(amountX >= 0 && amountY >= 0, "No negative withdrawal");

//         bytes32 poolId = _getPoolId(key);
//         Market storage market = markets[poolId];
//         require(market.isInitialized, "Not init");

//         require(market.reserveX >= amountX, "Insufficient X");
//         require(market.reserveY >= amountY, "Insufficient Y");

//         // Optionally decay L before removing. Adjust as you see fit:
//         _applyDecay(poolId);

//         // Move tokens out
//         poolManager.unlock(abi.encode(msg.sender, key.currency0, key.currency1, amountX, amountY, false));

//         // update
//         market.reserveX -= amountX;
//         market.reserveY -= amountY;

//         emit LiquidityRemoved(poolId, amountX, amountY);
//     }

//     function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
//         (address payer, Currency currency0, Currency currency1, uint256 amountX, uint256 amountY, bool add) =
//             abi.decode(data, (address, Currency, Currency, uint256, uint256, bool));

//         if (add) {
//             // user -> pool
//             poolManager.sync(currency0);
//             IERC20(Currency.unwrap(currency0)).transferFrom(payer, address(poolManager), amountX);
//             poolManager.settle();

//             poolManager.sync(currency1);
//             IERC20(Currency.unwrap(currency1)).transferFrom(payer, address(poolManager), amountY);
//             poolManager.settle();

//             // Optionally mint some form of "receipt" if you like
//             poolManager.mint(address(this), currency0.toId(), amountX);
//             poolManager.mint(address(this), currency1.toId(), amountY);
//         } else {
//             // burn from this hook
//             poolManager.burn(payer, currency0.toId(), amountX);
//             poolManager.burn(payer, currency1.toId(), amountY);

//             // manager -> user
//             poolManager.sync(currency0);
//             IERC20(Currency.unwrap(currency0)).transfer(payer, amountX);
//             poolManager.settle();

//             poolManager.sync(currency1);
//             IERC20(Currency.unwrap(currency1)).transfer(payer, amountY);
//             poolManager.settle();
//         }
//         return "";
//     }

//     // --------------------------------------------------
//     // Views
//     // --------------------------------------------------
//     function getMarketState(bytes32 poolId)
//         external
//         view
//         returns (int256 reserveX, int256 reserveY, int256 liquidityFactor, int256 decayRate, uint256 lastUpdate)
//     {
//         Market storage m = markets[poolId];
//         require(m.isInitialized, "Not init");
//         return (m.reserveX, m.reserveY, m.liquidityFactor, m.decayRate, m.lastUpdate);
//     }

//     function getCurrentPrice(bytes32 poolId) external view returns (int256) {
//         Market storage m = markets[poolId];
//         require(m.isInitialized, "Not init");
//         int256 diff = (m.reserveY - m.reserveX);
//         int256 z = (diff * m.liquidityFactor) / 1e18;
//         return z.cdf(); // pm-AMM "price" in [0,1]
//     }

//     // --------------------------------------------------
//     // A Simple Exp Function in 1e18 (for Decay)
//     // --------------------------------------------------
//     /**
//      * @dev Example of a fixed-point exponential function (expWad) in solidity.
//      *      You can also use a known library (e.g. solmate’s FixedPointMathLib, etc.).
//      *      This is a minimal version for demonstration.
//      */
//     function _expWad(int256 x) internal pure returns (int256) {
//         // If x <= -42 in 1e18, the result is effectively zero in typical double-precision.
//         // If x >= +135, it likely overflows 2**255.
//         // You can clamp or revert as desired.  Below is a naive version:
//         if (x > 135305999368893231589) revert("exp overflow");
//         if (x < -42139678854452767551) {
//             return 0;
//         }
//         // Taylor expansion or precompiled approach.
//         // For brevity, here’s a simple approach using solmate’s code structure:
//         // (In practice, just import a well-tested library.)
//         // -- see https://github.com/Rari-Capital/solmate/blob/main/src/utils/FixedPointMathLib.sol
//         // for a more complete, optimized version.
//         // This placeholder returns an approximation: e^(x/1e18).
//         // For a production system, do use a robust library version.

//         // We'll do a quick exponent approximation by "pow2(e * x/1e18)" or something similar.
//         // For clarity, I'll just illustrate a minimal approach:
//         int256 ONE_18 = 1e18;
//         // We convert x to double in normal units
//         // NOTE: This is extremely minimal / approximate.
//         // Prefer a real fixed-point exponential library in practice.

//         // Use a quick series expansion or call the built-in if your environment has it.
//         // Here we do an extremely rough approach:
//         // exponent in double = x/1e18
//         // return int256( real_exp( double(x)/1e18 ) * 1e18 );

//         // A simple bounding approach: we step around 0.
//         // This is purely for demonstration. Replace with something better!
//         // e^0 = 1
//         if (x == 0) return ONE_18;
//         // If x is small, approximate linearly
//         // ...
//         // [In real code, do a proper approximation or reference a known library.]

//         // For demonstration, let’s show an extremely naive approach:
//         int256 xx = x / 1e14; // scale down some for exponent
//         // convert to int => in practice, use a floating approximation
//         // obviously naive, but enough to show the structure
//         int256 eApprox = int256(10 ** uint256((uint256(xx) / 434294)));
//         // This is nonsense for many x. REPLACE with a real method.

//         // ensure we scale back up to 1e18
//         return int256(eApprox);
//     }
// }
