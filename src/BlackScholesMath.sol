// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title BlackScholesMath
 * @notice Illustrative library that:
 *   1) Approximates alpha(T) = T^(0.625) in fixed-point.
 *   2) Approximates normal PDF and CDF.
 *   3) Provides a function to compute the "Black–Scholes–like" invariant
 *   4) Includes a small iterative root-finder to solve for Yv_new in a swap.
 *
 * WARNING: Not production-ready. The normal CDF, PDF, and root-solver
 * are naive approximations for demonstration purposes.
 */
library BlackScholesMath {
    // -----------------------------------
    // Fixed-Point Utilities
    // -----------------------------------
    // We'll use 1e18-based fixed-point for demonstration.
    uint256 internal constant WAD = 1e18;
    uint256 internal constant HALF_WAD = 5e17;
    uint256 internal constant TWO_WAD = 2e18;
    uint256 internal constant PI = 3141592653589793000; // ~3.141592653589793

    /**
     * @notice Wad-based exponent approximation for x in 1e18 fixed point
     * @dev Approximate e^(x/1e18). Very naive approach, not production safe.
     */
    function expWad(int256 x) internal pure returns (uint256) {
        // For demonstration, use a rough series expansion.
        // Better: use a robust library like PRBMath or solmate's wadExp.
        // Here, we only do a truncated series of e^x = 1 + x + x^2/2! + ...
        // BEWARE of large x causing overflow.

        // Limit x to a safe range to avoid extreme overflows.
        if (x > 135305999368893231589) {
            // exp(135.305999...) ~ 2^128
            return type(uint256).max;
        }
        if (x < -135305999368893231589) {
            return 0;
        }

        // Convert x from 1e18 scale to normal floating "like" scale
        // so we do expansions in double precision style. This is a toy example.
        // For better results, do a high-precision method.
        // We'll do expansions in int256 then convert to 1e18 at the end.
        int256 term = int256(WAD); // current term of series
        int256 sum = int256(WAD); // 1.0 in 1e18
        int256 n = 1;
        for (uint256 i = 1; i < 20; i++) {
            term = (term * x) / int256(WAD * i);
            sum += term;
            // break early if term is tiny
            if (term > -100 && term < 100) {
                break;
            }
            n++;
        }

        if (sum < 0) {
            // e^x can't be negative
            return 0;
        }
        return uint256(sum);
    }

    /**
     * @notice Raises x^(y) in 1e18 fixed point, for x,y in 1e18
     * @dev Returns a 1e18 fixed-point result. Very naive exponent approach: e^(y*ln(x))
     *      This is for demonstration only.
     */
    function powWad(uint256 x, uint256 y) internal pure returns (uint256) {
        // x^y = e^(y * ln(x))
        // ln(x) in wad => multiply y in wad => exp => result
        if (x == 0) {
            return 0;
        }
        // compute ln(x)
        // naive: ln(x) ~ use a small approximation or direct series.
        // We'll just do "ln(x) = ln( x / WAD ), scaled by 1e18".
        // This is again extremely rough and not robust.
        // For a real approach, consider using a well-tested library.

        // Shift x so we do ln( x / 1e18 )
        // Use a small approximation: ln(1 + z) ~ z - z^2/2 + ...
        // Here we do a simpler approach with a single iteration if close to 1.
        // This is purely for demonstration, likely inaccurate for large x.

        // We'll do a piecewise approach:
        // if x ~ 1e18, ln(x) ~ 0
        // if x < 1e18, approximate
        // if x > 1e18, approximate
        // ...
        // In a real library, do a better job.

        int256 x_ = int256(x);
        int256 ln_x;
        if (x_ == int256(WAD)) {
            ln_x = 0; // ln(1) = 0
        } else if (x_ < int256(WAD)) {
            // 0 < x < 1 => ln(x) is negative
            // y = 1 - x_ / 1e18
            int256 diff = int256(WAD) - x_;
            // naive: ln(1 - diff) ~ - diff - diff^2/2 ...
            ln_x = -diff;
        } else {
            // x > 1 => ln(x) is positive
            int256 diff = x_ - int256(WAD);
            ln_x = diff;
        }

        // multiply ln_x * y, both in wad => scale down by 1e18
        int256 exponent = (ln_x * int256(y)) / int256(WAD);
        uint256 ePow = expWad(exponent);
        return ePow;
    }

    // -----------------------------------
    // 1) alpha(T) = T^(0.625)
    // -----------------------------------
    function alpha(uint256 T) internal pure returns (uint256) {
        // T^(5/8) = exp( (5/8) * ln(T) )
        // (5/8) in 1e18 = 0.625 * 1e18 = 625000000000000000
        // We'll do T^0.625 in 1e18 fixed point:
        uint256 exponent = 650000000000000000; // 0.625 * 1e18
        return powWad(T, exponent);
    }

    // -----------------------------------
    // 2) Normal PDF and CDF Approximations
    // -----------------------------------
    /**
     * @notice Standard Normal PDF = 1/sqrt(2π) * exp( -x^2/2 )
     * @param x input in 1e18 fixed point
     * @return pdf ~ in 1e18 scale
     */
    function phi(int256 x) internal pure returns (uint256) {
        // pdf(x) = 1/sqrt(2π) * e^(-x^2 / 2)
        // We do everything in wad.
        // 1 / sqrt(2π) ~ 0.3989424489 => ~0.3989424489 * 1e18 ~ 398942448900000000
        int256 oneOverSqrt2Pi = 398942448900000000;
        // compute -x^2/2 in wad
        // x^2 in wad => (x * x / WAD). Then /2 => /2 in normal integer
        int256 x2 = (x * x) / int256(WAD);
        int256 halfx2 = x2 / 2;
        // exponent = -halfx2
        int256 exponent = -halfx2;
        uint256 ePart = expWad(exponent);
        // multiply by 1/sqrt(2π)
        uint256 pdfVal = (uint256(oneOverSqrt2Pi) * ePart) / WAD;
        return pdfVal;
    }

    /**
     * @notice Very rough approximation to Standard Normal CDF
     * @dev This uses a polynomial (Abramowitz & Stegun or similar).
     */
    function Phi(int256 x) internal pure returns (uint256) {
        // Use an approximation for the CDF:
        // For x>=0:  1 - 1/(1 + p*x*(a1 + a2...)) e^(-x^2/2), etc.
        // For x<0:   = 1 - Phi(-x).
        // This is a naive “error function” style approximation for demonstration.
        if (x == 0) {
            return WAD / 2;
        } else if (x > 3500000000000000000) {
            // x>3.5 => ~1.0
            return WAD;
        } else if (x < -3500000000000000000) {
            // x<-3.5 => ~0.0
            return 0;
        }
        bool neg = (x < 0);
        if (neg) {
            x = -x;
        }
        // polynomial constants
        uint256 p = 332670552950000000; // ~0.33267
        uint256 b1 = 4368494900000000; // ~0.0043684949
        uint256 b2 = 142151175400000000; // ~0.1421511754
        // naive approach
        // t = 1 / (1 + p*x)
        uint256 px = (uint256(p) * uint256(x < 0 ? -x : x)) / WAD;
        uint256 denom = WAD + px;
        if (denom == 0) {
            return neg ? 0 : WAD;
        }
        uint256 t = (WAD * WAD) / denom;
        // approx cdf ~ 1 - (b1*t + b2*t^2 ) * e^(-x^2/2)
        int256 x2 = (x * x) / int256(WAD);
        int256 exponent = -(x2 / 2);
        uint256 ePart = expWad(exponent);
        uint256 t1 = (b1 * t) / WAD;
        uint256 t2 = ((b2 * t) / WAD * t) / WAD;
        uint256 poly = t1 + t2;
        uint256 cdfPos = WAD - ((poly * ePart) / WAD);
        if (cdfPos > WAD) {
            cdfPos = WAD;
        }
        if (neg) {
            // cdf(-x) = 1 - cdf(x)
            return WAD - cdfPos;
        } else {
            return cdfPos;
        }
    }

    // -----------------------------------
    // 3) The Black–Scholes–like Invariant
    // F(L, Xv, Yv, T) = (Yv - Xv)*Phi( (Yv - Xv)/(L*sqrt(T)) )
    //                   + L*sqrt(T)*phi( (Yv - Xv)/(L*sqrt(T)) )
    //                   - Yv
    // -----------------------------------
    function blackScholesInvariant(uint256 L, uint256 Xv, uint256 Yv, uint256 T) internal pure returns (int256) {
        // z = Yv - Xv
        int256 z = int256(Yv) - int256(Xv);

        // comp = L * sqrt(T).
        // We'll do sqrt(T) in wad => T^(1/2).
        uint256 sqrtT = powWad(T, 500000000000000000); // T^0.5
        uint256 comp = (L * sqrtT) / WAD;

        // if comp ~ 0, return a large # so solver can shift away
        if (comp == 0) {
            return 1e18 * 1000;
        }

        // Arg for phi/Phi: (z / comp) in 1e18
        int256 arg = (z * int256(WAD)) / int256(comp);

        uint256 cdfVal = Phi(arg); // in 1e18
        uint256 pdfVal = phi(arg); // in 1e18

        // (z * Phi(z/comp)) in 1e18 => z in int256, cdfVal in wad => z * cdfVal / 1e18
        int256 term1 = (z * int256(cdfVal)) / int256(WAD);

        // L * sqrt(T) * phi(...) => comp * pdfVal
        int256 term2 = (int256(comp) * int256(pdfVal)) / int256(WAD);

        // sum => term1 + term2 - Yv
        int256 sum_ = term1 + term2 - int256(Yv);

        return sum_;
    }

    // -----------------------------------
    // 4) Solve for Yv_new after a swap
    // We do a small Newton or bisection iteration:
    //    blackScholesInvariant(L, Xv_new, Yv_new, T) = 0
    // for Yv_new
    // -----------------------------------
    function solveForYvNew(uint256 L, uint256 Xv_new, uint256 Yv_initialGuess, uint256 T)
        internal
        pure
        returns (uint256)
    {
        // We'll do a simple bisection approach around [0, 2*Yv_initialGuess]
        // or so. If Yv_initialGuess is large, we can expand. This is naive.
        // In production, you might do a better bracket or a better numeric method.

        uint256 left = 0;
        uint256 right = 2 * Yv_initialGuess + 1;
        if (right == 0) {
            right = 1;
        }

        for (uint256 i = 0; i < 64; i++) {
            uint256 mid = (left + right) / 2;
            int256 f_mid = blackScholesInvariant(L, Xv_new, mid, T);

            if (f_mid > 0) {
                // if f_mid>0 => we want to increase Yv_new => move left up
                left = mid + 1;
            } else {
                right = mid;
            }
        }

        return right;
    }
}
