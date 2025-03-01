// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {BaseHook} from "./BaseHook.sol";
import {SafeCallback} from "@uniswap/v4-periphery/src/base/SafeCallback.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";
import {MockERC20} from "./MockERC20.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

import {FixedPointMathLib} from "src/FixedPointMathLib.sol";
import {Gaussian} from "lib/solstat/src/Gaussian.sol";
import {console} from "forge-std/console.sol";
import {DynamicPoolBasedMinter} from "src/DynamicPoolBasedMinter.sol";

contract Hook is BaseHook, SafeCallback {
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;

    // ------------------------------------------------
    // Storage
    // ------------------------------------------------

    struct PoolState {
        uint256 X_real; // Real reserve for token0
        uint256 Y_real; // Real reserve for token1
        uint256 L; // Black–Scholes–style liquidity parameter
            // uint256 T; // Expiry time in some 1e18 scale
            // uint256 PoolCreationTime; // Start time (optional usage)
    }

    /// @notice PoolId => current pool state
    mapping(PoolId => PoolState) public poolStates;

    /// @notice Track total outstanding “liquidity shares” for each pool
    mapping(PoolId => uint256) public totalLiquidityShares;

    /// @notice Track each user's liquidity shares per pool
    mapping(PoolId => mapping(address => uint256)) public userLiquidityShares;
    MockERC20 public USDC;

    constructor(IPoolManager poolManager_, MockERC20 erc20) SafeCallback(poolManager_) {
        USDC = erc20;
    }

    function _poolManager() internal view override returns (IPoolManager) {
        return poolManager;
    }

    DynamicPoolBasedMinter public dynamicMarket;

    function setMinter(DynamicPoolBasedMinter minter) public {
        dynamicMarket = minter;
    }
    // ------------------------------------------------
    // Hook Permissions
    // ------------------------------------------------

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ------------------------------------------------
    // 1) A new custom INITIALIZE function for T
    // ------------------------------------------------
    function getMarketState(PoolKey calldata key) external view returns (int256, int256, int256) {
        PoolId pid = key.toId();
        PoolState storage ps = poolStates[pid];
        return (int256(ps.X_real), int256(ps.Y_real), int256(ps.L));
    }

    // ------------------------------------------------
    // 2) BLACK–SCHOLES–LIKE INVARIANT & UTILS
    // ------------------------------------------------

    function blackScholesInvariant(uint256 L, uint256 Xv, uint256 Yv /*, uint256 T*/ )
        internal
        pure
        returns (int256 err)
    {
        // z = Yv - Xv
        int256 z = int256(Yv) - int256(Xv);

        // sqrtT = sqrt(T)
        // uint256 sqrtT = FixedPointMathLib.sqrtWad(T);
        // if (sqrtT == 0) return 1e27; // if T=0 => large error

        // comp = L * sqrtT
        uint256 comp = (L); /*(* sqrtT*/
        /// 1e18;
        if (comp == 0) return 1e27;

        // arg = z / comp in 1e18
        int256 arg = (z * int256(1e18)) / int256(comp);

        // cdfVal = Phi(arg)
        int256 cdfVal = Gaussian.cdf(arg);
        // pdfVal = phi(arg)
        int256 pdfVal = Gaussian.pdf(arg);

        // term1 = z * cdfVal / 1e18
        int256 term1 = (z * cdfVal) / 1e18;
        // term2 = comp * pdfVal / 1e18
        int256 term2 = (int256(comp) * pdfVal) / 1e18;

        err = term1 + term2 - int256(Yv);
    }

    function solveForYvNew(uint256 L, uint256 Xv, uint256 Yv0 /*, uint256 T*/ ) internal pure returns (uint256) {
        uint256 left = 0;
        uint256 right = 2 * Yv0 + 1;
        for (uint256 i = 0; i < 100; i++) {
            uint256 mid = (left + right) >> 1;
            int256 f_mid = blackScholesInvariant(L, Xv, mid /*, T*/ );
            // console.log("Iteration %d ", i);
            // console.log("Value %d ", f_mid);
            // console.log(left, "|", right);
            // console.log("L %d ", mid);

            if (f_mid < 0) {
                right = mid;
            } else if (f_mid > 0) {
                left = mid;
            }
            if (f_mid == 0) break;
        }
        return right;
    }

    /// @notice Example function to set or recompute L at the "inception" ratio.
    function solveLAtInception(uint256 X_real, uint256 Y_real /*, uint256 T */ ) internal pure returns (uint256) {
        if ( /*T == 0 || */ X_real == 0 || Y_real == 0) {
            // Edge-case: if T=0 or no tokens, just return 0 or something big
            // Adjust to your preference
            return 0;
        }
        // uint256 sqrtT = FixedPointMathLib.sqrtWad(T);
        // Scale to Xv, Yv
        uint256 Xv = X_real; //(X_real * sqrtT) / 1e18;
        uint256 Yv = Y_real; //(Y_real * sqrtT) / 1e18;

        // Simple big upper bound for L
        uint256 left = 1;
        uint256 right = 1e24;
        int256 prev_mid = 0;
        for (uint256 i = 0; i < 100; i++) {
            uint256 mid = (left + right) >> 1;
            int256 f_mid = blackScholesInvariant(mid, Xv, Yv /*, T*/ );
            // console.log("Iteration %d ", i);
            // console.log("Value %d ", f_mid);
            // console.log(left, "|", right);
            // console.log("L %d ", mid);

            if (f_mid > 0) {
                // means mid is too small, we need bigger L
                // right = mid - 1;
                right = mid;
            } else if (f_mid < 0) {
                // mid might be big enough
                // left = mid + 1;
                left = mid;
            }
            if (f_mid == 0) break;
            prev_mid = f_mid;
        }
        return right;
    }

    // ------------------------------------------------
    // 3) SWAP LOGIC
    // ------------------------------------------------

    function _beforeSwap(
        address, // caller
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata // extraData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        bool zeroForOne = params.zeroForOne;
        bool isExactInput = (params.amountSpecified < 0);

        uint256 swapAmount = isExactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        (Currency inC, Currency outC) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

        PoolId pid = key.toId();
        PoolState storage ps = poolStates[pid];
        // console.log(ps.T, block.timestamp, ps.PoolCreationTime);
        // Current real reserves
        uint256 Xr = ps.X_real;
        uint256 Yr = ps.Y_real;
        uint256 L_ = ps.L;
        // uint256 T_ = ps.T;
        // uint256 timeComponent = (ps.T - block.timestamp) * 1e18 / (ps.T - ps.PoolCreationTime);

        // console.log("Xr:", Xr);
        // console.log("Yr:", Yr);
        // console.log("L:", L_);
        // console.log("T:", timeComponent);

        // Inbound deposit
        uint256 newXr;
        uint256 newYr;
        if (zeroForOne) {
            newXr = Xr + swapAmount;
            newYr = Yr;
        } else {
            newXr = Xr;
            newYr = Yr + swapAmount;
        }

        // alpha(T) = sqrt(T)
        // uint256 sqrtT = FixedPointMathLib.sqrtWad(timeComponent);
        // uint256 alphaT = uint256(FixedPointMathLib.powWad(int256(timeComponent), int256(45 * 1e16)));
        // console.log("AlphaT:", alphaT);
        // console.log(uint256(55) * 1e16);
        uint256 Xv = Xr; //(Xr * alphaT) / 1e18;
        uint256 Yv = Yr; //(Yr * alphaT) / 1e18;

        // console.log("Xv:", Xv);
        // console.log("Yv:", Yv);
        // add deposit in "v-scale"
        uint256 Xv_new = Xv;
        uint256 Yv_new = Yv;
        if (zeroForOne) {
            // uint256 dXv = (swapAmount * alphaT) / 1e18;
            Xv_new = Xv + swapAmount;
        } else {
            // uint256 dYv = (swapAmount * alphaT) / 1e18;
            Yv_new = Yv + swapAmount;
        }

        // Solve for new needed out
        uint256 outAmt;
        // console.log("ZeroForOne:", zeroForOne);
        // console.log("Xv_new: %d", Xv_new);
        // console.log("Yv_new: %d", Yv_new);
        //36586369005839212439
        //34151006418859819652
        // L_ = solveLAtInception(Xv, Yv, 1e18);
        // console.log("L_:", L_);
        if (zeroForOne) {
            // X->Y
            uint256 Yv_new_sol = solveForYvNew(L_, Xv_new, Yv /*, timeComponent*/ );
            // console.log("Yv_new_sol: %d", Yv_new_sol);
            // console.log("Yv:", Yv);
            if (Yv < Yv_new_sol) revert("Negative output");
            // console.log(Yv, Yv_new_sol);
            uint256 dYv = Yv - Yv_new_sol;
            outAmt = dYv; //(dYv * 1e18) / alphaT;
            // console.log("dYv:", dYv);
            // console.log("OutAmt:", outAmt);
            newYr = Yr - outAmt;
        } else {
            // Y->X
            uint256 Xv_new_sol = solveForYvNew(L_, Yv_new, Xv /*, timeComponent*/ );
            // console.log("Xv_new_sol: %d", Xv_new_sol);

            if (Xv < Xv_new_sol) revert("Negative output");

            uint256 dXv = Xv - Xv_new_sol;
            outAmt = dXv; // (dXv * 1e18) / alphaT;
            // console.log("dYv:", dXv);
            // console.log("OutAmt:", outAmt);
            newXr = Xr - outAmt;
        }

        if (outAmt == 0) {
            revert("Zero output");
        }

        // Update pool storage
        ps.X_real = newXr;
        ps.Y_real = newYr;

        // Perform token movements in the manager's accounting
        poolManager.mint(address(this), inC.toId(), swapAmount);
        poolManager.burn(address(this), outC.toId(), outAmt);

        // Return swap delta
        int128 aIn = swapAmount.toInt128();
        int128 aOut = outAmt.toInt128();
        BeforeSwapDelta delta = isExactInput ? toBeforeSwapDelta(aIn, -aOut) : toBeforeSwapDelta(-aOut, aIn);
        ps.L = solveLAtInception(ps.X_real, ps.Y_real /*, 1e18*/ );
        return (BaseHook.beforeSwap.selector, delta, 0);
    }

    // ------------------------------------------------
    // 4) LIQUIDITY MANAGEMENT
    // ------------------------------------------------

    /// @dev We revert in the "standard" hook entry-points and push users to our custom flow
    function _beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert("Use addLiquidity()");
    }

    /**
     * @notice Add liquidity to the pool with your desired amounts.
     * @dev We’ll do the actual token transfers in `_unlockCallback`.
     */
    function addLiquidity(PoolKey calldata key, uint256 amtX, uint256 amtY) external {
        // Encode the "add" action in some way. For example, action=1
        // We pass user + pool info + amounts
        poolManager.unlock(
            abi.encode(
                /* action = */
                uint8(1),
                msg.sender,
                key.currency0,
                key.currency1,
                amtX,
                amtY,
                key.toId()
            )
        );
    }

    /**
     * @notice Remove liquidity by burning your share tokens in exchange for underlying reserves.
     * @dev The actual tokens are sent out in `_unlockCallback`.
     */
    function removeLiquidity(PoolKey calldata key, uint256 sharesToBurn) external {
        // Encode the "remove" action as action=2
        poolManager.unlock(
            abi.encode(
                /* action = */
                uint8(2),
                msg.sender,
                key.currency0,
                key.currency1,
                sharesToBurn,
                /* unused amtY param = */
                0,
                key.toId()
            )
        );
    }

    // ------------------------------------------------
    // 5) UNLOCK CALLBACK
    // ------------------------------------------------

    /**
     * @dev The "unlock callback" is called by the PoolManager after `poolManager.unlock(data)`.modif
     *      We decode `data`, figure out which flow (add or remove), and execute accordingly.
     */
    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        (uint8 action, address payer, Currency c0, Currency c1, uint256 amountA, uint256 amountBOrUnused, PoolId pid) =
            abi.decode(data, (uint8, address, Currency, Currency, uint256, uint256, PoolId));

        PoolState storage ps = poolStates[pid];

        if (action == 1) {
            // ----------------------------
            //  ACTION = 1 => ADD LIQUIDITY
            // ----------------------------
            // amountA = amtX, amountBOrUnused = amtY
            uint256 amtX = amountA;
            uint256 amtY = amountBOrUnused;

            // 1) Transfer user’s tokens into Manager
            //    Then Manager => Hook
            // (token0)
            poolManager.sync(c0);
            IERC20(Currency.unwrap(c0)).transferFrom(payer, address(poolManager), amtX);
            poolManager.settle();

            // (token1)
            poolManager.sync(c1);
            IERC20(Currency.unwrap(c1)).transferFrom(payer, address(poolManager), amtY);
            poolManager.settle();

            // 2) Mint to Hook's internal balance
            poolManager.mint(address(this), c0.toId(), amtX);
            poolManager.mint(address(this), c1.toId(), amtY);

            // 3) Update reserves in storage
            uint256 X_before = ps.X_real;
            uint256 Y_before = ps.Y_real;

            ps.X_real = X_before + amtX;
            ps.Y_real = Y_before + amtY;

            // 4) Mint liquidity shares to user
            //    For simplicity, we do a typical formula:
            //    If totalShares==0 => minted = amtX + amtY
            //    else minted = totalShares * min(amtX/X_before, amtY/Y_before)
            //    (You can pick your own approach)
            uint256 _total = totalLiquidityShares[pid];
            uint256 minted;
            if (_total == 0) {
                // bootstrap
                minted = amtX + amtY;
            } else {
                // pro rata
                uint256 mintX = (_total * amtX) / X_before;
                uint256 mintY = (_total * amtY) / Y_before;
                minted = (mintX < mintY) ? mintX : mintY;
            }
            totalLiquidityShares[pid] = _total + minted;
            userLiquidityShares[pid][payer] += minted;

            /* uint256 timeComponent = (ps.T - block.timestamp) * 1e18 / (ps.T - ps.PoolCreationTime); */
            ps.L = solveLAtInception(ps.X_real, ps.Y_real /*, timeComponent */ );
        } else if (action == 2) {
            // -------------------------------
            // ACTION = 2 => REMOVE LIQUIDITY
            // -------------------------------
            // amountA = sharesToBurn
            uint256 sharesToBurn = amountA;
            uint256 userBal = userLiquidityShares[pid][payer];
            require(sharesToBurn <= userBal, "Not enough shares");

            // 1) Figure out how much underlying to send out
            uint256 _total = totalLiquidityShares[pid];
            require(_total > 0, "No total shares");

            // Pro rata to user’s share
            uint256 X_out = (ps.X_real * sharesToBurn) / _total;
            uint256 Y_out = (ps.Y_real * sharesToBurn) / _total;
            // console.log(X_out, Y_out);
            // 2) Burn user’s shares
            userLiquidityShares[pid][payer] = userBal - sharesToBurn;
            totalLiquidityShares[pid] = _total - sharesToBurn;

            // 3) Update the pool's real reserves
            ps.X_real -= X_out;
            ps.Y_real -= Y_out;
            // console.log(X_out, Y_out);
            // 4) Burn tokens from the Hook’s internal balance
            //    so the manager “knows” these tokens are being pulled out
            // console.log(c0.balanceOf(address(this)));
            // console.log(c0.balanceOf(address(this)));
            poolManager.take(c0, address(this), X_out);
            poolManager.burn(address(this), c0.toId(), X_out);
            // console.log(c0.balanceOf(address(this)));
            poolManager.take(c1, address(this), Y_out);
            poolManager.burn(address(this), c1.toId(), Y_out);

            // console.log("fail");
            // 5) Actually transfer underlying tokens out to user
            //    Typically you do manager.sync + transfer + settle or
            //    call manager's safeTransferFrom if available.
            //    We'll replicate your addLiquidity style:
            // console.log(c0.balanceOf(address(this)));

            // console.log("fail2");
            // console.log(c0.balanceOf(address(this)));
            IERC20(Currency.unwrap(c0)).transfer(payer, X_out);
            // console.log("faila");

            poolManager.settle();
            // console.log("failb");

            poolManager.sync(c1);
            // console.log("fail3");
            IERC20(Currency.unwrap(c1)).transfer(payer, Y_out);
            poolManager.settle();
            // console.log("fail4");
            // 6) Optionally recompute L, if that's part of your design
            /*  uint256 timeComponent = (ps.T - block.timestamp) * 1e18 / (ps.T - ps.PoolCreationTime);*/
            // console.log("fail5");
            ps.L = solveLAtInception(ps.X_real, ps.Y_real /*, timeComponent */ );
        } else {
            revert("Unknown action");
        }

        return "";
    }

    // ------------------------------------------------
    // 6) AUX VIEW: GET POOL PRICE (unchanged)
    // ------------------------------------------------

    /**
     * @notice Returns the current pool price (marginal rate for a small zeroForOne swap) in 1e18 fixed-point.
     * @param key The pool key.
     * @return price The price computed as dY/dX based on the Black–Scholes–like invariant.
     */
    function getPoolPrice(PoolKey calldata key) external view returns (uint256 price) {
        PoolId pid = key.toId();
        PoolState storage ps = poolStates[pid];
        /*  require(ps.T > 0, "Pool time not initialized");
        uint256 timeComponent = (ps.T - block.timestamp) * 1e18 / (ps.T - ps.PoolCreationTime);*/

        // Compute √T
        /*uint256 sqrtT = FixedPointMathLib.sqrtWad(timeComponent);
        uint256 alphaT = uint256(FixedPointMathLib.powWad(int256(timeComponent), int256(55 * 1e17)));
        require(alphaT > 0, "alphaT is zero");
        require(sqrtT > 0, "sqrtT is zero");
        */
        // Scale the real reserves to "v-scale"
        uint256 Xv = ps.X_real; // (ps.X_real * alphaT) / 1e18;
        uint256 Yv = ps.Y_real; //(ps.Y_real * alphaT) / 1e18;
        console.log(Xv,Yv);
        return (Yv * 1e18) / Xv;
    }

    Market public market;

    function getMarket() public view returns (Market memory) {
        return market;
    }

    event MarketMade(address indexed maker, uint256 timestamp, uint256 startPrice);

    function MakeMarket(
        string calldata marketDescription,
        uint256 registrationDelay,
        uint256 marketLength,
        uint256 initialUSDC,
        uint256 startPrice
    ) public {
        emit MarketMade(msg.sender, block.timestamp, startPrice);
        USDC.transferFrom(msg.sender, address(this), initialUSDC);

        dynamicMarket.startMarket(initialUSDC, startPrice);

        market = Market({
            description: marketDescription,
            keyRegistrationExpiration: block.timestamp + registrationDelay,
            expiration: block.timestamp + registrationDelay + marketLength,
            c1: "",
            c2: "",
            publicKeys: new string[](0),
            partialDecripts: new string[](0),
            isFinalized: false,
            winner: false
        });
    }

    function submitKey(string calldata publicKey) public {
        require(block.timestamp < market.keyRegistrationExpiration, "Key registration period has expired");
        market.publicKeys.push(publicKey);
    }

    function getKeys() public view returns (string[] memory) {
        return market.publicKeys;
    }

    function submitPartialDecript(string calldata partialDecript) public {
        // require(block.timestamp > market.expiration, "Market has not ended");
        market.partialDecripts.push(partialDecript);
    }

    function modifyVote(bytes calldata newVote) public {
        (market.c1, market.c2) = abi.decode(newVote, (bytes, bytes));
    }

    function getDecryptionShares() public view returns (string[] memory) {
        return market.partialDecripts;
    }

    function getWinner() public view returns (bool) {
        return market.winner;
    }

    function isFinalized() public view returns (bool) {
        return market.isFinalized;
    }

    function chooseWinner(bool winner) public {
        require(market.isFinalized == false, "Market is already finalized");
        require(market.partialDecripts.length > 0, "No decryption shares");
        market.winner = winner;
        market.isFinalized = true;
    }
}

struct Market {
    string description;
    uint256 keyRegistrationExpiration;
    uint256 expiration;
    bytes c1;
    bytes c2;
    string[] publicKeys;
    string[] partialDecripts;
    bool isFinalized;
    bool winner;
}
