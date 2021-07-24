pragma solidity 0.7.6;
pragma abicoder v2;

import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3Factory } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import { TickMath } from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import { PositionKey } from "@uniswap/v3-periphery/contracts/libraries/PositionKey.sol";
import { LiquidityAmounts } from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import { PoolAddress } from "@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";
import { FixedPoint96 } from "@uniswap/v3-core/contracts/libraries/FixedPoint96.sol";
import { FullMath } from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import { BitMath } from "@uniswap/v3-core/contracts/libraries/BitMath.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/SafeCast.sol";
import { SafeMath } from "@openzeppelin/contracts/math/SafeMath.sol";

/**
 * Uniswap's v3 pool: token0 & token1
 * -> token0's price = token1 / token0; tick index = log(1.0001, token0's price)
 * Our system: base & quote
 * -> base's price = quote / base; tick index = log(1.0001, base price)
 * Figure out: (base, quote) == (token0, token1) or (token1, token0)
 */
library UniswapV3Broker {
    using SafeCast for uint256;
    using SafeMath for uint256;
    using SafeCast for uint128;
    using SafeCast for int256;

    struct AddLiquidityParams {
        address pool;
        address baseToken;
        address quoteToken;
        int24 lowerTick;
        int24 upperTick;
        uint256 base;
        uint256 quote;
    }

    struct AddLiquidityResponse {
        uint256 base;
        uint256 quote;
        uint128 liquidity;
        uint256 feeGrowthInsideQuoteX128;
    }

    struct RemoveLiquidityParams {
        address pool;
        int24 lowerTick;
        int24 upperTick;
        uint128 liquidity;
    }

    struct RemoveLiquidityResponse {
        uint256 base; // amount of base token received from burning the liquidity (excl. fee)
        uint256 quote; // amount of quote token received from burning the liquidity (excl. fee)
        uint256 feeGrowthInsideQuoteX128;
    }

    struct SwapParams {
        address pool;
        address baseToken;
        address quoteToken;
        bool isBaseToQuote;
        bool isExactInput;
        uint256 amount;
        uint160 sqrtPriceLimitX96; // price slippage protection
    }

    struct SwapResponse {
        uint256 base;
        uint256 quote;
        uint256 fee;
    }

    function addLiquidity(AddLiquidityParams memory params) internal returns (AddLiquidityResponse memory response) {
        // zero inputs
        require(params.base > 0 || params.quote > 0, "UB_ZIs");

        {
            // get the equivalent amount of liquidity from amount0 & amount1 with current price
            response.liquidity = LiquidityAmounts.getLiquidityForAmounts(
                getSqrtMarkPriceX96(params.pool),
                TickMath.getSqrtRatioAtTick(params.lowerTick),
                TickMath.getSqrtRatioAtTick(params.upperTick),
                params.base,
                params.quote
            );
            // TODO revision needed. We might not want to revert on zero liquidity but not sure atm
            // UB_ZL: zero liquidity
            require(response.liquidity > 0, "UB_ZL");
        }

        {
            // call mint()
            bytes memory data = abi.encode(params.baseToken);
            (uint256 addedAmount0, uint256 addedAmount1) =
                IUniswapV3Pool(params.pool).mint(
                    address(this),
                    params.lowerTick,
                    params.upperTick,
                    response.liquidity,
                    data
                );

            // fetch the fee growth state if this has liquidity
            uint256 feeGrowthInside1LastX128 = _getFeeGrowthInsideLast(params.pool, params.lowerTick, params.upperTick);

            response.base = addedAmount0;
            response.quote = addedAmount1;
            response.feeGrowthInsideQuoteX128 = feeGrowthInside1LastX128;
        }
    }

    function removeLiquidity(RemoveLiquidityParams memory params)
        internal
        returns (RemoveLiquidityResponse memory response)
    {
        // call burn(), this will only update tokensOwed instead of transfer the token
        (uint256 amount0Burned, uint256 amount1Burned) =
            IUniswapV3Pool(params.pool).burn(params.lowerTick, params.upperTick, params.liquidity);

        // call collect to `transfer` tokens to CH, the amount including every trader pooled into the same range
        IUniswapV3Pool(params.pool).collect(
            address(this),
            params.lowerTick,
            params.upperTick,
            type(uint128).max,
            type(uint128).max
        );

        // TODO: feeGrowthInside{01}LastX128 would be reset to 0 after pool.burn(0)?
        // fetch the fee growth state if this has liquidity
        uint256 feeGrowthInside1LastX128 = _getFeeGrowthInsideLast(params.pool, params.lowerTick, params.upperTick);

        // make base & quote into the right order
        response.base = amount0Burned;
        response.quote = amount1Burned;
        response.feeGrowthInsideQuoteX128 = feeGrowthInside1LastX128;
    }

    function swap(SwapParams memory params) internal returns (SwapResponse memory response) {
        // zero input
        require(params.amount > 0, "UB_ZI");

        // UniswapV3Pool will use a signed value to determine isExactInput or not.
        int256 specifiedAmount = params.isExactInput ? params.amount.toInt256() : -params.amount.toInt256();

        // FIXME: need confirmation
        // signedAmount0 & signedAmount1 are deltaAmount, in the perspective of the pool
        // > 0: pool gets; user pays
        // < 0: pool provides; user gets
        (int256 signedAmount0, int256 signedAmount1) =
            IUniswapV3Pool(params.pool).swap(
                address(this),
                params.isBaseToQuote,
                specifiedAmount,
                // FIXME: suppose the reason is for under/overflow but need confirmation
                params.sqrtPriceLimitX96 == 0
                    ? (params.isBaseToQuote ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                    : params.sqrtPriceLimitX96,
                abi.encode(params.baseToken)
            );

        uint256 amount0 = signedAmount0 < 0 ? (-signedAmount0).toUint256() : signedAmount0.toUint256();
        uint256 amount1 = signedAmount1 < 0 ? (-signedAmount1).toUint256() : signedAmount1.toUint256();

        // isExactInput = true, isZeroForOne = true => exact token0
        // isExactInput = false, isZeroForOne = false => exact token0
        // isExactInput = false, isZeroForOne = true => exact token1
        // isExactInput = true, isZeroForOne = false => exact token1
        uint256 exactAmount = params.isExactInput == params.isBaseToQuote ? amount0 : amount1;
        // FIXME: why is this check necessary for exactOutput but not for exactInput?
        // it's technically possible to not receive the full output amount,
        // so if no price limit has been specified, require this possibility away
        // incorrect output amount
        if (!params.isExactInput && params.sqrtPriceLimitX96 == 0) require(exactAmount == params.amount, "UB_IOA");

        uint256 amountForFee = params.isBaseToQuote ? amount0 : amount1;
        (response.base, response.quote, response.fee) = (amount0, amount1, calcFee(address(params.pool), amountForFee));
    }

    function getPool(
        address factory,
        address quoteToken,
        address baseToken,
        uint24 uniswapFeeRatio
    ) internal view returns (address) {
        PoolAddress.PoolKey memory poolKeys = PoolAddress.getPoolKey(quoteToken, baseToken, uniswapFeeRatio);
        return IUniswapV3Factory(factory).getPool(poolKeys.token0, poolKeys.token1, uniswapFeeRatio);
    }

    function getTickSpacing(address pool) internal view returns (int24 tickSpacing) {
        tickSpacing = IUniswapV3Pool(pool).tickSpacing();
    }

    function getUniswapFeeRatio(address pool) internal view returns (uint24 feeRatio) {
        feeRatio = IUniswapV3Pool(pool).fee();
    }

    function getLiquidity(address pool) internal view returns (uint128 liquidity) {
        liquidity = IUniswapV3Pool(pool).liquidity();
    }

    // note assuming base token == token0
    function getSqrtMarkPriceX96(address pool) internal view returns (uint160 sqrtMarkPrice) {
        (sqrtMarkPrice, , , , , , ) = IUniswapV3Pool(pool).slot0();
    }

    // note assuming base token == token0
    function getTick(address pool) internal view returns (int24 tick) {
        (, tick, , , , , ) = IUniswapV3Pool(pool).slot0();
    }

    // note assuming base token == token0
    function getIsTickInitialized(address pool, int24 tick) internal view returns (bool initialized) {
        (, , , , , , , initialized) = IUniswapV3Pool(pool).ticks(tick);
    }

    // note assuming base token == token0
    function getTickLiquidityNet(address pool, int24 tick) internal view returns (int128 liquidityNet) {
        (, liquidityNet, , , , , , ) = IUniswapV3Pool(pool).ticks(tick);
    }

    // note assuming base token == token0
    function getSqrtMarkTwapX96(address pool, uint256 twapInterval) internal view returns (uint160) {
        if (twapInterval == 0) {
            return getSqrtMarkPriceX96(pool);
        }

        uint32[] memory secondsAgos = new uint32[](2);

        // solhint-disable-next-line not-rely-on-time
        secondsAgos[0] = uint32(twapInterval);
        secondsAgos[1] = uint32(0);
        (int56[] memory tickCumulatives, ) = IUniswapV3Pool(pool).observe(secondsAgos);

        return TickMath.getSqrtRatioAtTick(int24((tickCumulatives[1] - tickCumulatives[0]) / uint32(twapInterval)));
    }

    /// copied from UniswapV3-periphery
    /// @notice Computes the amount of token0 for a given amount of liquidity and a price range
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary
    /// @param liquidity The liquidity being valued
    /// @return amount0 The amount of token0
    function getAmount0ForLiquidity(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        return
            FullMath.mulDiv(
                uint256(liquidity) << FixedPoint96.RESOLUTION,
                sqrtRatioBX96 - sqrtRatioAX96,
                sqrtRatioBX96
            ) / sqrtRatioAX96;
    }

    /// copied from UniswapV3-periphery
    /// @notice Computes the amount of token1 for a given amount of liquidity and a price range
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary
    /// @param liquidity The liquidity being valued
    /// @return amount1 The amount of token1
    function getAmount1ForLiquidity(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        return FullMath.mulDiv(liquidity, sqrtRatioBX96 - sqrtRatioAX96, FixedPoint96.Q96);
    }

    // assuming token1 == quote token
    function getFeeGrowthInsideQuote(
        address pool,
        int24 lowerTick,
        int24 upperTick,
        int24 currentTick
    ) internal view returns (uint256 feeGrowthInsideQuoteX128) {
        (, , , uint256 lowerFeeGrowthOutside1X128, , , , ) = IUniswapV3Pool(pool).ticks(lowerTick);
        (, , , uint256 upperFeeGrowthOutside1X128, , , , ) = IUniswapV3Pool(pool).ticks(upperTick);
        uint256 feeGrowthGlobal1X128 = IUniswapV3Pool(pool).feeGrowthGlobal1X128();

        uint256 feeGrowthBelow =
            currentTick >= lowerTick ? lowerFeeGrowthOutside1X128 : feeGrowthGlobal1X128 - lowerFeeGrowthOutside1X128;
        uint256 feeGrowthAbove =
            currentTick < upperTick ? upperFeeGrowthOutside1X128 : feeGrowthGlobal1X128 - upperFeeGrowthOutside1X128;

        // this value can underflow per feeGrowthOutside specs
        return feeGrowthGlobal1X128 - feeGrowthBelow - feeGrowthAbove;
    }

    function calcFee(address pool, uint256 amount) internal view returns (uint256) {
        return FullMath.mulDivRoundingUp(amount, IUniswapV3Pool(pool).fee(), 1e6);
    }

    // note assuming base token == token0
    function getTickBitmap(address pool, int16 wordPos) internal view returns (uint256 tickBitmap) {
        return IUniswapV3Pool(pool).tickBitmap(wordPos);
    }

    // copied from UniswapV3-core
    function getNextInitializedTickWithinOneWord(
        address pool,
        int24 tick,
        int24 tickSpacing,
        bool lte
    ) internal view returns (int24 next, bool initialized) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--; // round towards negative infinity

        if (lte) {
            (int16 wordPos, uint8 bitPos) = _position(compressed);
            // all the 1s at or to the right of the current bitPos
            uint256 mask = (1 << bitPos) - 1 + (1 << bitPos);
            uint256 masked = getTickBitmap(pool, wordPos) & mask;

            // if there are no initialized ticks to the right of or at the current tick, return rightmost in the word
            initialized = masked != 0;
            // overflow/underflow is possible, but prevented externally by limiting both tickSpacing and tick
            next = initialized
                ? (compressed - int24(bitPos - BitMath.mostSignificantBit(masked))) * tickSpacing
                : (compressed - int24(bitPos)) * tickSpacing;
        } else {
            // start from the word of the next tick, since the current tick state doesn't matter
            (int16 wordPos, uint8 bitPos) = _position(compressed + 1);
            // all the 1s at or to the left of the bitPos
            uint256 mask = ~((1 << bitPos) - 1);
            uint256 masked = getTickBitmap(pool, wordPos) & mask;

            // if there are no initialized ticks to the left of the current tick, return leftmost in the word
            initialized = masked != 0;
            // overflow/underflow is possible, but prevented externally by limiting both tickSpacing and tick
            next = initialized
                ? (compressed + 1 + int24(BitMath.leastSignificantBit(masked) - bitPos)) * tickSpacing
                : (compressed + 1 + int24(type(uint8).max - bitPos)) * tickSpacing;
        }
    }

    function _getFeeGrowthInsideLast(
        address pool,
        int24 lowerTick,
        int24 upperTick
    ) private view returns (uint256 feeGrowthInside1LastX128) {
        // FIXME
        // check if the case sensitive of address(this) break the PositionKey computing
        // get this' positionKey
        bytes32 positionKey = PositionKey.compute(address(this), lowerTick, upperTick);

        // get feeGrowthInside{0,1}LastX128
        // feeGrowthInside{0,1}LastX128 would be kept in position even after removing the whole liquidity
        (, , feeGrowthInside1LastX128, , ) = IUniswapV3Pool(pool).positions(positionKey);
    }

    function _position(int24 tick) private pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(tick >> 8);
        bitPos = uint8(tick % 256);
    }
}
