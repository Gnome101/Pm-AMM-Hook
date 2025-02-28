// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";

/**
 * @title VirtualReservesLib
 * @notice Provides helper functions to compute “virtual reserves” for the pm-AMM,
 *         now incorporating time decay on the liquidity factor L.
 */
library VirtualReservesLib {
    // ------------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------------
    /// @dev phi(0) = 1/sqrt(2*pi) ≈ 0.398942280401432677 in 1e18 fixed point
    int256 constant PHI0 = 398942280401432677;

    // ------------------------------------------------------------------------
    // Primary Function
    // ------------------------------------------------------------------------
    /**
     * @notice Computes virtual reserves `(vX, vY)` at the current timestamp,
     *         decaying `liquidityFactor` from its last update time.
     * @dev If you want to store and reuse the decayed `LAfterDecay`, you may return it
     *      from this function and persist in your main contract’s storage.
     *
     * Requirements:
     *  - `reserveX` and `reserveY` are actual (on-chain) reserves in 1e18 scale.
     *  - `liquidityFactor` is the old L (in 1e18) at `lastTimestamp`.
     *  - `decayRate` is the per-second rate (1e18 = “1.0 per second”).
     *  - This function:
     *       1) Applies time decay to L: `LAfterDecay = L * exp(-decayRate * dt)`
     *       2) Computes eq = LAfterDecay * PHI0.
     *       3) Ensures eq >= |(reserveY - reserveX)|/2 to avoid negative vX/vY.
     *       4) Returns `(vX, vY, LAfterDecay)`.
     */
    function getVirtualReserves(
        int256 reserveX,
        int256 reserveY,
        int256 liquidityFactor, // L before decay
        int256 decayRate, // 1e18 scale, e.g. 1e16 => 0.01/sec
        uint256 lastTimestamp,
        uint256 currentTimestamp
    ) internal pure returns (int256 vX, int256 vY, int256 LAfterDecay) {
        // ----------------------------
        // 1) Compute decayed L
        // ----------------------------
        uint256 dt = (currentTimestamp > lastTimestamp) ? (currentTimestamp - lastTimestamp) : 0;
        int256 decayedL = liquidityFactor;

        if (decayRate != 0 && dt > 0) {
            // exponent = -decayRate * dt (in 1e18)
            int256 exponent = -(decayRate * int256(dt));
            // decayedL = L0 * expWad(exponent)
            decayedL = mulWadDown(liquidityFactor, expWad(exponent));
        }

        // If something made L negative, clamp it to zero.
        if (decayedL < 0) {
            decayedL = 0;
        }

        LAfterDecay = decayedL;

        // ----------------------------
        // 2) eq = decayedL * PHI0
        // ----------------------------
        int256 eq = mulWadDown(decayedL, PHI0);
        // eq is the “balanced” half-sum in the pm-AMM’s virtual domain

        // ----------------------------
        // 3) Check difference constraints
        // ----------------------------
        int256 delta = reserveY - reserveX;
        int256 halfDelta = delta / 2;

        // eq must be >= abs(delta)/2 to ensure vX,vY >= 0
        if (eq < 0) {
            revert("VRLib: eq < 0 after decay; invalid L or phi(0) scaling");
        }
        if (eq < _abs(halfDelta)) {
            revert("VRLib: insufficient L to keep virtual reserves nonnegative");
        }

        // ----------------------------
        // 4) vX = eq - delta/2, vY = eq + delta/2
        // ----------------------------
        vX = eq - halfDelta;
        vY = eq + halfDelta;

        console.log("reserveX:", uint256(_pos(reserveX)));
        console.log("reserveY:", uint256(_pos(reserveY)));
        console.log("LBeforeDecay:", uint256(_pos(liquidityFactor)));
        console.log("LAfterDecay:", uint256(_pos(LAfterDecay)));
        console.log("delta:", delta < 0 ? uint256(-delta) : uint256(delta));
        console.log("vX:", vX < 0 ? uint256(-vX) : uint256(vX));
        console.log("vY:", vY < 0 ? uint256(-vY) : uint256(vY));
    }

    // ------------------------------------------------------------------------
    // Internal Helpers
    // ------------------------------------------------------------------------

    /**
     * @notice A minimal exponent function in 1e18 fixed-point,
     *         e.g. `expWad(x)` approximates `e^(x/1e18)`.
     * @dev In production, prefer a robust library (e.g. Solmate’s `FixedPointMathLib`).
     */
    function expWad(int256 x) internal pure returns (int256) {
        // Very naive bounding
        //  e^(x/1e18) for x < -42e18 => ~0
        //  for x > +135e18 => overflow
        if (x <= -42139678854452767551) return 0; // <= -42 in 1e18
        if (x >= 135305999368893231589) revert("expWad overflow");

        // We’ll do a short polynomial or rational approximation here just as a placeholder.
        // Real usage: import a well-tested fixed-point library.
        // For demonstration, let's do an extremely rough approach:
        // e^x ~= 1 + x/1e18 + (x^2)/(2*1e36) + ...
        // This is not accurate for large x, so use real expansions in practice.

        // We'll do a small series expansion up to 5 terms (just as an example):
        int256 ONE_18 = 1e18;
        int256 x_1e18 = x; // x is 1e18 scale

        // term1 = 1
        int256 result = ONE_18;

        // term2 = x
        int256 term = x_1e18;
        result += term;

        // term3 = x^2 / 2!
        term = (term * x_1e18) / ONE_18; // x^2
        term = term / 2; // /2!
        result += term;

        // term4 = x^3 / 3!
        term = (term * x_1e18) / ONE_18; // x^3
        term = term / 3; // /3!
        result += term;

        // term5 = x^4 / 4!
        term = (term * x_1e18) / ONE_18; // x^4
        term = term / 4; // /4!
        result += term;

        // And so on if you want more accuracy.
        // Return the sum in 1e18 scale
        return result < int256(0) ? int256(0) : result;
    }

    /**
     * @notice Multiplies two 1e18 fixed-point numbers, rounding down.
     */
    function mulWadDown(int256 a, int256 b) internal pure returns (int256) {
        return (a * b) / int256(1e18);
    }

    /**
     * @dev Simple absolute value helper for int256
     */
    function _abs(int256 x) private pure returns (int256) {
        return x >= 0 ? x : -x;
    }

    /**
     * @dev Return x but ensure it's non-negative for console printing
     */
    function _pos(int256 x) private pure returns (int256) {
        return x < 0 ? int256(0) : x;
    }
}
